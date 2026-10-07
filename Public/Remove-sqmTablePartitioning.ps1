<#
.SYNOPSIS
    Entfernt die Partitionierung einer Tabelle vollstaendig (Gegenstueck zu
    Invoke-sqmTablePartitionConversion).

.DESCRIPTION
    Holt die Tabelle und alle ihre Indizes vom Partition Scheme auf eine einzelne Filegroup
    zurueck und raeumt danach die nicht mehr benoetigten Partitionierungsobjekte ab:

    1. Pre-Flight (ohne Aenderung): Tabelle vorhanden, keine Memory-Optimized-Tabelle, nur
       unterstuetzte Indextypen (Heap, Clustered/Nonclustered Rowstore, Clustered/Nonclustered
       Columnstore - XML-/Spatial-Indizes muessen vorher entfernt werden), Ziel-Filegroup
       vorhanden.
    2. Clustered Index / PRIMARY KEY / UNIQUE-Constraint und jeder Nonclustered Index auf dem
       Partition Scheme werden per CREATE ... WITH (DROP_EXISTING = ON) ON [<Filegroup>] mit
       unveraenderter Definition (Schluessel, INCLUDE, Filter, Eindeutigkeit, Fuellfaktor, Sperr-
       Optionen, Kompression) neu aufgebaut. Constraints bleiben dabei erhalten, auch wenn
       Fremdschluessel auf sie verweisen. Deaktivierte Nonclustered-Indizes werden mitverschoben
       und danach wieder deaktiviert.
       Columnstore verlangt auf einer partitionierten Tabelle, dass alle Indizes partitions-
       ausgerichtet sind; ein Umzug per DROP_EXISTING ist dann nicht moeglich. Ein Nonclustered
       Columnstore Index - und bei einem Clustered Columnstore Index alle Nonclustered-Indizes -
       werden deshalb vor dem Umbau entfernt und am Ende mit derselben Definition auf der Ziel-
       Filegroup neu angelegt (PRIMARY KEY/UNIQUE-Constraints per ALTER TABLE; verweisen
       Fremdschluessel darauf, bricht die Funktion vorher ab). Bricht der Lauf dazwischen ab,
       steht die DDL der noch fehlenden Indizes in der Fehlermeldung. Ein Clustered Columnstore
       Index selbst laesst sich auf keinem direkten Weg umziehen: er wird entfernt, der Heap wie
       unter 3. umgezogen und der Index auf der Ziel-Filegroup neu angelegt (die Daten werden
       dabei einmal dekomprimiert und neu komprimiert).
    3. Heap: SQL Server kann einen Heap nicht direkt verschieben. Es wird ein temporaerer Clustered
       Index (sqmUnpartitionTmp) auf der Ziel-Filegroup angelegt und sofort wieder entfernt; der
       Heap bleibt danach auf der Ziel-Filegroup. Bleibt der temporaere Index nach einem Abbruch
       zurueck, raeumt ein erneuter Aufruf ihn ab.
    4. Partition Scheme(s) und Partition Function(s), die danach von keinem Objekt mehr verwendet
       werden, werden gedroppt. Noch anderweitig verwendete bleiben mit Warnung bestehen.
    5. Optional (-RemoveEmptyFilegroups): Filegroups des entfernten Schemes, die jetzt leer sind,
       werden samt Dateien entfernt (DBCC SHRINKFILE EMPTYFILE, REMOVE FILE, REMOVE FILEGROUP).
       Nie PRIMARY, die Standard-Filegroup oder die Ziel-Filegroup.
    6. Der Eintrag in master.dbo.sqm_PartitionRegistry wird geloescht (ausser
       -KeepRegistration), sonst wuerden die Wartungs-Jobs eine nicht mehr partitionierte Tabelle
       weiter bearbeiten wollen.

    Wiederholbar: bricht ein Lauf ab, setzt ein erneuter Aufruf bei den noch partitionierten
    Indizes fort. Ist die Tabelle selbst schon unpartitioniert, werden Scheme/Function aus dem
    Registry-Eintrag ermittelt und abgeraeumt.

    NICHT rueckgaengig gemacht wird eine bei der Konvertierung vorgenommene Erweiterung des
    PRIMARY KEY/UNIQUE-Constraints um die Partitionsspalte (-AllowKeyChange): welche Spalte damals
    angehaengt wurde, ist nicht mehr feststellbar, und ein Entfernen wuerde die Eindeutigkeits-
    Semantik aendern. Ein durch die Konvertierung eines Heaps angelegter Clustered Index
    (IX_<Tabelle>_<Spalte>) bleibt als normaler Clustered Index bestehen.

    Jeder Index wird dabei einmal komplett neu geschrieben (Dauer und Transaktionsprotokoll wie
    bei einem Index-Rebuild); bei Heaps mit Nonclustered-Indizes werden diese durch den
    temporaeren Clustered Index zusaetzlich zweimal neu aufgebaut.

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER Database
    Datenbank der Tabelle.
.PARAMETER Schema
    Schema der Tabelle.
.PARAMETER Table
    Tabellenname.
