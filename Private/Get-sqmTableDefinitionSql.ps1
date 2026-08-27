<#
.SYNOPSIS
	Baut CREATE TABLE- und Index-/PK-DDL fuer eine strukturelle Kopie einer Tabelle nach.

.DESCRIPTION
	Liest Spalten (inkl. IDENTITY-Eigenschaft) und Indizes/PRIMARY KEY/UNIQUE-Constraints der
	Quelltabelle aus sys.columns/sys.indexes/sys.index_columns/sys.key_constraints und liefert
	fertige DDL-Strings fuer eine NEUE Tabelle mit identischer Struktur zurueck - fuehrt selbst
	NICHTS aus, der Aufrufer entscheidet ueber Ausfuehrung/Fehlerbehandlung/Logging.

	Ziel kann entweder eine EINZELNE Filegroup sein (-FilegroupName - z.B. Staging-Tabelle fuer
	SWITCH PARTITION, die zwingend unpartitioniert auf einer Filegroup liegen muss) oder ein
	Partition Scheme (-PartitionSchemeName + -PartitionColumn - z.B. eine neue partitionierte
	Zieltabelle). Genau eines von beiden ist Pflicht.

	Extrahiert aus der urspruenglich inline in Invoke-sqmPartitionArchive.ps1 dupliziert
	vorhandenen Logik, damit Invoke-sqmTablePartitionConversion (-Method BatchedSwap) dieselbe
	Rekonstruktion fuer eine neue partitionierte Zieltabelle wiederverwenden kann.

	Rekonstruiert Spalten und Indizes/PK/UNIQUE-Constraints. FREMDSCHLUESSEL, TRIGGER und
	BERECHTIGUNGEN werden NICHT rekonstruiert (bewusst ausserhalb des Umfangs - Aufrufer muss das
	vorher pruefen/ausschliessen, siehe Invoke-sqmTablePartitionConversion -Method BatchedSwap).

.PARAMETER SqlInstance
	Ziel-Instanz.
.PARAMETER Database
	Datenbank der Quelltabelle.
.PARAMETER Schema
	Schema der Quelltabelle.
.PARAMETER Table
	Name der Quelltabelle.
.PARAMETER TargetTable
	Name der neuen Tabelle, fuer die die DDL generiert wird (nicht notwendigerweise die Quelle -
	z.B. eine Staging- oder Swap-Zieltabelle).
.PARAMETER TargetSchema
	Schema der neuen Tabelle. Standard: gleiches Schema wie die Quelltabelle (-Schema) - muss beim
	Aufrufer bereits existieren (siehe Copy-sqmPartitionedTable, das es vorher per CREATE SCHEMA
	sicherstellt). Nur bei einer NEUEN Tabelle in einer anderen Datenbank/einem anderen Schema als
	die Quelle relevant.
.PARAMETER FilegroupName
	Einzelne Filegroup fuer Tabelle + alle Indizes/Constraints. Alternative zu
	-PartitionSchemeName/-PartitionColumn.
.PARAMETER PartitionSchemeName
	Partition Scheme fuer Tabelle + alle Indizes/Constraints. Erfordert -PartitionColumn.
	Alternative zu -FilegroupName.
.PARAMETER PartitionColumn
	Partitionsspalte - Pflicht wenn -PartitionSchemeName angegeben ist.
.PARAMETER SqlCredential
	Optionales PSCredential.
.PARAMETER EnableException
	Fehler sofort als Ausnahme ausloesen.

.OUTPUTS
	PSCustomObject mit:
		CreateTableSql : CREATE TABLE-Statement (String).
		IndexSql       : Array weiterer Statements (CREATE INDEX / ALTER TABLE ADD CONSTRAINT),
		                 in der Reihenfolge auszufuehren wie zurueckgegeben.
		HasIdentity    : $true wenn die Quelltabelle eine IDENTITY-Spalte hat.
		ColumnNames    : Array der Spaltennamen in Quellreihenfolge (fuer INSERT/OUTPUT-Spaltenlisten).

.NOTES
	Benoetigt: dbatools. Intern verwendet - normalerweise nicht direkt aufgerufen.
