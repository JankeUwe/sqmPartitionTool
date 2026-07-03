-- ============================================================================
-- sqm_ExtendPartitionWindow
-- Instanzweite Wartungsprozedur (liegt in master, ein Job fuer die ganze
-- Instanz statt ein Job pro partitionierter Tabelle). Loopt ueber alle aktiven
-- Zeilen aus master.dbo.sqm_PartitionRegistry und erweitert das Sliding
-- Window per SPLIT RANGE, wenn weniger als FutureBufferPeriods leere
-- Perioden nach der aktuellen Periode (heute) vorhanden sind.
--
-- Idempotent: liest bei jedem Lauf den tatsaechlichen Zustand aus
-- sys.partition_range_values (nie einen gecachten "letzten Stand") - ein
-- Job-Rerun oder ein nachgeholter Lauf nach Ausfallzeit ist damit sicher.
--
-- EINSCHRAENKUNG: automatische Erweiterung wird nur fuer FilegroupStrategy
-- 'Single' unterstuetzt (das ohnehin empfohlene Standardverhalten - siehe
-- New-sqmPartitionFilegroupPlan). Bei 'Single' zeigt NEXT USED wiederholt auf
-- dasselbe, bereits bei der Konvertierung angelegte Filegroup - es muss also
-- kein neues Filegroup automatisiert angelegt werden. Tabellen mit
-- FilegroupStrategy 'PerPeriod' werden erkannt, aber uebersprungen (mit
-- Warnung) - dort neue Filegroups/Dateien vollautomatisch aus einer
-- T-SQL-Prozedur anzulegen waere deutlich fehleranfaelliger zu warten als der
-- PowerShell-Weg (New-sqmPartitionFilegroupPlan) und ist bewusst nicht
-- Teil dieser Prozedur; PerPeriod-Tabellen muessen manuell erweitert werden.
--
-- Jede Tabelle wird per TRY/CATCH isoliert behandelt (ein Fehler bei einer
-- Tabelle blockiert nicht die anderen), Fehler werden am Ende aggregiert
-- als RAISERROR gemeldet (gleiches Muster wie -ContinueOnError in
-- New-sqmOlaUsrDbBackupJob).
-- ============================================================================
CREATE OR ALTER PROCEDURE dbo.sqm_ExtendPartitionWindow
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RegistryId INT, @DatabaseName SYSNAME, @TableName SYSNAME,
            @PartitionFunctionName SYSNAME, @PartitionSchemeName SYSNAME,
            @Granularity VARCHAR(10), @BoundaryType VARCHAR(10), @SurrogateDateFormat VARCHAR(10),
            @FilegroupStrategy VARCHAR(10), @FutureBufferPeriods INT;

    DECLARE @ProcessedCount INT = 0, @ExtendedCount INT = 0, @SkippedCount INT = 0,
            @ErrorCount INT = 0, @ErrorSummary NVARCHAR(MAX) = N'';

    DECLARE reg_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT RegistryId, DatabaseName, TableName, PartitionFunctionName, PartitionSchemeName,
               Granularity, BoundaryType, ISNULL(SurrogateDateFormat, N'yyyyMMdd'), FilegroupStrategy, FutureBufferPeriods
        FROM master.dbo.sqm_PartitionRegistry
        WHERE IsActive = 1;

    OPEN reg_cursor;
    FETCH NEXT FROM reg_cursor INTO @RegistryId, @DatabaseName, @TableName, @PartitionFunctionName,
        @PartitionSchemeName, @Granularity, @BoundaryType, @SurrogateDateFormat, @FilegroupStrategy, @FutureBufferPeriods;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @ProcessedCount += 1;

        IF @FilegroupStrategy <> 'Single'
        BEGIN
            SET @SkippedCount += 1;
            SET @ErrorSummary = @ErrorSummary + N'[' + @DatabaseName + N'.' + @TableName +
                N'] uebersprungen - FilegroupStrategy ''PerPeriod'' wird von sqm_ExtendPartitionWindow ' +
                N'nicht automatisch erweitert, siehe Prozedur-Kommentar. ';
            GOTO NextTable;
        END

        BEGIN TRY
            DECLARE @FgName SYSNAME = N'FG_' + @TableName + N'_PART';
            DECLARE @innerSql NVARCHAR(MAX) = N'
