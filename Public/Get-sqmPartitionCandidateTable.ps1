<#
.SYNOPSIS
    Listet Tabellen einer Datenbank als Kandidaten fuer die Partitionierung auf.

.DESCRIPTION
    Liest alle Benutzertabellen einer Datenbank (ueber dbatools Get-DbaDbTable) und reichert sie
    mit Informationen an, die fuer die Partitionierungsentscheidung relevant sind: Zeilenzahl,
    Groesse, ob die Tabelle bereits partitioniert ist, und ob sie einen Clustered Index hat oder
    ein Heap ist.

    Wird sowohl von der CLI direkt als auch von Show-sqmPartitionToolGui (Tabellen-Auswahl-Schritt)
    verwendet.

.PARAMETER SqlInstance
    Ziel-Instanz.

.PARAMETER Database
    Zieldatenbank.

.PARAMETER SqlCredential
    Optionales PSCredential.

.PARAMETER IncludeAlreadyPartitioned
    Wenn gesetzt, werden auch bereits partitionierte Tabellen zurueckgegeben (Standard: nur
    nicht-partitionierte Tabellen, da das die eigentlichen Kandidaten fuer eine Neu-Konvertierung
    sind).

.EXAMPLE
    Get-sqmPartitionCandidateTable -SqlInstance "SQL01" -Database "Sales"

.EXAMPLE
    Get-sqmPartitionCandidateTable -SqlInstance "SQL01" -Database "Sales" -IncludeAlreadyPartitioned |
        Where-Object { $_.RowCount -gt 1000000 }

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool).
#>
function Get-sqmPartitionCandidateTable
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $true, Position = 1)]
		[string]$Database,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$IncludeAlreadyPartitioned
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	Invoke-sqmLogging -Message "Ermittle Partitionierungs-Kandidaten in '$Database' auf '$SqlInstance'." -FunctionName $functionName -Level "INFO"

	$query = @"
SELECT
    s.name                                                            AS SchemaName,
    t.name                                                            AS TableName,
    SUM(dps.row_count)                                                AS [RowCount],
    CAST(SUM(dps.reserved_page_count) * 8.0 / 1024 AS DECIMAL(18,2))  AS SizeMB,
    MAX(CASE WHEN di.index_id = 1 THEN 1 ELSE 0 END)                  AS HasClusteredIndex,
    MAX(CASE WHEN psch.data_space_id IS NOT NULL THEN 1 ELSE 0 END)   AS IsPartitioned
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats dps ON dps.object_id = t.object_id AND dps.index_id IN (0, 1)
-- Daten-tragender Index (Heap index_id=0 oder Clustered index_id=1) - dessen data_space_id
-- entscheidet, ob die Tabelle wirklich partitioniert ist (nicht nur irgendein Nonclustered-Index).
JOIN sys.indexes di ON di.object_id = t.object_id AND di.index_id IN (0, 1)
LEFT JOIN sys.partition_schemes psch ON psch.data_space_id = di.data_space_id
WHERE t.is_ms_shipped = 0
GROUP BY s.name, t.name
ORDER BY s.name, t.name
"@

	try
	{
		$rows = Invoke-DbaQuery @connParams -Query $query -ErrorAction Stop
	}
	catch
	{
		$msg = "Fehler beim Ermitteln der Tabellen in '$Database' auf '$SqlInstance': $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		throw
	}

	$results = foreach ($r in $rows)
	{
		$isPartitioned = [bool]$r.IsPartitioned
		if ($isPartitioned -and -not $IncludeAlreadyPartitioned) { continue }

		[PSCustomObject]@{
			SchemaName        = $r.SchemaName
			TableName         = $r.TableName
			RowCount          = [int64]$r.RowCount
			SizeMB            = [decimal]$r.SizeMB
			HasClusteredIndex = [bool]$r.HasClusteredIndex
			IsHeap            = -not [bool]$r.HasClusteredIndex
			IsPartitioned     = $isPartitioned
		}
	}

	Invoke-sqmLogging -Message "$(@($results).Count) Tabelle(n) gefunden." -FunctionName $functionName -Level "INFO"
	return $results
}
