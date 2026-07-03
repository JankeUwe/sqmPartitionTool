<#
.SYNOPSIS
    Entfernt (und optional archiviert) manuell eine einzelne alte Partition einer Tabelle.

.DESCRIPTION
    Manueller/ad-hoc Einzellauf der Retention-Logik fuer GENAU EINE Partition (die aelteste mit
    Daten, oder eine explizit angegebene Boundary) - im Gegensatz zu sqm_RetirePartitionWindow,
    das automatisiert ALLE registrierten Tabellen gemaess ihrer konfigurierten Aufbewahrung
    durchgeht. Nuetzlich fuer Tests, einmalige Bereinigungen oder um vor dem Einrichten des
    automatischen Jobs den Ablauf an einer echten Partition zu pruefen.

    Ablauf (immer in dieser Reihenfolge - SWITCH vor MERGE, niemals umgekehrt):
    1. Test-sqmPartitionIndexAlignment - blockiert bei nicht ausgerichteten Indizes.
    2. Staging-Tabelle mit identischer Struktur auf demselben Filegroup wie die Zielpartition
       anlegen (falls nicht vorhanden).
    3. ALTER TABLE ... SWITCH PARTITION <n> TO <staging> (Metadaten-Operation).
    4. Optional (-ArchiveDatabaseName): Zeilen aus der Staging-Tabelle batchweise in die
       Archiv-Datenbank kopieren (dieselbe Instanz), danach Zeilenzahl-Abgleich.
    5. Staging-Tabelle leeren/droppen.
    6. Defensive Pruefung, dass die Partition wirklich leer ist, ERST DANN
       ALTER PARTITION FUNCTION ... MERGE RANGE (<boundary>).

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER Database
    Datenbank der partitionierten Tabelle.
.PARAMETER Schema
    Schema.
.PARAMETER Table
    Tabellenname (muss bereits partitioniert sein).
.PARAMETER PartitionNumber
    Zu entfernende Partition (per Nummer aus Get-sqmPartitionStatus). Ohne Angabe wird die
    aelteste Partition mit Daten (niedrigste PartitionNumber > 1, sofern nicht leer) verwendet.
.PARAMETER ArchiveDatabaseName
    Wenn angegeben: Daten vor dem Entfernen in diese Datenbank kopieren (muss auf derselben
    Instanz liegen). Ohne Angabe werden die Daten nur entfernt (kein Archiv).
.PARAMETER ArchiveSchemaName
    Zielschema in der Archiv-Datenbank. Standard: gleiches Schema wie die Quelltabelle.
.PARAMETER ArchiveBatchSize
    Batchgroesse fuer die Kopie in die Archiv-Datenbank. Standard: 50000. Enthaelt die Partition
    mehr Zeilen als dieser Wert, wird in mehreren Batches (je eine eigene Transaktion) statt in
    einer einzelnen INSERT...SELECT kopiert - vermeidet Transaktionslog-Wachstum und lange
    Sperren bei sehr grossen Partitionen.
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    Invoke-sqmPartitionArchive -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory"

.EXAMPLE
    Invoke-sqmPartitionArchive -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" `
        -PartitionNumber 2 -ArchiveDatabaseName "SalesArchive"

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), Test-sqmPartitionIndexAlignment,
    Get-sqmPartitionStatus.
