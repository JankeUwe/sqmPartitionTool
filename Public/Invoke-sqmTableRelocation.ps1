<#
.SYNOPSIS
    Verschiebt eine komplette Tabelle in vertraeglichen Batches in eine andere Datenbank
    (derselben Instanz) und haengt sie am Ende per View unter dem alten Namen wieder ein.

.DESCRIPTION
    Fuer die einmalige, vollstaendige Auslagerung einer (typischerweise sehr grossen) Tabelle in
    eine separate Datenbank - im Unterschied zu Invoke-sqmPartitionArchive (das fortlaufend nur
    ABGELAUFENE PARTITIONEN einer weiterhin aktiven, partitionierten Tabelle auslagert), verschiebt
    diese Funktion die GESAMTE Tabelle in EINEM Vorgang (ueber ggf. mehrere Aufrufe verteilt).

    Ablauf:
    1. Zieltabelle in der Zieldatenbank anlegen, falls noch nicht vorhanden (Struktur/IDENTITY
       per SELECT INTO ... WHERE 1=0 aus der Quelle uebernommen), danach Clustered Index/PK
       auf der Schluesselspalte nachbilden (guenstig fuer den anschliessenden Batch-Load in den
       noch leeren Heap).
    2. Batchweise, NICHT-destruktive Kopie (die Quelltabelle bleibt bis zum Abschluss unveraendert
       bestehen - jeder Batch ist eine eigene, kleine Transaktion, damit das Transaktionslog nicht
       anwaechst). Fortsetzbar: liest bei jedem Aufruf den tatsaechlichen Fortschritt (MAX der
       Schluesselspalte in der Zieltabelle) und macht dort weiter - ein Lauf kann jederzeit
       abgebrochen und spaeter erneut aufgerufen werden, auch ueber -MaxDurationMinutes gezielt in
       Wartungsfenster aufgeteilt.
    3. Erst wenn ALLE Zeilen kopiert sind (Zeilenzahl-Abgleich Quelle/Ziel), der eigentliche,
       einmalige Cutover: Quelltabelle wird umbenannt (Sicherheitsnetz - bleibt vollstaendig
       erhalten, wird NICHT geloescht), danach ein View mit dem urspruenglichen Tabellennamen
       angelegt, der per Cross-DB-Query auf die Zieltabelle zeigt. Bestehende Abfragen/Reports
       auf den alten Tabellennamen laufen danach unveraendert weiter.

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER Database
    Quelldatenbank.
.PARAMETER Schema
    Schema der Quelltabelle.
.PARAMETER Table
    Tabellenname.
.PARAMETER TargetDatabaseName
    Zieldatenbank (muss auf derselben Instanz existieren - wird nicht automatisch angelegt).
.PARAMETER TargetSchemaName
    Zielschema. Standard: gleiches Schema wie die Quelltabelle.
.PARAMETER KeyColumn
    Spalte fuer die Batch-Reihenfolge (muss sortierbar/eindeutig sein, typischerweise die
    IDENTITY-/PK-Spalte). Ohne Angabe wird automatisch die einzelne Schluesselspalte eines
    einspaltigen Clustered Index/PK verwendet - bei zusammengesetztem Schluessel oder Heap ohne
    eindeutige Spalte ist die explizite Angabe Pflicht.
.PARAMETER BatchSize
    Zeilen pro Batch/Transaktion. Standard: 50000.
.PARAMETER MaxDurationMinutes
    Bricht nach dieser Laufzeit sauber zwischen zwei Batches ab (0 = kein Limit, Standard) -
    fuer die gezielte Aufteilung sehr grosser Tabellen auf mehrere Wartungsfenster. Ein erneuter
    Aufruf setzt automatisch beim letzten kopierten Schluesselwert fort.
.PARAMETER SkipCompatibilityView
    Kopiert nur die Daten, ohne den abschliessenden Cutover (Umbenennen + View). Fuer mehrstufige
    Migrationen, bei denen der Cutover separat/spaeter ausgeloest werden soll (siehe -CutoverOnly).
.PARAMETER CutoverOnly
    Fuehrt NUR den Cutover aus (Umbenennen + View) - keine Kopie. Voraussetzung: Zeilenzahlen von
    Quelle und Ziel sind bereits identisch (z.B. nach mehreren -SkipCompatibilityView-Laeufen).
.PARAMETER RenamedTableSuffix
    Suffix fuer die umbenannte Original-Tabelle. Standard: '_Original'.
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    Invoke-sqmTableRelocation -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
        -Table "OrderHistory" -TargetDatabaseName "SalesArchive" -BatchSize 20000

