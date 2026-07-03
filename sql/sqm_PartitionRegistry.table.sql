-- ============================================================================
-- sqm_PartitionRegistry
-- Zentrale Metadaten-Tabelle fuer sqmPartitionTool: eine Zeile pro Tabelle,
-- die per Invoke-sqmTablePartitionConversion partitioniert und registriert
-- wurde. sqm_ExtendPartitionWindow und sqm_RetirePartitionWindow loopen ueber
-- IsActive=1 Zeilen dieser Tabelle - ein Job pro Instanz statt ein Job pro
-- partitionierter Tabelle.
-- Wird von Install-sqmPartitionMaintenanceProcs per CREATE-IF-NOT-EXISTS
-- deployed. Liegt in master (analog zu sqm_BackupExclude in sqmSQLTool).
-- ============================================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_PartitionRegistry') AND type = 'U'
)
BEGIN
    CREATE TABLE master.dbo.sqm_PartitionRegistry
    (
        RegistryId             INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_sqm_PartitionRegistry PRIMARY KEY,
        DatabaseName            SYSNAME       NOT NULL,
        SchemaName              SYSNAME       NOT NULL,
        TableName               SYSNAME       NOT NULL,
        PartitionColumn         SYSNAME       NOT NULL,
        PartitionFunctionName   SYSNAME       NOT NULL,
        PartitionSchemeName     SYSNAME       NOT NULL,
        -- Month | Quarter | Year
        Granularity             VARCHAR(10)   NOT NULL,
        -- Date (echte date/datetime2-Spalte) | Int (numerischer Surrogatschluessel) |
        -- Text (char/varchar-Surrogatschluessel mit demselben Zahlenformat als String)
        BoundaryType            VARCHAR(10)   NOT NULL,
        -- Nur relevant bei BoundaryType Int/Text: 'yyyyMMdd' oder 'yyyyMM' - NULL bei BoundaryType Date
        SurrogateDateFormat     VARCHAR(10)   NULL,
        -- Single (ein gemeinsames Filegroup) | PerPeriod (ein Filegroup je Zeitraum)
        FilegroupStrategy       VARCHAR(10)   NOT NULL,
        -- Wie viele zukuenftige, leere Perioden beim Extend-Job vorgehalten werden
        FutureBufferPeriods     INT           NOT NULL CONSTRAINT DF_sqm_PartitionRegistry_FutureBufferPeriods DEFAULT (3),
        -- Retention: NULL = keine automatische Loeschung/Archivierung fuer diese Tabelle
        RetentionValue          INT           NULL,
        -- Months | Years
        RetentionUnit           VARCHAR(10)   NULL,
        ArchiveEnabled          BIT           NOT NULL CONSTRAINT DF_sqm_PartitionRegistry_ArchiveEnabled DEFAULT (0),
        ArchiveDatabaseName     SYSNAME       NULL,
        ArchiveSchemaName       SYSNAME       NULL,
        -- Batchgroesse fuer die Kopie in die Archiv-Datenbank
        ArchiveBatchSize        INT           NOT NULL CONSTRAINT DF_sqm_PartitionRegistry_ArchiveBatchSize DEFAULT (50000),
        -- IsActive=0: Tabelle bleibt partitioniert, wird aber von den Wartungs-Jobs ignoriert
        -- (Register-sqmPartitionTable/Remove-sqmPartitionRegistration steuern dieses Flag)
        IsActive                BIT           NOT NULL CONSTRAINT DF_sqm_PartitionRegistry_IsActive DEFAULT (1),
        CreatedBy               SYSNAME       NOT NULL CONSTRAINT DF_sqm_PartitionRegistry_CreatedBy DEFAULT (SUSER_SNAME()),
        CreatedAt                DATETIME2    NOT NULL CONSTRAINT DF_sqm_PartitionRegistry_CreatedAt DEFAULT (SYSDATETIME()),
        LastExtendedAt            DATETIME2    NULL,
        LastRetentionRunAt        DATETIME2    NULL,
        CONSTRAINT UQ_sqm_PartitionRegistry_Table UNIQUE (DatabaseName, SchemaName, TableName)
    );
END
GO

-- Migrationspfad fuer bereits vor der Text/SurrogateDateFormat-Erweiterung angelegte Tabellen
-- (z.B. DEV02-Testinstallation) - CREATE TABLE oben greift dort nicht, da die Tabelle schon existiert.
IF EXISTS (
    SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_PartitionRegistry') AND type = 'U'
)
AND NOT EXISTS (
    SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'master.dbo.sqm_PartitionRegistry') AND name = 'SurrogateDateFormat'
)
BEGIN
    ALTER TABLE master.dbo.sqm_PartitionRegistry ADD SurrogateDateFormat VARCHAR(10) NULL;
END
GO
