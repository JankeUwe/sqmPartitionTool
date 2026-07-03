<#
.SYNOPSIS
    Liest Eintraege aus master.dbo.sqm_PartitionRegistry.

.DESCRIPTION
    Zeigt, welche Tabellen ueber sqmPartitionTool partitioniert und fuer die automatische
    Wartung (Erweiterung/Retention) registriert sind. Ohne Filter werden alle Eintraege der
    Instanz zurueckgegeben (auch IsActive=0).

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER DatabaseName
    Filtert auf eine Datenbank.
.PARAMETER SchemaName
    Filtert auf ein Schema (setzt -DatabaseName voraus, um eindeutig zu sein - wird sonst
    ignoriert wenn mehrdeutig).
.PARAMETER TableName
    Filtert auf eine Tabelle.
.PARAMETER ActiveOnly
    Nur IsActive=1 Eintraege.
.PARAMETER SqlCredential
    Optionales PSCredential.

.EXAMPLE
    Get-sqmPartitionRegistry -SqlInstance "SQL01"

.EXAMPLE
    Get-sqmPartitionRegistry -SqlInstance "SQL01" -DatabaseName "Sales" -TableName "OrderHistory"

.NOTES
    Benoetigt: dbatools. Falls sqm_PartitionRegistry noch nicht existiert, wird eine leere
    Ergebnisliste zurueckgegeben (kein Fehler).
#>
function Get-sqmPartitionRegistry
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $false)]
		[string]$DatabaseName,

		[Parameter(Mandatory = $false)]
		[string]$SchemaName,

		[Parameter(Mandatory = $false)]
		[string]$TableName,

		[Parameter(Mandatory = $false)]
		[switch]$ActiveOnly,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$existsCheck = Invoke-DbaQuery @connParams -Database master `
		-Query "SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_PartitionRegistry') AND type = 'U'" `
		-ErrorAction SilentlyContinue

	if (-not $existsCheck) { return @() }

	$where = [System.Collections.Generic.List[string]]::new()
	if ($DatabaseName) { $where.Add("DatabaseName = N'$DatabaseName'") }
	if ($SchemaName)   { $where.Add("SchemaName = N'$SchemaName'") }
	if ($TableName)    { $where.Add("TableName = N'$TableName'") }
	if ($ActiveOnly)   { $where.Add("IsActive = 1") }

	$whereSql = if ($where.Count -gt 0) { "WHERE " + ($where -join ' AND ') } else { '' }
	$query = "SELECT * FROM master.dbo.sqm_PartitionRegistry $whereSql ORDER BY DatabaseName, SchemaName, TableName"

	return Invoke-DbaQuery @connParams -Database master -Query $query -ErrorAction Stop
}