#>
function Invoke-sqmPartitionArchive
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
		[int]$PartitionNumber,

		[Parameter(Mandatory = $false)]
		[string]$ArchiveDatabaseName,

		[Parameter(Mandatory = $false)]
		[string]$ArchiveSchemaName,

		[Parameter(Mandatory = $false)]
		[int]$ArchiveBatchSize = 50000,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
	if (-not $ArchiveSchemaName) { $ArchiveSchemaName = $Schema }

	try
	{
		# 1. Index-Alignment pruefen -------------------------------------------------------------
		$alignParams = @{ SqlInstance = $SqlInstance; Database = $Database; Schema = $Schema; Table = $Table }
		if ($SqlCredential) { $alignParams['SqlCredential'] = $SqlCredential }
		$alignment = Test-sqmPartitionIndexAlignment @alignParams
		if (-not $alignment.AllAligned)
		{
			$names = ($alignment.NonAlignedIndexes | ForEach-Object { $_.IndexName }) -join ', '
			throw "'$Schema.$Table' hat nicht partitionsausgerichtete Indizes ($names) - SWITCH PARTITION nicht moeglich. Indizes zuerst auf das Partition Scheme umbauen oder entfernen."
		}

		# 2. Zu entfernende Partition bestimmen ---------------------------------------------------
		$statusParams = @{ SqlInstance = $SqlInstance; Database = $Database; Schema = $Schema; Table = $Table }
		if ($SqlCredential) { $statusParams['SqlCredential'] = $SqlCredential }
		$status = Get-sqmPartitionStatus @statusParams
		if (-not $status) { throw "'$Schema.$Table' ist nicht partitioniert." }

		if (-not $PartitionNumber)
		{
			$candidate = $status | Where-Object { -not $_.IsEmpty } | Sort-Object PartitionNumber | Select-Object -First 1
			if (-not $candidate) { throw "'$Schema.$Table' hat keine Partition mit Daten - nichts zu entfernen." }
			$PartitionNumber = $candidate.PartitionNumber
		}
		$targetPartition = $status | Where-Object { $_.PartitionNumber -eq $PartitionNumber } | Select-Object -First 1
		if (-not $targetPartition) { throw "Partition $PartitionNumber existiert nicht auf '$Schema.$Table'." }
		if ($PartitionNumber -eq ($status | Measure-Object -Property PartitionNumber -Maximum).Maximum)
		{
			throw "Partition $PartitionNumber ist die letzte (Zukunfts-Catch-All-)Partition und darf nicht entfernt werden."
		}

		$rowsToMove = $targetPartition.RowsInPartition
		$action = "Partition $PartitionNumber von '$Schema.$Table' ($rowsToMove Zeile(n)) entfernen" +
		$(if ($ArchiveDatabaseName) { " und nach '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' archivieren" } else { '' })

		if (-not $PSCmdlet.ShouldProcess($Database, $action)) { return }

		Invoke-sqmLogging -Message $action -FunctionName $functionName -Level "INFO"

		# 3. Staging-Tabelle auf demselben Filegroup anlegen --------------------------------------
		# Staging-Tabelle wird direkt auf dem Filegroup der Zielpartition angelegt (Pflicht fuer
		# SWITCH PARTITION - Quelle und Ziel muessen auf demselben Filegroup liegen). Spaltenliste
		# wird aus sys.columns nachgebildet, damit die Tabelle explizit per CREATE TABLE ... ON
		# [Filegroup] entstehen kann (SELECT INTO ohne ON-Klausel legt immer auf PRIMARY an).
		$stagingTable = "${Table}_sqmStage_$PartitionNumber"
		Invoke-DbaQuery @connParams -Query "IF OBJECT_ID(N'[$Schema].[$stagingTable]') IS NOT NULL DROP TABLE [$Schema].[$stagingTable];" -ErrorAction Stop -EnableException

		function _FormatColumnType($col)
		{
			switch ($col.TypeName)
			{
				{ $_ -in @('varchar', 'char', 'binary', 'varbinary') } { return "$($col.TypeName)($(if ($col.max_length -eq -1) { 'max' } else { $col.max_length }))" }
				{ $_ -in @('nvarchar', 'nchar') } { return "$($col.TypeName)($(if ($col.max_length -eq -1) { 'max' } else { $col.max_length / 2 }))" }
				'decimal' { return "decimal($($col.precision),$($col.scale))" }
				'numeric' { return "numeric($($col.precision),$($col.scale))" }
				default { return $col.TypeName }
			}
		}

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
		$colDefSql = ($colDefs | ForEach-Object {
				$nullability = if ($_.is_nullable) { 'NULL' } else { 'NOT NULL' }
				# IDENTITY-Eigenschaft muss zwischen Quelle und Staging-Tabelle uebereinstimmen -
				# sonst lehnt SWITCH PARTITION mit der irrefuehrenden Meldung "kein identischer
				# Index" ab (SQL Server meldet einen IDENTITY-Mismatch ueber denselben Fehlertext).
				$identityClause = if ([bool]$_.is_identity) { " IDENTITY($($_.seed_value),$($_.increment_value))" } else { '' }
				"[$($_.ColumnName)] $(_FormatColumnType $_)$identityClause $nullability"
			}) -join ', '

		Invoke-DbaQuery @connParams -Query "CREATE TABLE [$Schema].[$stagingTable] ($colDefSql) ON [$($targetPartition.FilegroupName)];" -ErrorAction Stop -EnableException

		# Alle Indizes (Clustered + Nonclustered) auf der Staging-Tabelle nachbilden - Pflicht fuer
		# SWITCH PARTITION, das fuer JEDEN Index der Quelle einen strukturell identischen Index auf
		# dem Ziel verlangt, alle auf demselben Filegroup wie die Zielpartition. Ist ein Index als
		# PRIMARY KEY/UNIQUE CONSTRAINT hinterlegt, akzeptiert SQL Server dafuer KEINEN gleichwertigen
		# "einfachen" Index als Gegenstueck - die Constraint-Eigenschaft selbst muss ebenfalls
        # uebereinstimmen (empirisch verifiziert: sonst "kein identischer Index"-Fehler trotz
        # identischer Spalten/Eindeutigkeit).
		$idxQuery = @"
SELECT i.index_id, i.is_unique, i.type_desc, kc.type AS ConstraintType
FROM sys.indexes i
LEFT JOIN sys.key_constraints kc ON kc.parent_object_id = i.object_id AND kc.unique_index_id = i.index_id
WHERE i.object_id = OBJECT_ID(N'[$Schema].[$Table]') AND i.index_id >= 1
ORDER BY i.index_id
"@
		$srcIndexes = Invoke-DbaQuery @connParams -Query $idxQuery -ErrorAction Stop -EnableException
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
			$keyCols = @($idxCols | Where-Object { -not [bool]$_.is_included_column } | ForEach-Object { "[$($_.ColumnName)]$(if ([bool]$_.is_descending_key) { ' DESC' })" })
			$includeCols = @($idxCols | Where-Object { [bool]$_.is_included_column } | ForEach-Object { "[$($_.ColumnName)]" })
			$clusterKw = if ($idx.type_desc -eq 'CLUSTERED') { 'CLUSTERED' } else { 'NONCLUSTERED' }
			$includeClause = if ($includeCols.Count -gt 0) { " INCLUDE ($($includeCols -join ', '))" } else { '' }

			if ($idx.ConstraintType -in @('PK', 'UQ'))
			{
				$constraintKw = if ($idx.ConstraintType -eq 'PK') { 'PRIMARY KEY' } else { 'UNIQUE' }
				$constraintName = "${constraintKw}_${stagingTable}_$($idx.index_id)" -replace ' ', '_'
				$idxDdl = "ALTER TABLE [$Schema].[$stagingTable] ADD CONSTRAINT [$constraintName] $constraintKw $clusterKw ($($keyCols -join ', ')) ON [$($targetPartition.FilegroupName)];"
			}
			else
			{
				$uniqueKw = if ([bool]$idx.is_unique) { 'UNIQUE ' } else { '' }
				$idxDdl = "CREATE ${uniqueKw}${clusterKw} INDEX [IX_${stagingTable}_$($idx.index_id)] ON [$Schema].[$stagingTable] ($($keyCols -join ', '))$includeClause ON [$($targetPartition.FilegroupName)];"
			}
			Invoke-DbaQuery @connParams -Query $idxDdl -ErrorAction Stop -EnableException
		}
		# Quelle ist Heap -> Staging-Tabelle bleibt ebenfalls Heap (bereits korrekt auf dem
		# Zielfilegroup angelegt, kein weiterer Schritt noetig).

		# 4. SWITCH PARTITION (Metadaten-Operation) ------------------------------------------------
		$switchDdl = "ALTER TABLE [$Schema].[$Table] SWITCH PARTITION $PartitionNumber TO [$Schema].[$stagingTable];"
		try
		{
			Invoke-DbaQuery @connParams -Query $switchDdl -ErrorAction Stop -EnableException
		}
		catch
		{
			Invoke-DbaQuery @connParams -Query "DROP TABLE IF EXISTS [$Schema].[$stagingTable];" -ErrorAction SilentlyContinue
			throw "SWITCH PARTITION fehlgeschlagen: $($_.Exception.Message)"
		}
		Invoke-sqmLogging -Message "Partition $PartitionNumber per SWITCH in '$stagingTable' verschoben." -FunctionName $functionName -Level "INFO"

		# 5. Optional archivieren -------------------------------------------------------------------
		$archivedRows = 0
		if ($ArchiveDatabaseName)
		{
			$archTableExistsQuery = "SELECT 1 FROM [$ArchiveDatabaseName].sys.tables t JOIN [$ArchiveDatabaseName].sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = N'$ArchiveSchemaName' AND t.name = N'$Table'"
			$archExists = Invoke-DbaQuery @connParams -Query $archTableExistsQuery -ErrorAction Stop -EnableException
			if (-not $archExists)
			{
				$createArchSql = "IF SCHEMA_ID(N'$ArchiveSchemaName') IS NULL EXEC(N'CREATE SCHEMA [$ArchiveSchemaName]'); " +
				"SELECT * INTO [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table] FROM [$Schema].[$stagingTable] WHERE 1 = 0;"
				Invoke-DbaQuery @connParams -Query $createArchSql -ErrorAction Stop -EnableException
				Invoke-sqmLogging -Message "Archiv-Tabelle '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' angelegt." -FunctionName $functionName -Level "INFO"
			}

			# Staging-Tabelle wird NICHT vor dem Zeilenzahl-Abgleich geleert (Schritt 6 uebernimmt das
			# erst danach), damit bei einem Kopierfehler nichts verloren geht. Vorher/Nachher-Differenz
			# statt absoluter Zeilenzahl, damit bereits vorhandene Archiv-Daten aus frueheren Laeufen
			# nicht mitzaehlen.
			$archCountBefore = [int64](Invoke-DbaQuery @connParams -Query "SELECT COUNT(*) AS Cnt FROM [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table]" -ErrorAction Stop -EnableException).Cnt

			# Hat die Quelltabelle eine IDENTITY-Spalte, uebernimmt SELECT INTO diese Eigenschaft auch
			# auf die Archiv-Tabelle - ein einfaches INSERT...SELECT * wird dann von SQL Server
			# abgelehnt, sofern nicht explizit eine Spaltenliste verwendet und IDENTITY_INSERT gesetzt
			# wird.
			$hasIdentityCol = [bool]($colDefs | Where-Object { [bool]$_.is_identity })
			$archColList = ($colDefs | ForEach-Object { "[$($_.ColumnName)]" }) -join ', '
			$archColListDeleted = ($colDefs | ForEach-Object { "DELETED.[$($_.ColumnName)]" }) -join ', '

			# Bei sehr grossen Partitionen wuerde eine einzelne INSERT...SELECT alle Zeilen in EINER
			# Transaktion kopieren (Transaktionslog-Wachstum, lange Sperren, Timeout-Risiko). Ab
			# ArchiveBatchSize Zeilen wird stattdessen in Batches per DELETE TOP(@BatchSize) ... OUTPUT
			# INTO kopiert (jeder Batch = eigene Transaktion) - unkritisch, dass dabei die
			# Staging-Tabelle bereits waehrenddessen geleert wird, sie wird ohnehin direkt danach
			# TRUNCATE/DROP.
			$copyBody = if ($rowsToMove -gt $ArchiveBatchSize)
			{
				"DECLARE @RowsAffected INT = 1; " +
				"WHILE @RowsAffected > 0 " +
				"BEGIN " +
				"DELETE TOP ($ArchiveBatchSize) FROM [$Schema].[$stagingTable] " +
				"OUTPUT $archColListDeleted INTO [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table] ($archColList); " +
				"SET @RowsAffected = @@ROWCOUNT; " +
				"END"
			}
			else
			{
				"INSERT INTO [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table] ($archColList) SELECT $archColList FROM [$Schema].[$stagingTable];"
			}
			$insertSql = if ($hasIdentityCol)
			{
				"SET IDENTITY_INSERT [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table] ON; $copyBody " +
				"SET IDENTITY_INSERT [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table] OFF;"
			}
			else
			{
				$copyBody
			}
			Invoke-DbaQuery @connParams -Query $insertSql -ErrorAction Stop -EnableException
			$archCountAfter = [int64](Invoke-DbaQuery @connParams -Query "SELECT COUNT(*) AS Cnt FROM [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table]" -ErrorAction Stop -EnableException).Cnt
			$archivedRows = $archCountAfter - $archCountBefore

			if ($archivedRows -ne $rowsToMove)
			{
				throw "Zeilenzahl-Abgleich nach Archiv-Kopie fehlgeschlagen: erwartet $rowsToMove, archiviert $archivedRows. Staging-Tabelle '$stagingTable' wurde NICHT geleert - manuell pruefen."
			}
			Invoke-sqmLogging -Message "$archivedRows Zeile(n) nach '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' archiviert." -FunctionName $functionName -Level "INFO"
		}

		# 6. Staging-Tabelle leeren + entfernen -----------------------------------------------------
		Invoke-DbaQuery @connParams -Query "TRUNCATE TABLE [$Schema].[$stagingTable]; DROP TABLE [$Schema].[$stagingTable];" -ErrorAction Stop -EnableException

		# 7. Defensive Leerheits-Pruefung, dann MERGE RANGE -----------------------------------------
		$rowsNowQuery = "SELECT SUM(p.rows) AS Cnt FROM sys.partitions p JOIN sys.tables t ON t.object_id = p.object_id JOIN sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = N'$Schema' AND t.name = N'$Table' AND p.partition_number = $PartitionNumber AND p.index_id IN (0,1)"
		$rowsNow = (Invoke-DbaQuery @connParams -Query $rowsNowQuery -ErrorAction Stop -EnableException).Cnt
		if ([int64]$rowsNow -ne 0)
		{
			throw "Partition $PartitionNumber ist nach SWITCH nicht leer ($rowsNow Zeile(n)) - MERGE RANGE wird NICHT ausgefuehrt (wuerde Daten in die Nachbarpartition verschieben). Manuell pruefen."
		}

		# MERGE RANGE braucht die OBERE Grenze der entfernten Partition (= die Boundary, die zwischen
		# ihr und der naechsten Partition entfernt werden soll), NICHT ihre untere Grenze. Ein
		# [string]-Boundary-Wert (BoundaryType 'Text', SQL_VARIANT liefert dann einen .NET-String)
		# muss als N'...'-Literal gequotet werden, statt sich auf implizite int->varchar-Konvertierung
		# zu verlassen (analog zur BoundaryValue-Formatierung in New-sqmPartitionSchemeSet.ps1).
		$upperBoundaryLiteral = if ($targetPartition.UpperBoundaryValue -is [datetime]) { "'$($targetPartition.UpperBoundaryValue.ToString('yyyy-MM-dd'))'" }
		elseif ($targetPartition.UpperBoundaryValue -is [string]) { "N'$($targetPartition.UpperBoundaryValue.Replace("'", "''"))'" }
		else { "$($targetPartition.UpperBoundaryValue)" }
		$mergeDdl = "ALTER PARTITION FUNCTION [$($status[0].PartitionFunctionName)]() MERGE RANGE ($upperBoundaryLiteral);"
		Invoke-DbaQuery @connParams -Query $mergeDdl -ErrorAction Stop -EnableException
		Invoke-sqmLogging -Message "MERGE RANGE fuer Partition $PartitionNumber abgeschlossen." -FunctionName $functionName -Level "INFO"

		return [PSCustomObject]@{
			SchemaName          = $Schema
			TableName           = $Table
			PartitionNumber     = $PartitionNumber
			RowsRemoved         = $rowsToMove
			Archived            = [bool]$ArchiveDatabaseName
			ArchiveDatabaseName = $ArchiveDatabaseName
			ArchivedRows        = $archivedRows
			Status              = 'Success'
		}
	}
	catch
	{
		$msg = "Fehler in ${functionName}: $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw }
		throw
	}
}
