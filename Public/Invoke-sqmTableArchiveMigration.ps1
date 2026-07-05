<#
.SYNOPSIS
    Migriert eine noch nicht partitionierte, aktive Tabelle monatsweise in eine partitionierte Kopie in einer Archiv-Datenbank.

.DESCRIPTION
    Fuer den Fall, dass eine bestehende (nicht partitionierte) Tabelle NICHT wie bei
    Invoke-sqmTablePartitionConversion in der eigentlichen Datenbank partitioniert werden soll,
    sondern als partitionierte Kopie in eine separate Archiv-Datenbank ueberfuehrt wird - waehrend
    die Quelltabelle weiterhin unveraendert aktiv bleibt (kein Cutover, keine automatische
    Loeschung).

    Ablauf:
    1. Leere Strukturkopie der Tabelle in der (vom Admin bereits angelegten) Archiv-Datenbank
       anlegen (SELECT INTO ... WHERE 1 = 0), falls noch nicht vorhanden.
    1b. Optional (-ConfirmArchiveTable): pausiert nach dem Anlegen der leeren Tabelle und wartet
        auf eine Admin-Bestaetigung (Read-Host), bevor mit Schritt 2 fortgefahren wird - z.B. um
        die leere Tabelle vorher manuell zu pruefen. Nur beim allerersten Aufruf relevant (die
        Tabelle existiert danach, Schritt 1/1b werden bei einem Resume uebersprungen).
    2. Diese leere Kopie per Invoke-sqmTablePartitionConversion partitionieren - mit
       -ManualStartValue/-ManualEndValue aus dem tatsaechlichen Min/Max-Bereich der Quelle (die
       Kopie selbst ist ja leer). Nutzt die komplette bestehende Partitionierungslogik unveraendert.
    2b. Optional (-DataCompression Row/Page): wendet nach der Partitionierung ROW- oder
        PAGE-Kompression auf ALLE Partitionen der Archiv-Tabelle an (ALTER TABLE ... REBUILD).
        SELECT INTO kennt keine Kompressions-Klausel, daher als separater Schritt danach - laeuft
        ebenfalls nur beim allerersten Aufruf.
    3. In der QUELLDATENBANK (nicht master) eine Log-Tabelle (dbo.sqm_ArchiveMonthLog) und eine
       MERGE-Batch-Prozedur (dbo.sqm_ArchiveMonthBatch) idempotent anlegen/aktualisieren.
    4. Fuer jeden noch nicht abgeschlossenen Monat (YYYYMM, Standard: vom aeltesten Datenwert bis
       zum VORMONAT - der laufende Monat wird standardmaessig nicht migriert) die Prozedur
       wiederholt aufrufen, bis sie den Monat als abgeschlossen meldet.
    4b. Optional (-PurgeSourceAfterArchive): nach jedem abgeschlossenen Monat werden dessen Zeilen
        (nach Row-Count-Gegenpruefung) batchweise aus der Quelltabelle geloescht und - alle
        -ShrinkAfterEveryNPeriods Monate - der freigewordene Platz per DBCC SHRINKFILE auf dem
        Datentraeger zurueckgegeben. Fuer SAN/Datentraeger mit wenig freiem Platz, bei denen die
        Migration sonst nicht durchlaufen wuerde, weil Quelle UND Archiv-Kopie gleichzeitig Platz
        brauchen.

    Sicherheit gegen Unterbrechung: jeder Batch ist ein MERGE (WHEN MATCHED -> UPDATE, WHEN NOT
    MATCHED -> INSERT), also beliebig oft wiederholbar ohne Duplikate. Der Fortsetzpunkt
    (LastKeyProcessed) liegt dauerhaft in dbo.sqm_ArchiveMonthLog, nicht im Funktionsaufruf selbst -
    ein Abbruch (Netzwerk, Prozess-Kill) an JEDER Stelle verliert nichts, ein erneuter Aufruf
    (derselbe Funktionsaufruf oder direkt die Prozedur) setzt exakt dort fort, wo zuletzt committet
    wurde.

    Ohne -PurgeSourceAfterArchive wird die Quelltabelle von dieser Funktion nie geloescht oder
    umbenannt - ob/wann Quelldaten entfernt werden, ist dann eine spaetere, manuelle
    Admin-Entscheidung. Mit -PurgeSourceAfterArchive werden bereits archivierte Monate dagegen
    laufend (nach Bestaetigung ihrer vollstaendigen Archivierung) aus der Quelle geloescht - siehe
    Schritt 4b und die Parameterbeschreibung dort.

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER Database
    Quelldatenbank (enthaelt die noch nicht partitionierte, aktive Tabelle).
.PARAMETER Schema
    Schema der Quelltabelle.
.PARAMETER Table
    Tabellenname.
.PARAMETER ArchiveDatabaseName
    Archiv-Datenbank (muss auf derselben Instanz bereits existieren - wird NICHT automatisch
    angelegt, das ist Aufgabe des Admins).
.PARAMETER ArchiveSchemaName
    Zielschema in der Archiv-Datenbank. Standard: gleiches Schema wie die Quelltabelle.
.PARAMETER DateColumn
    Datumsspalte, nach der monatsweise migriert und in der Archiv-Datenbank partitioniert wird.
    Neben echten DATE/DATETIME-Typen wird auch ein YYYYMMDD-Ganzzahl- oder String-Surrogat
    unterstuetzt (z.B. INT-Spalte mit Wert 20240115) - siehe -BoundaryType.