#>
function Get-sqmTableDefinitionSql
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $true)]
		[string]$Database,

		[Parameter(Mandatory = $true)]
		[string]$Schema,

		[Parameter(Mandatory = $true)]
		[string]$Table,

		[Parameter(Mandatory = $true)]
		[string]$TargetTable,

		[Parameter(Mandatory = $false)]
		[string]$TargetSchema,

		[Parameter(Mandatory = $false)]
		[string]$FilegroupName,

		[Parameter(Mandatory = $false)]
		[string]$PartitionSchemeName,

		[Parameter(Mandatory = $false)]
		[string]$PartitionColumn,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	if (-not $FilegroupName -and -not $PartitionSchemeName)
	{
		throw "Get-sqmTableDefinitionSql: entweder -FilegroupName oder -PartitionSchemeName (mit -PartitionColumn) muss angegeben werden."
	}
	if ($PartitionSchemeName -and -not $PartitionColumn)
	{
		throw "Get-sqmTableDefinitionSql: -PartitionColumn ist Pflicht wenn -PartitionSchemeName angegeben ist."
	}
	if (-not $TargetSchema) { $TargetSchema = $Schema }

	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$onClause = if ($PartitionSchemeName) { "[$PartitionSchemeName]([$PartitionColumn])" } else { "[$FilegroupName]" }

	function _FormatColumnType($col)
	{
		switch ($col.TypeName)
		{
			{ $_ -in @('varchar', 'char', 'binary', 'varbinary') } { return "$($col.TypeName)($(if ($col.max_length -eq -1) { 'max' } else { $col.max_length }))" }
			{ $_ -in @('nvarchar', 'nchar') } { return "$($col.TypeName)($(if ($col.max_length -eq -1) { 'max' } else { $col.max_length / 2 }))" }
			'decimal' { return "decimal($($col.precision),$($col.scale))" }
			'numeric' { return "numeric($($col.precision),$($col.scale))" }
			# datetime2/datetimeoffset/time haben eine Sekundenbruchteil-Genauigkeit (0-7) in
			# sys.columns.scale - ohne diese explizit zu uebernehmen faellt CREATE TABLE auf die
			# Standardgenauigkeit datetime2(7)/... zurueck, was bei abweichender Quellspalten-
			# Genauigkeit (z.B. datetime2(0)) zu einem Typ-Mismatch fuehrt (SWITCH PARTITION lehnt
			# ab bzw. die Partition Function erwartet die urspruengliche Genauigkeit).
			{ $_ -in @('datetime2', 'datetimeoffset', 'time') } { return "$($col.TypeName)($($col.scale))" }
			default { return $col.TypeName }
		}
	}

	# 1. Spalten ----------------------------------------------------------------------------------
	$colDefQuery = @"
SELECT c.name AS ColumnName, ty.name AS TypeName, c.max_length, c.precision, c.scale, c.is_nullable,
    c.is_identity, ic.seed_value, ic.increment_value
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE c.object_id = OBJECT_ID(N'[$Schema].[$Table]')
ORDER BY c.column_id
"@
	$colDefs = Invoke-DbaQuery @connParams -Query $colDefQuery -ErrorAction Stop -EnableException
	$hasIdentity = [bool]($colDefs | Where-Object { [bool]$_.is_identity })

	$colDefSql = ($colDefs | ForEach-Object {
			$nullability = if ($_.is_nullable) { 'NULL' } else { 'NOT NULL' }
			# IDENTITY-Eigenschaft muss zwischen Quelle und Zieltabelle uebereinstimmen - sonst
			# lehnt SWITCH PARTITION mit der irrefuehrenden Meldung "kein identischer Index" ab
			# (SQL Server meldet einen IDENTITY-Mismatch ueber denselben Fehlertext).
			$identityClause = if ([bool]$_.is_identity) { " IDENTITY($($_.seed_value),$($_.increment_value))" } else { '' }
			"[$($_.ColumnName)] $(_FormatColumnType $_)$identityClause $nullability"
		}) -join ', '

	$createTableSql = "CREATE TABLE [$TargetSchema].[$TargetTable] ($colDefSql) ON $onClause;"

	# 2. Indizes / PK / UNIQUE-Constraints ----------------------------------------------------------
	# Ist ein Index als PRIMARY KEY/UNIQUE CONSTRAINT hinterlegt, akzeptiert SQL Server dafuer
	# KEINEN gleichwertigen "einfachen" Index als Gegenstueck - die Constraint-Eigenschaft selbst
	# muss ebenfalls uebereinstimmen (empirisch verifiziert: sonst "kein identischer Index"-Fehler
	# trotz identischer Spalten/Eindeutigkeit).
	$idxQuery = @"
