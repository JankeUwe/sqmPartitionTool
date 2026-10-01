<#
.SYNOPSIS
    Kopiert eine bereits partitionierte Tabelle als NEU partitionierte Tabelle in eine andere Datenbank.

.DESCRIPTION
    Fuer den Fall, dass eine bereits partitionierte Tabelle unveraendert aktiv bleiben soll, aber
    zusaetzlich (mit einer ANDEREN Partitionierung - z.B. groeberer Granularitaet, abweichender
    Filegroup-Strategie oder sogar einer anderen Partitionsspalte) in eine separate Datenbank
    kopiert werden muss - im Unterschied zu:
    - Invoke-sqmTablePartitionConversion: partitioniert eine noch NICHT partitionierte Tabelle
      IN-PLACE in derselben Datenbank.
    - Invoke-sqmTableArchiveMigration: migriert eine noch NICHT partitionierte Tabelle monatsweise
      in eine partitionierte Kopie in einer Archiv-Datenbank, MIT abschliessendem Cutover (Quelle
      wird umbenannt und durch eine View ersetzt).
    - Invoke-sqmTableRelocation: verschiebt eine BELIEBIGE (nicht notwendigerweise partitionierte)
      Tabelle komplett in eine andere Datenbank, ebenfalls MIT Cutover, aber OHNE die Zieltabelle
      zu partitionieren.

    Diese Funktion setzt eine BEREITS partitionierte Quelltabelle voraus, legt eine STRUKTURELL
    IDENTISCHE, aber NEU partitionierte Kopie in der Zieldatenbank an und kopiert alle Zeilen dorthin
    - die Quelltabelle bleibt dabei vollstaendig unveraendert und aktiv (kein Rename, keine View,
    kein Cutover). Gedacht fuer den Fall, dass Quelle und Kopie parallel mit unterschiedlichem
    Partitionierungsschema weiterexistieren sollen (z.B. ein Reporting-/Analyse-Abzug mit groeberer
    Granularitaet, oder eine testweise Neupartitionierung, bevor die Produktionstabelle umgestellt
    wird).

    Ablauf:
    1. Prueft, dass die Quelltabelle TATSAECHLICH bereits partitioniert ist (sonst Hinweis auf
       Invoke-sqmTablePartitionConversion/Invoke-sqmTableArchiveMigration) und dass die
       Zieldatenbank existiert (wird nicht automatisch angelegt - Admin-Aufgabe, gleiche Konvention
       wie Invoke-sqmTableRelocation/Invoke-sqmTableArchiveMigration).
    2. Leitet die Partitionsspalte automatisch aus dem bestehenden Partition Scheme der Quelle ab
       (sofern nicht per -PartitionColumn ausdruecklich eine andere Spalte gewaehlt wird).
    3. Existiert die Zieltabelle noch nicht: Min/Max der Quelldaten ermitteln
       (Get-sqmPartitionColumnRange), Boundary-Liste fuer die NEUE Granularitaet berechnen
       (Get-sqmPartitionBoundaryList), Filegroups + Partition Function/Scheme in der Zieldatenbank
       anlegen (New-sqmPartitionFilegroupPlan/New-sqmPartitionSchemeSet) und die Zieltabelle
       strukturell identisch zur Quelle anlegen (Get-sqmTableDefinitionSql), aber auf dem neuen
       Scheme statt der alten Filegroup(s).
    4. Batchweise, resumable Kopie ALLER Zeilen (gleiches Muster wie Invoke-sqmTableRelocation:
       Keyset-Pagination ueber -KeyColumn (eine Spalte oder ein Tupel aus bis zu 5 Spalten), jeder
       Batch eine eigene kleine Transaktion, Fortsetzpunkt = letztes Schluesseltupel in der
       Zieltabelle - ein abgebrochener Lauf oder -MaxDurationMinutes kann
       jederzeit per erneutem Aufruf fortgesetzt werden, dabei wird Schritt 3 uebersprungen, wenn die
       Zieltabelle bereits existiert).
    5. Nach vollstaendiger Kopie: Zeilenzahl-Abgleich Quelle/Ziel, optionale Kompression
       (nur beim allerersten Aufruf, analog Invoke-sqmTablePartitionConversion), Registrierung der
       NEUEN Tabelle in sqm_PartitionRegistry (Register-sqmPartitionTable), ausser -NoRegister.

    Die Quelltabelle wird von dieser Funktion NIE veraendert, umbenannt oder geloescht.

.PARAMETER SqlInstance
    Ziel-Instanz (Quelle UND Ziel muessen auf derselben Instanz liegen).
