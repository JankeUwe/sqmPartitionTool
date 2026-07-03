<#
.SYNOPSIS
    Traegt eine partitionierte Tabelle in die zentrale Registry ein (oder aktualisiert sie).

.DESCRIPTION
    Schreibt/aktualisiert eine Zeile in master.dbo.sqm_PartitionRegistry. Wird normalerweise von
    Invoke-sqmTablePartitionConversion automatisch aufgerufen; kann auch eigenstaendig genutzt
    werden, um eine bereits anderweitig partitionierte Tabelle nachtraeglich unter die Verwaltung
    von sqm_ExtendPartitionWindow/sqm_RetirePartitionWindow zu stellen, oder um Retention-/
    Archiv-Einstellungen einer bereits registrierten Tabelle zu aendern (Upsert per
    DatabaseName/SchemaName/TableName - siehe UQ_sqm_PartitionRegistry_Table).

    Legt die Registry-Tabelle bei Bedarf automatisch an (Install-sqmPartitionMaintenanceProcs).

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER Database
    Datenbank der partitionierten Tabelle.
.PARAMETER Schema
    Schema.
.PARAMETER Table
    Tabellenname.
.PARAMETER PartitionColumn
    Partitionsspalte.
.PARAMETER PartitionFunctionName
    Name der Partition Function.
.PARAMETER PartitionSchemeName
    Name des Partition Scheme.
.PARAMETER Granularity
    Month, Quarter oder Year.
.PARAMETER BoundaryType
    Date oder Int.
.PARAMETER FilegroupStrategy
    Single oder PerPeriod.
.PARAMETER FutureBufferPeriods
    Anzahl vorausschauend leer gehaltener Perioden. Standard: 3.
.PARAMETER RetentionValue
    Aufbewahrungsdauer (Zahl). Ohne Angabe: keine automatische Retention fuer diese Tabelle.
.PARAMETER RetentionUnit
    Months oder Years (Pflicht, wenn -RetentionValue gesetzt ist).
.PARAMETER ArchiveEnabled
    Bei Retention: alte Partitionen vor dem Entfernen in eine Archiv-Datenbank kopieren statt nur
    zu loeschen.
.PARAMETER ArchiveDatabaseName
    Ziel-Datenbank fuer die Archivierung (muss auf derselben Instanz liegen - siehe
    Invoke-sqmPartitionArchive).
.PARAMETER ArchiveSchemaName
    Ziel-Schema in der Archiv-Datenbank. Standard: gleiches Schema wie die Quelltabelle.
.PARAMETER IsActive
    Ob die Tabelle von den Wartungs-Jobs beruecksichtigt wird. Standard: $true.
.PARAMETER SqlCredential
    Optionales PSCredential.