SELECT i.index_id, i.is_unique, i.type_desc, kc.type AS ConstraintType
FROM sys.indexes i
LEFT JOIN sys.key_constraints kc ON kc.parent_object_id = i.object_id AND kc.unique_index_id = i.index_id
WHERE i.object_id = OBJECT_ID(N'[$Schema].[$Table]') AND i.index_id >= 1
ORDER BY i.index_id
"@
	$srcIndexes = Invoke-DbaQuery @connParams -Query $idxQuery -ErrorAction Stop -EnableException
	$indexSql = [System.Collections.Generic.List[string]]::new()

	foreach ($idx in $srcIndexes)
	{
		$idxColQuery = @"
SELECT c.name AS ColumnName, ic.is_descending_key, ic.is_included_column
FROM sys.index_columns ic
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE ic.object_id = OBJECT_ID(N'[$Schema].[$Table]') AND ic.index_id = $($idx.index_id)
ORDER BY ic.is_included_column, ic.key_ordinal, ic.index_column_id
"@
		$idxCols = Invoke-DbaQuery @connParams -Query $idxColQuery -ErrorAction Stop -EnableException
		$keyColNames = @($idxCols | Where-Object { -not [bool]$_.is_included_column } | ForEach-Object { $_.ColumnName })
		$keyCols = @($idxCols | Where-Object { -not [bool]$_.is_included_column } | ForEach-Object { "[$($_.ColumnName)]$(if ([bool]$_.is_descending_key) { ' DESC' })" })
		$includeCols = @($idxCols | Where-Object { [bool]$_.is_included_column } | ForEach-Object { "[$($_.ColumnName)]" })
		$clusterKw = if ($idx.type_desc -eq 'CLUSTERED') { 'CLUSTERED' } else { 'NONCLUSTERED' }
		$includeClause = if ($includeCols.Count -gt 0) { " INCLUDE ($($includeCols -join ', '))" } else { '' }

		# SQL Server verlangt fuer JEDEN eindeutigen Index (PK/UNIQUE-Constraint oder blosser
		# CREATE UNIQUE INDEX) auf einer partitionierten Tabelle, dass die Partitionsspalte Teil
		# des Indexschluessels ist - sonst "Partitionsspalten fuer einen eindeutigen Index muessen
		# eine Teilmenge des Indexschluessels sein". Gilt nur bei -PartitionSchemeName (nicht bei
		# -FilegroupName, z.B. Staging-Tabelle fuer SWITCH PARTITION - die ist unpartitioniert).
		# Nicht-eindeutige Indizes richtet SQL Server automatisch aus, ohne die Spalte im
		# Schluessel zu benoetigen.
		if ($PartitionSchemeName -and [bool]$idx.is_unique -and $PartitionColumn -notin $keyColNames)
		{
			$keyCols += "[$PartitionColumn]"
		}

		if ($idx.ConstraintType -in @('PK', 'UQ'))
		{
			$constraintKw = if ($idx.ConstraintType -eq 'PK') { 'PRIMARY KEY' } else { 'UNIQUE' }
			$constraintName = "${constraintKw}_${TargetTable}_$($idx.index_id)" -replace ' ', '_'
			$indexSql.Add("ALTER TABLE [$TargetSchema].[$TargetTable] ADD CONSTRAINT [$constraintName] $constraintKw $clusterKw ($($keyCols -join ', ')) ON $onClause;")
		}
		else
		{
			$uniqueKw = if ([bool]$idx.is_unique) { 'UNIQUE ' } else { '' }
			$indexSql.Add("CREATE ${uniqueKw}${clusterKw} INDEX [IX_${TargetTable}_$($idx.index_id)] ON [$TargetSchema].[$TargetTable] ($($keyCols -join ', '))$includeClause ON $onClause;")
		}
	}

	return [PSCustomObject]@{
		CreateTableSql = $createTableSql
		IndexSql       = $indexSql.ToArray()
		HasIdentity    = $hasIdentity
		ColumnNames    = @($colDefs | ForEach-Object { $_.ColumnName })
	}
}
