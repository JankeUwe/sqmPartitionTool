<#
.SYNOPSIS
    Plant und legt die fuer eine Partitionierung benoetigten Filegroups/Dateien an.

.DESCRIPTION
    Berechnet aus einer Boundary-Liste (Get-sqmPartitionBoundaryList, N Boundary-Werte) die
    benoetigten Filegroup-Namen fuer N+1 Partitionen und legt sie an (ALTER DATABASE ... ADD
    FILEGROUP + ADD FILE), idempotent - bereits vorhandene Filegroups/Dateien werden
    uebersprungen, nicht neu angelegt.

    -FilegroupStrategy Single (Standard, empfohlen): EIN gemeinsames Filegroup fuer alle
    Partitionen (FG_<Table>_PART). Deutlich weniger Betriebsaufwand als PerPeriod, bietet aber
    weiterhin Partition Elimination und SWITCH PARTITION.

    -FilegroupStrategy PerPeriod: ein eigenes Filegroup je Zeitraum (FG_<Table>_<Periode>,
    z.B. FG_Sales_2024-03). Ermoeglicht partitionsweise Sicherung/Restore und das Verschieben
    einzelner Perioden auf andere Datentraeger, erzeugt aber bei feiner Granularitaet ueber lange
    Zeitraeume viele Dateien - die GUI/CLI sollte bei Month+PerPeriod ueber lange Zeitraeume warnen
    (siehe Show-sqmPartitionToolGui).

    dbatools hat kein dediziertes Filegroup-Erstellungs-Cmdlet - die DDL wird bewusst direkt per
    Invoke-DbaQuery ausgefuehrt (T-SQL fuer ALTER DATABASE ... ADD FILEGROUP/ADD FILE ist einfach
    und sicher genug fuer den direkten Weg).

.PARAMETER SqlInstance
    Ziel-Instanz.

.PARAMETER Database
    Zieldatenbank.

.PARAMETER TableName
    Tabellenname (fliesst in die Filegroup-/Dateinamen ein).

.PARAMETER BoundaryList
    Ergebnis von Get-sqmPartitionBoundaryList.

.PARAMETER FilegroupStrategy
    Single (Standard) oder PerPeriod.

.PARAMETER FileSizeMB
    Initiale Dateigroesse je angelegter Datei in MB. Standard: 64.

.PARAMETER FileGrowthMB
    Autogrowth-Schrittweite in MB. Standard: 64.

.PARAMETER FilePath
    Zielverzeichnis fuer die neuen Datendateien. Ohne Angabe wird der Standard-Datenpfad der
    Instanz verwendet (Get-DbaDefaultPath).

.PARAMETER SqlCredential
    Optionales PSCredential.

.EXAMPLE
    $boundaries = Get-sqmPartitionBoundaryList -MinValue '2023-01-01' -MaxValue '2024-06-01' -Granularity Month -BoundaryType Date
    New-sqmPartitionFilegroupPlan -SqlInstance "SQL01" -Database "Sales" -TableName "OrderHistory" -BoundaryList $boundaries -FilegroupStrategy Single

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool).
#>
function New-sqmPartitionFilegroupPlan
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $true, Position = 1)]
		[string]$Database,

		[Parameter(Mandatory = $true)]
		[string]$TableName,

		[Parameter(Mandatory = $true)]
		[PSCustomObject[]]$BoundaryList,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Single', 'PerPeriod')]
		[string]$FilegroupStrategy = 'Single',

		[Parameter(Mandatory = $false)]
		[int]$FileSizeMB = 64,

		[Parameter(Mandatory = $false)]
		[int]$FileGrowthMB = 64,

		[Parameter(Mandatory = $false)]
		[string]$FilePath,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	function _Sanitize([string]$s) { return ($s -replace '[^A-Za-z0-9_\-]', '_') }

	# --- Filegroup-Namen bestimmen -----------------------------------------------------------
	$filegroupNames = [System.Collections.Generic.List[string]]::new()
	if ($FilegroupStrategy -eq 'Single')
	{
		$filegroupNames.Add("FG_$(_Sanitize $TableName)_PART")
	}
	else
	{
		# N Boundaries -> N+1 Partitionen: Partition 0 = "vor der ersten Boundary" (PRE),
		# Partition i (i=1..N) = die Periode, die bei BoundaryList[i-1] beginnt.
		$filegroupNames.Add("FG_$(_Sanitize $TableName)_PRE")
		foreach ($b in $BoundaryList)
		{
			$filegroupNames.Add("FG_$(_Sanitize $TableName)_$(_Sanitize $b.PeriodLabel)")
		}
	}

	if ($filegroupNames.Count -gt 50 -and $FilegroupStrategy -eq 'PerPeriod')
	{
		Invoke-sqmLogging -Message "PerPeriod-Strategie erzeugt $($filegroupNames.Count) Filegroups/Dateien fuer '$TableName' - bei so vielen Perioden 'Single' oder eine groebere Granularitaet erwaegen." -FunctionName $functionName -Level "WARNING"
	}

	# --- Zielverzeichnis ermitteln -------------------------------------------------------------
	if (-not $FilePath)
	{
		try
		{
			$defaultPath = Get-DbaDefaultPath @connParams -ErrorAction Stop
			$FilePath = $defaultPath.Data
		}
		catch
		{
			$msg = "Standard-Datenpfad konnte nicht ermittelt werden: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw
		}
	}

	# --- Bestehende Filegroups auf der Zieldatenbank ermitteln (Idempotenz) --------------------
	$existingFgQuery = "SELECT name FROM sys.filegroups"
	try
	{
		$existingFgRows = Invoke-DbaQuery @connParams -Database $Database -Query $existingFgQuery -ErrorAction Stop
		$existingFgNames = @($existingFgRows | ForEach-Object { $_.name })
	}
	catch
	{
		$msg = "Bestehende Filegroups konnten nicht ermittelt werden: $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		throw
	}

	$created = [System.Collections.Generic.List[string]]::new()
	$skipped = [System.Collections.Generic.List[string]]::new()

	foreach ($fg in $filegroupNames)
	{
		if ($fg -in $existingFgNames)
		{
			$skipped.Add($fg)
			continue
		}

		$logicalFileName = $fg
		$physicalFileName = Join-Path $FilePath "$Database`_$fg.ndf"

		$action = "Filegroup '$fg' + Datei '$physicalFileName' anlegen"
		if ($PSCmdlet.ShouldProcess($Database, $action))
		{
			$ddl = @"
ALTER DATABASE [$Database] ADD FILEGROUP [$fg];
ALTER DATABASE [$Database] ADD FILE (
    NAME = N'$logicalFileName',
    FILENAME = N'$physicalFileName',
    SIZE = ${FileSizeMB}MB,
    FILEGROWTH = ${FileGrowthMB}MB
) TO FILEGROUP [$fg];
"@
			try
			{
				Invoke-DbaQuery @connParams -Database master -Query $ddl -ErrorAction Stop
				$created.Add($fg)
				Invoke-sqmLogging -Message "Filegroup '$fg' angelegt ($physicalFileName)." -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$msg = "Fehler beim Anlegen von Filegroup '$fg': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw
			}
		}
	}

	return [PSCustomObject]@{
		TableName         = $TableName
		FilegroupStrategy = $FilegroupStrategy
		FilegroupNames    = $filegroupNames.ToArray()
		Created           = $created.ToArray()
		AlreadyExisted    = $skipped.ToArray()
	}
}
