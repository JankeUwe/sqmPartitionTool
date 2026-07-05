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
       - Muss die Archiv-Tabelle dabei erst neu angelegt werden (SELECT INTO ... WHERE 1 = 0),
         wird optional -DataCompression (Row/Page) per ALTER TABLE ... REBUILD angewendet
         (SELECT INTO kennt keine Kompressions-Klausel) und optional (-ConfirmArchiveTable) auf
         eine Admin-Bestaetigung gewartet, BEVOR die Daten aus der Staging-Tabelle kopiert werden.
         Zu diesem Zeitpunkt ist die Partition bereits per SWITCH in die Staging-Tabelle verschoben
         (Schritt 3) - bei Ablehnung bleiben Staging-Tabelle und Archiv-Tabelle (leer) unveraendert
         bestehen, nichts geht verloren.
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
.PARAMETER DataCompression
    None (Standard), Row oder Page. Wird NUR angewendet wenn die Archiv-Tabelle in diesem Aufruf
    neu angelegt wird (per ALTER TABLE ... REBUILD nach dem SELECT INTO, das selbst keine
    Kompressions-Klausel unterstuetzt). Bereits vorhandene Archiv-Tabellen werden nicht veraendert.
.PARAMETER ConfirmArchiveTable
    Nur relevant wenn die Archiv-Tabelle in diesem Aufruf neu angelegt wird: pausiert danach und
    fragt per Read-Host nach Admin-Bestaetigung, bevor die Daten aus der Staging-Tabelle kopiert
    werden. Die Partition wurde zu diesem Zeitpunkt bereits per SWITCH in die Staging-Tabelle
    verschoben - bei Ablehnung bleiben Staging- und (leere) Archiv-Tabelle unveraendert bestehen.
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
		[ValidateSet('None', 'Row', 'Page')]
		[string]$DataCompression = 'None',

		[Parameter(Mandatory = $false)]
		[switch]$ConfirmArchiveTable,

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

		# Spalten + Indizes/PK/UNIQUE nachbilden - Pflicht fuer SWITCH PARTITION, das fuer JEDEN
		# Index der Quelle einen strukturell identischen Index auf dem Ziel verlangt, alle auf
		# demselben Filegroup wie die Zielpartition (siehe Get-sqmTableDefinitionSql fuer Details/
		# Begruendung der IDENTITY-/Constraint-Sonderfaelle).
		$defParams = @{
			SqlInstance   = $SqlInstance
			Database      = $Database
			Schema        = $Schema
			Table         = $Table
			TargetTable   = $stagingTable
			FilegroupName = $targetPartition.FilegroupName
		}
		if ($SqlCredential) { $defParams['SqlCredential'] = $SqlCredential }
		$tableDef = Get-sqmTableDefinitionSql @defParams -EnableException

		Invoke-DbaQuery @connParams -Query $tableDef.CreateTableSql -ErrorAction Stop -EnableException
		foreach ($idxDdl in $tableDef.IndexSql)
		{
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

				if ($DataCompression -ne 'None')
				{
					$compressionSql = "ALTER TABLE [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table] REBUILD WITH (DATA_COMPRESSION = $($DataCompression.ToUpper()));"
					Invoke-DbaQuery @connParams -Query $compressionSql -ErrorAction Stop -EnableException
					Invoke-sqmLogging -Message "$DataCompression-Kompression auf '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' angewendet." -FunctionName $functionName -Level "INFO"
				}

				if ($ConfirmArchiveTable)
				{
					Invoke-sqmLogging -Message "Warte auf Admin-Bestaetigung vor dem Kopieren der Partitionsdaten in '$ArchiveDatabaseName.$ArchiveSchemaName.$Table'." -FunctionName $functionName -Level "INFO"
					$goAhead = Read-Host "Archiv-Tabelle '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' wurde angelegt. Jetzt Daten aus '$stagingTable' kopieren? (j/n)"
					if ($goAhead -notmatch '^[jJyY]')
					{
						throw "Abgebrochen nach Anlage der Archiv-Tabelle (Admin-Bestaetigung verweigert). Partition $PartitionNumber wurde bereits per SWITCH nach '[$Schema].[$stagingTable]' verschoben und bleibt dort (NICHT geleert/geloescht) - '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' bleibt leer. Manuell pruefen; ein erneuter Aufruf ohne explizites -PartitionNumber waehlt ggf. eine ANDERE Partition (die aktuell aelteste MIT Daten), da diese Partition im Quellindex bereits leer ist."
					}
				}
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
			$hasIdentityCol = $tableDef.HasIdentity
			$archColList = ($tableDef.ColumnNames | ForEach-Object { "[$_]" }) -join ', '
			$archColListDeleted = ($tableDef.ColumnNames | ForEach-Object { "DELETED.[$_]" }) -join ', '

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
		# ihr und der naechsten Partition entfernt werden soll), NICHT ihre untere Grenze.
		$mergeDdl = "ALTER PARTITION FUNCTION [$($status[0].PartitionFunctionName)]() MERGE RANGE ($($(if ($targetPartition.UpperBoundaryValue -is [datetime]) { "'$($targetPartition.UpperBoundaryValue.ToString('yyyy-MM-dd'))'" } else { $targetPartition.UpperBoundaryValue })));"
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