USE ' + QUOTENAME(@DatabaseName) + N';

DECLARE @MaxBoundary SQL_VARIANT;
SELECT TOP 1 @MaxBoundary = prv.value
FROM sys.partition_range_values prv
JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
WHERE pf.name = @pPfName
ORDER BY prv.boundary_id DESC;

IF @MaxBoundary IS NULL
BEGIN
    RAISERROR(''Partition Function %s nicht gefunden oder hat keine Boundary-Werte.'', 16, 1, @pPfName);
    RETURN;
END

DECLARE @MaxBoundaryDate DATE, @CurrentPeriod DATE, @NextPeriod DATE, @TargetPeriod DATE;
DECLARE @Today DATE = CAST(GETDATE() AS DATE);

-- BoundaryType Int/Text: Surrogatschluessel als String (''20240115'' oder ''202401'', je nach
-- @pSurrogateDateFormat) - dieselbe Unterscheidung wie beim Generieren der Boundary-Literale weiter
-- unten. BoundaryType Date: @MaxBoundary ist bereits ein echter Datumswert.
IF @pBoundaryType = ''Date''
    SET @MaxBoundaryDate = CAST(@MaxBoundary AS DATE);
ELSE
BEGIN
    DECLARE @MaxBoundaryStr VARCHAR(10) = CASE WHEN @pBoundaryType = ''Int''
        THEN CONVERT(VARCHAR(10), CAST(@MaxBoundary AS BIGINT))
        ELSE CAST(@MaxBoundary AS VARCHAR(10)) END;

    IF @pSurrogateDateFormat = ''yyyyMM''
        SET @MaxBoundaryDate = DATEFROMPARTS(CAST(LEFT(@MaxBoundaryStr, 4) AS INT), CAST(RIGHT(@MaxBoundaryStr, 2) AS INT), 1);
    ELSE
        SET @MaxBoundaryDate = CONVERT(DATE, @MaxBoundaryStr, 112);
END

IF @pGranularity = ''Month''
    SET @CurrentPeriod = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
ELSE IF @pGranularity = ''Quarter''
    SET @CurrentPeriod = DATEFROMPARTS(YEAR(@Today), ((MONTH(@Today) - 1) / 3) * 3 + 1, 1);
ELSE
    SET @CurrentPeriod = DATEFROMPARTS(YEAR(@Today), 1, 1);

-- @MaxBoundaryDate ist bereits als Boundary vorhanden - die naechste zu ergaenzende Periode
-- liegt EINE Periode danach, sonst versucht SPLIT RANGE einen bereits vorhandenen Wert erneut
-- einzufuegen ("Doppelte Bereichsbegrenzungswerte").
IF @pGranularity = ''Month''
    SET @NextPeriod = DATEADD(MONTH, 1, @MaxBoundaryDate);
ELSE IF @pGranularity = ''Quarter''
    SET @NextPeriod = DATEADD(MONTH, 3, @MaxBoundaryDate);
ELSE
    SET @NextPeriod = DATEADD(YEAR, 1, @MaxBoundaryDate);

IF @pGranularity = ''Month''
    SET @TargetPeriod = DATEADD(MONTH, @pFutureBufferPeriods, @CurrentPeriod);
ELSE IF @pGranularity = ''Quarter''
    SET @TargetPeriod = DATEADD(MONTH, @pFutureBufferPeriods * 3, @CurrentPeriod);
ELSE
    SET @TargetPeriod = DATEADD(YEAR, @pFutureBufferPeriods, @CurrentPeriod);