.PARAMETER TargetFilegroup
    Filegroup, auf der Tabelle und Indizes danach liegen. Standard: die Standard-Filegroup der
    Datenbank (meist PRIMARY).
.PARAMETER RemoveEmptyFilegroups
    Filegroups des entfernten Partition Schemes, die danach leer sind, samt ihrer Dateien
    entfernen. Fehler dabei (z.B. Datei erst nach der naechsten Protokollsicherung entfernbar)
    werden nur als Warnung gemeldet.
.PARAMETER Online
    Versucht ONLINE=ON fuer die Rowstore-Indizes (nur Enterprise/Developer Edition). Faellt auf
    anderen Editionen automatisch mit Warnung auf OFFLINE zurueck. Columnstore-Indizes werden
    immer offline neu aufgebaut.
.PARAMETER KeepRegistration
    Registry-Eintrag in master.dbo.sqm_PartitionRegistry nicht loeschen.
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.OUTPUTS
    PSCustomObject mit Status (Success | NotPartitioned | WhatIf), TargetFilegroup,
    IndexesMoved, DroppedPartitionSchemes, DroppedPartitionFunctions, RemovedFilegroups,
    Unregistered, Warnings und Statements (die ausgefuehrte bzw. bei -WhatIf geplante DDL).

.EXAMPLE
    Remove-sqmTablePartitioning -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" -WhatIf

    Zeigt die geplante DDL, ohne etwas zu aendern.

