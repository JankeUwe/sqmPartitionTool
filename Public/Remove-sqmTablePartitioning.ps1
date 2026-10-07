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
    temporaeren Clustered Index zusaetzlich zweimal neu aufgebaut. Vor jeder Aenderung wird
    geprueft, ob Tabelle und Indizes in die Ziel-Filegroup passen (freier Platz in den Dateien
    plus moegliches Autogrowth bis zur Laufwerks- bzw. Dateigrenze, -SkipSpaceCheck).

    -TruncateData: fuer Tabellen, deren Daten bereits vollstaendig in einer Archiv-Datenbank
    liegen (typisch: die nach dem Cutover von Invoke-sqmTableArchiveMigration verbliebene
    '<Tabelle>_Original'). Die Tabelle wird vor dem Umbau per TRUNCATE TABLE geleert, der Umbau
    selbst ist dann eine Sache von Sekunden, und die Filegroups werden frei. Vorher (ohne Kosten,
    nur Metadaten) geprueft:
    - die Archiv-Tabelle (-ArchiveTable, bei '<X>_Original' automatisch aus der View '<X>'
      abgeleitet) existiert, ist nicht die Tabelle selbst und hat mindestens so viele Zeilen wie
      die zu leerende Tabelle (-SkipArchiveCheck schaltet das ab);
    - kein Fremdschluessel einer anderen Tabelle, keine indizierte View, keine Replikation und
      kein CDC auf der Tabelle (TRUNCATE wuerde daran scheitern).
    Zusaetzlich zur normalen Bestaetigung fragt die Funktion vor dem TRUNCATE noch einmal
    gesondert nach; diese Rueckfrage schaltet nur -Force ab (nicht -Confirm:$false).

    Registry: geloescht wird der Eintrag der Tabelle selbst und jeder weitere Eintrag derselben
    Datenbank, der auf ein jetzt entferntes Partition Scheme zeigt (nach einem Cutover steht er
    unter dem Namen der View, nicht unter '<Tabelle>_Original').

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
    Registry-Eintraege in master.dbo.sqm_PartitionRegistry nicht loeschen.
.PARAMETER TruncateData
    Tabelle vor dem Entfernen der Partitionierung leeren (TRUNCATE TABLE). Nur fuer Tabellen,
    deren Daten bereits in einer Archiv-Datenbank liegen, siehe DESCRIPTION.
.PARAMETER ArchiveTable
    Nur mit -TruncateData: Archiv-Tabelle als 'Datenbank.Schema.Tabelle' (gleiche Instanz), gegen
    die die Zeilenzahl geprueft wird. Ohne Angabe bei '<X>_Original' aus der View '<X>' abgeleitet.
.PARAMETER SkipArchiveCheck
    Nur mit -TruncateData: Zeilenzahl-Pruefung gegen die Archiv-Tabelle auslassen.
.PARAMETER Force
    Nur mit -TruncateData: gesonderte Rueckfrage vor dem TRUNCATE unterdruecken (fuer
    unbeaufsichtigte Laeufe).
.PARAMETER SkipSpaceCheck
    Platzpruefung der Ziel-Filegroup auslassen.
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.OUTPUTS
    PSCustomObject mit Status (Success | NotPartitioned | WhatIf | Cancelled), TargetFilegroup,
    IndexesMoved, DroppedPartitionSchemes, DroppedPartitionFunctions, RemovedFilegroups,
    Unregistered, UnregisteredTables, Truncated, RowsTruncated, ArchiveTable, ArchiveRows,
    SpaceNeededMB, SpaceAvailableMB, Warnings und Statements (die ausgefuehrte bzw. bei -WhatIf
    geplante DDL).

.EXAMPLE
    Remove-sqmTablePartitioning -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" -WhatIf

    Zeigt die geplante DDL, ohne etwas zu aendern.

.EXAMPLE
    Remove-sqmTablePartitioning -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" `
        -TargetFilegroup "PRIMARY" -RemoveEmptyFilegroups -Confirm:$false