DECLARE @BoundaryLiteral NVARCHAR(50), @StepSql NVARCHAR(MAX), @NextPeriodStr VARCHAR(8);
WHILE @NextPeriod < @TargetPeriod
BEGIN
    IF @pBoundaryType = ''Date''
        SET @BoundaryLiteral = QUOTENAME(CONVERT(VARCHAR(10), @NextPeriod, 120), N'''''''');
    ELSE
    BEGIN
        -- Surrogatschluessel-String im konfigurierten Format erzeugen (yyyyMM hat keinen
        -- passenden CONVERT-Style - manuell aus Jahr/Monat zusammensetzen).
        SET @NextPeriodStr = CASE WHEN @pSurrogateDateFormat = ''yyyyMM''
            THEN CONVERT(VARCHAR(4), YEAR(@NextPeriod)) + RIGHT(''0'' + CONVERT(VARCHAR(2), MONTH(@NextPeriod)), 2)
            ELSE CONVERT(VARCHAR(8), @NextPeriod, 112) END;

        SET @BoundaryLiteral = CASE WHEN @pBoundaryType = ''Text''
            THEN QUOTENAME(@NextPeriodStr, N'''''''')
            ELSE @NextPeriodStr END;
    END

    -- EXEC() akzeptiert bei einem parenthesierten Argument keinen Ausdruck, der QUOTENAME()
    -- direkt per String-Verkettung einbindet (empirisch verifiziert - Syntaxfehler trotz
    -- gueltigem Ausdruck bei SELECT) - daher erst in eine Variable schreiben, dann EXEC(@var).
    SET @StepSql = N''ALTER PARTITION SCHEME '' + QUOTENAME(@pPsName) + N'' NEXT USED '' + QUOTENAME(@pFgName) + N'';'';
    EXEC(@StepSql);
    SET @StepSql = N''ALTER PARTITION FUNCTION '' + QUOTENAME(@pPfName) + N''() SPLIT RANGE ('' + @BoundaryLiteral + N'');'';
    EXEC(@StepSql);

    SET @pExtendedThisTable = @pExtendedThisTable + 1;

    IF @pGranularity = ''Month''
        SET @NextPeriod = DATEADD(MONTH, 1, @NextPeriod);
    ELSE IF @pGranularity = ''Quarter''
        SET @NextPeriod = DATEADD(MONTH, 3, @NextPeriod);
    ELSE
        SET @NextPeriod = DATEADD(YEAR, 1, @NextPeriod);
END
';
            DECLARE @extendedThisTable INT = 0;
            EXEC sp_executesql @innerSql,
                N'@pPfName SYSNAME, @pPsName SYSNAME, @pFgName SYSNAME, @pGranularity VARCHAR(10), @pBoundaryType VARCHAR(10), @pSurrogateDateFormat VARCHAR(10), @pFutureBufferPeriods INT, @pExtendedThisTable INT OUTPUT',
                @pPfName = @PartitionFunctionName, @pPsName = @PartitionSchemeName, @pFgName = @FgName,
                @pGranularity = @Granularity, @pBoundaryType = @BoundaryType, @pSurrogateDateFormat = @SurrogateDateFormat, @pFutureBufferPeriods = @FutureBufferPeriods,
                @pExtendedThisTable = @extendedThisTable OUTPUT;

            IF @extendedThisTable > 0
            BEGIN
                SET @ExtendedCount += @extendedThisTable;
                UPDATE master.dbo.sqm_PartitionRegistry SET LastExtendedAt = SYSDATETIME() WHERE RegistryId = @RegistryId;
            END
        END TRY
        BEGIN CATCH
            SET @ErrorCount += 1;
            SET @ErrorSummary = @ErrorSummary + N'[' + @DatabaseName + N'.' + @TableName + N'] ' + ERROR_MESSAGE() + N' ';
        END CATCH

        NextTable:
        FETCH NEXT FROM reg_cursor INTO @RegistryId, @DatabaseName, @TableName, @PartitionFunctionName,
            @PartitionSchemeName, @Granularity, @BoundaryType, @SurrogateDateFormat, @FilegroupStrategy, @FutureBufferPeriods;
    END

    CLOSE reg_cursor;
    DEALLOCATE reg_cursor;

    PRINT N'sqm_ExtendPartitionWindow: ' + CAST(@ProcessedCount AS VARCHAR(10)) + N' Tabelle(n) geprueft, ' +
        CAST(@ExtendedCount AS VARCHAR(10)) + N' Boundary(s) hinzugefuegt, ' +
        CAST(@SkippedCount AS VARCHAR(10)) + N' uebersprungen (PerPeriod), ' +
        CAST(@ErrorCount AS VARCHAR(10)) + N' Fehler.';

    IF @ErrorCount > 0
        RAISERROR(N'sqm_ExtendPartitionWindow: %d von %d Tabelle(n) fehlgeschlagen: %s', 16, 1, @ErrorCount, @ProcessedCount, @ErrorSummary);
END
GO