.EXAMPLE
    Remove-sqmTablePartitioning -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" `
        -TargetFilegroup "PRIMARY" -RemoveEmptyFilegroups -Confirm:$false

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool).
#>
function Remove-sqmTablePartitioning
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
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
		[string]$TargetFilegroup,

		[Parameter(Mandatory = $false)]
		[switch]$RemoveEmptyFilegroups,

		[Parameter(Mandatory = $false)]
		[switch]$Online,

		[Parameter(Mandatory = $false)]
		[switch]$KeepRegistration,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
	$objName = "[$Schema].[$Table]" -replace "'", "''"
	$tmpIndexName = 'sqmUnpartitionTmp'
	$warnings = [System.Collections.Generic.List[string]]::new()
	$addWarning = {
		param ([string]$Text)
		$warnings.Add($Text)
		Invoke-sqmLogging -Message $Text -FunctionName $functionName -Level "WARNING"
	}

	try
	{
		# =========================================================================================
		# 1. Pre-Flight: Tabelle, Indizes, Ziel-Filegroup
		# =========================================================================================
		$tbl = Invoke-DbaQuery @connParams -Query "SELECT t.object_id, t.is_memory_optimized, t.lob_data_space_id, ds.type AS LobDataSpaceType FROM sys.tables t LEFT JOIN sys.data_spaces ds ON ds.data_space_id = t.lob_data_space_id WHERE t.object_id = OBJECT_ID(N'$objName');" -ErrorAction Stop -EnableException -As PSObject
		if (-not $tbl) { throw "Tabelle '$Schema.$Table' nicht gefunden in Datenbank '$Database'." }
		if ([bool]$tbl.is_memory_optimized) { throw "'$Schema.$Table' ist eine Memory-Optimized-Tabelle - nicht unterstuetzt." }

		$idxQuery = @"
SELECT i.index_id, i.name AS IndexName, i.type AS IndexType, i.type_desc, i.is_unique, i.is_primary_key,
       i.is_unique_constraint, i.is_disabled, i.has_filter, i.filter_definition, i.fill_factor, i.is_padded,
       i.allow_row_locks, i.allow_page_locks, i.ignore_dup_key,
       ds.type AS DataSpaceType, ds.name AS DataSpaceName, ds.data_space_id
FROM sys.indexes i
JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id
WHERE i.object_id = OBJECT_ID(N'$objName')
ORDER BY i.index_id;
"@
		$indexes = @(Invoke-DbaQuery @connParams -Query $idxQuery -ErrorAction Stop -EnableException -As PSObject)
		$base = $indexes | Where-Object { [int]$_.index_id -le 1 } | Select-Object -First 1
		$partitionedIndexes = @($indexes | Where-Object { $_.DataSpaceType -eq 'PS' })

		$unsupported = @($indexes | Where-Object { [int]$_.IndexType -notin 0, 1, 2, 5, 6 })
		if ($unsupported.Count -gt 0 -and $partitionedIndexes.Count -gt 0)
		{
			throw "Nicht unterstuetzte Indextypen auf '$Schema.$Table': $(($unsupported | ForEach-Object { "$($_.IndexName) ($($_.type_desc))" }) -join ', '). Diese vorher entfernen und danach neu anlegen."
		}
		if ($base -and [int]$base.index_id -eq 1 -and [bool]$base.is_disabled)
		{
			throw "Der Clustered Index '$($base.IndexName)' von '$Schema.$Table' ist deaktiviert - die Tabelle ist nicht lesbar. Erst neu aufbauen (ALTER INDEX ... REBUILD)."
		}

		# Ziel-Filegroup
		if (-not $TargetFilegroup)
		{
			$TargetFilegroup = [string](Invoke-DbaQuery @connParams -Query "SELECT name FROM sys.filegroups WHERE is_default = 1;" -ErrorAction Stop -EnableException -As PSObject).name
			Invoke-sqmLogging -Message "-TargetFilegroup nicht angegeben - Standard-Filegroup der Datenbank wird verwendet: '$TargetFilegroup'." -FunctionName $functionName -Level "INFO"
		}
		$fgLiteral = $TargetFilegroup -replace "'", "''"
		$targetFg = Invoke-DbaQuery @connParams -Query "SELECT data_space_id, type FROM sys.filegroups WHERE name = N'$fgLiteral';" -ErrorAction Stop -EnableException -As PSObject
		if (-not $targetFg) { throw "Filegroup '$TargetFilegroup' existiert nicht in Datenbank '$Database'." }
		if ($targetFg.type -ne 'FG') { throw "Filegroup '$TargetFilegroup' ist keine Rowstore-Filegroup (Typ $($targetFg.type))." }

		# Partition Schemes, die die Tabelle verwendet (Indizes + LOB-Daten). Ist die Tabelle schon
		# unpartitioniert (Wiederholung nach Abbruch), aus dem Registry-Eintrag.
		$schemeIds = [System.Collections.Generic.List[int]]::new()
		foreach ($ix in $partitionedIndexes) { if (-not $schemeIds.Contains([int]$ix.data_space_id)) { $schemeIds.Add([int]$ix.data_space_id) } }
		if ($tbl.LobDataSpaceType -eq 'PS' -and -not $schemeIds.Contains([int]$tbl.lob_data_space_id)) { $schemeIds.Add([int]$tbl.lob_data_space_id) }

		$registryRow = $null
		$regQuery = @"
IF OBJECT_ID(N'master.dbo.sqm_PartitionRegistry') IS NOT NULL
    SELECT RegistryId, PartitionSchemeName, PartitionFunctionName
    FROM master.dbo.sqm_PartitionRegistry
    WHERE DatabaseName = N'$($Database -replace "'", "''")' AND SchemaName = N'$($Schema -replace "'", "''")' AND TableName = N'$($Table -replace "'", "''")';
"@
		$registryRow = Invoke-DbaQuery @connParams -Query $regQuery -ErrorAction Stop -EnableException -As PSObject | Select-Object -First 1

		if ($schemeIds.Count -eq 0 -and $registryRow)
		{
			$psRow = Invoke-DbaQuery @connParams -Query "SELECT data_space_id FROM sys.partition_schemes WHERE name = N'$($registryRow.PartitionSchemeName -replace "'", "''")';" -ErrorAction Stop -EnableException -As PSObject
			if ($psRow)
			{
				$schemeIds.Add([int]$psRow.data_space_id)
				Invoke-sqmLogging -Message "'$Schema.$Table' ist bereits unpartitioniert - Partition Scheme '$($registryRow.PartitionSchemeName)' aus dem Registry-Eintrag wird abgeraeumt, falls unbenutzt." -FunctionName $functionName -Level "INFO"
			}
		}

		$leftoverTmp = $base -and [int]$base.index_id -eq 1 -and $base.IndexName -eq $tmpIndexName
		if ($schemeIds.Count -eq 0 -and -not $leftoverTmp -and -not $registryRow)
		{
			Invoke-sqmLogging -Message "'$Schema.$Table' ist nicht partitioniert - nichts zu tun." -FunctionName $functionName -Level "INFO"
			return [PSCustomObject]@{
				SchemaName = $Schema; TableName = $Table; TargetFilegroup = $TargetFilegroup; Status = 'NotPartitioned'
				IndexesMoved = @(); DroppedPartitionSchemes = @(); DroppedPartitionFunctions = @(); RemovedFilegroups = @()
				Unregistered = $false; Warnings = @(); Statements = @()
			}
		}

		# =========================================================================================
		# 2. Edition (ONLINE), Spalten und Kompression je Index
		# =========================================================================================
		$onlineEdition = $false
		if ($Online)
		{
			try
			{
				$edResult = Invoke-DbaQuery @connParams -Query "SELECT CAST(SERVERPROPERTY('EngineEdition') AS INT) AS EngineEdition" -ErrorAction Stop -As PSObject
				$onlineEdition = ([int]$edResult.EngineEdition -eq 3)
				if (-not $onlineEdition) { & $addWarning "-Online angefordert, aber EngineEdition ist nicht Enterprise/Developer - falle zurueck auf OFFLINE." }
			}
			catch { $onlineEdition = $false }
		}
		if ($onlineEdition -and @($indexes | Where-Object { [int]$_.IndexType -in 5, 6 }).Count -gt 0)
		{
			# SQL Server: "the operation cannot be performed online on a table with a columnstore index"
			& $addWarning "-Online: '$Schema.$Table' hat einen Columnstore Index - Indexoperationen sind dann nicht online moeglich, falle zurueck auf OFFLINE."
			$onlineEdition = $false
		}
		$onlineClause = if ($onlineEdition) { 'ON' } else { 'OFF' }

		$colQuery = @"
SELECT ic.index_id, c.name AS ColumnName, ic.key_ordinal, ic.is_descending_key, ic.is_included_column,
       ic.partition_ordinal, ic.index_column_id
FROM sys.index_columns ic
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE ic.object_id = OBJECT_ID(N'$objName');
"@
		$allCols = @(Invoke-DbaQuery @connParams -Query $colQuery -ErrorAction Stop -EnableException -As PSObject)

		$compQuery = @"
SELECT p.index_id, p.data_compression_desc, COUNT(*) AS PartitionCount
FROM sys.partitions p
WHERE p.object_id = OBJECT_ID(N'$objName')
GROUP BY p.index_id, p.data_compression_desc;
"@
		$compRows = @(Invoke-DbaQuery @connParams -Query $compQuery -ErrorAction Stop -EnableException -As PSObject)
		$getCompression = {
			param ([int]$IndexId, [string]$IndexName)
			$rows = @($compRows | Where-Object { [int]$_.index_id -eq $IndexId } | Sort-Object { [int]$_.PartitionCount } -Descending)
			if ($rows.Count -eq 0) { return 'NONE' }
			if ($rows.Count -gt 1)
			{
				& $addWarning "Index '$IndexName' hat je Partition unterschiedliche Kompression ($(($rows | ForEach-Object { "$($_.data_compression_desc) x$($_.PartitionCount)" }) -join ', ')) - verwendet wird die haeufigste: $($rows[0].data_compression_desc)."
			}
			return [string]$rows[0].data_compression_desc
		}

		# =========================================================================================
		# 3. DDL planen
		# =========================================================================================
		$statements = [System.Collections.Generic.List[object]]::new()
		$movedIndexes = [System.Collections.Generic.List[string]]::new()
		$fgQuoted = "[$($TargetFilegroup -replace '\]', ']]')]"

		$buildIndexDdl = {
			param ($ix, [bool]$Recreate = $false)
			$id = [int]$ix.index_id
			$cols = @($allCols | Where-Object { [int]$_.index_id -eq $id })
			$compression = & $getCompression $id $ix.IndexName
			$name = "[$($ix.IndexName -replace '\]', ']]')]"
			$whereSql = if ([bool]$ix.has_filter) { " WHERE $($ix.filter_definition)" } else { '' }

			switch ([int]$ix.IndexType)
			{
				5
				{
					$dropExisting = if ($Recreate) { '' } else { 'DROP_EXISTING = ON, ' }
					return "CREATE CLUSTERED COLUMNSTORE INDEX $name ON [$Schema].[$Table] WITH (${dropExisting}DATA_COMPRESSION = $compression) ON $fgQuoted;"
				}
				6
				{
					$csCols = ($cols | Where-Object { [bool]$_.is_included_column -or [int]$_.key_ordinal -gt 0 } | Sort-Object { [int]$_.index_column_id } | ForEach-Object { "[$($_.ColumnName)]" }) -join ', '
					$dropExisting = if ($Recreate) { '' } else { 'DROP_EXISTING = ON, ' }
					return "CREATE NONCLUSTERED COLUMNSTORE INDEX $name ON [$Schema].[$Table] ($csCols)$whereSql WITH (${dropExisting}DATA_COMPRESSION = $compression) ON $fgQuoted;"
				}
				default
				{
					# Nur echte Schluessel- und INCLUDE-Spalten. Die von SQL Server bei partitionierten
					# Indizes intern angehaengte Partitionsspalte (key_ordinal = 0, nicht included)
					# gehoert nicht zur Definition und faellt hier weg.
					$keyCols = ($cols | Where-Object { [int]$_.key_ordinal -gt 0 } | Sort-Object { [int]$_.key_ordinal } | ForEach-Object { "[$($_.ColumnName)]$(if ([bool]$_.is_descending_key) { ' DESC' })" }) -join ', '
					$inclCols = @($cols | Where-Object { [bool]$_.is_included_column } | Sort-Object { [int]$_.index_column_id } | ForEach-Object { "[$($_.ColumnName)]" })
					$inclSql = if ($inclCols.Count -gt 0) { " INCLUDE ($($inclCols -join ', '))" } else { '' }

					$opts = [System.Collections.Generic.List[string]]::new()
					if (-not $Recreate) { $opts.Add('DROP_EXISTING = ON') }
					$opts.Add("ONLINE = $onlineClause")
					if ([int]$ix.fill_factor -gt 0) { $opts.Add("FILLFACTOR = $([int]$ix.fill_factor)") }
					if ([bool]$ix.is_padded) { $opts.Add('PAD_INDEX = ON') }
					if (-not [bool]$ix.allow_row_locks) { $opts.Add('ALLOW_ROW_LOCKS = OFF') }
					if (-not [bool]$ix.allow_page_locks) { $opts.Add('ALLOW_PAGE_LOCKS = OFF') }
					if ([bool]$ix.ignore_dup_key) { $opts.Add('IGNORE_DUP_KEY = ON') }
					$opts.Add("DATA_COMPRESSION = $compression")

					$uniqueKw = if ([bool]$ix.is_unique) { 'UNIQUE ' } else { '' }
					$typeKw = if ([int]$ix.IndexType -eq 1) { 'CLUSTERED' } else { 'NONCLUSTERED' }
					if ($Recreate -and ([bool]$ix.is_primary_key -or [bool]$ix.is_unique_constraint))
					{
						$constraintKw = if ([bool]$ix.is_primary_key) { 'PRIMARY KEY' } else { 'UNIQUE' }
						return "ALTER TABLE [$Schema].[$Table] ADD CONSTRAINT $name $constraintKw $typeKw ($keyCols) WITH ($($opts -join ', ')) ON $fgQuoted;"
					}
					return "CREATE $uniqueKw$typeKw INDEX $name ON [$Schema].[$Table] ($keyCols)$inclSql$whereSql WITH ($($opts -join ', ')) ON $fgQuoted;"
				}
			}
		}

		# Reihenfolge: Basis (Heap bzw. Clustered Index), danach die Nonclustered-Indizes per
		# DROP_EXISTING. Columnstore verlangt dagegen auf einer partitionierten Tabelle, dass alles
		# partitionsausgerichtet ist (live verifiziert, SQL Server 2022):
		# - ein Nonclustered Columnstore Index kann weder vor noch nach der Basis umziehen;
		# - bei einem Clustered Columnstore Index kann weder ein Nonclustered Index vorher noch der
		#   Columnstore Index vor den Nonclustered-Indizes umziehen.
		# Diese Indizes werden deshalb vor dem Umbau der Basis entfernt und am Ende mit derselben
		# Definition auf der Ziel-Filegroup neu angelegt.
		$baseStatements = [System.Collections.Generic.List[object]]::new()
		$baseDropStatements = [System.Collections.Generic.List[object]]::new()
		$baseRecreateStatements = [System.Collections.Generic.List[object]]::new()
		$baseIsColumnstore = $base -and [int]$base.IndexType -eq 5
		if ($base -and ([int]$base.index_id -eq 0 -or $baseIsColumnstore) -and $base.DataSpaceType -eq 'PS')
		{
			$partCol = $allCols | Where-Object { [int]$_.index_id -eq [int]$base.index_id -and [int]$_.partition_ordinal -eq 1 } | Select-Object -First 1
			if (-not $partCol) { throw "Partitionsspalte von '$Schema.$Table' nicht ermittelbar." }
			$heapCompression = 'NONE'
			if ($baseIsColumnstore)
			{
				# Ein partitionierter Clustered Columnstore Index laesst sich weder per DROP_EXISTING
				# (auch nicht ueber einen Rowstore-Zwischenschritt) noch per DROP INDEX ... MOVE TO
				# umziehen, und auf einem partitionierten Heap nicht auf einer Filegroup neu anlegen.
				# Einziger Weg: entfernen, Heap umziehen, auf der Ziel-Filegroup neu anlegen.
				$cciSql = & $buildIndexDdl $base $true
				$cciQuoted = "[$($base.IndexName -replace '\]', ']]')]"
				$baseDropStatements.Add([PSCustomObject]@{ Step = "Clustered Columnstore Index '$($base.IndexName)' entfernen (wird danach neu angelegt)"; Sql = "DROP INDEX $cciQuoted ON [$Schema].[$Table];"; DropsIndex = $base.IndexName; RecreateSql = $cciSql })
				$baseRecreateStatements.Add([PSCustomObject]@{ Step = "Clustered Columnstore Index '$($base.IndexName)' auf '$TargetFilegroup' neu anlegen"; Sql = $cciSql; RecreatesIndex = $base.IndexName })
			}
			else
			{
				$heapCompression = & $getCompression 0 '(Heap)'
			}
			$baseStatements.Add([PSCustomObject]@{ Step = "Heap auf '$TargetFilegroup' (temporaerer Clustered Index)"; Sql = "CREATE CLUSTERED INDEX [$tmpIndexName] ON [$Schema].[$Table] ([$($partCol.ColumnName)]) WITH (ONLINE = $onlineClause, DATA_COMPRESSION = $heapCompression) ON $fgQuoted;" })
			$baseStatements.Add([PSCustomObject]@{ Step = "Temporaeren Clustered Index entfernen"; Sql = "DROP INDEX [$tmpIndexName] ON [$Schema].[$Table] WITH (ONLINE = $onlineClause);" })
			$movedIndexes.Add($(if ($baseIsColumnstore) { $base.IndexName } else { '(Heap)' }))
		}
		elseif ($leftoverTmp)
		{
			# Rest eines abgebrochenen Laufs: Heap steckt noch im temporaeren Clustered Index.
			if ($base.DataSpaceType -eq 'PS')
			{
				$baseStatements.Add([PSCustomObject]@{ Step = "Temporaerer Clustered Index (Rest eines frueheren Laufs) auf '$TargetFilegroup'"; Sql = (& $buildIndexDdl $base) })
			}
			$baseStatements.Add([PSCustomObject]@{ Step = "Temporaeren Clustered Index (Rest eines frueheren Laufs) entfernen"; Sql = "DROP INDEX [$tmpIndexName] ON [$Schema].[$Table] WITH (ONLINE = $onlineClause);" })
			$movedIndexes.Add('(Heap)')
		}
		elseif ($base -and [int]$base.index_id -eq 1 -and $base.DataSpaceType -eq 'PS')
		{
			$baseStatements.Add([PSCustomObject]@{ Step = "Clustered Index '$($base.IndexName)' auf '$TargetFilegroup'"; Sql = (& $buildIndexDdl $base) })
			$movedIndexes.Add($base.IndexName)
		}
		$baseMoves = $baseStatements.Count -gt 0

		$recreateStatements = [System.Collections.Generic.List[object]]::new()
		$dropStatements = [System.Collections.Generic.List[object]]::new()
		$moveStatements = [System.Collections.Generic.List[object]]::new()
		foreach ($ix in ($partitionedIndexes | Where-Object { [int]$_.index_id -gt 1 }))
		{
			$ixQuoted = "[$($ix.IndexName -replace '\]', ']]')]"
			$target = $moveStatements
			if ($baseMoves -and ([int]$ix.IndexType -eq 6 -or $baseIsColumnstore))
			{
				$isConstraint = [bool]$ix.is_primary_key -or [bool]$ix.is_unique_constraint
				if ($isConstraint)
				{
					$fkRefs = @(Invoke-DbaQuery @connParams -Query "SELECT fk.name AS ForeignKeyName, OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id) AS ReferencingTable FROM sys.foreign_keys fk WHERE fk.referenced_object_id = OBJECT_ID(N'$objName') AND fk.key_index_id = $([int]$ix.index_id);" -ErrorAction Stop -EnableException -As PSObject)
					if ($fkRefs.Count -gt 0)
					{
						throw "Constraint '$($ix.IndexName)' muss fuer den Columnstore-Umbau entfernt und neu angelegt werden, aber Fremdschluessel verweisen darauf: $(($fkRefs | ForEach-Object { "$($_.ReferencingTable) ($($_.ForeignKeyName))" }) -join '; '). Diese vorher entfernen und danach neu anlegen."
					}
				}
				$createSql = & $buildIndexDdl $ix $true
				$dropSql = if ($isConstraint) { "ALTER TABLE [$Schema].[$Table] DROP CONSTRAINT $ixQuoted;" } else { "DROP INDEX $ixQuoted ON [$Schema].[$Table];" }
				$dropStatements.Add([PSCustomObject]@{ Step = "Index '$($ix.IndexName)' entfernen (wird danach neu angelegt)"; Sql = $dropSql; DropsIndex = $ix.IndexName; RecreateSql = $createSql })
				$recreateStatements.Add([PSCustomObject]@{ Step = "Index '$($ix.IndexName)' auf '$TargetFilegroup' neu anlegen"; Sql = $createSql; RecreatesIndex = $ix.IndexName })
				$target = $recreateStatements
			}
			else
			{
				$moveStatements.Add([PSCustomObject]@{ Step = "Index '$($ix.IndexName)' auf '$TargetFilegroup'"; Sql = (& $buildIndexDdl $ix) })
			}
			if ([bool]$ix.is_disabled)
			{
				# Neuaufbau aktiviert den Index - vorherigen Zustand wiederherstellen.
				$target.Add([PSCustomObject]@{ Step = "Index '$($ix.IndexName)' wieder deaktivieren (war deaktiviert)"; Sql = "ALTER INDEX $ixQuoted ON [$Schema].[$Table] DISABLE;" })
			}
			$movedIndexes.Add($ix.IndexName)
		}
		# Gesamtreihenfolge: DROPs, Basis, Nonclustered per DROP_EXISTING, Neuanlagen
		foreach ($list in @($dropStatements, $baseDropStatements, $baseStatements, $moveStatements, $baseRecreateStatements, $recreateStatements))
		{
			foreach ($st in $list) { $statements.Add($st) }
		}

		# Filegroups der betroffenen Schemes merken, bevor die Schemes gedroppt werden.
		$schemeInfo = @()
		$schemeFilegroups = @()
		if ($schemeIds.Count -gt 0)
		{
			$idList = $schemeIds -join ','
			$schemeInfo = @(Invoke-DbaQuery @connParams -Query "SELECT ps.data_space_id, ps.name AS SchemeName, ps.function_id, pf.name AS FunctionName FROM sys.partition_schemes ps JOIN sys.partition_functions pf ON pf.function_id = ps.function_id WHERE ps.data_space_id IN ($idList);" -ErrorAction Stop -EnableException -As PSObject)
			$schemeFilegroups = @(Invoke-DbaQuery @connParams -Query "SELECT DISTINCT fg.data_space_id, fg.name AS FilegroupName FROM sys.destination_data_spaces dds JOIN sys.filegroups fg ON fg.data_space_id = dds.data_space_id WHERE dds.partition_scheme_id IN ($idList);" -ErrorAction Stop -EnableException -As PSObject)
		}

		$applyAction = "Partitionierung von '$Schema.$Table' entfernen ($($movedIndexes.Count) Index/Indizes auf '$TargetFilegroup', Scheme(s): $(($schemeInfo | ForEach-Object { $_.SchemeName }) -join ', '))"
		if (-not $PSCmdlet.ShouldProcess($Database, $applyAction))
		{
			return [PSCustomObject]@{
				SchemaName = $Schema; TableName = $Table; TargetFilegroup = $TargetFilegroup; Status = 'WhatIf'
				IndexesMoved = @($movedIndexes); DroppedPartitionSchemes = @($schemeInfo | ForEach-Object { $_.SchemeName })
				DroppedPartitionFunctions = @($schemeInfo | ForEach-Object { $_.FunctionName } | Select-Object -Unique)
				RemovedFilegroups = @(); Unregistered = $false; Warnings = @($warnings); Statements = @($statements | ForEach-Object { $_.Sql })
			}
		}

		# =========================================================================================
		# 4. Indizes verschieben
		# =========================================================================================
		Invoke-sqmLogging -Message "$applyAction - Start. Jeder Index wird dabei komplett neu geschrieben." -FunctionName $functionName -Level "INFO"
		# Entfernte, noch nicht neu angelegte Indizes: bei einem Abbruch gehoert ihre DDL in die
		# Fehlermeldung, ein erneuter Aufruf kennt sie nicht mehr.
		$pendingRecreate = [ordered]@{}
		foreach ($st in $statements)
		{
			Invoke-sqmLogging -Message "$($st.Step) ..." -FunctionName $functionName -Level "INFO"
			try
			{
				Invoke-DbaQuery @connParams -Query $st.Sql -ErrorAction Stop -EnableException | Out-Null
			}
			catch
			{
				$msg = "$($st.Step) fehlgeschlagen: $($_.Exception.Message) (erneuter Aufruf setzt bei den noch partitionierten Indizes fort)"
				if ($pendingRecreate.Count -gt 0)
				{
					$msg += " ACHTUNG: entfernte Indizes manuell neu anlegen: $($pendingRecreate.Values -join ' ')"
				}
				throw $msg
			}
			if ($st.PSObject.Properties['DropsIndex']) { $pendingRecreate[$st.DropsIndex] = $st.RecreateSql }
			if ($st.PSObject.Properties['RecreatesIndex']) { $pendingRecreate.Remove($st.RecreatesIndex) }
		}

		# =========================================================================================
		# 5. Unbenutzte Partition Schemes und Functions entfernen
		# =========================================================================================
		$droppedSchemes = [System.Collections.Generic.List[string]]::new()
		$droppedFunctions = [System.Collections.Generic.List[string]]::new()
		foreach ($s in $schemeInfo)
		{
			$usersQuery = @"
SELECT OBJECT_SCHEMA_NAME(i.object_id) + '.' + OBJECT_NAME(i.object_id) + ISNULL('.' + i.name, '') AS UsedBy FROM sys.indexes i WHERE i.data_space_id = $([int]$s.data_space_id)
UNION ALL
SELECT OBJECT_SCHEMA_NAME(t.object_id) + '.' + t.name + ' (LOB)' FROM sys.tables t WHERE t.lob_data_space_id = $([int]$s.data_space_id)
UNION ALL
SELECT OBJECT_SCHEMA_NAME(t.object_id) + '.' + t.name + ' (FILESTREAM)' FROM sys.tables t WHERE t.filestream_data_space_id = $([int]$s.data_space_id);
"@
			$users = @(Invoke-DbaQuery @connParams -Query $usersQuery -ErrorAction Stop -EnableException -As PSObject)
			if ($users.Count -gt 0)
			{
				& $addWarning "Partition Scheme '$($s.SchemeName)' wird noch verwendet und bleibt bestehen: $(($users | Select-Object -First 10 | ForEach-Object { $_.UsedBy }) -join ', ')$(if ($users.Count -gt 10) { ' ...' })."
				continue
			}
			Invoke-DbaQuery @connParams -Query "DROP PARTITION SCHEME [$($s.SchemeName -replace '\]', ']]')];" -ErrorAction Stop -EnableException | Out-Null
			$droppedSchemes.Add($s.SchemeName)
			Invoke-sqmLogging -Message "Partition Scheme '$($s.SchemeName)' entfernt." -FunctionName $functionName -Level "INFO"
		}

		foreach ($f in ($schemeInfo | Group-Object function_id | ForEach-Object { $_.Group[0] }))
		{
			$fnUsers = @(Invoke-DbaQuery @connParams -Query "SELECT name FROM sys.partition_schemes WHERE function_id = $([int]$f.function_id);" -ErrorAction Stop -EnableException -As PSObject)
			if ($fnUsers.Count -gt 0)
			{
				& $addWarning "Partition Function '$($f.FunctionName)' wird noch von Scheme(s) $(($fnUsers | ForEach-Object { $_.name }) -join ', ') verwendet und bleibt bestehen."
				continue
			}
			Invoke-DbaQuery @connParams -Query "DROP PARTITION FUNCTION [$($f.FunctionName -replace '\]', ']]')];" -ErrorAction Stop -EnableException | Out-Null
			$droppedFunctions.Add($f.FunctionName)
			Invoke-sqmLogging -Message "Partition Function '$($f.FunctionName)' entfernt." -FunctionName $functionName -Level "INFO"
		}

		# =========================================================================================
		# 6. Optional: leere Filegroups entfernen
		# =========================================================================================
		$removedFilegroups = [System.Collections.Generic.List[string]]::new()
		if ($RemoveEmptyFilegroups)
		{
			$dbQuoted = "[$($Database -replace '\]', ']]')]"
			foreach ($fg in $schemeFilegroups)
			{
				$fgId = [int]$fg.data_space_id
				$fgName = [string]$fg.FilegroupName
				if ($fgId -eq 1 -or $fgId -eq [int]$targetFg.data_space_id) { continue }

				$useQuery = @"
SELECT
    (SELECT is_default FROM sys.filegroups WHERE data_space_id = $fgId) AS IsDefault,
    (SELECT COUNT(*) FROM sys.allocation_units WHERE data_space_id = $fgId) AS AllocationUnits,
    (SELECT COUNT(*) FROM sys.destination_data_spaces WHERE data_space_id = $fgId) AS SchemeUses,
    (SELECT COUNT(*) FROM sys.indexes WHERE data_space_id = $fgId) AS IndexUses,
    (SELECT COUNT(*) FROM sys.tables WHERE lob_data_space_id = $fgId OR filestream_data_space_id = $fgId) AS TableUses;
"@
				$use = Invoke-DbaQuery @connParams -Query $useQuery -ErrorAction Stop -EnableException -As PSObject
				if ([bool]$use.IsDefault)
				{
					& $addWarning "Filegroup '$fgName' ist die Standard-Filegroup der Datenbank und bleibt bestehen."
					continue
				}
				if ([int]$use.AllocationUnits -gt 0 -or [int]$use.SchemeUses -gt 0 -or [int]$use.IndexUses -gt 0 -or [int]$use.TableUses -gt 0)
				{
					& $addWarning "Filegroup '$fgName' ist nicht leer bzw. wird noch verwendet und bleibt bestehen."
					continue
				}

				try
				{
					$files = @(Invoke-DbaQuery @connParams -Query "SELECT name FROM sys.database_files WHERE data_space_id = $fgId;" -ErrorAction Stop -EnableException -As PSObject)
					foreach ($file in $files)
					{
						$fileLiteral = ([string]$file.name) -replace "'", "''"
						Invoke-DbaQuery @connParams -Query "DBCC SHRINKFILE (N'$fileLiteral', EMPTYFILE) WITH NO_INFOMSGS;" -ErrorAction Stop -EnableException | Out-Null
						Invoke-DbaQuery @connParams -Query "ALTER DATABASE $dbQuoted REMOVE FILE [$(([string]$file.name) -replace '\]', ']]')];" -ErrorAction Stop -EnableException | Out-Null
					}
					Invoke-DbaQuery @connParams -Query "ALTER DATABASE $dbQuoted REMOVE FILEGROUP [$($fgName -replace '\]', ']]')];" -ErrorAction Stop -EnableException | Out-Null
					$removedFilegroups.Add($fgName)
					Invoke-sqmLogging -Message "Filegroup '$fgName' samt $($files.Count) Datei(en) entfernt." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					& $addWarning "Filegroup '$fgName' konnte nicht entfernt werden: $($_.Exception.Message) (im FULL-Recovery-Modell ggf. erst nach der naechsten Protokollsicherung erneut versuchen)."
				}
			}
		}

		# =========================================================================================
		# 7. Registry-Eintrag entfernen
		# =========================================================================================
		$unregistered = $false
		if ($registryRow -and -not $KeepRegistration)
		{
			$unregParams = @{ SqlInstance = $SqlInstance; DatabaseName = $Database; SchemaName = $Schema; TableName = $Table; Purge = $true }
			if ($SqlCredential) { $unregParams['SqlCredential'] = $SqlCredential }
			Remove-sqmPartitionRegistration @unregParams -Confirm:$false | Out-Null
			$unregistered = $true
		}
		elseif ($registryRow)
		{
			& $addWarning "Registry-Eintrag fuer '$Schema.$Table' bleibt bestehen (-KeepRegistration) - die Wartungs-Jobs werden fuer diese Tabelle fehlschlagen, bis er entfernt ist."
		}

		Invoke-sqmLogging -Message "$applyAction - erfolgreich." -FunctionName $functionName -Level "INFO"

		return [PSCustomObject]@{
			SchemaName                = $Schema
			TableName                 = $Table
			TargetFilegroup           = $TargetFilegroup
			Status                    = 'Success'
			IndexesMoved              = @($movedIndexes)
			DroppedPartitionSchemes   = @($droppedSchemes)
			DroppedPartitionFunctions = @($droppedFunctions)
			RemovedFilegroups         = @($removedFilegroups)
			Unregistered              = $unregistered
			Warnings                  = @($warnings)
			Statements                = @($statements | ForEach-Object { $_.Sql })
		}
	}
	catch
	{
		$msg = "Fehler in ${functionName}: $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		throw
	}
}
