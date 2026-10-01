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
       per SELECT INTO ... WHERE 1=0 aus der Quelle uebernommen), danach einen einspaltigen
       Clustered Index/PK der Quelle nachbilden.
    2. NICHT-destruktive Kopie mit den Kopierroutinen von sqmDataTransfer (die Quelltabelle bleibt
       bis zum Abschluss unveraendert bestehen): mit automatisch erkannter Chunk-Spalte
       (Datum/Periode/yyyyMMdd) per Invoke-sqmChunkedTableTransfer - je Chunk fortsetzbar, ein
       abgebrochener Lauf setzt beim naechsten Aufruf fort. Ohne geeignete Chunk-Spalte die ganze
       Tabelle in einem Copy-sqmTableData-Durchgang (ein unvollstaendiges Ziel wird beim
       naechsten Aufruf geleert und neu kopiert).
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
    Spalte fuer den Clustered Index der neu angelegten Zieltabelle. Ohne Angabe die Spalte eines
    einspaltigen Clustered Index/PK der Quelle, sonst bleibt das Ziel ein Heap. Zum Kopieren
    selbst wird kein Schluessel gebraucht.
.PARAMETER BatchSize
    SqlBulkCopy-Batchgroesse. Ohne Angabe gilt die Standard-Batchgroesse von sqmDataTransfer.