.PARAMETER Database
    Quelldatenbank.
.PARAMETER Schema
    Schema der Quelltabelle.
.PARAMETER Table
    Name der Quelltabelle (muss bereits partitioniert sein).
.PARAMETER TargetDatabaseName
    Zieldatenbank (muss auf derselben Instanz bereits existieren - wird nicht automatisch angelegt).
.PARAMETER TargetSchemaName
    Zielschema. Standard: gleiches Schema wie die Quelltabelle. Wird in der Zieldatenbank angelegt,
    falls es dort noch nicht existiert.
.PARAMETER TargetTableName
    Name der neuen Tabelle. Standard: gleicher Name wie die Quelltabelle.
.PARAMETER PartitionColumn
    Partitionsspalte fuer die NEUE Partitionierung. Ohne Angabe wird automatisch die Spalte
    verwendet, nach der die Quelltabelle BEREITS partitioniert ist - eine abweichende Spalte ist
    moeglich, muss dann aber fuer Partition Functions geeignet sein (siehe
    Get-sqmPartitionColumnCandidate).
.PARAMETER Granularity
    Month, Quarter oder Year - die NEUE Granularitaet fuer die Zielkopie (unabhaengig von der
    Granularitaet der Quellpartitionierung).
.PARAMETER BoundaryType
    Date, Int oder Text - siehe Invoke-sqmTablePartitionConversion. Ohne Angabe automatisch aus dem
    Spaltentyp von -PartitionColumn abgeleitet.
.PARAMETER SurrogateDateFormat
    Nur relevant bei BoundaryType Int oder Text: 'yyyyMMdd' (Standard) oder 'yyyyMM'.
.PARAMETER FilegroupStrategy
    Single (Standard) oder PerPeriod - fuer die NEUE Partitionierung in der Zieldatenbank.
.PARAMETER FutureBufferPeriods
    Anzahl vorausschauend leer angelegter Perioden. Standard: 3.
.PARAMETER DataCompression
    None (Standard), Row oder Page. Wird nur beim allerersten Aufruf (Anlage der Zielkopie)
    angewendet, analog Invoke-sqmTablePartitionConversion.
.PARAMETER KeyColumn
    Eine oder mehrere (max. 5) Spalten fuer die Batch-Reihenfolge/den Fortsetzpunkt, die ZUSAMMEN
    jede Zeile eindeutig identifizieren (z.B. -KeyColumn 'VMTG', 'VID1', 'VID2', 'VSEQ', 'VPOS'),
    NICHT notwendigerweise identisch mit -PartitionColumn. Keine der Spalten darf NULL enthalten.
    Ohne Angabe automatisch: eindeutiger Clustered Index, PK oder Unique Index mit 1-5 NOT-NULL-
    Spalten (Clustered bevorzugt), sonst ein einspaltiger Clustered Index. Bei einem Heap ohne
    solchen Index ist die explizite Angabe Pflicht.
    Bei mehreren Spalten wird ueber das Tupel (K1, K2, ...) geblaettert - ein passender Index auf
    genau diesen Spalten (in dieser Reihenfolge) haelt jeden Batch billig.
.PARAMETER BatchSize
    Zeilen pro Batch/Transaktion. Standard: 50000.
.PARAMETER MaxDurationMinutes
    Bricht nach dieser Laufzeit sauber zwischen zwei Batches ab (0 = kein Limit, Standard) - fuer
    die gezielte Aufteilung sehr grosser Tabellen auf mehrere Wartungsfenster. Ein erneuter Aufruf
    setzt automatisch beim letzten kopierten Schluesselwert fort.
.PARAMETER NoRegister
    Neue Tabelle NICHT in sqm_PartitionRegistry eintragen (z.B. fuer einen einmaligen Testabzug
    ohne automatische Wartungs-Jobs).
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    Copy-sqmPartitionedTable -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" `
        -TargetDatabaseName "SalesReporting" -Granularity Year

.EXAMPLE
    # Ueber mehrere Wartungsfenster verteilt (je max. 90 Minuten)
    Copy-sqmPartitionedTable -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" `
        -TargetDatabaseName "SalesReporting" -Granularity Quarter -MaxDurationMinutes 90

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), Get-sqmPartitionColumnRange,
    Get-sqmPartitionBoundaryList, New-sqmPartitionFilegroupPlan, New-sqmPartitionSchemeSet,
    Get-sqmTableDefinitionSql (privat), Register-sqmPartitionTable. Zieldatenbank muss bereits
    existieren (wird nicht automatisch angelegt). Erneuter Aufruf ist jederzeit sicher (resumable) -
    existiert die Zieltabelle bereits, wird Schritt 3 uebersprungen und nur die Kopie fortgesetzt.
