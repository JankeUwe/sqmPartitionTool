<#
.SYNOPSIS
	Ermittelt die Schluesselspalte(n), ueber die Copy-sqmPartitionedTable batchweise blaettern kann.

.DESCRIPTION
	Gemeinsame Ableitungsregel fuer Copy-sqmPartitionedTable UND die GUI (Schritt 6, Copy-Modus),
	damit beide immer dieselbe Entscheidung treffen ("braucht diese Tabelle eine explizite
	Schluesselangabe?").

	Reihenfolge:
	1. Eindeutiger, ungefilterter, aktiver Clustered Index / PK / Unique Index mit 1-5 Schluessel-
	   spalten, von denen keine NULL zulaesst. Bevorzugt der Clustered Index (ORDER BY entlang der
	   physischen Reihenfolge), dann der PK, dann der schmalste.
	2. Fallback (bisheriges Verhalten): einspaltiger, NICHT eindeutiger Clustered Index -
	   IsUnique = $false, der Aufrufer warnt.
	Sonst: Columns leer -> explizite Angabe noetig.

.OUTPUTS
	PSCustomObject mit Columns ([string[]]), IndexName, IsUnique.
#>
function Get-sqmCopyKeyColumn
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[hashtable]$ConnParams,

		[Parameter(Mandatory = $true)]
		[string]$Database,

		[Parameter(Mandatory = $true)]
		[string]$Schema,

		[Parameter(Mandatory = $true)]
		[string]$Table
	)

	$obj = "N'[$Schema].[$Table]'"
	$uniqueQuery = @"
SELECT TOP 1 i.name AS IndexName,
       STRING_AGG(c.name, ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS KeyColumns
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID($obj) AND i.type IN (1, 2) AND i.is_unique = 1 AND i.has_filter = 0 AND i.is_disabled = 0
GROUP BY i.index_id, i.name, i.is_primary_key
HAVING COUNT(*) <= 5 AND MAX(CAST(c.is_nullable AS INT)) = 0
ORDER BY CASE WHEN i.index_id = 1 THEN 0 WHEN i.is_primary_key = 1 THEN 1 ELSE 2 END, COUNT(*), i.index_id;
"@
	$row = @(Invoke-DbaQuery @ConnParams -Database $Database -Query $uniqueQuery -ErrorAction Stop -EnableException -As PSObject)
	if ($row.Count -gt 0 -and $row[0].KeyColumns)
	{
		return [PSCustomObject]@{ Columns = [string[]]@($row[0].KeyColumns -split ','); IndexName = [string]$row[0].IndexName; IsUnique = $true }
	}

	$ciQuery = @"
SELECT i.name AS IndexName, c.name AS ColumnName
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID($obj) AND i.index_id = 1
ORDER BY ic.key_ordinal;
"@
	$ciRows = @(Invoke-DbaQuery @ConnParams -Database $Database -Query $ciQuery -ErrorAction Stop -EnableException -As PSObject)
	if ($ciRows.Count -eq 1)
	{
		return [PSCustomObject]@{ Columns = [string[]]@($ciRows[0].ColumnName); IndexName = [string]$ciRows[0].IndexName; IsUnique = $false }
	}

	return [PSCustomObject]@{ Columns = [string[]]@(); IndexName = $null; IsUnique = $false }
}