.PARAMETER MaxDurationMinutes
    Veraltet, wird ignoriert (seit 1.15.0.0). Ein abgebrochener Lauf setzt beim naechsten Aufruf
    pro Chunk fort.
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
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), Invoke-sqmChunkedTableTransfer/Copy-sqmTableData/
    Get-sqmChunkColumnCandidate (sqmDataTransfer). Zieldatenbank muss bereits existieren
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
		[int]$BatchSize,

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

			# Einspaltiger Clustered Index/PK der Quelle wird auf der neuen Zieltabelle nachgebildet -
			# zum Kopieren selbst ist kein Schluessel mehr noetig (sqmDataTransfer, siehe unten).
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
				# @(...) erzwingt Array-Kontext (eine einzelne Zeile waere sonst ein DataRow-Objekt)
				$ciKeyRows = @(Invoke-DbaQuery @connParams -Database $Database -Query $ciKeyQuery -ErrorAction Stop -EnableException -As PSObject)
				if ($ciKeyRows.Count -eq 1) { $KeyColumn = $ciKeyRows[0].ColumnName }
			}
			if ($KeyColumn -and -not ($colDefs | Where-Object { $_.ColumnName -eq $KeyColumn })) { throw "Schluesselspalte '$KeyColumn' nicht in '$Schema.$Table' gefunden." }
			if ($MaxDurationMinutes -gt 0) { Write-Warning "-MaxDurationMinutes wird seit sqmPartitionTool 1.15.0.0 nicht mehr unterstuetzt - die Kopie ist pro Chunk fortsetzbar, ein abgebrochener Lauf setzt beim naechsten Aufruf fort." }

			$action = "'$Schema.$Table' -> '$TargetDatabaseName.$TargetSchemaName.$Table' verschieben (sqmDataTransfer)"
			if (-not $PSCmdlet.ShouldProcess($Database, $action)) { return }

			# --- Zieltabelle anlegen (falls nicht vorhanden) + Clustered Index nachbilden ----------
			$targetExists = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT 1 FROM [$TargetDatabaseName].sys.tables t JOIN [$TargetDatabaseName].sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = N'$TargetSchemaName' AND t.name = N'$Table'" -ErrorAction Stop -EnableException -As PSObject
			if (-not $targetExists)
			{
				Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query "IF SCHEMA_ID(N'$TargetSchemaName') IS NULL EXEC(N'CREATE SCHEMA [$TargetSchemaName]');" -ErrorAction Stop -EnableException -As PSObject | Out-Null
				Invoke-DbaQuery @connParams -Database $Database -Query "SELECT * INTO [$TargetDatabaseName].[$TargetSchemaName].[$Table] FROM [$Schema].[$Table] WHERE 1 = 0;" -ErrorAction Stop -EnableException -As PSObject | Out-Null
				if ($KeyColumn)
				{
					Invoke-DbaQuery @connParams -Database $Database -Query "CREATE CLUSTERED INDEX [IX_${Table}_${KeyColumn}] ON [$TargetDatabaseName].[$TargetSchemaName].[$Table] ([$KeyColumn]);" -ErrorAction Stop -EnableException -As PSObject | Out-Null
				}
				Invoke-sqmLogging -Message "Zieltabelle '$TargetDatabaseName.$TargetSchemaName.$Table' angelegt." -FunctionName $functionName -Level "INFO"
			}

			# --- Kopie mit den Kopierroutinen von sqmDataTransfer ----------------------------------
			# Mit geeigneter Chunk-Spalte (Datum/Periode/yyyyMMdd, automatisch erkannt):
			# Invoke-sqmChunkedTableTransfer - je Chunk fortsetzbar, Indizes waehrend der Ladung
			# deaktiviert. Ohne: die ganze Tabelle in einem Copy-sqmTableData-Durchgang (ein
			# abgebrochener Lauf wird beim naechsten Aufruf geleert und neu kopiert).
			$sw = [System.Diagnostics.Stopwatch]::StartNew()
			$tgtBefore = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT COUNT_BIG(*) AS Cnt FROM [$TargetDatabaseName].[$TargetSchemaName].[$Table]" -QueryTimeout 0 -ErrorAction Stop -EnableException -As PSObject)[0].Cnt
			$chunkCandidate = @(Get-sqmChunkColumnCandidate -SqlInstance $SqlInstance -Database $Database -Table "$Schema.$Table" -SqlCredential $SqlCredential) | Select-Object -First 1
			if ($chunkCandidate)
			{
				Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Chunked copy by [$($chunkCandidate.ColumnName)] ($($chunkCandidate.SuggestedGranularity), ~$($chunkCandidate.EstimatedChunks) chunk(s)) ..."
				$transferParams = @{
					Source              = $SqlInstance
					SourceDatabase      = $Database
					Destination         = $SqlInstance
					DestinationDatabase = $TargetDatabaseName
					Table               = "$Schema.$Table"
					DestinationTable    = "$TargetSchemaName.$Table"
					ChunkColumn         = $chunkCandidate.ColumnName
					NoReport            = $true
					NoOpen              = $true
					EnableException     = $true
					Confirm             = $false
				}
				if ($SqlCredential) { $transferParams['SqlCredential'] = $SqlCredential }
				if ($PSBoundParameters.ContainsKey('BatchSize')) { $transferParams['BatchSize'] = $BatchSize }
				$transferResults = @(Invoke-sqmChunkedTableTransfer @transferParams)
				$failed = @($transferResults | Where-Object { $_.Status -in @('Failed', 'Mismatch', 'NotFound') })
				if ($failed.Count -gt 0) { throw "Kopie unvollstaendig - $($failed.Count) Chunk-Schritt(e) fehlgeschlagen: $(($failed | Select-Object -First 3 | ForEach-Object { "$($_.Chunk) $($_.Step): $($_.Message)" }) -join '; ')" }
			}
			else
			{
				$srcNow = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT COUNT_BIG(*) AS Cnt FROM [$Schema].[$Table]" -QueryTimeout 0 -ErrorAction Stop -EnableException -As PSObject)[0].Cnt
				if ($tgtBefore -ne $srcNow)
				{
					Write-Host "[$(Get-Date -Format 'HH:mm:ss')] No chunk column - copying the whole table in one pass ($srcNow row(s)) ..."
					$copyParams = @{
						Source              = $SqlInstance
						SourceDatabase      = $Database
						Destination         = $SqlInstance
						DestinationDatabase = $TargetDatabaseName
						Table               = "$Schema.$Table"
						DestinationTable    = "$TargetSchemaName.$Table"
						SourceQuery         = "SELECT * FROM [$Schema].[$Table]"
						Truncate            = ($tgtBefore -gt 0)
						KeepIdentity        = $true
						KeepNulls           = $true
						EnableException     = $true
						Confirm             = $false
					}
					if ($SqlCredential) { $copyParams['SourceCredential'] = $SqlCredential; $copyParams['DestinationCredential'] = $SqlCredential }
					if ($PSBoundParameters.ContainsKey('BatchSize')) { $copyParams['BatchSize'] = $BatchSize }
					$copyResult = @(Copy-sqmTableData @copyParams) | Select-Object -First 1
					if (-not $copyResult -or $copyResult.Status -ne 'Success') { throw "Kopie fehlgeschlagen: $(if ($copyResult) { $copyResult.Message } else { 'kein Ergebnis von Copy-sqmTableData' })" }
				}
			}
			$tgtAfter = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT COUNT_BIG(*) AS Cnt FROM [$TargetDatabaseName].[$TargetSchemaName].[$Table]" -QueryTimeout 0 -ErrorAction Stop -EnableException -As PSObject)[0].Cnt
			$totalCopied = [Math]::Max([int64]0, $tgtAfter - $tgtBefore)
			Invoke-sqmLogging -Message "Kopie abgeschlossen: Ziel enthaelt $tgtAfter Zeile(n) ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) s)." -FunctionName $functionName -Level "INFO"
			Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Copy done: target has $tgtAfter row(s) ($([math]::Round($sw.Elapsed.TotalSeconds, 1)) s)."

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