.EXAMPLE
    # Ueber mehrere Wartungsfenster verteilt (je max. 60 Minuten), Cutover erst zum Schluss
    Invoke-sqmTableRelocation -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
        -Table "OrderHistory" -TargetDatabaseName "SalesArchive" -MaxDurationMinutes 60

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool). Zieldatenbank muss bereits existieren
    (wird nicht automatisch angelegt). Empfehlung bei sehr grossen Tabellen: waehrend der Kopie
    regelmaessige Transaktionslog-Sicherungen der Quelldatenbank einplanen (jeder Batch ist zwar
    eine eigene kleine Transaktion, das Log waechst bei FULL Recovery aber dennoch kumulativ ueber
    alle Batches, bis es gesichert wird).
#>
function Invoke-sqmTableRelocation
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
		[string]$TargetDatabaseName,

		[Parameter(Mandatory = $false)]
		[string]$TargetSchemaName,

		[Parameter(Mandatory = $false)]
		[string]$KeyColumn,

		[Parameter(Mandatory = $false)]
		[ValidateRange(100, 1000000)]
		[int]$BatchSize = 50000,

		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1440)]
		[int]$MaxDurationMinutes = 0,

		[Parameter(Mandatory = $false)]
		[switch]$SkipCompatibilityView,

		[Parameter(Mandatory = $false)]
		[switch]$CutoverOnly,

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
	if (-not $TargetSchemaName) { $TargetSchemaName = $Schema }

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

	function _FormatKeyLiteral($value, [string]$typeName)
	{
		if ($null -eq $value -or $value -is [System.DBNull]) { return 'NULL' }
		$dateTypes = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
		# 'yyyyMMdd' (Datumsteil ohne Trennzeichen) statt 'yyyy-MM-dd' - DATEFORMAT-unabhaengig,
		# siehe Kommentar in New-sqmPartitionSchemeSet.ps1 (sonst Resume-Punkt falsch bei einer
		# DATETIME-KeyColumn und dmy-Login).
		if ($typeName -in $dateTypes) { return "'$(([datetime]$value).ToString('yyyyMMdd HH:mm:ss.fffffff'))'" }
		if ($typeName -in @('char', 'varchar', 'nchar', 'nvarchar', 'uniqueidentifier')) { return "'$("$value".Replace("'", "''"))'" }
		return "$value"
	}

	try
	{
		if (-not $CutoverOnly)
		{
			# --- Spalten-/Schluesselmetadaten ----------------------------------------------------
			$colDefQuery = @"
SELECT c.name AS ColumnName, ty.name AS TypeName, c.max_length, c.precision, c.scale, c.is_nullable,
    c.is_identity, ic.seed_value, ic.increment_value
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
LEFT JOIN sys.identity_columns ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE c.object_id = OBJECT_ID(N'[$Schema].[$Table]')
ORDER BY c.column_id
"@
			$colDefs = Invoke-DbaQuery @connParams -Database $Database -Query $colDefQuery -ErrorAction Stop -EnableException -As PSObject
			if (-not $colDefs) { throw "Tabelle '$Schema.$Table' nicht gefunden in '$Database'." }
			$hasIdentityCol = [bool]($colDefs | Where-Object { [bool]$_.is_identity })
			$colList = ($colDefs | ForEach-Object { "[$($_.ColumnName)]" }) -join ', '

			if (-not $KeyColumn)
			{
				$ciKeyQuery = @"
SELECT c.name AS ColumnName, COUNT(*) OVER () AS KeyColCount
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'[$Schema].[$Table]') AND i.index_id = 1
ORDER BY ic.key_ordinal
"@
				# @(...) zwingt das Ergebnis in einen echten Array-Kontext - ohne das wuerde
				# $ciKey[0] bei GENAU EINER Ergebniszeile (dann ein einzelnes DataRow-Objekt statt
				# eines Arrays) versehentlich DataRows EIGENEN Spalten-Indexer aufrufen ($ciKey[0]
				# waere dann der WERT der ersten Spalte, also "Id" als String statt des DataRow-
				# Objekts) - .ColumnName darauf liefert dann lautlos $null statt eines Fehlers.
				$ciKeyRows = @(Invoke-DbaQuery @connParams -Database $Database -Query $ciKeyQuery -ErrorAction Stop -EnableException -As PSObject)
				if ($ciKeyRows.Count -eq 1) { $KeyColumn = $ciKeyRows[0].ColumnName }
				else { throw "'-KeyColumn' ist Pflicht: '$Schema.$Table' hat keinen einspaltigen Clustered Index/PK (Heap oder zusammengesetzter Schluessel)." }
			}
			$keyColDef = $colDefs | Where-Object { $_.ColumnName -eq $KeyColumn } | Select-Object -First 1
			if (-not $keyColDef) { throw "Schluesselspalte '$KeyColumn' nicht in '$Schema.$Table' gefunden." }

			$action = "'$Schema.$Table' -> '$TargetDatabaseName.$TargetSchemaName.$Table' verschieben (Batchgroesse $BatchSize)"
			if (-not $PSCmdlet.ShouldProcess($Database, $action)) { return }

			# --- Zieltabelle anlegen (falls nicht vorhanden) + Clustered Index/PK nachbilden -----
			$targetExists = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT 1 FROM [$TargetDatabaseName].sys.tables t JOIN [$TargetDatabaseName].sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = N'$TargetSchemaName' AND t.name = N'$Table'" -ErrorAction Stop -EnableException -As PSObject
			if (-not $targetExists)
			{
				Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query "IF SCHEMA_ID(N'$TargetSchemaName') IS NULL EXEC(N'CREATE SCHEMA [$TargetSchemaName]');" -ErrorAction Stop -EnableException -As PSObject | Out-Null
				Invoke-DbaQuery @connParams -Database $Database -Query "SELECT * INTO [$TargetDatabaseName].[$TargetSchemaName].[$Table] FROM [$Schema].[$Table] WHERE 1 = 0;" -ErrorAction Stop -EnableException -As PSObject | Out-Null
				Invoke-DbaQuery @connParams -Database $Database -Query "CREATE $(if ($ciKeyRows) { 'CLUSTERED' } else { '' }) INDEX [IX_${Table}_${KeyColumn}] ON [$TargetDatabaseName].[$TargetSchemaName].[$Table] ([$KeyColumn]);" -ErrorAction Stop -EnableException -As PSObject | Out-Null
				Invoke-sqmLogging -Message "Zieltabelle '$TargetDatabaseName.$TargetSchemaName.$Table' angelegt." -FunctionName $functionName -Level "INFO"
			}

			# --- Fortsetzpunkt ermitteln (Resume: MAX der Schluesselspalte im Ziel) --------------
			$resumeRow = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT MAX([$KeyColumn]) AS LastKey FROM [$TargetDatabaseName].[$TargetSchemaName].[$Table]" -ErrorAction Stop -EnableException -As PSObject
			# MAX() ueber eine leere Tabelle liefert aus SQL Server NULL, das per Invoke-DbaQuery als
			# [System.DBNull]::Value zurueckkommt - NICHT PowerShells $null. Ein Vergleich mit $null
			# waere hier stillschweigend falsch (DBNull.Value -eq $null ist False) und wuerde weiter
			# unten zu einer leeren, syntaktisch ungueltigen WHERE-Klausel fuehren.
			$lastKeyValue = if (-not $resumeRow -or -not $resumeRow[0]) { $null } elseif ($resumeRow[0].LastKey -is [System.DBNull]) { $null } else { $resumeRow[0].LastKey }
			if ($null -ne $lastKeyValue) { Invoke-sqmLogging -Message "Fortsetzung ab '$KeyColumn' > $lastKeyValue (bereits kopierte Zeilen bleiben unberuehrt)." -FunctionName $functionName -Level "INFO" }

			# --- Batchweise, nicht-destruktive Kopie ----------------------------------------------
			$sw = [System.Diagnostics.Stopwatch]::StartNew()
			$totalCopied = 0
			$timeBudgetHit = $false
			while ($true)
			{
				if ($MaxDurationMinutes -gt 0 -and $sw.Elapsed.TotalMinutes -ge $MaxDurationMinutes)
				{
					$timeBudgetHit = $true
					Invoke-sqmLogging -Message "Zeitbudget ($MaxDurationMinutes Min.) erreicht - $totalCopied Zeile(n) in diesem Lauf kopiert. Erneuter Aufruf setzt automatisch fort." -FunctionName $functionName -Level "WARNING"
					break
				}

				$whereClause = if ($null -eq $lastKeyValue) { '' } else { "WHERE [$KeyColumn] > $(_FormatKeyLiteral $lastKeyValue $keyColDef.TypeName)" }
				$batchSql = @"
DECLARE @KeyTable TABLE ([Key_] SQL_VARIANT);
INSERT INTO [$TargetDatabaseName].[$TargetSchemaName].[$Table] ($colList)
OUTPUT INSERTED.[$KeyColumn] INTO @KeyTable
SELECT TOP ($BatchSize) $colList FROM [$Schema].[$Table] $whereClause ORDER BY [$KeyColumn];
SELECT MAX([Key_]) AS LastKey, COUNT(*) AS Cnt FROM @KeyTable;
"@
				$batchSql = if ($hasIdentityCol)
				{
					"SET IDENTITY_INSERT [$TargetDatabaseName].[$TargetSchemaName].[$Table] ON; $batchSql SET IDENTITY_INSERT [$TargetDatabaseName].[$TargetSchemaName].[$Table] OFF;"
				}
				else { $batchSql }

				$batchResult = Invoke-DbaQuery @connParams -Database $Database -Query $batchSql -ErrorAction Stop -EnableException -As PSObject
				if (-not $batchResult -or -not $batchResult[0]) { throw "Batch-Abfrage gab kein Ergebnis zurueck." }
				$rowsThisBatch = [int64]$(if ($null -ne $batchResult[0].Cnt) { $batchResult[0].Cnt } else { 0 })
				if ($rowsThisBatch -eq 0) { break }

				$lastKeyValue = $batchResult[0].LastKey
				$totalCopied += $rowsThisBatch
				Invoke-sqmLogging -Message "$totalCopied Zeile(n) kopiert (Batch: $rowsThisBatch, letzter Schluessel: $lastKeyValue)." -FunctionName $functionName -Level "INFO"
			}

			if ($timeBudgetHit)
			{
				return [PSCustomObject]@{
					SchemaName = $Schema; TableName = $Table; TargetDatabaseName = $TargetDatabaseName
					RowsCopiedThisRun = $totalCopied; Status = 'PartialTimeBudget'; CutoverDone = $false
				}
			}
			if ($SkipCompatibilityView)
			{
				return [PSCustomObject]@{
					SchemaName = $Schema; TableName = $Table; TargetDatabaseName = $TargetDatabaseName
					RowsCopiedThisRun = $totalCopied; Status = 'CopyComplete'; CutoverDone = $false
				}
			}
		}

		# --- Cutover: Zeilenzahl-Abgleich, dann Umbenennen + View --------------------------------
		$srcCount = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT COUNT(*) AS Cnt FROM [$Schema].[$Table]" -ErrorAction Stop -EnableException -As PSObject)[0].Cnt
		$tgtCount = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT COUNT(*) AS Cnt FROM [$TargetDatabaseName].[$TargetSchemaName].[$Table]" -ErrorAction Stop -EnableException -As PSObject)[0].Cnt
		if ($srcCount -ne $tgtCount)
		{
			throw "Cutover abgebrochen: Zeilenzahlen stimmen nicht ueberein (Quelle $srcCount, Ziel $tgtCount). Kopie ist noch nicht vollstaendig - erneut ohne -CutoverOnly aufrufen."
		}

		$cutoverAction = "Cutover '$Schema.$Table' ($srcCount Zeile(n) verifiziert): umbenennen + View anlegen"
		if (-not $PSCmdlet.ShouldProcess($Database, $cutoverAction)) { return }

		$renamedName = "${Table}${RenamedTableSuffix}"
		Invoke-DbaQuery @connParams -Database $Database -Query "EXEC sp_rename N'[$Schema].[$Table]', N'$renamedName';" -ErrorAction Stop -EnableException -As PSObject | Out-Null
		Invoke-sqmLogging -Message "Original-Tabelle umbenannt: '$Schema.$Table' -> '$Schema.$renamedName' (bleibt vollstaendig erhalten)." -FunctionName $functionName -Level "INFO"

		if (-not $colDefs)
		{
			# CutoverOnly-Pfad: Spaltenliste wurde oben nicht ermittelt, jetzt nachholen (von der
			# gerade umbenannten Original-Tabelle, deren Struktur identisch zur Zieltabelle ist).
			$colDefs = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT name AS ColumnName FROM sys.columns WHERE object_id = OBJECT_ID(N'[$Schema].[$renamedName]') ORDER BY column_id" -ErrorAction Stop -EnableException -As PSObject
			$colList = ($colDefs | ForEach-Object { "[$($_.ColumnName)]" }) -join ', '
		}

		$viewDdl = "CREATE VIEW [$Schema].[$Table] AS SELECT $colList FROM [$TargetDatabaseName].[$TargetSchemaName].[$Table];"
		Invoke-DbaQuery @connParams -Database $Database -Query $viewDdl -ErrorAction Stop -EnableException -As PSObject | Out-Null
		Invoke-sqmLogging -Message "Kompatibilitaets-View '$Schema.$Table' -> '$TargetDatabaseName.$TargetSchemaName.$Table' angelegt." -FunctionName $functionName -Level "INFO"

		return [PSCustomObject]@{
			SchemaName          = $Schema
			TableName           = $Table
			TargetDatabaseName  = $TargetDatabaseName
			RenamedOriginalName = $renamedName
			RowsRelocated       = $srcCount
			Status              = 'Success'
			CutoverDone         = $true
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