.PARAMETER KeyColumn
    Eine oder mehrere Spalten (in dieser Reihenfolge, max. 4) fuer den MERGE-Abgleich und die
    Keyset-Pagination - muessen als TUPEL eindeutig sein. Zusammengesetzte Schluessel sind erlaubt,
    z.B. -KeyColumn 'VMTG', 'VID1', 'VID2', 'VSEQ'. Ohne Angabe wird automatisch die vollstaendige
    Schluesselspalten-Liste (in key_ordinal-Reihenfolge) des Clustered Index/PK verwendet - Pflicht
    nur bei einem echten Heap (kein Clustered Index) oder mehr als 4 Schluesselspalten.
.PARAMETER Granularity
    Aktuell nur 'Month' unterstuetzt (YYYYMM-basierte Migration).
.PARAMETER BatchSize
    Zeilen pro MERGE-Batch *innerhalb* eines Monats. Standard: 50000.
.PARAMETER StartPeriod
    Erster zu migrierender Monat (YYYYMM). Ohne Angabe: der Monat von MIN(DateColumn) der Quelle.
.PARAMETER EndPeriod
    Letzter zu migrierender Monat (YYYYMM). Ohne Angabe: der VORMONAT (der laufende, noch "offene"
    Monat wird standardmaessig nicht migriert).
.PARAMETER FilegroupStrategy
    Single (Standard) oder PerPeriod - durchgereicht an Invoke-sqmTablePartitionConversion fuer die
    Archiv-Kopie.
.PARAMETER FutureBufferPeriods
    Durchgereicht an Invoke-sqmTablePartitionConversion. Standard: 3.
.PARAMETER BoundaryType
    Date (echtes DATE/DATETIME), Int (YYYYMMDD als Ganzzahl, z.B. CORO_DB.dbo.CARCHIVE.VTDAT) oder
    Varchar (YYYYMMDD als String). Steuert sowohl die Perioden-Erkennung/-Grenzen dieser Funktion
    als auch (durchgereicht) Invoke-sqmTablePartitionConversion fuer die Archiv-Kopie. Ohne Angabe
    automatische Ableitung aus dem SQL-Spaltentyp von DateColumn.
.PARAMETER AllowKeyChange
    Durchgereicht an Invoke-sqmTablePartitionConversion.
.PARAMETER Method
    Durchgereicht an Invoke-sqmTablePartitionConversion.
.PARAMETER Online
    Durchgereicht an Invoke-sqmTablePartitionConversion.
.PARAMETER DataCompression
    None (Standard), Row oder Page. Wird NUR beim allerersten Aufruf (Anlage der Archiv-Kopie)
    angewendet - per ALTER TABLE ... REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = ...) nach
    der Partitionierung, da SELECT INTO keine Kompressions-Klausel unterstuetzt.
.PARAMETER ConfirmArchiveTable
    Pausiert nach dem Anlegen der leeren Archiv-Tabelle (Schritt 1) und fragt per Read-Host nach
    Admin-Bestaetigung, bevor mit der Partitionierung (Schritt 2) fortgefahren wird. Nur beim
    allerersten Aufruf relevant. Wird die Bestaetigung verweigert, bleibt die leere Tabelle
    bestehen und ein erneuter Aufruf setzt genau dort fort.
.PARAMETER PurgeSourceAfterArchive
    Loescht nach jedem als abgeschlossen bestaetigten Monat (Schritt 4) die soeben archivierten
    Zeilen aus der QUELLTABELLE - in Batches (-BatchSize), erst NACH einer Row-Count-Gegenpruefung
    gegen dbo.sqm_ArchiveMonthLog.RowsArchived fuer diesen Monat. Gedacht fuer SAN/Datentraeger mit
    wenig freiem Platz: ohne dieses Flag bleibt die Quelltabelle unveraendert (siehe Standard-
    Ablauf oben), mit diesem Flag wird der Speicherplatz laufend freigegeben statt erst nach
    vollstaendigem Abschluss der gesamten Migration.
.PARAMETER ShrinkAfterEveryNPeriods
    Nur relevant mit -PurgeSourceAfterArchive. Nach wie vielen geleerten Monaten
    DBCC SHRINKFILE (siehe -AggressiveShrink) auf den Datendateien der Quelldatenbank ausgefuehrt
    wird, um den durch das Loeschen freigewordenen Platz auch auf dem Datentraeger zurueckzugeben.
    Standard: 1 (nach jedem Monat).
.PARAMETER AggressiveShrink
    Nur relevant mit -PurgeSourceAfterArchive. Standardmaessig wird TRUNCATEONLY verwendet
    (schnell, keine Seitenverschiebung/Fragmentierung, gibt aber nur am Dateiende freien Platz
    zurueck). Mit diesem Schalter wird stattdessen ein voller Shrink ausgefuehrt (mehr
    Platzgewinn, fragmentiert dafuer die verbleibenden Indizes - Rebuild danach empfohlen).
.PARAMETER CutoverToArchiveView
    Sobald alle angeforderten Monate (-StartPeriod bis -EndPeriod) archiviert sind: Quelltabelle
    umbenennen (siehe -RenamedTableSuffix, bleibt vollstaendig erhalten - kein automatisches Drop)
    und unter dem urspruenglichen Namen durch eine Kompatibilitaets-View auf die partitionierte
    Kopie in der Archiv-Datenbank ersetzen (gleiches Muster wie bei Invoke-sqmTableRelocation).
    Bestehender Anwendungscode, der die Quelltabelle unter ihrem alten Namen anspricht, laeuft
    danach unveraendert weiter - jetzt gegen die Archiv-Kopie. Idempotent: existiert die
    umbenannte Tabelle bereits, wird der Cutover uebersprungen (schon frueher ausgefuehrt).
    ACHTUNG: der laufende, noch nicht abgeschlossene Monat wird nie automatisch migriert (siehe
    -EndPeriod) - dessen Zeilen bleiben nach dem Cutover in der umbenannten Original-Tabelle
    zurueck und muessen vom Admin manuell gepflegt/nachgezogen werden, bevor diese geloescht wird.
