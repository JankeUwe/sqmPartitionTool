<#
.SYNOPSIS
    Legt Partition Function und Partition Scheme fuer eine Boundary-/Filegroup-Kombination an.

.DESCRIPTION
    Erstellt (idempotent - existiert Function/Scheme bereits mit demselben Namen, wird
    uebersprungen statt fehlzuschlagen) eine RANGE-RIGHT-Partition-Function fuer den angegebenen
    SQL-Datentyp und eine darauf aufbauende Partition Scheme, die jede Partition dem passenden
    Filegroup zuordnet (aus New-sqmPartitionFilegroupPlan).

    Namenskonvention: PF_<Table>_<Spalte> / PS_<Table>_<Spalte>.

.PARAMETER SqlInstance
    Ziel-Instanz.

.PARAMETER Database
    Zieldatenbank.

.PARAMETER TableName
    Tabellenname (fliesst in Function-/Scheme-Namen ein).

.PARAMETER PartitionColumn
    Partitionsspalte (fliesst in Function-/Scheme-Namen ein).

.PARAMETER SqlDataType
    SQL-Datentyp der Partitionsspalte fuer die Partition Function, z.B. 'date', 'datetime2(3)', 'int'.

.PARAMETER BoundaryList
    Ergebnis von Get-sqmPartitionBoundaryList (N Eintraege -> N+1 Partitionen).

.PARAMETER FilegroupNames
    Ergebnis von New-sqmPartitionFilegroupPlan (.FilegroupNames) - bei Single-Strategie ein
    Element, bei PerPeriod N+1 Elemente (muss dann exakt zur Partitionsanzahl passen).

.PARAMETER SqlCredential
    Optionales PSCredential.

