<#
	===========================================================================
	 Module Name: sqmPartitionTool
	-------------------------------------------------------------------------
	 Automatische SQL-Server-Tabellen-Partitionierung (GUI + CLI).
	 Baut auf dbatools und sqmSQLTool auf (RequiredModules) - Logging
	 (Invoke-sqmLogging) und Konfiguration (Get-sqmConfig) werden direkt aus
	 sqmSQLTool wiederverwendet, nicht neu implementiert.
	===========================================================================
#>

# =============================================================================
# SCHRITT 1: Modulkonfiguration (nur fuer diese Module eigene Einstellungen -
# gemeinsame Dinge wie LogPath/OutputPath kommen aus sqmSQLTool ueber Get-sqmConfig)
# =============================================================================
$script:sqmPartitionModuleConfig = @{
	# Default-Kategorie fuer die von diesem Modul angelegten SQL-Agent-Jobs
	JobCategory                = 'Database Maintenance'
	# Standard-Anzahl vorausschauend leer angelegter Perioden bei der Konvertierung
	DefaultFutureBufferPeriods = 3
	# Default-Schedules fuer die beiden Wartungs-Jobs
	ExtendJobScheduleTime      = '02:00'
	RetentionJobScheduleTime   = '03:00'
	RetentionJobScheduleDay    = 'Sunday'
}

# Aktuelle Version aus der Manifestdatei lesen
$manifestPath = Join-Path $PSScriptRoot 'sqmPartitionTool.psd1'
$script:sqmPartitionModuleVersion = '1.0.0.0'
if (Test-Path $manifestPath)
{
	try
	{
		$manifestData = Import-PowerShellDataFile -Path $manifestPath -ErrorAction Stop
		$script:sqmPartitionModuleVersion = $manifestData.ModuleVersion
	}
	catch { }
}

# =============================================================================
# SCHRITT 2: dbatools- und sqmSQLTool-Verfuegbarkeit pruefen
# (RequiredModules im Manifest erzwingt das eigentlich schon beim Import,
#  diese Pruefung liefert aber eine verstaendlichere Fehlermeldung als der
#  generische PowerShell-RequiredModules-Fehler)
# =============================================================================
$script:dbatoolsAvailable  = [bool](Get-Module -Name dbatools)
$script:sqmSQLToolAvailable = [bool](Get-Module -Name sqmSQLTool)

if (-not $script:dbatoolsAvailable)
{
	try { Import-Module dbatools -ErrorAction Stop; $script:dbatoolsAvailable = $true }
	catch { Write-Warning "dbatools-Modul nicht gefunden. Installation: Install-Module dbatools" }
}

if (-not $script:sqmSQLToolAvailable)
{
	try { Import-Module sqmSQLTool -ErrorAction Stop; $script:sqmSQLToolAvailable = $true }
	catch { Write-Warning "sqmSQLTool-Modul nicht gefunden. sqmPartitionTool benoetigt es fuer Logging/Konfiguration (Invoke-sqmLogging/Get-sqmConfig)." }
}

# =============================================================================
# SCHRITT 3: Private und Public Funktionen laden
# =============================================================================
$PublicPath  = Join-Path $PSScriptRoot 'Public'
$PrivatePath = Join-Path $PSScriptRoot 'Private'

Get-ChildItem -Path $PrivatePath -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
	. $_.FullName
}

Get-ChildItem -Path $PublicPath -Filter *.ps1 -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
	. $_.FullName
}

# Export-ModuleMember wird NICHT aufgerufen - Export laeuft ausschliesslich ueber
# FunctionsToExport in sqmPartitionTool.psd1 (gleiche Begruendung wie sqmSQLTool:
# vermeidet die PowerShell WARNING ueber Bindestriche in Verb-Noun-Funktionsnamen).