.PARAMETER RenamedTableSuffix
    Nur relevant mit -CutoverToArchiveView. Suffix fuer die umbenannte Original-Tabelle.
    Standard: '_Original' (gleiche Konvention wie Invoke-sqmTableRelocation).
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    Invoke-sqmTableArchiveMigration -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
        -Table "OrderHistory" -ArchiveDatabaseName "SalesArchive" -DateColumn "OrderDate"

.EXAMPLE
    # Nur einen bestimmten Zeitraum migrieren, kleinere Batches
    Invoke-sqmTableArchiveMigration -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
        -Table "OrderHistory" -ArchiveDatabaseName "SalesArchive" -DateColumn "OrderDate" `
        -StartPeriod 202401 -EndPeriod 202412 -BatchSize 20000

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), Invoke-sqmTablePartitionConversion,
    Get-sqmPartitionColumnRange, Install-sqmArchiveMigrationInfra (privat). Die Archiv-Datenbank
    muss vom Admin bereits angelegt sein. Erneuter Aufruf ist jederzeit sicher (idempotent) - bereits
    abgeschlossene Monate werden uebersprungen, ein unterbrochener Monat setzt beim
    Fortsetzpunkt aus dbo.sqm_ArchiveMonthLog (Quelldatenbank) fort.
#>
function Invoke-sqmTableArchiveMigration
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

		[Parameter(Mandatory = $true)]
		[string]$ArchiveDatabaseName,

		[Parameter(Mandatory = $false)]
		[string]$ArchiveSchemaName,

		[Parameter(Mandatory = $true)]
		[string]$DateColumn,

		[Parameter(Mandatory = $false)]
		[ValidateCount(1, 4)]
		[string[]]$KeyColumn,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Month')]
		[string]$Granularity = 'Month',

		[Parameter(Mandatory = $false)]
		[ValidateRange(100, 1000000)]
		[int]$BatchSize = 50000,

		[Parameter(Mandatory = $false)]
		[int]$StartPeriod,

		[Parameter(Mandatory = $false)]
		[int]$EndPeriod,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Single', 'PerPeriod')]
		[string]$FilegroupStrategy = 'Single',

		[Parameter(Mandatory = $false)]
		[int]$FutureBufferPeriods = 3,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Date', 'Int', 'Varchar')]
		[string]$BoundaryType,

		[Parameter(Mandatory = $false)]
		[switch]$AllowKeyChange,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Default', 'NewTableSwap')]
		[string]$Method = 'Default',

		[Parameter(Mandatory = $false)]
		[switch]$Online,

		[Parameter(Mandatory = $false)]
		[ValidateSet('None', 'Row', 'Page')]
		[string]$DataCompression = 'None',

		[Parameter(Mandatory = $false)]
		[switch]$ConfirmArchiveTable,

		[Parameter(Mandatory = $false)]
		[switch]$PurgeSourceAfterArchive,

		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 1000)]
		[int]$ShrinkAfterEveryNPeriods = 1,

		[Parameter(Mandatory = $false)]
		[switch]$AggressiveShrink,

		[Parameter(Mandatory = $false)]
		[switch]$CutoverToArchiveView,

		[Parameter(Mandatory = $false)]
		[string]$RenamedTableSuffix = '_Original',

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
	if (-not $ArchiveSchemaName) { $ArchiveSchemaName = $Schema }

	# =============================================================================================
	# Cutover (-CutoverToArchiveView): eigene, verschachtelte Funktion statt Inline-Code, weil sie
	# von ZWEI Stellen aus aufgerufen werden muss - dem regulaeren Pfad (nach der Perioden-Schleife)
	# UND dem fruehen "nichts zu tun"-Pfad (wenn alle Monate schon in einem frueheren Aufruf
	# archiviert wurden und dieser Aufruf nur noch den Cutover nachholen soll). Sieht $connParams/
	# $Schema/$Table/etc. aus dem umschliessenden Funktions-Scope (gleiches Muster wie
	# Set-Step6Enabled in Show-sqmPartitionToolGui.ps1).
	# =============================================================================================
	function Invoke-CutoverIfRequested
	{
		if (-not $CutoverToArchiveView) { return $false }

		$renamedName = "${Table}${RenamedTableSuffix}"
		$alreadyDone = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[$Schema].[$renamedName]');" -ErrorAction Stop -EnableException
		if ($alreadyDone)
		{
			Invoke-sqmLogging -Message "Cutover uebersprungen: '$Schema.$renamedName' existiert bereits - vermutlich schon frueher ausgefuehrt." -FunctionName $functionName -Level "INFO"
			return $false
		}

		$cutoverAction = "'$Schema.$Table' umbenennen -> '$Schema.$renamedName', dann View '$Schema.$Table' -> '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' anlegen"
		if (-not $PSCmdlet.ShouldProcess($Database, $cutoverAction)) { return $false }

		$residualRows = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT COUNT(*) AS Cnt FROM [$Schema].[$Table];" -ErrorAction Stop -EnableException).Cnt

		Invoke-DbaQuery @connParams -Database $Database -Query "EXEC sp_rename N'[$Schema].[$Table]', N'$renamedName';" -ErrorAction Stop -EnableException
		Invoke-sqmLogging -Message "Original-Tabelle umbenannt: '$Schema.$Table' -> '$Schema.$renamedName' (bleibt vollstaendig erhalten, wird NICHT geloescht)." -FunctionName $functionName -Level "INFO"

		$colRows = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT name AS ColumnName FROM sys.columns WHERE object_id = OBJECT_ID(N'[$Schema].[$renamedName]') ORDER BY column_id;" -ErrorAction Stop -EnableException
		$colList = ($colRows | ForEach-Object { "[$($_.ColumnName)]" }) -join ', '
		$viewDdl = "CREATE VIEW [$Schema].[$Table] AS SELECT $colList FROM [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table];"
		Invoke-DbaQuery @connParams -Database $Database -Query $viewDdl -ErrorAction Stop -EnableException

		$residualMsg = if ($residualRows -gt 0)
		{
			"ACHTUNG: $residualRows Zeile(n) in '$Schema.$renamedName' wurden NICHT archiviert (z.B. der laufende, noch offene Monat) - vor dem Loeschen pruefen/manuell nachziehen."
		}
		else { "'$Schema.$renamedName' ist leer." }
		Invoke-sqmLogging -Message "Cutover abgeschlossen: '$Schema.$Table' ist jetzt eine View auf '$ArchiveDatabaseName.$ArchiveSchemaName.$Table'. $residualMsg Admin kann '$Schema.$renamedName' nach Pruefung manuell loeschen." -FunctionName $functionName -Level "INFO"
		return $true
	}

	try
	{
		# =========================================================================================
		# 0. Archiv-Datenbank muss existieren (Admin legt sie an, nicht diese Funktion)
		# =========================================================================================
		$dbExists = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT 1 FROM sys.databases WHERE name = N'$ArchiveDatabaseName';" -ErrorAction Stop -EnableException
		if (-not $dbExists)
		{
			throw "Archiv-Datenbank '$ArchiveDatabaseName' existiert nicht auf '$SqlInstance' - muss vom Admin vorher angelegt werden."
		}

		# Cutover bereits in einem frueheren Aufruf durchgefuehrt? Dann ist '$Schema.$Table' jetzt
		# eine VIEW, nicht mehr die Quelltabelle - jeglicher Versuch, KeyColumn/Wertebereich daraus
		# abzuleiten, wuerde fehlschlagen (Views haben keinen Clustered Index). Direkt hier abbrechen,
		# statt erst in Schritt 1 mit einer irrefuehrenden KeyColumn-Fehlermeldung zu scheitern.
		if ($CutoverToArchiveView)
		{
			$renamedNameCheck = "${Table}${RenamedTableSuffix}"
			$cutoverAlreadyDone = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'[$Schema].[$renamedNameCheck]');" -ErrorAction Stop -EnableException
			if ($cutoverAlreadyDone)
			{
				Invoke-sqmLogging -Message "Cutover bereits abgeschlossen: '$Schema.$renamedNameCheck' existiert bereits, '$Schema.$Table' ist die Kompatibilitaets-View - nichts zu tun." -FunctionName $functionName -Level "INFO"
				return [PSCustomObject]@{
					SchemaName = $Schema; TableName = $Table; ArchiveDatabaseName = $ArchiveDatabaseName
					MonthsProcessed = 0; MonthsAlreadyDone = 0; TotalRowsArchived = 0
					CutoverPerformed = $false; Status = 'NothingToDo'
				}
			}
		}

		# =========================================================================================
		# 1. KeyColumn ermitteln (falls nicht angegeben) - gleiche Herleitung wie Invoke-sqmTableRelocation,
		#    jetzt aber fuer zusammengesetzte Schluessel: ALLE Spalten des Clustered Index/PK in
		#    key_ordinal-Reihenfolge werden uebernommen (statt bei mehr als einer Spalte abzubrechen).
		# =========================================================================================
		if (-not $KeyColumn)
		{
			$ciKeyQuery = @"
SELECT c.name AS ColumnName
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'[$Schema].[$Table]') AND i.index_id = 1
ORDER BY ic.key_ordinal
"@
			# @(...) erzwingt Array-Kontext - siehe gleicher Kommentar in Invoke-sqmTableRelocation.
			$ciKeyRows = @(Invoke-DbaQuery @connParams -Database $Database -Query $ciKeyQuery -ErrorAction Stop -EnableException)
			if ($ciKeyRows.Count -eq 0) { throw "'-KeyColumn' ist Pflicht: '$Schema.$Table' ist ein Heap (kein Clustered Index/PK, aus dem ein Schluessel automatisch abgeleitet werden koennte)." }
			if ($ciKeyRows.Count -gt 4) { throw "'$Schema.$Table' hat einen zusammengesetzten Schluessel mit $($ciKeyRows.Count) Spalten - aktuell werden maximal 4 Schluesselspalten unterstuetzt. '-KeyColumn' muss eine eigene, hoechstens 4-spaltige eindeutige Schluesselliste explizit angeben." }
			$KeyColumn = @($ciKeyRows | ForEach-Object { $_.ColumnName })
		}
		elseif (@($KeyColumn).Count -gt 4)
		{
			throw "'-KeyColumn' unterstuetzt aktuell maximal 4 Spalten (erhalten: $(@($KeyColumn).Count))."
		}
		$keyColumnsCsv = ($KeyColumn -join ',')
		Invoke-sqmLogging -Message "Schluessel fuer '$Schema.$Table': $keyColumnsCsv$(if (@($KeyColumn).Count -gt 1) { ' (zusammengesetzt)' })." -FunctionName $functionName -Level "INFO"

		# ---------------------------------------------------------------------------------------
		# 1b. Nicht blockierender Hinweis: ohne einen Index mit $DateColumn als fuehrender Spalte
		#     scanned jeder Batch-Aufruf von sqm_ArchiveMonthBatch potenziell die gesamte Tabelle -
		#     bei sehr grossen Tabellen (mehrere 100GB+) ein echtes Performance-Risiko. Anlegen eines
		#     passenden Index ist eine Admin-Entscheidung, wird hier nur empfohlen, nicht automatisch
		#     ausgefuehrt.
		# ---------------------------------------------------------------------------------------
		$dateIdxQuery = @"
SELECT 1
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal = 1 AND ic.is_included_column = 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'[$Schema].[$Table]') AND c.name = N'$DateColumn'
"@
		$dateColIndexed = Invoke-DbaQuery @connParams -Database $Database -Query $dateIdxQuery -ErrorAction Stop -EnableException
		if (-not $dateColIndexed)
		{
			Invoke-sqmLogging -Message "'$Schema.$Table' hat keinen Index mit '$DateColumn' als fuehrender Spalte - jeder Batch-Aufruf von sqm_ArchiveMonthBatch scanned dadurch potenziell die gesamte Tabelle/Partition. Bei grossen Tabellen wird DRINGEND empfohlen, VOR einem echten Migrationslauf einen nichtclustered Index auf ($DateColumn, $keyColumnsCsv) anzulegen (Admin-Entscheidung, wird von diesem Tool NICHT automatisch erstellt)." -FunctionName $functionName -Level "WARNING"
		}

		# ---------------------------------------------------------------------------------------
		# 1c. BoundaryType von $DateColumn ermitteln (falls nicht angegeben) - gleiche Herleitung
		#     wie Invoke-sqmTablePartitionConversion.ps1 (Date/Datetime-Typen -> 'Date',
		#     Varchar/Nvarchar/Char/Nchar -> 'Varchar' [YYYYMMDD-String], sonst -> 'Int'
		#     [YYYYMMDD als Ganzzahl, z.B. CORO_DB.dbo.CARCHIVE.VTDAT]). Noetig, weil sowohl die
		#     Start/EndPeriod-Ableitung aus dem Quellwertebereich als auch die an
		#     sqm_ArchiveMonthBatch uebergebenen Periodengrenzen sonst blind einen echten
		#     DATE/DATETIME-Typ voraussetzen wuerden - schlaegt bei einem YYYYMMDD-Surrogat wie
		#     VTDAT sonst mit "date ist inkompatibel mit int" fehl (live gegen CARCHIVE bestaetigt).
		# ---------------------------------------------------------------------------------------
		$dateColTypeQuery = "SELECT ty.name AS TypeName FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id WHERE c.object_id = OBJECT_ID(N'[$Schema].[$Table]') AND c.name = N'$DateColumn';"
		$dateColTypeRow = Invoke-DbaQuery @connParams -Database $Database -Query $dateColTypeQuery -ErrorAction Stop -EnableException
		if (-not $dateColTypeRow) { throw "Spalte '$DateColumn' nicht gefunden in '$Schema.$Table'." }
		$dateColTypeName = [string]$dateColTypeRow.TypeName

		if (-not $BoundaryType)
		{
			$dateTypes = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
			$varcharTypes = @('varchar', 'nvarchar', 'char', 'nchar')
			$BoundaryType = if ($dateColTypeName -in $dateTypes) { 'Date' } elseif ($dateColTypeName -in $varcharTypes) { 'Varchar' } else { 'Int' }
			Invoke-sqmLogging -Message "BoundaryType nicht angegeben - aus Spaltentyp '$dateColTypeName' von '$DateColumn' abgeleitet: $BoundaryType." -FunctionName $functionName -Level "INFO"
		}

		# =========================================================================================
		# 2. Zu migrierende Monate bestimmen (rein lesend - noch keine Aenderung)
		# =========================================================================================
		# archiveExists/completedPeriods werden VOR dem Quellwertebereich ermittelt, weil eine mit
		# -PurgeSourceAfterArchive bereits vollstaendig geleerte Quelltabelle keinen Wertebereich
		# mehr liefert (IsEmpty) - genau der Fall, in dem ein Folgeaufruf trotzdem noch sinnvoll ist
		# (z.B. nur um -CutoverToArchiveView nachzuholen). Ohne bereits bekannte, abgeschlossene
		# Monate aus dem Log ist eine leere Quelle dagegen wirklich nichts zu migrieren.
		$archiveExists = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT 1 FROM [$ArchiveDatabaseName].sys.tables t JOIN [$ArchiveDatabaseName].sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = N'$ArchiveSchemaName' AND t.name = N'$Table'" -ErrorAction Stop -EnableException

		# Log-Tabelle existiert evtl. noch nicht (allererster Aufruf ueberhaupt) - dann sind
		# logischerweise auch noch keine Monate abgeschlossen.
		$logTableExists = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'dbo.sqm_ArchiveMonthLog') AND type = 'U';" -ErrorAction Stop -EnableException
		$completedPeriods = if ($logTableExists)
		{
			$completedQuery = "SELECT YYYYMM FROM dbo.sqm_ArchiveMonthLog WHERE SchemaName = N'$Schema' AND TableName = N'$Table' AND ArchiveDatabaseName = N'$ArchiveDatabaseName' AND Status = 'Completed';"
			@(Invoke-DbaQuery @connParams -Database $Database -Query $completedQuery -ErrorAction Stop -EnableException | ForEach-Object { [int]$_.YYYYMM })
		}
		else { @() }

		$rangeParams = @{ SqlInstance = $SqlInstance; Database = $Database; Schema = $Schema; Table = $Table; Column = $DateColumn }
		if ($SqlCredential) { $rangeParams['SqlCredential'] = $SqlCredential }
		$srcRange = Get-sqmPartitionColumnRange @rangeParams
		if ($srcRange.IsEmpty -and $completedPeriods.Count -eq 0)
		{
			throw "'$Schema.$Table' ist leer - keine Migration moeglich (keine Werte in '$DateColumn')."
		}

		if ($srcRange.IsEmpty)
		{
			# Quelle wurde vermutlich bereits vollstaendig archiviert und (per -PurgeSourceAfterArchive)
			# geleert - Start/EndPeriod koennen dann nicht mehr aus dem jetzt leeren Quellwertebereich
			# abgeleitet werden, nur noch aus dem Log.
			if (-not $StartPeriod) { $StartPeriod = ($completedPeriods | Measure-Object -Minimum).Minimum }
			if (-not $EndPeriod) { $EndPeriod = ($completedPeriods | Measure-Object -Maximum).Maximum }
		}
		else
		{
			# Bei Int/Varchar wird MinValue als YYYYMMDD-Surrogat interpretiert (siehe BoundaryType-
			# Herleitung oben) statt direkt als [datetime] gecastet zu werden - Letzteres schlaegt fuer
			# einen rohen Ganzzahlwert wie 20240101 fehl ("nicht als DateTime erkannt").
			$minValDt = if ($BoundaryType -in @('Int', 'Varchar')) { [datetime]::ParseExact([string]$srcRange.MinValue, 'yyyyMMdd', $null) } else { [datetime]$srcRange.MinValue }
			if (-not $StartPeriod) { $StartPeriod = [int]$minValDt.ToString('yyyyMM') }
			if (-not $EndPeriod) { $EndPeriod = [int](Get-Date).AddMonths(-1).ToString('yyyyMM') }
		}
		if ($EndPeriod -lt $StartPeriod) { throw "-EndPeriod ($EndPeriod) liegt vor -StartPeriod ($StartPeriod)." }

		$allPeriods = [System.Collections.Generic.List[int]]::new()
		$cursor = [datetime]::ParseExact("$($StartPeriod)01", 'yyyyMMdd', $null)
		$endCursor = [datetime]::ParseExact("$($EndPeriod)01", 'yyyyMMdd', $null)
		while ($cursor -le $endCursor)
		{
			$allPeriods.Add([int]$cursor.ToString('yyyyMM'))
			$cursor = $cursor.AddMonths(1)
		}

		$pendingPeriods = @($allPeriods | Where-Object { $_ -notin $completedPeriods })

		if ($pendingPeriods.Count -eq 0 -and $archiveExists)
		{
			Invoke-sqmLogging -Message "Alle Monate ($StartPeriod - $EndPeriod) fuer '$Schema.$Table' bereits archiviert - nichts zu tun." -FunctionName $functionName -Level "INFO"
			$cutoverPerformed = Invoke-CutoverIfRequested
			return [PSCustomObject]@{
				SchemaName = $Schema; TableName = $Table; ArchiveDatabaseName = $ArchiveDatabaseName
				MonthsProcessed = 0; MonthsAlreadyDone = $completedPeriods.Count; TotalRowsArchived = 0
				CutoverPerformed = $cutoverPerformed; Status = 'NothingToDo'
			}
		}

		$action = "'$Schema.$Table' -> '$ArchiveDatabaseName.$ArchiveSchemaName.$Table': " +
		$(if (-not $archiveExists) { "Archiv-Kopie anlegen + partitionieren, dann " } else { '' }) +
		"$($pendingPeriods.Count) Monat(e) archivieren ($StartPeriod - $EndPeriod)"
		if (-not $PSCmdlet.ShouldProcess($Database, $action)) { return }

		# =========================================================================================
		# 3. Archiv-Kopie sicherstellen (einmalig - idempotent uebersprungen bei Resume)
		# =========================================================================================
		if (-not $archiveExists)
		{
			Invoke-DbaQuery @connParams -Database $Database -Query "IF SCHEMA_ID(N'$ArchiveSchemaName') IS NULL EXEC(N'CREATE SCHEMA [$ArchiveSchemaName]');" -ErrorAction Stop -EnableException
			Invoke-DbaQuery @connParams -Database $Database -Query "SELECT * INTO [$ArchiveDatabaseName].[$ArchiveSchemaName].[$Table] FROM [$Schema].[$Table] WHERE 1 = 0;" -ErrorAction Stop -EnableException
			Invoke-sqmLogging -Message "Leere Strukturkopie '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' angelegt." -FunctionName $functionName -Level "INFO"

			if ($ConfirmArchiveTable)
			{
				Invoke-sqmLogging -Message "Warte auf Admin-Bestaetigung vor der Partitionierung von '$ArchiveDatabaseName.$ArchiveSchemaName.$Table'." -FunctionName $functionName -Level "INFO"
				$goAhead = Read-Host "Leere Archiv-Tabelle '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' wurde angelegt. Jetzt partitionieren? (j/n)"
				if ($goAhead -notmatch '^[jJyY]')
				{
					throw "Abgebrochen nach Anlage der leeren Archiv-Tabelle (Admin-Bestaetigung verweigert). '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' bleibt unveraendert (leer, unpartitioniert) - ein erneuter Aufruf setzt hier fort."
				}
			}

			$convParams = @{
				SqlInstance         = $SqlInstance
				Database            = $ArchiveDatabaseName
				Schema              = $ArchiveSchemaName
				Table               = $Table
				PartitionColumn     = $DateColumn
				Granularity         = $Granularity
				FilegroupStrategy   = $FilegroupStrategy
				FutureBufferPeriods = $FutureBufferPeriods
				ManualStartValue    = $srcRange.MinValue
				ManualEndValue      = $srcRange.MaxValue
				Method              = $Method
				Confirm             = $false
				EnableException     = $true
			}
			if ($BoundaryType) { $convParams['BoundaryType'] = $BoundaryType }
			if ($AllowKeyChange) { $convParams['AllowKeyChange'] = $true }
			if ($Online) { $convParams['Online'] = $true }
			if ($SqlCredential) { $convParams['SqlCredential'] = $SqlCredential }

			Invoke-sqmTablePartitionConversion @convParams | Out-Null
			Invoke-sqmLogging -Message "Archiv-Kopie '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' partitioniert (Bereich $($srcRange.MinValue) - $($srcRange.MaxValue))." -FunctionName $functionName -Level "INFO"

			if ($DataCompression -ne 'None')
			{
				$compressionSql = "ALTER TABLE [$ArchiveSchemaName].[$Table] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = $($DataCompression.ToUpper()));"
				Invoke-DbaQuery @connParams -Database $ArchiveDatabaseName -Query $compressionSql -ErrorAction Stop -EnableException
				Invoke-sqmLogging -Message "$DataCompression-Kompression auf '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' angewendet (alle Partitionen)." -FunctionName $functionName -Level "INFO"
			}
		}
		else
		{
			Invoke-sqmLogging -Message "Archiv-Kopie '$ArchiveDatabaseName.$ArchiveSchemaName.$Table' existiert bereits - ueberspringe Anlage/Partitionierung." -FunctionName $functionName -Level "INFO"
		}

		# =========================================================================================
		# 4. Infrastruktur (Log-Tabelle + Batch-Prozedur) in der QUELLDATENBANK sicherstellen
		# =========================================================================================
		$installParams = @{ SqlInstance = $SqlInstance; Database = $Database }
		if ($SqlCredential) { $installParams['SqlCredential'] = $SqlCredential }
		$mod = Get-Module -Name sqmPartitionTool
		& $mod { param($p) Install-sqmArchiveMigrationInfra @p } $installParams | Out-Null

		# =========================================================================================
		# 5. Je ausstehendem Monat: Batch-Prozedur wiederholt aufrufen, bis MonthComplete = 1
		# =========================================================================================
		$totalRows = 0
		$totalPurgedRows = 0
		$periodsPurged = 0
		$shrinkRunsPerformed = 0
		$periodIndex = 0
		$totalPeriodsToProcess = $pendingPeriods.Count
		# Invoke-sqmLogging schreibt NUR in eine Logdatei, nie auf die Konsole - ohne dieses
		# Write-Progress/Write-Host haette ein Admin bei einer sehr grossen Tabelle (mehrere
		# 100GB-TB) ueber Stunden/Tage hinweg keinerlei sichtbares Lebenszeichen, dass die Migration
		# tatsaechlich noch laeuft (nicht nur haengt). Write-Progress fuer interaktive Konsolen,
		# zusaetzlich eine Write-Host-Zeile pro Monat, damit es auch in einem Transkript/einer
		# umgeleiteten Ausgabe (nicht-interaktiv, z.B. geplanter Task) sichtbar bleibt.
		$progressActivity = "Archiving '$Schema.$Table' -> '$ArchiveDatabaseName.$ArchiveSchemaName.$Table'"
		foreach ($period in $pendingPeriods)
		{
			$periodIndex++
			$percentComplete = if ($totalPeriodsToProcess -gt 0) { [int](100 * ($periodIndex - 1) / $totalPeriodsToProcess) } else { 0 }
			Write-Progress -Activity $progressActivity -Status "Period $period ($periodIndex of $totalPeriodsToProcess) - $totalRows row(s) archived so far" -PercentComplete $percentComplete
			Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Archiving period $period ($periodIndex of $totalPeriodsToProcess) ..."

			$monthComplete = $false
			$rowsThisPeriod = 0
			while (-not $monthComplete)
			{
				$batchSql = @"
DECLARE @RowsThisCall BIGINT, @MonthComplete BIT;
EXEC dbo.sqm_ArchiveMonthBatch
    @SchemaName = N'$Schema', @TableName = N'$Table', @DateColumn = N'$DateColumn', @KeyColumns = N'$keyColumnsCsv',
    @YYYYMM = $period, @BoundaryType = N'$BoundaryType', @ArchiveDatabaseName = N'$ArchiveDatabaseName', @ArchiveSchemaName = N'$ArchiveSchemaName',
    @ArchiveTableName = N'$Table', @BatchSize = $BatchSize,
    @RowsThisCall = @RowsThisCall OUTPUT, @MonthComplete = @MonthComplete OUTPUT;
SELECT @RowsThisCall AS RowsThisCall, @MonthComplete AS MonthComplete;
"@
				$batchResult = Invoke-DbaQuery @connParams -Database $Database -Query $batchSql -ErrorAction Stop -EnableException
				$rowsThisCall = [int64]$batchResult.RowsThisCall
				$monthComplete = [bool]$batchResult.MonthComplete
				$totalRows += $rowsThisCall
				$rowsThisPeriod += $rowsThisCall
				Invoke-sqmLogging -Message "Monat $period : $rowsThisCall Zeile(n) in diesem Batch verarbeitet - $(if ($monthComplete) { 'Monat abgeschlossen' } else { 'weitere Batches folgen' })." -FunctionName $functionName -Level "INFO"
				Write-Progress -Activity $progressActivity -Status "Period $period ($periodIndex of $totalPeriodsToProcess) - $rowsThisPeriod row(s) this period, $totalRows total so far" -PercentComplete $percentComplete
			}
			Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Period $period done: $rowsThisPeriod row(s) archived (running total: $totalRows)."

			# ---------------------------------------------------------------------------------------
			# 5b. Optional (-PurgeSourceAfterArchive): abgeschlossenen Monat aus der Quelle loeschen,
			#     dann periodisch shrinken. NUR nach Row-Count-Gegenpruefung gegen das Log - trennt
			#     dieses Sicherheitsnetz bewusst von $monthComplete allein.
			# ---------------------------------------------------------------------------------------
			if ($PurgeSourceAfterArchive)
			{
				$periodStartDate = [datetime]::ParseExact("$($period)01", 'yyyyMMdd', $null)
				$periodEndDate = $periodStartDate.AddMonths(1)
				# Literal je nach BoundaryType passend formatieren (Int: unquotierte YYYYMMDD-Zahl,
				# Varchar: quotierter YYYYMMDD-String, Date: quotiertes ISO-Datum) - dieselbe
				# YYYYMMDD-Konvention wie Get-sqmPartitionBoundaryList/Invoke-sqmTablePartitionConversion.
				$periodStartLit = switch ($BoundaryType) { 'Int' { [int]$periodStartDate.ToString('yyyyMMdd') }; 'Varchar' { "'$($periodStartDate.ToString('yyyyMMdd'))'" }; default { "'$($periodStartDate.ToString('yyyy-MM-dd'))'" } }
				$periodEndLit = switch ($BoundaryType) { 'Int' { [int]$periodEndDate.ToString('yyyyMMdd') }; 'Varchar' { "'$($periodEndDate.ToString('yyyyMMdd'))'" }; default { "'$($periodEndDate.ToString('yyyy-MM-dd'))'" } }

				$loggedRows = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT RowsArchived FROM dbo.sqm_ArchiveMonthLog WHERE SchemaName = N'$Schema' AND TableName = N'$Table' AND ArchiveDatabaseName = N'$ArchiveDatabaseName' AND YYYYMM = $period;" -ErrorAction Stop -EnableException).RowsArchived
				$sourceRowsNow = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT COUNT(*) AS Cnt FROM [$Schema].[$Table] WHERE [$DateColumn] >= $periodStartLit AND [$DateColumn] < $periodEndLit;" -ErrorAction Stop -EnableException).Cnt

				if ($sourceRowsNow -ne $loggedRows)
				{
					Invoke-sqmLogging -Message "Monat $period : Row-Count-Gegenpruefung fehlgeschlagen (Quelle: $sourceRowsNow, laut Log archiviert: $loggedRows) - Loeschen aus der Quelle uebersprungen. Manuell pruefen, bevor erneut versucht wird." -FunctionName $functionName -Level "WARNING"
				}
				else
				{
					$deletedThisPeriod = 0
					$rowsAffected = 1
					while ($rowsAffected -gt 0)
					{
						$purgeSql = "DELETE TOP ($BatchSize) FROM [$Schema].[$Table] WHERE [$DateColumn] >= $periodStartLit AND [$DateColumn] < $periodEndLit; SELECT @@ROWCOUNT AS Cnt;"
						$rowsAffected = [int64](Invoke-DbaQuery @connParams -Database $Database -Query $purgeSql -ErrorAction Stop -EnableException).Cnt
						$deletedThisPeriod += $rowsAffected
					}
					$totalPurgedRows += $deletedThisPeriod
					$periodsPurged++
					Invoke-sqmLogging -Message "Monat $period : $deletedThisPeriod Zeile(n) aus Quelltabelle '$Schema.$Table' geloescht (Row-Count-Gegenpruefung bestanden)." -FunctionName $functionName -Level "INFO"

					if ($periodsPurged % $ShrinkAfterEveryNPeriods -eq 0)
					{
						try
						{
							$shrinkParams = @{ SqlInstance = $SqlInstance; Database = $Database; Confirm = $false; EnableException = $true }
							if ($SqlCredential) { $shrinkParams['SqlCredential'] = $SqlCredential }
							if ($AggressiveShrink) { $shrinkParams['Aggressive'] = $true }
							$mod = Get-Module -Name sqmPartitionTool
							& $mod { param($p) Invoke-sqmFileSpaceShrink @p } $shrinkParams | Out-Null
							$shrinkRunsPerformed++
						}
						catch
						{
							# Shrink ist ein "Nice-to-have" fuer Plattenplatz, kein Abbruchgrund - die
							# eigentliche Archivierung + der Loeschvorgang sind bereits sicher erfolgt.
							Invoke-sqmLogging -Message "Shrink nach Monat $period fehlgeschlagen (Migration wird fortgesetzt): $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						}
					}
				}
			}
		}
		if ($totalPeriodsToProcess -gt 0) { Write-Progress -Activity $progressActivity -Completed }

		$cutoverPerformed = Invoke-CutoverIfRequested

		return [PSCustomObject]@{
			SchemaName          = $Schema
			TableName           = $Table
			ArchiveDatabaseName = $ArchiveDatabaseName
			MonthsProcessed     = $pendingPeriods.Count
			MonthsAlreadyDone   = $completedPeriods.Count
			TotalRowsArchived   = $totalRows
			PeriodsPurged       = $periodsPurged
			RowsPurged          = $totalPurgedRows
			ShrinkRunsPerformed = $shrinkRunsPerformed
			CutoverPerformed    = $cutoverPerformed
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