.EXAMPLE
    New-sqmPartitionSchemeSet -SqlInstance "SQL01" -Database "Sales" -TableName "OrderHistory" `
        -PartitionColumn "OrderDate" -SqlDataType "date" -BoundaryList $boundaries -FilegroupNames $plan.FilegroupNames

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool).
#>
function New-sqmPartitionSchemeSet
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
		[string]$PartitionColumn,

		[Parameter(Mandatory = $true)]
		[string]$SqlDataType,

		[Parameter(Mandatory = $true)]
		[PSCustomObject[]]$BoundaryList,

		[Parameter(Mandatory = $true)]
		[string[]]$FilegroupNames,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	function _Sanitize([string]$s) { return ($s -replace '[^A-Za-z0-9_]', '_') }

	$expectedPartitionCount = $BoundaryList.Count + 1
	$isSingleFg = ($FilegroupNames.Count -eq 1)

	if (-not $isSingleFg -and $FilegroupNames.Count -ne $expectedPartitionCount)
	{
		throw "FilegroupNames hat $($FilegroupNames.Count) Eintraege, erwartet werden entweder 1 (Single-Strategie) oder $expectedPartitionCount (PerPeriod, N+1 fuer N=$($BoundaryList.Count) Boundaries)."
	}

	$pfName = "PF_$(_Sanitize $TableName)_$(_Sanitize $PartitionColumn)"
	$psName = "PS_$(_Sanitize $TableName)_$(_Sanitize $PartitionColumn)"

	# --- Idempotenz: existiert Function/Scheme bereits? ----------------------------------------
	$existsQuery = @"
SELECT
    (SELECT COUNT(*) FROM sys.partition_functions WHERE name = N'$pfName') AS FunctionExists,
    (SELECT COUNT(*) FROM sys.partition_schemes WHERE name = N'$psName') AS SchemeExists
"@
	$existing = Invoke-DbaQuery @connParams -Database $Database -Query $existsQuery -ErrorAction Stop

	if ([int]$existing.FunctionExists -gt 0 -or [int]$existing.SchemeExists -gt 0)
	{
		# Von keinem Index/keiner Tabelle benutzt = Ueberbleibsel eines frueheren Laufs (z.B. Tabelle
		# danach geloescht). Dessen Grenzen passen meist nicht zu den aktuellen Daten - wiederverwendet
		# landeten alle neueren Zeilen in der letzten Partition. Also verwerfen und neu anlegen.
		$usageQuery = @"
SELECT COUNT(*) AS UsedBy
FROM sys.indexes i
JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
LEFT JOIN sys.partition_functions pf ON pf.function_id = ps.function_id
WHERE ps.name = N'$psName' OR pf.name = N'$pfName'
"@
		$usedBy = [int](Invoke-DbaQuery @connParams -Database $Database -Query $usageQuery -ErrorAction Stop -EnableException -As PSObject)[0].UsedBy
		if ($usedBy -gt 0)
		{
			Invoke-sqmLogging -Message "Partition Function '$pfName' und/oder Scheme '$psName' existieren bereits auf '$Database' und werden benutzt - ueberspringe Erstellung." -FunctionName $functionName -Level "INFO"
			return [PSCustomObject]@{
				PartitionFunctionName = $pfName
				PartitionSchemeName   = $psName
				AlreadyExisted        = $true
				PartitionCount        = $expectedPartitionCount
			}
		}

		$dropAction = "Unbenutzte Partition Function '$pfName' / Scheme '$psName' verwerfen (werden mit aktuellen Grenzen neu angelegt)"
		if ($PSCmdlet.ShouldProcess($Database, $dropAction))
		{
			# Alle (unbenutzten) Schemes auf dieser Function zuerst, sonst laesst sich die Function nicht loeschen
			$dropSql = @"
DECLARE @sql NVARCHAR(MAX) = N'';
SELECT @sql += N'DROP PARTITION SCHEME ' + QUOTENAME(ps.name) + N';'
FROM sys.partition_schemes ps LEFT JOIN sys.partition_functions pf ON pf.function_id = ps.function_id
WHERE ps.name = N'$psName' OR pf.name = N'$pfName';
IF EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = N'$pfName') SET @sql += N'DROP PARTITION FUNCTION [$pfName];';
EXEC sys.sp_executesql @sql;
"@
			Invoke-DbaQuery @connParams -Database $Database -Query $dropSql -ErrorAction Stop -EnableException | Out-Null
			Invoke-sqmLogging -Message "$dropAction - erledigt." -FunctionName $functionName -Level "WARNING"
		}
		else
		{
			return [PSCustomObject]@{
				PartitionFunctionName = $pfName
				PartitionSchemeName   = $psName
				AlreadyExisted        = $true
				PartitionCount        = $expectedPartitionCount
			}
		}
	}

	# --- Boundary-Werte fuer die Function formatieren ------------------------------------------
	# 'yyyyMMdd' (ohne Trennzeichen) statt 'yyyy-MM-dd': Letzteres wird von SQL Server abhaengig
	# vom Session-DATEFORMAT (@@LANGUAGE des Logins) interpretiert - bei einer dmy-Sprache (z.B.
	# Deutsch) wird '2025-02-01' als Tag=02/Monat=01 statt Monat=02/Tag=01 gelesen, alle
	# Monatsgrenzen kollabieren dann auf 12 Tage im Januar (live gegen einen Deutsch-Login
	# bestaetigt). Das unseparierte Format ist DATEFORMAT-unabhaengig immer sicher.
	$boundarySql = ($BoundaryList | ForEach-Object {
			$v = $_.BoundaryValue
			if ($v -is [datetime]) { "'$($v.ToString('yyyyMMdd'))'" }
			elseif ($v -is [string]) { "N'$($v.Replace("'", "''"))'" }
			else { "$v" }
		}) -join ', '

	$pfDdl = "CREATE PARTITION FUNCTION [$pfName] ($SqlDataType) AS RANGE RIGHT FOR VALUES ($boundarySql);"

	$psFgList = if ($isSingleFg) { "ALL TO ([$($FilegroupNames[0])])" }
	else { "TO (" + (($FilegroupNames | ForEach-Object { "[$_]" }) -join ', ') + ")" }

	$psDdl = "CREATE PARTITION SCHEME [$psName] AS PARTITION [$pfName] $psFgList;"

	$action = "Partition Function '$pfName' + Scheme '$psName' anlegen ($expectedPartitionCount Partitionen)"
	if ($PSCmdlet.ShouldProcess($Database, $action))
	{
		try
		{
			Invoke-DbaQuery @connParams -Database $Database -Query $pfDdl -ErrorAction Stop
			Invoke-DbaQuery @connParams -Database $Database -Query $psDdl -ErrorAction Stop
			Invoke-sqmLogging -Message "$action - erfolgreich." -FunctionName $functionName -Level "INFO"
		}
		catch
		{
			$msg = "Fehler beim Anlegen von Partition Function/Scheme fuer '$TableName.$PartitionColumn': $($_.Exception.Message)"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw
		}
	}

	return [PSCustomObject]@{
		PartitionFunctionName = $pfName
		PartitionSchemeName   = $psName
		AlreadyExisted        = $false
		PartitionCount        = $expectedPartitionCount
	}
}
