<#
.SYNOPSIS
    Listet Spalten einer Tabelle mit Eignungsbewertung als Partitionsspalte auf.

.DESCRIPTION
    Liest alle Spalten der Tabelle und markiert, ob der Datentyp als Partition-Function-Typ
    zulaessig ist. SQL Server erlaubt fuer Partition Functions keine LOB-Typen (varchar(max),
    nvarchar(max), varbinary(max), xml, text/ntext/image), keine CLR-Typen und kein timestamp/
    rowversion. Nullable-Spalten werden zusaetzlich markiert (NULL-Werte sortieren bei RANGE RIGHT
    in die am weitesten links liegende Partition - relevant fuer die Bewertung, kein Ausschlusskriterium).

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
    Get-sqmPartitionColumnCandidate -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory"

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool).
#>
function Get-sqmPartitionColumnCandidate
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

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	# Datentypen, die SQL Server fuer Partition Functions NICHT erlaubt:
	# LOB-Typen (max-Laenge), text/ntext/image, xml, CLR/sql_variant/hierarchyid/geography/geometry,
	# timestamp/rowversion.
	$disallowedTypes = @('text', 'ntext', 'image', 'xml', 'sql_variant', 'hierarchyid',
		'geography', 'geometry', 'timestamp', 'rowversion')

	Invoke-sqmLogging -Message "Ermittle Spalten von '$Schema.$Table' in '$Database' auf '$SqlInstance'." -FunctionName $functionName -Level "INFO"

	$query = @"
SELECT
    c.name                                       AS ColumnName,
    ty.name                                      AS DataType,
    c.max_length                                 AS MaxLength,
    c.is_nullable                                AS IsNullable,
    c.column_id                                  AS ColumnId,
    CASE WHEN ic.column_id IS NOT NULL THEN 1 ELSE 0 END AS IsPrimaryKeyColumn,
    CASE WHEN pkidx.index_id IS NOT NULL AND pkidx.type = 1 THEN 1 ELSE 0 END AS ClusteredIndexIsPk
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
LEFT JOIN sys.key_constraints kc ON kc.parent_object_id = t.object_id AND kc.type = 'PK'
LEFT JOIN sys.index_columns ic ON ic.object_id = t.object_id AND ic.index_id = kc.unique_index_id AND ic.column_id = c.column_id
LEFT JOIN sys.indexes pkidx ON pkidx.object_id = t.object_id AND pkidx.index_id = kc.unique_index_id
WHERE s.name = N'$Schema' AND t.name = N'$Table'
ORDER BY c.column_id
"@

	try
	{
		$rows = Invoke-DbaQuery @connParams -Query $query -ErrorAction Stop
	}
	catch
	{
		$msg = "Fehler beim Ermitteln der Spalten von '$Schema.$Table': $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		throw
	}

	if (-not $rows)
	{
		$msg = "Tabelle '$Schema.$Table' nicht gefunden oder hat keine Spalten."
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
		return @()
	}

	$results = foreach ($r in $rows)
	{
		$typeName = [string]$r.DataType
		$isLob = ($typeName -in @('varchar', 'nvarchar', 'varbinary')) -and ([int]$r.MaxLength -eq -1)
		$isCompatible = (-not $isLob) -and ($typeName -notin $disallowedTypes)

		[PSCustomObject]@{
			ColumnName              = $r.ColumnName
			DataType                = $typeName
			IsNullable              = [bool]$r.IsNullable
			IsPrimaryKeyColumn      = [bool]$r.IsPrimaryKeyColumn
			ClusteredIndexIsPk      = [bool]$r.ClusteredIndexIsPk
			IsPartitionTypeCompatible = $isCompatible
		}
	}

	return $results
}
