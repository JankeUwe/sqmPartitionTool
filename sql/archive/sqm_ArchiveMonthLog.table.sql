-- ============================================================================
-- sqm_ArchiveMonthLog
-- Fortschritts-Log fuer Invoke-sqmTableArchiveMigration: eine Zeile pro
-- (Schema, Tabelle, Archiv-Datenbank, Monat). Liegt bewusst in der
-- QUELLDATENBANK der jeweiligen Migration (nicht in master wie
-- sqm_PartitionRegistry) - die Log-Daten gehoeren zu genau einem
-- Migrationsprojekt einer bestimmten Quelldatenbank, nicht zu instanzweiter
-- Wartungs-Konfiguration.
--
-- LastKeyProcessed1..LastKeyProcessed4 ist der Fortsetzungspunkt fuer die
-- Batch-Schleife innerhalb eines Monats (sqm_ArchiveMonthBatch), als TUPEL
-- statt Einzelwert - seit Unterstuetzung zusammengesetzter Schluessel (z.B.
-- CORO_DB.dbo.CARCHIVE mit VMTG/VID1/VID2/VSEQ). Ungenutzte Spalten (Migration
-- mit weniger als 4 Schluesselspalten) bleiben NULL. Weil pro Batch sowohl neue
-- Zeilen eingefuegt als auch bereits archivierte, seither in der Quelle
-- geaenderte Zeilen per MERGE aktualisiert werden, laesst sich "bis wohin bin
-- ich gekommen" nicht mehr allein aus der Zielzeilenzahl ableiten (anders als
-- z.B. bei Invoke-sqmTableRelocations reinem MAX([KeyColumn])-Fortsetzung) -
-- der Fortsetzpunkt wird daher hier explizit gefuehrt.
--
-- Ersetzt die alte Einzelspalte LastKeyProcessed, die aus Kompatibilitaets-
-- gruenden (bereits deployte Testinstallationen) unveraendert in der Tabelle
-- verbleibt, aber von sqm_ArchiveMonthBatch nicht mehr gelesen/geschrieben wird.
--
-- Wird von Install-sqmArchiveMigrationInfra per CREATE-IF-NOT-EXISTS deployed
-- (analog zu sqm_PartitionRegistry.table.sql in sql\, nur mit eigenem
-- Installer, der nach $Database statt master deployed).
-- ============================================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.sqm_ArchiveMonthLog') AND type = 'U'
)
BEGIN
    CREATE TABLE dbo.sqm_ArchiveMonthLog
    (
        LogId               INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_sqm_ArchiveMonthLog PRIMARY KEY,
        SchemaName          SYSNAME       NOT NULL,
        TableName           SYSNAME       NOT NULL,
        ArchiveDatabaseName SYSNAME       NOT NULL,
        -- Format YYYYMM (z.B. 202601 fuer Januar 2026)
        YYYYMM              INT           NOT NULL,
        -- InProgress | Completed
        Status              VARCHAR(20)   NOT NULL,
        RowsArchived        BIGINT        NOT NULL CONSTRAINT DF_sqm_ArchiveMonthLog_RowsArchived DEFAULT (0),
        -- Veraltet (Einzelspalten-Vorgaenger von LastKeyProcessed1..4, siehe Header) - bleibt
        -- erhalten, wird nicht mehr benutzt.
        LastKeyProcessed    SQL_VARIANT   NULL,
        -- Fortsetzpunkt der Batch-Schleife innerhalb dieses Monats als Tupel (NULL = noch kein
        -- Batch gelaufen; alle 4 Spalten werden immer gemeinsam geschrieben, nie einzeln).
        LastKeyProcessed1   SQL_VARIANT   NULL,
        LastKeyProcessed2   SQL_VARIANT   NULL,
        LastKeyProcessed3   SQL_VARIANT   NULL,
        LastKeyProcessed4   SQL_VARIANT   NULL,
        StartedAt           DATETIME2     NOT NULL CONSTRAINT DF_sqm_ArchiveMonthLog_StartedAt DEFAULT (SYSDATETIME()),
        CompletedAt         DATETIME2     NULL,
        CONSTRAINT UQ_sqm_ArchiveMonthLog UNIQUE (SchemaName, TableName, ArchiveDatabaseName, YYYYMM)
    );
END
GO

-- ----------------------------------------------------------------------------
-- Upgrade-Pfad fuer bereits deployte Installationen mit der alten
-- Einzelspalten-Schema-Version (z.B. DEV01.ActiveSourceDB aus frueheren Tests
-- dieser Session). Rein additiv (neue NULLable Spalten) - kein Datenverlust,
-- keine Downtime, kein Table-Rebuild noetig. Jede ALTER TABLE in eigenem GO-
-- Batch, mit eigener IF-NOT-EXISTS-Absicherung - idempotent bei jedem
-- erneuten Deploy (Install-sqmArchiveMigrationInfra fuehrt diese Datei bei
-- jedem Aufruf erneut aus).
-- ----------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.sqm_ArchiveMonthLog') AND name = N'LastKeyProcessed1')
BEGIN
    ALTER TABLE dbo.sqm_ArchiveMonthLog ADD LastKeyProcessed1 SQL_VARIANT NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.sqm_ArchiveMonthLog') AND name = N'LastKeyProcessed2')
BEGIN
    ALTER TABLE dbo.sqm_ArchiveMonthLog ADD LastKeyProcessed2 SQL_VARIANT NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.sqm_ArchiveMonthLog') AND name = N'LastKeyProcessed3')
BEGIN
    ALTER TABLE dbo.sqm_ArchiveMonthLog ADD LastKeyProcessed3 SQL_VARIANT NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.sqm_ArchiveMonthLog') AND name = N'LastKeyProcessed4')
BEGIN
    ALTER TABLE dbo.sqm_ArchiveMonthLog ADD LastKeyProcessed4 SQL_VARIANT NULL;
END
GO
