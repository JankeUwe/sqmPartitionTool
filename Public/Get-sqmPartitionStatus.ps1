<#
.SYNOPSIS
    Zeigt den aktuellen Partitionierungsstatus einer Tabelle (Grenzwerte, Zeilenzahl je Partition).

.DESCRIPTION
    Liest sys.partitions / sys.partition_range_values / sys.destination_data_spaces fuer eine
    partitionierte Tabelle und liefert je Partition: Partitionsnummer, Grenzwert (untere Schranke),
    Zeilenzahl, reservierter Speicher, Filegroup-Name und ob die Partition leer ist.

    Wird von der GUI fuer die Boundary-Vorschau (vor der Konvertierung noch nicht anwendbar - dort
    liefert Get-sqmPartitionBoundaryList die Vorschau) und fuer die laufende Statusanzeige einer
    bereits partitionierten Tabelle verwendet, sowie von Test-sqmPartitionIndexAlignment und der
    Retention-Logik zur Leerheits-Pruefung vor MERGE RANGE.

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER Database
    Zieldatenbank.
.PARAMETER Schema
    Schema der Tabelle.
.PARAMETER Table
    Tabellenname.
.PARAMETER SqlCredential
    Optionales PSCredential.

.EXAMPLE
    Get-sqmPartitionStatus -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory"

.NOTES
    Benoetigt: dbatools.
#>
function Get-sqmPartitionStatus
{
	[CmdletBinding()]
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

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	# Fuer RANGE RIGHT ist Partition K's UNTERE Grenze der Boundary-Wert mit boundary_id = K-1
	# (Partition 1 hat keine untere Grenze - NULL/-unendlich) und ihre OBERE Grenze der
	# Boundary-Wert mit boundary_id = K (NULL bei der letzten/Zukunfts-Partition). Beide werden
	# explizit als eigene Spalten geliefert, damit Aufrufer (Invoke-sqmPartitionArchive fuer
	# MERGE RANGE, die Retention-Logik fuer die Ablauf-Pruefung) nicht selbst ueber Nachbar-Zeilen
	# rueckschliessen muessen - das war zuvor eine einzige, faelschlich "LowerBoundaryValue"
	# genannte Spalte mit dem OBEREN Grenzwert (boundary_id = K statt K-1).
	$query = @"
SELECT
    p.partition_number                                        AS PartitionNumber,
    prvLower.value                                             AS LowerBoundaryValue,
    prvUpper.value                                             AS UpperBoundaryValue,
    p.rows                                                     AS RowsInPartition,
    CAST(ips.reserved_page_count * 8.0 / 1024 AS DECIMAL(18,2)) AS SizeMB,
    fg.name                                                     AS FilegroupName,
    pf.name                                                     AS PartitionFunctionName,
    ps.name                                                     AS PartitionSchemeName
FROM sys.partitions p
JOIN sys.indexes i ON i.object_id = p.object_id AND i.index_id = p.index_id AND i.index_id IN (0, 1)
JOIN sys.tables t ON t.object_id = p.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
JOIN sys.partition_functions pf ON pf.function_id = ps.function_id
LEFT JOIN sys.partition_range_values prvLower ON prvLower.function_id = pf.function_id AND prvLower.boundary_id = p.partition_number - 1
LEFT JOIN sys.partition_range_values prvUpper ON prvUpper.function_id = pf.function_id AND prvUpper.boundary_id = p.partition_number
JOIN sys.destination_data_spaces dds ON dds.partition_scheme_id = ps.data_space_id AND dds.destination_id = p.partition_number
JOIN sys.filegroups fg ON fg.data_space_id = dds.data_space_id
JOIN sys.dm_db_partition_stats ips ON ips.object_id = p.object_id AND ips.partition_id = p.partition_id AND ips.index_id = p.index_id
WHERE s.name = N'$Schema' AND t.name = N'$Table'
ORDER BY p.partition_number
"@

	try
	{
		$rows = Invoke-DbaQuery @connParams -Query $query -ErrorAction Stop
	}
	catch
	{
		throw "Fehler beim Ermitteln des Partitionsstatus von '$Schema.$Table': $($_.Exception.Message)"
	}

	if (-not $rows)
	{
		Write-Warning "'$Schema.$Table' ist nicht partitioniert oder nicht gefunden."
		return @()
	}

	$results = foreach ($r in $rows)
	{
		[PSCustomObject]@{
			SchemaName            = $Schema
			TableName             = $Table
			PartitionNumber       = [int]$r.PartitionNumber
			LowerBoundaryValue    = $r.LowerBoundaryValue
			UpperBoundaryValue    = $r.UpperBoundaryValue
			RowsInPartition       = [int64]$r.RowsInPartition
			SizeMB                = [decimal]$r.SizeMB
			FilegroupName         = $r.FilegroupName
			IsEmpty               = ([int64]$r.RowsInPartition -eq 0)
			PartitionFunctionName = $r.PartitionFunctionName
			PartitionSchemeName   = $r.PartitionSchemeName
		}
	}
	return $results
}