#>
function Copy-sqmPartitionedTable
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
		[string]$TargetTableName,

		[Parameter(Mandatory = $false)]
		[string]$PartitionColumn,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Month', 'Quarter', 'Year')]
		[string]$Granularity,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Date', 'Int', 'Text')]
		[string]$BoundaryType,

		[Parameter(Mandatory = $false)]
		[ValidateSet('yyyyMMdd', 'yyyyMM')]
		[string]$SurrogateDateFormat = 'yyyyMMdd',

		[Parameter(Mandatory = $false)]
		[ValidateSet('Single', 'PerPeriod')]
		[string]$FilegroupStrategy = 'Single',

		[Parameter(Mandatory = $false)]
		[int]$FutureBufferPeriods = 3,

		[Parameter(Mandatory = $false)]
		[ValidateSet('None', 'Row', 'Page')]
		[string]$DataCompression = 'None',

		[Parameter(Mandatory = $false)]
		[ValidateCount(1, 5)]
		[string[]]$KeyColumn,

		[Parameter(Mandatory = $false)]
		[ValidateRange(100, 1000000)]
		[int]$BatchSize = 50000,

		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 1440)]
		[int]$MaxDurationMinutes = 0,

		[Parameter(Mandatory = $false)]
		[switch]$NoRegister,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
	if (-not $TargetSchemaName) { $TargetSchemaName = $Schema }
	if (-not $TargetTableName) { $TargetTableName = $Table }

	function _FormatColumnType($col)
	{
		switch ($col.TypeName)
		{
			'datetime2' { return "datetime2($($col.scale))" }
			'decimal'   { return "decimal($($col.precision),$($col.scale))" }
			'numeric'   { return "numeric($($col.precision),$($col.scale))" }
			'char'      { return "char($($col.max_length))" }
			'varchar'   { return $(if ([int]$col.max_length -eq -1) { 'varchar(max)' } else { "varchar($($col.max_length))" }) }
			'nchar'     { return "nchar($([int]$col.max_length / 2))" }
			'nvarchar'  { return $(if ([int]$col.max_length -eq -1) { 'nvarchar(max)' } else { "nvarchar($([int]$col.max_length / 2))" }) }
			default     { return $col.TypeName }
		}
	}

	function _FormatKeyLiteral($value, [string]$typeName)
	{
		if ($null -eq $value -or $value -is [System.DBNull]) { return 'NULL' }
		$inv = [System.Globalization.CultureInfo]::InvariantCulture
		# 'yyyyMMdd' statt 'yyyy-MM-dd' - DATEFORMAT-unabhaengig, siehe Kommentar in
		# New-sqmPartitionSchemeSet.ps1 (sonst Resume-Punkt falsch bei einer DATETIME-KeyColumn
		# und dmy-Login). Gebrochene Sekunden passend zum Typ: ein 7-stelliges Literal laesst sich
		# nicht in datetime konvertieren (Fehler 241), und ein auf datetime2 erweiterter
		# datetime-Wert (.0033333) waere groesser als das Literal (.003) -> letzte Zeile doppelt.
		switch ($typeName)
		{
			'date'           { return "'$(([datetime]$value).ToString('yyyyMMdd', $inv))'" }
			'smalldatetime'  { return "'$(([datetime]$value).ToString('yyyyMMdd HH:mm:ss', $inv))'" }
			'datetime'       { return "CAST('$(([datetime]$value).ToString('yyyyMMdd HH:mm:ss.fff', $inv))' AS DATETIME)" }
			'datetime2'      { return "'$(([datetime]$value).ToString('yyyyMMdd HH:mm:ss.fffffff', $inv))'" }
			'datetimeoffset' { return "'$(([datetimeoffset]$value).ToString('yyyy-MM-ddTHH:mm:ss.fffffffzzz', $inv))'" }
			'time'           { return "'$(([timespan]$value).ToString('hh\:mm\:ss\.fffffff', $inv))'" }
			'bit'            { return $(if ([bool]$value) { '1' } else { '0' }) }
			{ $_ -in @('binary', 'varbinary') } { return '0x' + (-join (([byte[]]$value) | ForEach-Object { $_.ToString('X2') })) }
			{ $_ -in @('char', 'varchar', 'uniqueidentifier') } { return "'$("$value".Replace("'", "''"))'" }
			{ $_ -in @('nchar', 'nvarchar') } { return "N'$("$value".Replace("'", "''"))'" }
			{ $_ -in @('float', 'real') } { return ([double]$value).ToString('R', $inv) }
			default          { return ([System.IFormattable]$value).ToString($null, $inv) }
		}
	}

	# Tupel-Vergleich (K1, K2, ...) > (v1, v2, ...) als verschachtelter Ausdruck - eine reine
	# UND-Verknuepfung von Einzelspalten-">" wuerde Zeilen ueberspringen (siehe sqm_ArchiveMonthBatch).
	# Das aeussere "[K1] >= v1" gibt dem Optimizer einen Seek-Praedikat auf die fuehrende Spalte.
	function _KeysetPredicate([object[]]$keyDefs, [object[]]$values)
	{
		$lits = @(for ($i = 0; $i -lt $keyDefs.Count; $i++) { _FormatKeyLiteral $values[$i] $keyDefs[$i].TypeName })
		$expr = "[$($keyDefs[-1].ColumnName)] > $($lits[-1])"
		for ($i = $keyDefs.Count - 2; $i -ge 0; $i--)
		{
			$expr = "[$($keyDefs[$i].ColumnName)] > $($lits[$i]) OR ([$($keyDefs[$i].ColumnName)] = $($lits[$i]) AND ($expr))"
		}
		if ($keyDefs.Count -eq 1) { return $expr }
		return "[$($keyDefs[0].ColumnName)] >= $($lits[0]) AND ($expr)"
	}

	try
	{
		# =========================================================================================
		# 0. Zieldatenbank muss existieren, Quelle/Ziel duerfen nicht identisch sein
		# =========================================================================================
		$dbExists = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT 1 FROM sys.databases WHERE name = N'$TargetDatabaseName';" -ErrorAction Stop -EnableException -As PSObject
		if (-not $dbExists) { throw "Zieldatenbank '$TargetDatabaseName' existiert nicht auf '$SqlInstance' - muss vom Admin vorher angelegt werden." }

		if ($Database -eq $TargetDatabaseName -and $Schema -eq $TargetSchemaName -and $Table -eq $TargetTableName)
		{
			throw "Quelle und Ziel sind identisch ('$Database.$Schema.$Table') - Zieldatenbank, -schema oder -tabellenname muessen sich unterscheiden."
		}

		# =========================================================================================
		# 1. Quelle muss bereits partitioniert sein - Partitionsspalte automatisch ableiten
		# =========================================================================================
		$srcPartQuery = @"
SELECT ps.name AS PartitionSchemeName, c.name AS PartitionColumn
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.partition_ordinal = 1
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE s.name = N'$Schema' AND t.name = N'$Table' AND i.index_id IN (0, 1);
"@
		$srcPart = Invoke-DbaQuery @connParams -Database $Database -Query $srcPartQuery -ErrorAction Stop -EnableException -As PSObject
		if (-not $srcPart)
		{
			throw "'$Schema.$Table' ist nicht partitioniert - diese Funktion setzt eine bereits partitionierte Quelltabelle voraus. Fuer eine noch nicht partitionierte Tabelle: Invoke-sqmTablePartitionConversion (gleiche Datenbank) oder Invoke-sqmTableArchiveMigration (andere Datenbank, mit Cutover)."
		}
		if (-not $PartitionColumn)
		{
			$PartitionColumn = $srcPart.PartitionColumn
			Invoke-sqmLogging -Message "-PartitionColumn nicht angegeben - aus dem bestehenden Partition Scheme '$($srcPart.PartitionSchemeName)' der Quelle uebernommen: '$PartitionColumn'." -FunctionName $functionName -Level "INFO"
		}

		# =========================================================================================
		# 2. Spaltentyp + BoundaryType der (neuen) Partitionsspalte ermitteln
		# =========================================================================================
		$typeQuery = @"
SELECT ty.name AS TypeName, c.precision, c.scale, c.max_length
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'$Schema' AND t.name = N'$Table' AND c.name = N'$PartitionColumn'
"@
		$colType = Invoke-DbaQuery @connParams -Database $Database -Query $typeQuery -ErrorAction Stop -EnableException -As PSObject
		if (-not $colType) { throw "Spalte '$PartitionColumn' nicht gefunden in '$Schema.$Table'." }

		$typeName = [string]$colType.TypeName
		$sqlDataType = _FormatColumnType $colType

		$dateTypes = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
		$textTypes = @('char', 'varchar', 'nchar', 'nvarchar')
		if (-not $BoundaryType)
		{
			$BoundaryType = if ($typeName -in $dateTypes) { 'Date' } elseif ($typeName -in $textTypes) { 'Text' } else { 'Int' }
			Invoke-sqmLogging -Message "BoundaryType nicht angegeben - aus Spaltentyp '$typeName' abgeleitet: $BoundaryType (SurrogateDateFormat: $SurrogateDateFormat)." -FunctionName $functionName -Level "INFO"
		}

		# =========================================================================================
		# 2b. Schluesselspalte(n) fuer die Batch-Kopie - VOR dem Anlegen der Zieltabelle pruefen,
		#     damit ein ungueltiger Schluessel keine leere Zieltabelle hinterlaesst
		# =========================================================================================
		$colDefQuery = @"
SELECT c.name AS ColumnName, ty.name AS TypeName, c.max_length, c.precision, c.scale, c.is_nullable, c.is_identity
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID(N'[$Schema].[$Table]')
ORDER BY c.column_id
"@
		$colDefs = Invoke-DbaQuery @connParams -Database $Database -Query $colDefQuery -ErrorAction Stop -EnableException -As PSObject
		$hasIdentityCol = [bool]($colDefs | Where-Object { [bool]$_.is_identity })
		$colList = ($colDefs | ForEach-Object { "[$($_.ColumnName)]" }) -join ', '

		if (-not $KeyColumn)
		{
			$autoKey = Get-sqmCopyKeyColumn -ConnParams $connParams -Database $Database -Schema $Schema -Table $Table
			if ($autoKey.Columns.Count -eq 0)
			{
				throw "'-KeyColumn' ist Pflicht: '$Schema.$Table' hat weder einen eindeutigen Index/PK mit 1-5 NOT-NULL-Spalten noch einen einspaltigen Clustered Index. Bitte die Spalte(n) angeben, die zusammen jede Zeile eindeutig identifizieren (max. 5)."
			}
			$KeyColumn = $autoKey.Columns
			Invoke-sqmLogging -Message "-KeyColumn aus Index '$($autoKey.IndexName)' abgeleitet: $($KeyColumn -join ', ')." -FunctionName $functionName -Level "INFO"
			if (-not $autoKey.IsUnique)
			{
				Invoke-sqmLogging -Message "Clustered Index '$($autoKey.IndexName)' ist NICHT eindeutig - bei doppelten Schluesselwerten an einer Batch-Grenze werden Zeilen uebersprungen (der Zeilenzahl-Abgleich am Ende meldet das). Fuer Sicherheit -KeyColumn mit eindeutigen Spalten angeben." -FunctionName $functionName -Level "WARNING"
			}
		}

		$keyColDefs = @(foreach ($k in $KeyColumn)
			{
				$def = $colDefs | Where-Object { $_.ColumnName -eq $k } | Select-Object -First 1
				if (-not $def) { throw "Schluesselspalte '$k' nicht in '$Schema.$Table' gefunden." }
				$def
			})
		if (@($KeyColumn | Select-Object -Unique).Count -ne $KeyColumn.Count) { throw "'-KeyColumn' enthaelt eine Spalte mehrfach: $($KeyColumn -join ', ')." }
		$keyList = ($KeyColumn | ForEach-Object { "[$_]" }) -join ', '
		$keyListDesc = ($KeyColumn | ForEach-Object { "[$_] DESC" }) -join ', '
		Invoke-sqmLogging -Message "Schluessel fuer die Batch-Kopie: $($KeyColumn -join ', ')$(if ($KeyColumn.Count -gt 1) { " (zusammengesetzt, $($KeyColumn.Count) Spalten)" })." -FunctionName $functionName -Level "INFO"

		# Ein NULL in einer Schluesselspalte faellt durch jeden ">"-Vergleich - die Zeile wuerde nie
		# kopiert. Nur NULL-faehige Spalten pruefen (bei NOT NULL kostet das nichts); fuer diese
		# Spalten kann die Pruefung die Tabelle scannen, wenn kein Index sie abdeckt.
		$nullableKeys = @($keyColDefs | Where-Object { [bool]$_.is_nullable } | ForEach-Object { $_.ColumnName })
		if ($nullableKeys.Count -gt 0)
		{
			Invoke-sqmLogging -Message "Schluesselspalte(n) $($nullableKeys -join ', ') erlauben NULL - pruefe auf vorhandene NULL-Werte (ohne passenden Index ein Scan der Quelltabelle)." -FunctionName $functionName -Level "WARNING"
			$nullCheck = "SELECT TOP (1) 1 AS HasNull FROM [$Schema].[$Table] WHERE " + (($nullableKeys | ForEach-Object { "[$_] IS NULL" }) -join ' OR ') + ';'
			if (Invoke-DbaQuery @connParams -Database $Database -Query $nullCheck -ErrorAction Stop -EnableException -As PSObject)
			{
				throw "Schluesselspalte(n) $($nullableKeys -join ', ') enthalten NULL-Werte - diese Zeilen koennten nicht kopiert werden. Bitte -KeyColumn mit Spalten ohne NULL-Werte angeben."
			}
		}

		# =========================================================================================
		# 3. Zieltabelle existiert schon (Resume eines fruehreren Laufs)?
		# =========================================================================================
		$targetExists = Invoke-DbaQuery @connParams -Database $Database -Query "SELECT 1 FROM [$TargetDatabaseName].sys.tables t JOIN [$TargetDatabaseName].sys.schemas s ON s.schema_id = t.schema_id WHERE s.name = N'$TargetSchemaName' AND t.name = N'$TargetTableName';" -ErrorAction Stop -EnableException -As PSObject

		$action = if ($targetExists)
		{
			"Kopie von '$Schema.$Table' nach '$TargetDatabaseName.$TargetSchemaName.$TargetTableName' fortsetzen (Zieltabelle existiert bereits)"
		}
		else
		{
			"'$Schema.$Table' (bereits partitioniert) als NEUE Tabelle nach '$TargetDatabaseName.$TargetSchemaName.$TargetTableName' kopieren, neu partitioniert nach $Granularity auf '$PartitionColumn'"
		}
		if (-not $PSCmdlet.ShouldProcess($Database, $action)) { return }

		# =========================================================================================
		# 4. Zieltabelle inkl. neuem Partition Scheme anlegen (nur beim allerersten Aufruf)
		# =========================================================================================
		$schemeInfo = $null
		if (-not $targetExists)
		{
			$rangeParams = @{ SqlInstance = $SqlInstance; Database = $Database; Schema = $Schema; Table = $Table; Column = $PartitionColumn }
			if ($SqlCredential) { $rangeParams['SqlCredential'] = $SqlCredential }
			$range = Get-sqmPartitionColumnRange @rangeParams
			if ($range.IsEmpty) { throw "'$Schema.$Table' ist leer - keine Kopie moeglich (keine Werte in '$PartitionColumn')." }

			$boundaries = Get-sqmPartitionBoundaryList -MinValue $range.MinValue -MaxValue $range.MaxValue -Granularity $Granularity -BoundaryType $BoundaryType -SurrogateDateFormat $SurrogateDateFormat -FutureBufferPeriods $FutureBufferPeriods
			Invoke-sqmLogging -Message "$($boundaries.Count) Boundary(s) berechnet -> $($boundaries.Count + 1) Partition(en) in '$TargetDatabaseName'." -FunctionName $functionName -Level "INFO"

			$fgParams = @{ SqlInstance = $SqlInstance; Database = $TargetDatabaseName; TableName = $TargetTableName; BoundaryList = $boundaries; FilegroupStrategy = $FilegroupStrategy }
			if ($SqlCredential) { $fgParams['SqlCredential'] = $SqlCredential }
			$fgPlan = New-sqmPartitionFilegroupPlan @fgParams -Confirm:$false

			$schemeParams = @{
				SqlInstance     = $SqlInstance
				Database        = $TargetDatabaseName
				TableName       = $TargetTableName
				PartitionColumn = $PartitionColumn
				SqlDataType     = $sqlDataType
				BoundaryList    = $boundaries
				FilegroupNames  = $fgPlan.FilegroupNames
			}
			if ($SqlCredential) { $schemeParams['SqlCredential'] = $SqlCredential }
			$schemeInfo = New-sqmPartitionSchemeSet @schemeParams -Confirm:$false

			Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query "IF SCHEMA_ID(N'$TargetSchemaName') IS NULL EXEC(N'CREATE SCHEMA [$TargetSchemaName]');" -ErrorAction Stop -EnableException -As PSObject | Out-Null

			$defParams = @{
				SqlInstance         = $SqlInstance
				Database            = $Database
				Schema              = $Schema
				Table               = $Table
				TargetTable         = $TargetTableName
				TargetSchema        = $TargetSchemaName
				PartitionSchemeName = $schemeInfo.PartitionSchemeName
				PartitionColumn     = $PartitionColumn
			}
			if ($SqlCredential) { $defParams['SqlCredential'] = $SqlCredential }
			$tableDef = Get-sqmTableDefinitionSql @defParams -EnableException

			Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query $tableDef.CreateTableSql -ErrorAction Stop -EnableException
			foreach ($idxDdl in $tableDef.IndexSql) { Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query $idxDdl -ErrorAction Stop -EnableException }
			Invoke-sqmLogging -Message "Neue partitionierte Tabelle '$TargetDatabaseName.$TargetSchemaName.$TargetTableName' angelegt (Struktur von '$Schema.$Table' uebernommen)." -FunctionName $functionName -Level "INFO"

			if ($DataCompression -ne 'None')
			{
				Invoke-sqmLogging -Message "$DataCompression-Kompression wird auf '$TargetDatabaseName.$TargetSchemaName.$TargetTableName' angewendet - alle Partitionen werden gebuendelt (kann bei grossen Tabellen mehrere Stunden dauern)." -FunctionName $functionName -Level "WARNING"
				try
				{
					$compressionSql = "ALTER TABLE [$TargetSchemaName].[$TargetTableName] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = $($DataCompression.ToUpper()));"
					Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query $compressionSql -ErrorAction Stop -EnableException -As PSObject | Out-Null
					Invoke-sqmLogging -Message "$DataCompression-Kompression auf '$TargetDatabaseName.$TargetSchemaName.$TargetTableName' abgeschlossen." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					Invoke-sqmLogging -Message "Fehler bei Kompressionsanwendung (Kopie wird fortgesetzt): $($_.Exception.Message). Kompression kann spaeter manuell mit ALTER TABLE ... REBUILD PARTITION angewendet werden." -FunctionName $functionName -Level "WARNING"
				}
			}
		}
		else
		{
			Invoke-sqmLogging -Message "Zieltabelle '$TargetDatabaseName.$TargetSchemaName.$TargetTableName' existiert bereits - setze die Kopie fort (Schritt 4 uebersprungen)." -FunctionName $functionName -Level "INFO"
		}

		# =========================================================================================
		# 5. Batchweise, resumable Kopie ALLER Zeilen (Muster wie Invoke-sqmTableRelocation)
		# =========================================================================================
		# Fortsetzpunkt = Tupel der in Schluesselreihenfolge LETZTEN Zeile im Ziel - eine echte Zeile,
		# kein spaltenweises MAX() (das ergaebe bei mehreren Spalten ein nie existierendes Tupel).
		$resumeRow = @(Invoke-DbaQuery @connParams -Database $Database -Query "SELECT TOP (1) $keyList FROM [$TargetDatabaseName].[$TargetSchemaName].[$TargetTableName] ORDER BY $keyListDesc;" -ErrorAction Stop -EnableException -As PSObject)
		$lastKeyValues = if ($resumeRow.Count -gt 0) { @(foreach ($k in $KeyColumn) { $resumeRow[0].$k }) } else { $null }
		if ($null -ne $lastKeyValues) { Invoke-sqmLogging -Message "Fortsetzung ab ($($KeyColumn -join ', ')) > ($($lastKeyValues -join ', ')) (bereits kopierte Zeilen bleiben unberuehrt)." -FunctionName $functionName -Level "INFO" }

		$keyVarCols = (1..$KeyColumn.Count | ForEach-Object { "[K$_] SQL_VARIANT" }) -join ', '
		$keyOutCols = (1..$KeyColumn.Count | ForEach-Object { "INSERTED.[$($KeyColumn[$_ - 1])]" }) -join ', '
		$keyVarList = (1..$KeyColumn.Count | ForEach-Object { "[K$_]" }) -join ', '
		$keyVarDesc = (1..$KeyColumn.Count | ForEach-Object { "[K$_] DESC" }) -join ', '

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

			$whereClause = if ($null -eq $lastKeyValues) { '' } else { "WHERE $(_KeysetPredicate $keyColDefs $lastKeyValues)" }
			# Neuer Fortsetzpunkt = in Schluesselreihenfolge groesstes Tupel des Batches; da der Batch
			# genau die TOP-n-Tupel ab dem alten Fortsetzpunkt enthaelt, ist das die letzte echte Zeile.
			$batchSql = @"
DECLARE @KeyTable TABLE ($keyVarCols);
INSERT INTO [$TargetDatabaseName].[$TargetSchemaName].[$TargetTableName] ($colList)
OUTPUT $keyOutCols INTO @KeyTable
SELECT TOP ($BatchSize) $colList FROM [$Schema].[$Table] $whereClause ORDER BY $keyList;
SELECT n.Cnt, k.* FROM (SELECT COUNT(*) AS Cnt FROM @KeyTable) n
OUTER APPLY (SELECT TOP (1) $keyVarList FROM @KeyTable ORDER BY $keyVarDesc) k;
"@
			$batchSql = if ($hasIdentityCol)
			{
				"SET IDENTITY_INSERT [$TargetDatabaseName].[$TargetSchemaName].[$TargetTableName] ON; $batchSql SET IDENTITY_INSERT [$TargetDatabaseName].[$TargetSchemaName].[$TargetTableName] OFF;"
			}
			else { $batchSql }

			$batchResult = Invoke-DbaQuery @connParams -Database $Database -Query $batchSql -ErrorAction Stop -EnableException -As PSObject
			if (-not $batchResult -or -not $batchResult[0]) { throw "Batch-Abfrage gab kein Ergebnis zurueck." }
			$rowsThisBatch = [int64]$(if ($null -ne $batchResult[0].Cnt) { $batchResult[0].Cnt } else { 0 })
			if ($rowsThisBatch -eq 0) { break }

			$lastKeyValues = @(1..$KeyColumn.Count | ForEach-Object { $batchResult[0]."K$_" })
			$totalCopied += $rowsThisBatch
			Invoke-sqmLogging -Message "$totalCopied Zeile(n) kopiert (Batch: $rowsThisBatch, letzter Schluessel: $($lastKeyValues -join ', '))." -FunctionName $functionName -Level "INFO"
		}

		if ($timeBudgetHit)
		{
			return [PSCustomObject]@{
				SourceSchemaName = $Schema; SourceTableName = $Table
				TargetDatabaseName = $TargetDatabaseName; TargetSchemaName = $TargetSchemaName; TargetTableName = $TargetTableName
				RowsCopiedThisRun = $totalCopied; Status = 'PartialTimeBudget'; Registered = $false
			}
		}

		# =========================================================================================
		# 6. Zeilenzahl-Abgleich
		# =========================================================================================
		$srcCount = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT COUNT(*) AS Cnt FROM [$Schema].[$Table];" -ErrorAction Stop -EnableException -As PSObject)[0].Cnt
		$tgtCount = [int64](Invoke-DbaQuery @connParams -Database $Database -Query "SELECT COUNT(*) AS Cnt FROM [$TargetDatabaseName].[$TargetSchemaName].[$TargetTableName];" -ErrorAction Stop -EnableException -As PSObject)[0].Cnt
		if ($srcCount -ne $tgtCount)
		{
			throw "Zeilenzahlen stimmen nach der Kopie nicht ueberein (Quelle $srcCount, Ziel $tgtCount) - vermutlich wurden waehrend der Kopie Zeilen in der (weiterhin aktiven) Quelle eingefuegt. Erneuter Aufruf kopiert die Differenz nach."
		}

		# =========================================================================================
		# 7. Registrieren
		# =========================================================================================
		$registered = $false
		if (-not $NoRegister)
		{
			if (-not $schemeInfo)
			{
				# Resume-Aufruf ohne Neuanlage (Schritt 4 uebersprungen) - Scheme-/Function-Namen aus
				# der bereits bestehenden Zieltabelle nachtraeglich ermitteln.
				$schemeLookupQuery = @"
SELECT ps.name AS PartitionSchemeName, pf.name AS PartitionFunctionName
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
JOIN sys.partition_functions pf ON pf.function_id = ps.function_id
WHERE s.name = N'$TargetSchemaName' AND t.name = N'$TargetTableName' AND i.index_id IN (0, 1);
"@
				$schemeInfo = Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query $schemeLookupQuery -ErrorAction Stop -EnableException -As PSObject
			}

			$regParams = @{
				SqlInstance           = $SqlInstance
				Database              = $TargetDatabaseName
				Schema                = $TargetSchemaName
				Table                 = $TargetTableName
				PartitionColumn       = $PartitionColumn
				PartitionFunctionName = $schemeInfo.PartitionFunctionName
				PartitionSchemeName   = $schemeInfo.PartitionSchemeName
				Granularity           = $Granularity
				BoundaryType          = $BoundaryType
				SurrogateDateFormat   = $SurrogateDateFormat
				FilegroupStrategy     = $FilegroupStrategy
				FutureBufferPeriods   = $FutureBufferPeriods
				DataCompression       = $DataCompression
			}
			if ($SqlCredential) { $regParams['SqlCredential'] = $SqlCredential }
			Register-sqmPartitionTable @regParams -Confirm:$false | Out-Null
			$registered = $true
		}

		return [PSCustomObject]@{
			SourceSchemaName   = $Schema
			SourceTableName    = $Table
			TargetDatabaseName = $TargetDatabaseName
			TargetSchemaName   = $TargetSchemaName
			TargetTableName    = $TargetTableName
			PartitionColumn    = $PartitionColumn
			Granularity        = $Granularity
			RowsCopied         = $totalCopied
			RowsVerified       = $tgtCount
			Registered         = $registered
			Status             = 'Success'
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