.EXAMPLE
    Register-sqmPartitionTable -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" `
        -PartitionColumn "OrderDate" -PartitionFunctionName "PF_OrderHistory_OrderDate" `
        -PartitionSchemeName "PS_OrderHistory_OrderDate" -Granularity Month -BoundaryType Date `
        -FilegroupStrategy Single -RetentionValue 36 -RetentionUnit Months -ArchiveEnabled `
        -ArchiveDatabaseName "SalesArchive"

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), Install-sqmPartitionMaintenanceProcs (privat).
#>
function Register-sqmPartitionTable
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $true, Position = 1)]
		[string]$Database,

		[Parameter(Mandatory = $true)]
		[string]$Schema,

		[Parameter(Mandatory = $true)]
		[string]$Table,

		[Parameter(Mandatory = $true)]
		[string]$PartitionColumn,

		[Parameter(Mandatory = $true)]
		[string]$PartitionFunctionName,

		[Parameter(Mandatory = $true)]
		[string]$PartitionSchemeName,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Month', 'Quarter', 'Year')]
		[string]$Granularity,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Date', 'Int')]
		[string]$BoundaryType,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Single', 'PerPeriod')]
		[string]$FilegroupStrategy = 'Single',

		[Parameter(Mandatory = $false)]
		[int]$FutureBufferPeriods = 3,

		[Parameter(Mandatory = $false)]
		[int]$RetentionValue,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Months', 'Years')]
		[string]$RetentionUnit,

		[Parameter(Mandatory = $false)]
		[switch]$ArchiveEnabled,

		[Parameter(Mandatory = $false)]
		[string]$ArchiveDatabaseName,

		[Parameter(Mandatory = $false)]
		[string]$ArchiveSchemaName,

		[Parameter(Mandatory = $false)]
		[bool]$IsActive = $true,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	if ($RetentionValue -and -not $RetentionUnit)
	{
		throw "-RetentionUnit ist Pflicht, wenn -RetentionValue gesetzt ist."
	}
	if ($ArchiveEnabled -and -not $ArchiveDatabaseName)
	{
		throw "-ArchiveDatabaseName ist Pflicht, wenn -ArchiveEnabled gesetzt ist."
	}
	if (-not $ArchiveSchemaName) { $ArchiveSchemaName = $Schema }

	# Registry-Tabelle sicherstellen (idempotent)
	$installParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $installParams['SqlCredential'] = $SqlCredential }
	$mod = Get-Module -Name sqmPartitionTool
	& $mod { param($p) Install-sqmPartitionMaintenanceProcs @p } $installParams | Out-Null

	$action = "'$Schema.$Table' in sqm_PartitionRegistry eintragen/aktualisieren"
	if (-not $PSCmdlet.ShouldProcess($Database, $action)) { return }

	$retValSql = if ($RetentionValue) { "$RetentionValue" } else { 'NULL' }
	$retUnitSql = if ($RetentionUnit) { "N'$RetentionUnit'" } else { 'NULL' }
	$archDbSql = if ($ArchiveDatabaseName) { "N'$ArchiveDatabaseName'" } else { 'NULL' }
	$archSchemaSql = if ($ArchiveEnabled) { "N'$ArchiveSchemaName'" } else { 'NULL' }

	$mergeSql = @"
MERGE master.dbo.sqm_PartitionRegistry AS tgt
USING (SELECT N'$Database' AS DatabaseName, N'$Schema' AS SchemaName, N'$Table' AS TableName) AS src
    ON tgt.DatabaseName = src.DatabaseName AND tgt.SchemaName = src.SchemaName AND tgt.TableName = src.TableName
WHEN MATCHED THEN UPDATE SET
    PartitionColumn = N'$PartitionColumn',
    PartitionFunctionName = N'$PartitionFunctionName',
    PartitionSchemeName = N'$PartitionSchemeName',
    Granularity = N'$Granularity',
    BoundaryType = N'$BoundaryType',
    FilegroupStrategy = N'$FilegroupStrategy',
    FutureBufferPeriods = $FutureBufferPeriods,
    RetentionValue = $retValSql,
    RetentionUnit = $retUnitSql,
    ArchiveEnabled = $([int][bool]$ArchiveEnabled),
    ArchiveDatabaseName = $archDbSql,
    ArchiveSchemaName = $archSchemaSql,
    IsActive = $([int]$IsActive)
WHEN NOT MATCHED THEN INSERT
    (DatabaseName, SchemaName, TableName, PartitionColumn, PartitionFunctionName, PartitionSchemeName,
     Granularity, BoundaryType, FilegroupStrategy, FutureBufferPeriods, RetentionValue, RetentionUnit,
     ArchiveEnabled, ArchiveDatabaseName, ArchiveSchemaName, IsActive)
VALUES
    (N'$Database', N'$Schema', N'$Table', N'$PartitionColumn', N'$PartitionFunctionName', N'$PartitionSchemeName',
     N'$Granularity', N'$BoundaryType', N'$FilegroupStrategy', $FutureBufferPeriods, $retValSql, $retUnitSql,
     $([int][bool]$ArchiveEnabled), $archDbSql, $archSchemaSql, $([int]$IsActive));
"@

	try
	{
		Invoke-DbaQuery @connParams -Database master -Query $mergeSql -ErrorAction Stop
		Invoke-sqmLogging -Message "$action - erfolgreich." -FunctionName $functionName -Level "INFO"
	}
	catch
	{
		$msg = "Fehler beim Registrieren von '$Schema.$Table': $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		throw
	}

	$getParams = @{ SqlInstance = $SqlInstance; DatabaseName = $Database; SchemaName = $Schema; TableName = $Table }
	if ($SqlCredential) { $getParams['SqlCredential'] = $SqlCredential }
	return Get-sqmPartitionRegistry @getParams
}