.EXAMPLE
    # Nach dem Cutover einer Archiv-Migration: die umbenannte Quelle leeren, entpartitionieren und
    # die Filegroups freigeben. Archiv-Tabelle wird aus der View 'OrderHistory' abgeleitet.
    Remove-sqmTablePartitioning -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory_Original" `
        -TruncateData -RemoveEmptyFilegroups

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
		[switch]$TruncateData,

		[Parameter(Mandatory = $false)]
		[string]$ArchiveTable,

		[Parameter(Mandatory = $false)]
		[switch]$SkipArchiveCheck,

		[Parameter(Mandatory = $false)]
		[switch]$Force,

		[Parameter(Mandatory = $false)]
		[switch]$SkipSpaceCheck,

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
	# Gemeinsames Rueckgabeobjekt, die Schritte fuellen es nach und nach.
	$result = [PSCustomObject]@{
		SchemaName                = $Schema
		TableName                 = $Table
		TargetFilegroup           = $TargetFilegroup
		Status                    = $null
		IndexesMoved              = @()
		DroppedPartitionSchemes   = @()
		DroppedPartitionFunctions = @()
		RemovedFilegroups         = @()
		Unregistered              = $false
		UnregisteredTables        = @()
		Truncated                 = $false
		RowsTruncated             = [int64]0
		ArchiveTable              = $null
		ArchiveRows               = $null
		SpaceNeededMB             = $null
		SpaceAvailableMB          = $null
		Warnings                  = @()
		Statements                = @()
	}
	if (-not $TruncateData -and ($ArchiveTable -or $SkipArchiveCheck -or $Force))
	{
		Invoke-sqmLogging -Message "-ArchiveTable/-SkipArchiveCheck/-Force wirken nur zusammen mit -TruncateData und werden ignoriert." -FunctionName $functionName -Level "WARNING"
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
		$result.TargetFilegroup = $TargetFilegroup

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
			Invoke-sqmLogging -Message "'$Schema.$Table' ist nicht partitioniert - nichts zu tun$(if ($TruncateData) { ' (auch kein TRUNCATE)' })." -FunctionName $functionName -Level "INFO"
			$result.Status = 'NotPartitioned'
			return $result
		}

		# Zeilen und belegter Platz der Tabelle (alle Indizes, inkl. LOB) - nur Metadaten.
		$sizeRow = Invoke-DbaQuery @connParams -Query "SELECT (SELECT ISNULL(SUM(p.rows), 0) FROM sys.partitions p WHERE p.object_id = OBJECT_ID(N'$objName') AND p.index_id IN (0, 1)) AS TableRows, (SELECT ISNULL(SUM(ps.reserved_page_count), 0) FROM sys.dm_db_partition_stats ps WHERE ps.object_id = OBJECT_ID(N'$objName')) AS ReservedPages;" -ErrorAction Stop -EnableException -As PSObject
		$tableRows = [int64]$sizeRow.TableRows
		$neededBytes = [int64]$sizeRow.ReservedPages * 8192

		# =========================================================================================
		# 1b. -TruncateData: Archiv und TRUNCATE-Hindernisse pruefen (nur Metadaten, kein Scan)
		# =========================================================================================
		if ($TruncateData)
		{
			$blockers = [System.Collections.Generic.List[string]]::new()
			$fkIn = @(Invoke-DbaQuery @connParams -Query "SELECT fk.name AS ForeignKeyName, OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id) AS ReferencingTable FROM sys.foreign_keys fk WHERE fk.referenced_object_id = OBJECT_ID(N'$objName') AND fk.parent_object_id <> fk.referenced_object_id;" -ErrorAction Stop -EnableException -As PSObject)
			if ($fkIn.Count -gt 0) { $blockers.Add("Fremdschluessel verweisen auf die Tabelle: $(($fkIn | ForEach-Object { "$($_.ReferencingTable) ($($_.ForeignKeyName))" }) -join '; ')") }
			$ixViews = @(Invoke-DbaQuery @connParams -Query "SELECT DISTINCT OBJECT_SCHEMA_NAME(d.referencing_id) + '.' + OBJECT_NAME(d.referencing_id) AS ViewName FROM sys.sql_expression_dependencies d JOIN sys.indexes i ON i.object_id = d.referencing_id WHERE d.referenced_id = OBJECT_ID(N'$objName') AND d.is_schema_bound_reference = 1;" -ErrorAction Stop -EnableException -As PSObject)
			if ($ixViews.Count -gt 0) { $blockers.Add("indizierte View(s) auf der Tabelle: $(($ixViews | ForEach-Object { $_.ViewName }) -join ', ')") }
			$repl = Invoke-DbaQuery @connParams -Query "SELECT is_replicated, is_tracked_by_cdc FROM sys.tables WHERE object_id = OBJECT_ID(N'$objName');" -ErrorAction Stop -EnableException -As PSObject
			if ([bool]$repl.is_replicated) { $blockers.Add('die Tabelle wird repliziert') }
			if ([bool]$repl.is_tracked_by_cdc) { $blockers.Add('Change Data Capture ist fuer die Tabelle aktiv') }
			if ($blockers.Count -gt 0) { throw "-TruncateData nicht moeglich, TRUNCATE TABLE wuerde scheitern: $($blockers -join ' | ')." }

			if (-not $SkipArchiveCheck)
			{
				if (-not $ArchiveTable)
				{
					# Cutover-Konvention von Invoke-sqmTableArchiveMigration: Quelle -> '<X>_Original',
					# unter '<X>' eine View auf die Archiv-Tabelle in einer anderen Datenbank.
					if ($Table -notmatch '^(.+)_Original$') { throw "-TruncateData: Archiv-Tabelle nicht ableitbar ('$Table' endet nicht auf '_Original'). Mit -ArchiveTable 'Datenbank.Schema.Tabelle' angeben oder -SkipArchiveCheck." }
					$viewName = $Matches[1]
					$refs = @(Invoke-DbaQuery @connParams -Query "SELECT DISTINCT d.referenced_database_name AS Db, ISNULL(d.referenced_schema_name, 'dbo') AS Sch, d.referenced_entity_name AS Tab FROM sys.sql_expression_dependencies d WHERE d.referencing_id = OBJECT_ID(N'[$Schema].[$($viewName -replace "'", "''")]') AND OBJECTPROPERTY(d.referencing_id, 'IsView') = 1;" -ErrorAction Stop -EnableException -As PSObject)
					$extRefs = @($refs | Where-Object { $_.Db -and $_.Db -ne $Database })
					if ($extRefs.Count -ne 1) { throw "-TruncateData: Archiv-Tabelle nicht ableitbar - die View '$Schema.$viewName' $(if ($refs.Count -eq 0) { 'existiert nicht oder hat keine Abhaengigkeiten' } else { "verweist auf $($extRefs.Count) Tabellen anderer Datenbanken" }). Mit -ArchiveTable 'Datenbank.Schema.Tabelle' angeben." }
					$archDb = [string]$extRefs[0].Db; $archSchema = [string]$extRefs[0].Sch; $archTab = [string]$extRefs[0].Tab
					Invoke-sqmLogging -Message "Archiv-Tabelle aus der View '$Schema.$viewName' abgeleitet: $archDb.$archSchema.$archTab." -FunctionName $functionName -Level "INFO"
				}
				else
				{
					$parts = @($ArchiveTable -split '\.' | ForEach-Object { $_.Trim().Trim('[', ']') })
					if ($parts.Count -ne 3) { throw "-ArchiveTable '$ArchiveTable': erwartet 'Datenbank.Schema.Tabelle'." }
					$archDb, $archSchema, $archTab = $parts
				}
				if ($archDb -eq $Database -and $archSchema -eq $Schema -and $archTab -eq $Table) { throw "-ArchiveTable ist die zu leerende Tabelle selbst." }

				$archDbQ = "[$($archDb -replace '\]', ']]')]"
				$archObj = "[$archDb].[$archSchema].[$archTab]" -replace "'", "''"
				$archRow = Invoke-DbaQuery @connParams -Query "SELECT OBJECT_ID(N'$archObj', 'U') AS ObjId, (SELECT SUM(p.rows) FROM $archDbQ.sys.partitions p WHERE p.object_id = OBJECT_ID(N'$archObj', 'U') AND p.index_id IN (0, 1)) AS ArchiveRows;" -ErrorAction Stop -EnableException -As PSObject
				if ($archRow.ObjId -is [DBNull] -or $null -eq $archRow.ObjId) { throw "-TruncateData: Archiv-Tabelle '$archDb.$archSchema.$archTab' nicht gefunden." }
				$archRows = [int64]$archRow.ArchiveRows
				$result.ArchiveTable = "$archDb.$archSchema.$archTab"
				$result.ArchiveRows = $archRows
				if ($archRows -lt $tableRows)
				{
					throw "-TruncateData abgebrochen: die Archiv-Tabelle '$archDb.$archSchema.$archTab' hat $archRows Zeilen, '$Schema.$Table' aber $tableRows - die Daten sind nicht vollstaendig archiviert."
				}
				Invoke-sqmLogging -Message "Archiv-Pruefung bestanden: '$archDb.$archSchema.$archTab' $archRows Zeilen >= '$Schema.$Table' $tableRows Zeilen (Metadaten aus sys.partitions)." -FunctionName $functionName -Level "INFO"
			}
			else
			{
				& $addWarning "-SkipArchiveCheck: '$Schema.$Table' ($tableRows Zeilen) wird ohne Abgleich mit einer Archiv-Tabelle geleert."
			}
		}
		elseif (-not $SkipSpaceCheck)
		{
			# =====================================================================================
			# 1c. Platzpruefung Ziel-Filegroup: freier Platz in den Dateien + moegliches Autogrowth
			# =====================================================================================
			$fileQuery = @"
SELECT f.file_id, f.name, CAST(f.size AS BIGINT) * 8192 AS SizeBytes,
       CAST(FILEPROPERTY(f.name, 'SpaceUsed') AS BIGINT) * 8192 AS UsedBytes,
       f.growth, f.max_size
FROM sys.database_files f
WHERE f.data_space_id = $([int]$targetFg.data_space_id) AND f.state = 0;
"@
			$files = @(Invoke-DbaQuery @connParams -Query $fileQuery -ErrorAction Stop -EnableException -As PSObject)
			$freeInside = [int64]0
			$growPerVolume = @{}
			$volumeFree = @{}
			$volumesKnown = $true
			foreach ($f in $files)
			{
				$freeInside += [int64]$f.SizeBytes - [int64]$f.UsedBytes
				if ([int]$f.growth -eq 0) { continue }
				$maxGrow = if ([int]$f.max_size -eq -1 -or [int64]$f.max_size -ge 268435456) { [int64]::MaxValue } else { [int64]$f.max_size * 8192 - [int64]$f.SizeBytes }
				try
				{
					$vol = Invoke-DbaQuery @connParams -Query "SELECT volume_mount_point, available_bytes FROM sys.dm_os_volume_stats(DB_ID(), $([int]$f.file_id));" -ErrorAction Stop -EnableException -As PSObject
					$key = [string]$vol.volume_mount_point
					$volumeFree[$key] = [int64]$vol.available_bytes
					$cur = if ($growPerVolume.ContainsKey($key)) { $growPerVolume[$key] } else { [int64]0 }
					$growPerVolume[$key] = [Math]::Min([decimal]$cur + [decimal]$maxGrow, [decimal][int64]::MaxValue)
				}
				catch { $volumesKnown = $false }
			}
			$growable = [int64]0
			foreach ($k in $growPerVolume.Keys) { $growable += [int64][Math]::Min([decimal]$growPerVolume[$k], [decimal]$volumeFree[$k]) }
			$available = $freeInside + $growable
			$result.SpaceNeededMB = [Math]::Round($neededBytes / 1MB, 0)
			$result.SpaceAvailableMB = [Math]::Round($available / 1MB, 0)

			if (-not $volumesKnown)
			{
				& $addWarning "Platzpruefung: freier Laufwerksplatz nicht ermittelbar (sys.dm_os_volume_stats, braucht VIEW SERVER STATE) - nur der freie Platz in den Dateien von '$TargetFilegroup' wurde beruecksichtigt."
			}
			if ($available -lt $neededBytes)
			{
				throw "Platzpruefung: '$Schema.$Table' belegt $($result.SpaceNeededMB) MB, in Filegroup '$TargetFilegroup' sind aber nur $($result.SpaceAvailableMB) MB verfuegbar (frei in den Dateien + moegliches Autogrowth). Platz schaffen, eine andere -TargetFilegroup waehlen, oder wenn die Daten archiviert sind -TruncateData. Pruefung abschaltbar mit -SkipSpaceCheck."
			}
			if ($available -lt [int64]($neededBytes * 1.2))
			{
				& $addWarning "Platzpruefung: knapp - '$Schema.$Table' belegt $($result.SpaceNeededMB) MB, in '$TargetFilegroup' sind $($result.SpaceAvailableMB) MB verfuegbar. Der Index-Neuaufbau braucht zusaetzlich Sortierplatz."
			}
			elseif ($freeInside -lt $neededBytes)
			{
				& $addWarning "Platzpruefung: die Dateien von '$TargetFilegroup' muessen per Autogrowth um ca. $([Math]::Round(($neededBytes - $freeInside) / 1MB, 0)) MB wachsen."
			}
			else
			{
				Invoke-sqmLogging -Message "Platzpruefung: '$Schema.$Table' belegt $($result.SpaceNeededMB) MB, in '$TargetFilegroup' frei: $([Math]::Round($freeInside / 1MB, 0)) MB." -FunctionName $functionName -Level "INFO"
			}

			$recovery = Invoke-DbaQuery @connParams -Query "SELECT recovery_model_desc FROM sys.databases WHERE database_id = DB_ID();" -ErrorAction Stop -EnableException -As PSObject
			if ($recovery.recovery_model_desc -eq 'FULL' -and $neededBytes -gt 1GB)
			{
				& $addWarning "Recovery-Modell FULL: der Index-Neuaufbau protokolliert vollstaendig, das Transaktionsprotokoll braucht ca. $($result.SpaceNeededMB) MB (Protokollsicherungen waehrend des Laufs einplanen)."
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

		if ($TruncateData)
		{
			$statements.Insert(0, [PSCustomObject]@{ Step = "TRUNCATE TABLE '$Schema.$Table' ($tableRows Zeilen)"; Sql = "TRUNCATE TABLE [$Schema].[$Table];" })
		}
		$result.IndexesMoved = @($movedIndexes)
		$result.Statements = @($statements | ForEach-Object { $_.Sql })

		$applyAction = "$(if ($TruncateData) { "'$Schema.$Table' LEEREN ($tableRows Zeilen) und " })Partitionierung von '$Schema.$Table' entfernen ($($movedIndexes.Count) Index/Indizes auf '$TargetFilegroup', Scheme(s): $(($schemeInfo | ForEach-Object { $_.SchemeName }) -join ', '))"
		if (-not $PSCmdlet.ShouldProcess($Database, $applyAction))
		{
			$result.Status = 'WhatIf'
			$result.DroppedPartitionSchemes = @($schemeInfo | ForEach-Object { $_.SchemeName })
			$result.DroppedPartitionFunctions = @($schemeInfo | ForEach-Object { $_.FunctionName } | Select-Object -Unique)
			$result.Warnings = @($warnings)
			return $result
		}

		# TRUNCATE ist nicht rueckgaengig zu machen: eigene Rueckfrage, die -Confirm:$false NICHT
		# abschaltet, nur -Force.
		if ($TruncateData -and -not $Force)
		{
			$archInfo = if ($result.ArchiveTable) { "Archiv '$($result.ArchiveTable)': $($result.ArchiveRows) Zeilen." } else { 'OHNE Abgleich mit einem Archiv (-SkipArchiveCheck).' }
			try { $continue = $PSCmdlet.ShouldContinue("Alle $tableRows Zeilen von '$Database.$Schema.$Table' werden endgueltig geloescht (TRUNCATE TABLE). $archInfo Fortfahren?", 'TRUNCATE TABLE') }
			catch { throw "-TruncateData: die Rueckfrage vor dem TRUNCATE ist in dieser Sitzung nicht moeglich (nicht interaktiv, z.B. Agent-Job). Nichts geaendert. Fuer unbeaufsichtigte Laeufe -Force angeben." }
			if (-not $continue)
			{
				Invoke-sqmLogging -Message "TRUNCATE von '$Schema.$Table' nicht bestaetigt - abgebrochen, nichts geaendert." -FunctionName $functionName -Level "WARNING"
				$result.Status = 'Cancelled'
				$result.Warnings = @($warnings)
				return $result
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
			if ($TruncateData -and $st.Sql -like 'TRUNCATE TABLE*')
			{
				$result.Truncated = $true
				$result.RowsTruncated = $tableRows
				Invoke-sqmLogging -Message "'$Schema.$Table' geleert ($tableRows Zeilen)." -FunctionName $functionName -Level "WARNING"
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

		# Weitere Eintraege derselben Datenbank, die auf ein jetzt entferntes Scheme zeigen (nach einem
		# Cutover steht der Eintrag unter dem View-Namen, nicht unter '<Tabelle>_Original').
		$unregisteredTables = [System.Collections.Generic.List[string]]::new()
		if ($unregistered) { $unregisteredTables.Add("$Schema.$Table") }
		if ($droppedSchemes.Count -gt 0)
		{
			$schemeList = ($droppedSchemes | ForEach-Object { "N'$($_ -replace "'", "''")'" }) -join ', '
			$dbLit = $Database -replace "'", "''"
			$staleQuery = "IF OBJECT_ID(N'master.dbo.sqm_PartitionRegistry') IS NOT NULL SELECT SchemaName, TableName FROM master.dbo.sqm_PartitionRegistry WHERE DatabaseName = N'$dbLit' AND PartitionSchemeName IN ($schemeList) AND NOT (SchemaName = N'$($Schema -replace "'", "''")' AND TableName = N'$($Table -replace "'", "''")');"
			$stale = @(Invoke-DbaQuery @connParams -Query $staleQuery -ErrorAction Stop -EnableException -As PSObject)
			foreach ($sr in $stale)
			{
				if ($KeepRegistration)
				{
					& $addWarning "Registry-Eintrag '$($sr.SchemaName).$($sr.TableName)' zeigt auf ein entferntes Partition Scheme und bleibt bestehen (-KeepRegistration)."
					continue
				}
				$srParams = @{ SqlInstance = $SqlInstance; DatabaseName = $Database; SchemaName = [string]$sr.SchemaName; TableName = [string]$sr.TableName; Purge = $true }
				if ($SqlCredential) { $srParams['SqlCredential'] = $SqlCredential }
				Remove-sqmPartitionRegistration @srParams -Confirm:$false | Out-Null
				$unregisteredTables.Add("$($sr.SchemaName).$($sr.TableName)")
				Invoke-sqmLogging -Message "Registry-Eintrag '$($sr.SchemaName).$($sr.TableName)' entfernt (zeigte auf ein entferntes Partition Scheme)." -FunctionName $functionName -Level "INFO"
			}
		}

		Invoke-sqmLogging -Message "$applyAction - erfolgreich." -FunctionName $functionName -Level "INFO"

		$result.Status = 'Success'
		$result.DroppedPartitionSchemes = @($droppedSchemes)
		$result.DroppedPartitionFunctions = @($droppedFunctions)
		$result.RemovedFilegroups = @($removedFilegroups)
		$result.Unregistered = $unregistered
		$result.UnregisteredTables = @($unregisteredTables)
		$result.Warnings = @($warnings)
		return $result
	}
	catch
	{
		$msg = "Fehler in ${functionName}: $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		throw
	}
}
