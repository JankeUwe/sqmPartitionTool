<#
.SYNOPSIS
    Prueft, ob alle Indizes einer partitionierten Tabelle partitionsausgerichtet (aligned) sind.

.DESCRIPTION
    SWITCH PARTITION verlangt, dass alle Nonclustered-Indizes auf demselben Partition Scheme wie
    die Tabelle selbst liegen (partitionsausgerichtet). Ein nicht-ausgerichteter Index (auf einem
    normalen Filegroup statt dem Partition Scheme) blockiert SWITCH PARTITION komplett und damit
    sowohl sqm_RetirePartitionWindow als auch Invoke-sqmPartitionArchive.

    Wird von diesen beiden als Pre-Flight-Guard aufgerufen, um SQL Servers rohe Fehlermeldung
    durch eine verstaendliche Meldung zu ersetzen.

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
    Test-sqmPartitionIndexAlignment -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory"

.NOTES
    Benoetigt: dbatools.
#>
function Test-sqmPartitionIndexAlignment
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

	$query = @"
SELECT
    i.name                                                          AS IndexName,
    i.index_id                                                      AS IndexId,
    i.type_desc                                                     AS IndexType,
    CASE WHEN psch.data_space_id IS NOT NULL THEN 1 ELSE 0 END      AS IsAligned,
    fg.name                                                         AS FilegroupName
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
LEFT JOIN sys.partition_schemes psch ON psch.data_space_id = i.data_space_id
LEFT JOIN sys.filegroups fg ON fg.data_space_id = i.data_space_id
WHERE s.name = N'$Schema' AND t.name = N'$Table' AND i.index_id > 0 AND i.type IN (1, 2)
ORDER BY i.index_id
"@

	$rows = Invoke-DbaQuery @connParams -Query $query -ErrorAction Stop
	if (-not $rows)
	{
		Write-Warning "'$Schema.$Table' hat keine Indizes oder wurde nicht gefunden."
		return [PSCustomObject]@{ SchemaName = $Schema; TableName = $Table; AllAligned = $true; NonAlignedIndexes = @() }
	}

	$nonAligned = @($rows | Where-Object { -not [bool]$_.IsAligned } | ForEach-Object {
			[PSCustomObject]@{ IndexName = $_.IndexName; IndexType = $_.IndexType; FilegroupName = $_.FilegroupName }
		})

	return [PSCustomObject]@{
		SchemaName        = $Schema
		TableName         = $Table
		AllAligned        = ($nonAligned.Count -eq 0)
		NonAlignedIndexes = $nonAligned
	}
}
