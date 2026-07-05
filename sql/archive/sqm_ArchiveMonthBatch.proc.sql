-- ============================================================================
-- sqm_ArchiveMonthBatch
-- Liegt in der QUELLDATENBANK (nicht master). Ein Aufruf = ein Batch: kopiert
-- per MERGE bis zu @BatchSize Zeilen eines einzelnen Monats (@YYYYMM) aus der
-- Quelltabelle in die (bereits partitionierte) Archiv-Tabelle einer anderen
-- Datenbank. WHEN MATCHED -> UPDATE, WHEN NOT MATCHED -> INSERT: dadurch ist
-- jeder Aufruf beliebig oft wiederholbar (idempotent), auch wenn eine Zeile
-- schon einmal archiviert wurde und sich seither in der Quelle geaendert hat.
--
-- @KeyColumns: eine oder mehrere (max. 4) durch Komma getrennte Spaltennamen,
-- in key_ordinal-Reihenfolge (z.B. N'VMTG,VID1,VID2,VSEQ'). Zusammen bilden
-- sie den (moeglicherweise zusammengesetzten) eindeutigen Schluessel fuer den
-- MERGE-Abgleich UND fuer die Keyset-Pagination innerhalb eines Monats.
--
-- Fortsetzpunkt (LastKeyProcessed1..4 in dbo.sqm_ArchiveMonthLog) liegt als
-- TUPEL vor, nicht im Prozeduraufruf selbst - ein Abbruch zwischen zwei
-- Aufrufen (Netzwerk, Prozess-Kill) verliert dadurch nichts: der naechste
-- Aufruf fuer denselben Monat liest den Stand aus der Log-Tabelle und macht
-- genau dort weiter.
--
-- WICHTIG (Korrektheit bei zusammengesetzten Schluesseln):
-- 1. Die Keyset-Pagination-Bedingung ("naechster Batch faengt hinter dem
--    zuletzt verarbeiteten Schluessel an") ist bei einem Tupel NICHT einfach
--    eine UND-Verknuepfung von Einzelspalten-">"-Vergleichen (das wuerde
--    Zeilen faelschlich ueberspringen/auslassen) - stattdessen wird hier die
--    Standard-Tupel-">"-Auswertung explizit als verschachtelter OR/AND-
--    Ausdruck aufgebaut ("erste Spalte groesser ODER erste Spalte gleich UND
--    zweite Spalte groesser ODER ..."), aequivalent zu (K1,K2,...) > (v1,v2,...).
-- 2. Der neue Fortsetzpunkt nach einem Batch ist NICHT das spaltenweise
--    Maximum ueber alle verarbeiteten Zeilen (das kann eine Tupel-Kombination
--    ergeben, die nie als echte Zeile existierte, und dadurch spaeter
--    tatsaechliche Zeilen dauerhaft und STILLSCHWEIGEND ueberspringen -
--    Datenverlust). Stattdessen bekommt jede Batch-Zeile ueber
--    ROW_NUMBER() OVER (ORDER BY <Schluesselspalten>) eine fortlaufende
--    Sequenznummer (dieselbe Sortierreihenfolge wie TOP()/Pagination), und
--    der neue Fortsetzpunkt ist das TUPEL genau der Zeile mit der hoechsten
--    Sequenznummer - garantiert eine echte, tatsaechlich verarbeitete Zeile.
--
-- Bekannte Einschraenkung: geht von aufsteigend sortierten Schluesselspalten
-- aus (wie bereits der vorherige Einzelspalten-Code) - absteigende Schluessel-
-- spalten (sys.index_columns.is_descending_key = 1) werden nicht
-- unterstuetzt. Fuer CORO_DB.dbo.CARCHIVE live geprueft: alle 4 Schluessel-
-- spalten (VMTG, VID1, VID2, VSEQ) sind aufsteigend - kein Blocker.
--
-- Bewusst OHNE eine einzelne grosse Transaktion ueber Log-Lesen + MERGE +
-- Log-Schreiben: bricht die Verbindung zwischen dem MERGE und dem
-- abschliessenden UPDATE von sqm_ArchiveMonthLog ab, wiederholt der naechste
-- Aufruf einfach denselben Schluesselbereich - durch MATCHED/UPDATE ist das
-- harmlos (keine Duplikate, keine verlorenen Aenderungen). Ein Batch selbst
-- (das MERGE-Statement) ist ohnehin ein einzelnes, atomares Statement -
-- SET XACT_ABORT ON sorgt bei einem Fehler mitten im Batch fuer sauberen
-- Rollback dieses einen Statements.
--
-- Wird von Install-sqmArchiveMigrationInfra per CREATE OR ALTER deployed.
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sqm_ArchiveMonthBatch
    @SchemaName          SYSNAME,
    @TableName           SYSNAME,
    @DateColumn          SYSNAME,
    @KeyColumns          NVARCHAR(400),
    @YYYYMM              INT,
    @ArchiveDatabaseName SYSNAME,
    @ArchiveSchemaName   SYSNAME,
    @ArchiveTableName    SYSNAME,
    @BatchSize           INT = 50000,
    -- Date (echtes DATE/DATETIME), Int (YYYYMMDD als Ganzzahl, z.B. CARCHIVE.VTDAT) oder Varchar
    -- (YYYYMMDD als String) - steuert, in welcher Form die Periodengrenzen mit @DateColumn
    -- verglichen werden (siehe Schritt 1 unten). Gleiche Konvention wie BoundaryType in
    -- Invoke-sqmTablePartitionConversion/Get-sqmPartitionBoundaryList.
    @BoundaryType        VARCHAR(10) = N'Date',
    @RowsThisCall        BIGINT OUTPUT,
    @MonthComplete       BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @RowsThisCall = 0;
    SET @MonthComplete = 0;

    IF @YYYYMM < 190001 OR @YYYYMM > 999912 OR (@YYYYMM % 100) NOT BETWEEN 1 AND 12
    BEGIN
        RAISERROR(N'sqm_ArchiveMonthBatch: @YYYYMM (%d) ist kein gueltiger YYYYMM-Wert.', 16, 1, @YYYYMM);
        RETURN;
    END

    IF @BoundaryType NOT IN (N'Date', N'Int', N'Varchar')
    BEGIN
        RAISERROR(N'sqm_ArchiveMonthBatch: @BoundaryType muss Date, Int oder Varchar sein (erhalten: %s).', 16, 1, @BoundaryType);
        RETURN;
    END

    -- @PeriodStart/@PeriodEnd dienen weiterhin nur der Kalenderarithmetik (Monatsgrenzen aus
    -- @YYYYMM) - fuer den eigentlichen Vergleich mit @DateColumn werden sie unten je nach
    -- @BoundaryType in die passende Darstellung konvertiert (Schritt 1), da @DateColumn nicht
    -- zwangslaeufig ein echter DATE/DATETIME-Typ ist (z.B. CARCHIVE.VTDAT ist INT im YYYYMMDD-
    -- Format - ein direkter DATE-Vergleich schlaegt dort mit "date ist inkompatibel mit int" fehl).
    DECLARE @PeriodStart DATE = DATEFROMPARTS(@YYYYMM / 100, @YYYYMM % 100, 1);
    DECLARE @PeriodEnd   DATE = DATEADD(MONTH, 1, @PeriodStart);

    -- ------------------------------------------------------------------------
    -- 1. Periodengrenzen in die zu @BoundaryType passende Darstellung konvertieren. SQL_VARIANT
    --    vergleicht sich beim Ausfuehren der dynamischen SQL korrekt gegen die echte Spalte
    --    (INT/VARCHAR/DATE) - dasselbe bereits bewaehrte Prinzip wie bei den @pLastKeyN-Parametern
    --    fuer die Schluesselspalten.
    -- ------------------------------------------------------------------------
    DECLARE @pPeriodStartVal SQL_VARIANT, @pPeriodEndVal SQL_VARIANT;
    IF @BoundaryType = N'Int'
    BEGIN
        SET @pPeriodStartVal = CAST(CONVERT(INT, CONVERT(VARCHAR(8), @PeriodStart, 112)) AS SQL_VARIANT);
        SET @pPeriodEndVal   = CAST(CONVERT(INT, CONVERT(VARCHAR(8), @PeriodEnd, 112)) AS SQL_VARIANT);
    END
    ELSE IF @BoundaryType = N'Varchar'
    BEGIN
        SET @pPeriodStartVal = CAST(CONVERT(VARCHAR(8), @PeriodStart, 112) AS SQL_VARIANT);
        SET @pPeriodEndVal   = CAST(CONVERT(VARCHAR(8), @PeriodEnd, 112) AS SQL_VARIANT);
    END
    ELSE
    BEGIN
        SET @pPeriodStartVal = CAST(@PeriodStart AS SQL_VARIANT);
        SET @pPeriodEndVal   = CAST(@PeriodEnd AS SQL_VARIANT);
    END

    -- ------------------------------------------------------------------------
    -- 0. @KeyColumns in eine geordnete Tabellenvariable zerlegen (OPENJSON statt
    --    STRING_SPLIT, damit auch SQL Server < 2022 ohne dessen "ordinal"-
    --    Spalte unterstuetzt bleibt).
    -- ------------------------------------------------------------------------
    DECLARE @KeyCols TABLE (KeyOrdinal INT NOT NULL PRIMARY KEY, ColumnName SYSNAME NOT NULL);
    INSERT INTO @KeyCols (KeyOrdinal, ColumnName)
    SELECT CAST([key] AS INT) + 1, LTRIM(RTRIM([value]))
    FROM OPENJSON(N'["' + REPLACE(@KeyColumns, N',', N'","') + N'"]');

    DECLARE @KeyColCount INT = (SELECT COUNT(*) FROM @KeyCols);
    IF @KeyColCount NOT BETWEEN 1 AND 4
    BEGIN
        RAISERROR(N'sqm_ArchiveMonthBatch: @KeyColumns muss 1 bis 4 Spalten enthalten (erhalten: %d).', 16, 1, @KeyColCount);
        RETURN;
    END

    -- ------------------------------------------------------------------------
    -- 1. Log-Zeile sicherstellen (Insert-if-missing) und Fortsetzpunkt (Tupel)
    --    lesen.
    -- ------------------------------------------------------------------------
    IF NOT EXISTS (
        SELECT 1 FROM dbo.sqm_ArchiveMonthLog
        WHERE SchemaName = @SchemaName AND TableName = @TableName
          AND ArchiveDatabaseName = @ArchiveDatabaseName AND YYYYMM = @YYYYMM
    )
    BEGIN
        INSERT INTO dbo.sqm_ArchiveMonthLog (SchemaName, TableName, ArchiveDatabaseName, YYYYMM, Status, RowsArchived)
        VALUES (@SchemaName, @TableName, @ArchiveDatabaseName, @YYYYMM, N'InProgress', 0);
    END

    DECLARE @l1 SQL_VARIANT, @l2 SQL_VARIANT, @l3 SQL_VARIANT, @l4 SQL_VARIANT;
    SELECT @l1 = LastKeyProcessed1, @l2 = LastKeyProcessed2, @l3 = LastKeyProcessed3, @l4 = LastKeyProcessed4
    FROM dbo.sqm_ArchiveMonthLog
    WHERE SchemaName = @SchemaName AND TableName = @TableName
      AND ArchiveDatabaseName = @ArchiveDatabaseName AND YYYYMM = @YYYYMM;

    -- ------------------------------------------------------------------------
    -- 2. Spaltenliste + IDENTITY-Eigenschaft der Quelltabelle ermitteln. Die
    --    Prozedur liegt direkt in der Quelldatenbank - kein USE/Datenbank-
    --    wechsel noetig, nur die Archiv-Seite braucht einen 3-Part-Namen.
    --    Computed Columns werden ausgeschlossen (koennen nicht explizit
    --    per INSERT/UPDATE gesetzt werden). Schluesselspalten (ALLE, nicht nur
    --    eine) werden vom UPDATE SET ausgeschlossen.
    -- ------------------------------------------------------------------------
    DECLARE @ColList NVARCHAR(MAX), @SrcColList NVARCHAR(MAX), @UpdateSetList NVARCHAR(MAX), @HasIdentity BIT;

    -- LEFT JOIN + IS NULL statt NOT EXISTS(...) im STRING_AGG-Argument: SQL Server erlaubt keine
    -- Unterabfrage im Argument einer Aggregatfunktion ("Eine Aggregatfunktion kann auf einem
    -- Ausdruck, der ein Aggregat oder eine Unterabfrage enthaelt, nicht ausgefuehrt werden") - live
    -- gegen DEV01 getestet und bestaetigt, dass NOT EXISTS(...) hier genau diesen Fehler ausloest.
    SELECT
        @ColList = STRING_AGG(QUOTENAME(c.name), N', ') WITHIN GROUP (ORDER BY c.column_id),
        @SrcColList = STRING_AGG(N'src.' + QUOTENAME(c.name), N', ') WITHIN GROUP (ORDER BY c.column_id),
        @UpdateSetList = STRING_AGG(
            CASE WHEN kc.ColumnName IS NULL THEN QUOTENAME(c.name) + N' = src.' + QUOTENAME(c.name) END,
            N', '
        ) WITHIN GROUP (ORDER BY c.column_id),
        @HasIdentity = MAX(CASE WHEN c.is_identity = 1 THEN 1 ELSE 0 END)
    FROM sys.columns c
    JOIN sys.tables t ON t.object_id = c.object_id
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    LEFT JOIN @KeyCols kc ON kc.ColumnName = c.name
    WHERE s.name = @SchemaName AND t.name = @TableName AND c.is_computed = 0;

    IF @ColList IS NULL
    BEGIN
        RAISERROR(N'sqm_ArchiveMonthBatch: Tabelle %s.%s nicht gefunden.', 16, 1, @SchemaName, @TableName);
        RETURN;
    END

    DECLARE @ArchiveFullName NVARCHAR(400) =
        QUOTENAME(@ArchiveDatabaseName) + N'.' + QUOTENAME(@ArchiveSchemaName) + N'.' + QUOTENAME(@ArchiveTableName);
    DECLARE @SourceFullName NVARCHAR(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);

    -- ------------------------------------------------------------------------
    -- 3. Aus @KeyCols abgeleitete Fragmente fuer MERGE-ON, ORDER BY, die
    --    Keyset-Pagination-Bedingung (Tupel-">"-Semantik, siehe Header) und
    --    die OUTPUT-Liste (Quell-/Ziel-Seite fuer @MergeOutput).
    -- ------------------------------------------------------------------------
    DECLARE @OnClause NVARCHAR(MAX) = (
        SELECT STRING_AGG(N'tgt.' + QUOTENAME(ColumnName) + N' = src.' + QUOTENAME(ColumnName), N' AND ')
            WITHIN GROUP (ORDER BY KeyOrdinal)
        FROM @KeyCols
    );
    DECLARE @OrderByClause NVARCHAR(MAX) = (
        SELECT STRING_AGG(QUOTENAME(ColumnName), N', ') WITHIN GROUP (ORDER BY KeyOrdinal)
        FROM @KeyCols
    );
    DECLARE @OutputSrcList NVARCHAR(MAX) = (
        SELECT STRING_AGG(N'inserted.' + QUOTENAME(ColumnName), N', ') WITHIN GROUP (ORDER BY KeyOrdinal)
        FROM @KeyCols
    );
    DECLARE @OutputTgtList NVARCHAR(MAX) = (
        SELECT STRING_AGG(N'K' + CAST(KeyOrdinal AS NVARCHAR(1)), N', ') WITHIN GROUP (ORDER BY KeyOrdinal)
        FROM @KeyCols
    );
    DECLARE @NewKeyAssignList NVARCHAR(MAX) = (
        SELECT STRING_AGG(N'@pNewLastKey' + CAST(KeyOrdinal AS NVARCHAR(1)) + N' = K' + CAST(KeyOrdinal AS NVARCHAR(1)), N', ')
            WITHIN GROUP (ORDER BY KeyOrdinal)
        FROM @KeyCols
    );

    -- Tupel-">"-Vergleich (K1,K2,...,Kn) > (@pLastKey1,...,@pLastKeyn), aufgebaut als
    -- verschachtelter OR/AND-Ausdruck - siehe Header fuer die Begruendung, warum
    -- einzeln UND-verknuepfte ">"-Vergleiche pro Spalte HIER FALSCH waeren.
    DECLARE @KeysetPredicate NVARCHAR(MAX) = N'';
    DECLARE @i INT = 1;
    WHILE @i <= @KeyColCount
    BEGIN
        DECLARE @clause NVARCHAR(MAX) = N'(';
        DECLARE @j INT = 1;
        WHILE @j < @i
        BEGIN
            DECLARE @colJ SYSNAME = (SELECT ColumnName FROM @KeyCols WHERE KeyOrdinal = @j);
            SET @clause += QUOTENAME(@colJ) + N' = @pLastKey' + CAST(@j AS NVARCHAR(1)) + N' AND ';
            SET @j += 1;
        END
        DECLARE @colI SYSNAME = (SELECT ColumnName FROM @KeyCols WHERE KeyOrdinal = @i);
        SET @clause += QUOTENAME(@colI) + N' > @pLastKey' + CAST(@i AS NVARCHAR(1)) + N')';
        SET @KeysetPredicate += CASE WHEN @i > 1 THEN N' OR ' ELSE N'' END + @clause;
        SET @i += 1;
    END

    -- ------------------------------------------------------------------------
    -- 4. Ein Batch per MERGE. src.__BatchSeq (ROW_NUMBER in derselben
    --    Sortierreihenfolge wie TOP()/Pagination) identifiziert eindeutig die
    --    "letzte" Zeile dieses Batches - deren Schluesseltupel wird der neue
    --    Fortsetzpunkt (siehe Header, Punkt 2).
    -- ------------------------------------------------------------------------
    DECLARE @Sql NVARCHAR(MAX) = N'
' + CASE WHEN @HasIdentity = 1 THEN N'SET IDENTITY_INSERT ' + @ArchiveFullName + N' ON;' ELSE N'' END + N'

DECLARE @MergeOutput TABLE (BatchSeq INT NOT NULL, K1 SQL_VARIANT NULL, K2 SQL_VARIANT NULL, K3 SQL_VARIANT NULL, K4 SQL_VARIANT NULL);

MERGE ' + @ArchiveFullName + N' AS tgt
USING (
    SELECT TOP (@pBatchSize) ' + @ColList + N',
           ROW_NUMBER() OVER (ORDER BY ' + @OrderByClause + N') AS __BatchSeq
    FROM ' + @SourceFullName + N'
    WHERE [' + @DateColumn + N'] >= @pPeriodStart AND [' + @DateColumn + N'] < @pPeriodEnd
      AND (@pLastKey1 IS NULL OR (' + @KeysetPredicate + N'))
    ORDER BY ' + @OrderByClause + N'
) AS src
ON (' + @OnClause + N')
WHEN MATCHED THEN UPDATE SET ' + @UpdateSetList + N'
WHEN NOT MATCHED THEN INSERT (' + @ColList + N') VALUES (' + @SrcColList + N')
OUTPUT src.__BatchSeq, ' + @OutputSrcList + N' INTO @MergeOutput (BatchSeq, ' + @OutputTgtList + N');

SELECT @pRowsThisCall = COUNT(*) FROM @MergeOutput;
SELECT ' + @NewKeyAssignList + N' FROM @MergeOutput WHERE BatchSeq = (SELECT MAX(BatchSeq) FROM @MergeOutput);
' + CASE WHEN @HasIdentity = 1 THEN N'SET IDENTITY_INSERT ' + @ArchiveFullName + N' OFF;' ELSE N'' END;

    DECLARE @n1 SQL_VARIANT, @n2 SQL_VARIANT, @n3 SQL_VARIANT, @n4 SQL_VARIANT;

    -- sp_executesql verlangt eine zur Parameterdefinition statisch passende
    -- Argumentliste - da @KeyColCount variiert (1-4), hier bewusst als
    -- expliziter 4-facher IF/ELSE-Cascade statt einer weiteren Ebene
    -- dynamisch gebauten SQLs (Lesbarkeit/Nachvollziehbarkeit vor Eleganz,
    -- bei Code der gegen eine 7-TB-Produktionstabelle laeuft).
    IF @KeyColCount = 1
        EXEC sp_executesql @Sql,
            N'@pBatchSize INT, @pPeriodStart SQL_VARIANT, @pPeriodEnd SQL_VARIANT, @pLastKey1 SQL_VARIANT, @pRowsThisCall BIGINT OUTPUT, @pNewLastKey1 SQL_VARIANT OUTPUT',
            @pBatchSize = @BatchSize, @pPeriodStart = @pPeriodStartVal, @pPeriodEnd = @pPeriodEndVal, @pLastKey1 = @l1,
            @pRowsThisCall = @RowsThisCall OUTPUT, @pNewLastKey1 = @n1 OUTPUT;
    ELSE IF @KeyColCount = 2
        EXEC sp_executesql @Sql,
            N'@pBatchSize INT, @pPeriodStart SQL_VARIANT, @pPeriodEnd SQL_VARIANT, @pLastKey1 SQL_VARIANT, @pLastKey2 SQL_VARIANT, @pRowsThisCall BIGINT OUTPUT, @pNewLastKey1 SQL_VARIANT OUTPUT, @pNewLastKey2 SQL_VARIANT OUTPUT',
            @pBatchSize = @BatchSize, @pPeriodStart = @pPeriodStartVal, @pPeriodEnd = @pPeriodEndVal, @pLastKey1 = @l1, @pLastKey2 = @l2,
            @pRowsThisCall = @RowsThisCall OUTPUT, @pNewLastKey1 = @n1 OUTPUT, @pNewLastKey2 = @n2 OUTPUT;
    ELSE IF @KeyColCount = 3
        EXEC sp_executesql @Sql,
            N'@pBatchSize INT, @pPeriodStart SQL_VARIANT, @pPeriodEnd SQL_VARIANT, @pLastKey1 SQL_VARIANT, @pLastKey2 SQL_VARIANT, @pLastKey3 SQL_VARIANT, @pRowsThisCall BIGINT OUTPUT, @pNewLastKey1 SQL_VARIANT OUTPUT, @pNewLastKey2 SQL_VARIANT OUTPUT, @pNewLastKey3 SQL_VARIANT OUTPUT',
            @pBatchSize = @BatchSize, @pPeriodStart = @pPeriodStartVal, @pPeriodEnd = @pPeriodEndVal, @pLastKey1 = @l1, @pLastKey2 = @l2, @pLastKey3 = @l3,
            @pRowsThisCall = @RowsThisCall OUTPUT, @pNewLastKey1 = @n1 OUTPUT, @pNewLastKey2 = @n2 OUTPUT, @pNewLastKey3 = @n3 OUTPUT;
    ELSE
        EXEC sp_executesql @Sql,
            N'@pBatchSize INT, @pPeriodStart SQL_VARIANT, @pPeriodEnd SQL_VARIANT, @pLastKey1 SQL_VARIANT, @pLastKey2 SQL_VARIANT, @pLastKey3 SQL_VARIANT, @pLastKey4 SQL_VARIANT, @pRowsThisCall BIGINT OUTPUT, @pNewLastKey1 SQL_VARIANT OUTPUT, @pNewLastKey2 SQL_VARIANT OUTPUT, @pNewLastKey3 SQL_VARIANT OUTPUT, @pNewLastKey4 SQL_VARIANT OUTPUT',
            @pBatchSize = @BatchSize, @pPeriodStart = @pPeriodStartVal, @pPeriodEnd = @pPeriodEndVal, @pLastKey1 = @l1, @pLastKey2 = @l2, @pLastKey3 = @l3, @pLastKey4 = @l4,
            @pRowsThisCall = @RowsThisCall OUTPUT, @pNewLastKey1 = @n1 OUTPUT, @pNewLastKey2 = @n2 OUTPUT, @pNewLastKey3 = @n3 OUTPUT, @pNewLastKey4 = @n4 OUTPUT;

    -- ------------------------------------------------------------------------
    -- 5. Log-Zeile fortschreiben. Weniger Zeilen als @BatchSize zurueckgekommen
    --    (auch 0) heisst: fuer diesen Monat gibt es keine weiteren Zeilen mehr.
    --    Alle 4 Tupel-Spalten werden unbedingt geschrieben (ISNULL ist fuer
    --    ungenutzte Spalten ein No-Op, da @n2/@n3/@n4 dann NULL bleiben).
    -- ------------------------------------------------------------------------
    SET @MonthComplete = CASE WHEN @RowsThisCall < @BatchSize THEN 1 ELSE 0 END;

    UPDATE dbo.sqm_ArchiveMonthLog
    SET RowsArchived = RowsArchived + @RowsThisCall,
        LastKeyProcessed1 = ISNULL(@n1, LastKeyProcessed1),
        LastKeyProcessed2 = ISNULL(@n2, LastKeyProcessed2),
        LastKeyProcessed3 = ISNULL(@n3, LastKeyProcessed3),
        LastKeyProcessed4 = ISNULL(@n4, LastKeyProcessed4),
        Status = CASE WHEN @MonthComplete = 1 THEN N'Completed' ELSE Status END,
        CompletedAt = CASE WHEN @MonthComplete = 1 THEN SYSDATETIME() ELSE CompletedAt END
    WHERE SchemaName = @SchemaName AND TableName = @TableName
      AND ArchiveDatabaseName = @ArchiveDatabaseName AND YYYYMM = @YYYYMM;
END
GO
