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
    4. Kopie ALLER Zeilen mit den Kopierroutinen von sqmDataTransfer (Copy-sqmTableData
       -SourceQuery, SqlBulkCopy - dieselbe Strecke wie Invoke-sqmChunkedTableTransfer), ein Chunk
       je Partition der NEUEN Zieltabelle, mit Fortschritt und Durchsatz je Partition. Fortsetzen
       nach Abbruch oder -MaxDurationMinutes per erneutem Aufruf: Partitionen mit gleicher
       Zeilenzahl in Quelle und Ziel werden uebersprungen, eine Partition mit abweichender Zahl wird
       im Ziel geleert und neu kopiert (kein Schluessel noetig). Schritt 3 wird uebersprungen, wenn
       die Zieltabelle bereits existiert.
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
    Veraltet, wird ignoriert (seit 1.15.0.0 wird partitionsweise per SqlBulkCopy kopiert, dafuer ist
    kein Schluessel noetig). Bleibt nur, damit bestehende Aufrufe nicht brechen.
.PARAMETER BatchSize
    SqlBulkCopy-Batchgroesse. Ohne Angabe gilt die Standard-Batchgroesse von sqmDataTransfer
    (Get-sqmTransferConfig DefaultBatchSize, Standard 500000).
.PARAMETER MaxDurationMinutes
    Bricht nach dieser Laufzeit sauber zwischen zwei Partitionen ab (0 = kein Limit, Standard) -
    fuer die gezielte Aufteilung sehr grosser Tabellen auf mehrere Wartungsfenster. Ein erneuter
    Aufruf setzt bei der ersten noch nicht vollstaendigen Partition fort.
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
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), Copy-sqmTableData (sqmDataTransfer), Get-sqmPartitionColumnRange,
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
	if ($KeyColumn) { Write-Warning "-KeyColumn wird seit sqmPartitionTool 1.15.0.0 ignoriert (partitionsweise Kopie per SqlBulkCopy braucht keinen Schluessel)." }
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
		# 5. Kopie ALLER Zeilen mit den Kopierroutinen von sqmDataTransfer (Copy-sqmTableData
		#    -SourceQuery -> SqlBulkCopy, Namens-Mapping, Abbruch per Cancel, Fortschritt) - ein
		#    Chunk je Partition der NEUEN Zieltabelle. Fortsetzen: Zeilenzahl je Partition in Quelle
		#    und Ziel (je EIN GROUP BY-Scan ueber $PARTITION der Ziel-Function); gleiche Zahl ->
		#    uebersprungen, abweichende Zahl -> Partition im Ziel leeren und neu kopieren. Kein
		#    Schluessel noetig.
		# =========================================================================================
		$tgtPfQuery = @"
SELECT pf.name AS PartitionFunctionName, pf.boundary_value_on_right AS RangeRight
FROM sys.indexes i
JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
JOIN sys.partition_functions pf ON pf.function_id = ps.function_id
WHERE i.object_id = OBJECT_ID(N'[$TargetSchemaName].[$TargetTableName]') AND i.index_id IN (0, 1);
"@
		$tgtPf = @(Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query $tgtPfQuery -ErrorAction Stop -EnableException -As PSObject) | Select-Object -First 1
		if (-not $tgtPf) { throw "Zieltabelle '$TargetDatabaseName.$TargetSchemaName.$TargetTableName' ist nicht partitioniert - vermutlich ein abgebrochener frueherer Lauf. Tabelle pruefen und (wenn leer) loeschen, dann erneut starten." }
		$pfName = [string]$tgtPf.PartitionFunctionName
		$rangeRight = [bool]$tgtPf.RangeRight
		$bounds = @(Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query "SELECT prv.value AS V FROM sys.partition_range_values prv JOIN sys.partition_functions pf ON pf.function_id = prv.function_id WHERE pf.name = N'$pfName' ORDER BY prv.boundary_id;" -ErrorAction Stop -EnableException -As PSObject | ForEach-Object { $_.V })

		function _BoundLiteral($v)
		{
			$inv = [System.Globalization.CultureInfo]::InvariantCulture
			if ($v -is [datetime]) { return "'$($v.ToString('yyyy-MM-ddTHH:mm:ss.fff', $inv))'" }
			if ($v -is [datetimeoffset]) { return "'$($v.ToString('yyyy-MM-ddTHH:mm:ss.fffffffzzz', $inv))'" }
			if ($v -is [string]) { return "N'$($v.Replace("'", "''"))'" }
			return ([System.IFormattable]$v).ToString($null, $inv)
		}
		# Partition k (1..n+1) als Bereichspraedikat auf der nackten Spalte (Index-Seek moeglich).
		# NULL liegt bei RANGE RIGHT wie LEFT immer in Partition 1.
		function _PartitionPredicate([int]$k)
		{
			$col = "[$PartitionColumn]"
			$lo = if ($k -ge 2) { _BoundLiteral $bounds[$k - 2] } else { $null }
			$hi = if ($k -le $bounds.Count) { _BoundLiteral $bounds[$k - 1] } else { $null }
			$geLo = if ($rangeRight) { '>=' } else { '>' }
			$ltHi = if ($rangeRight) { '<' } else { '<=' }
			if ($null -eq $lo -and $null -eq $hi) { return '1 = 1' }
			if ($null -eq $lo) { return "($col $ltHi $hi OR $col IS NULL)" }
			if ($null -eq $hi) { return "$col $geLo $lo" }
			return "$col $geLo $lo AND $col $ltHi $hi"
		}

		Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Counting rows per target partition in source and target ..."
		$srcCountByPart = @{}
		$dstCountByPart = @{}
		$srcPartExpr = "[$TargetDatabaseName].`$PARTITION.[$pfName]([$PartitionColumn])"
		foreach ($r in @(Invoke-DbaQuery @connParams -Database $Database -Query "SELECT $srcPartExpr AS P, COUNT_BIG(*) AS Cnt FROM [$Schema].[$Table] GROUP BY $srcPartExpr;" -QueryTimeout 0 -ErrorAction Stop -EnableException -As PSObject)) { $srcCountByPart[[int]$r.P] = [int64]$r.Cnt }
		foreach ($r in @(Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query "SELECT `$PARTITION.[$pfName]([$PartitionColumn]) AS P, COUNT_BIG(*) AS Cnt FROM [$TargetSchemaName].[$TargetTableName] GROUP BY `$PARTITION.[$pfName]([$PartitionColumn]);" -QueryTimeout 0 -ErrorAction Stop -EnableException -As PSObject)) { $dstCountByPart[[int]$r.P] = [int64]$r.Cnt }

		$copyBase = @{
			Source              = $SqlInstance
			SourceDatabase      = $Database
			Destination         = $SqlInstance
			DestinationDatabase = $TargetDatabaseName
			Table               = "$Schema.$Table"
			DestinationTable    = "$TargetSchemaName.$TargetTableName"
			KeepIdentity        = $true
			KeepNulls           = $true
			EnableException     = $true
			Confirm             = $false
		}
		if ($PSBoundParameters.ContainsKey('BatchSize')) { $copyBase['BatchSize'] = $BatchSize }
		if ($SqlCredential) { $copyBase['SourceCredential'] = $SqlCredential; $copyBase['DestinationCredential'] = $SqlCredential }

		$partCount = $bounds.Count + 1
		$toCopy = @(1..$partCount | Where-Object { $s = if ($srcCountByPart.ContainsKey($_)) { $srcCountByPart[$_] } else { 0 }; $d = if ($dstCountByPart.ContainsKey($_)) { $dstCountByPart[$_] } else { 0 }; $s -ne $d })
		Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $partCount partition(s), $($toCopy.Count) to copy, $($partCount - $toCopy.Count) already complete or empty."

		# Partition je Chunk per Index-Seek lesen, wenn die NEUE Partitionsspalte nicht die
		# Partitionsspalte der Quelle ist (dann greift keine Partition Elimination) und die Quelle
		# einen Index mit dieser Spalte vorne hat - sonst liest jeder Chunk die ganze Quelltabelle
		# (gleiche Regel wie Invoke-sqmChunkedTableTransfer -SourceAccess Auto).
		$sourceHint = ''
		if ($PartitionColumn -ne $srcPart.PartitionColumn -and $toCopy.Count -ge 4)
		{
			$seekIdx = @(Invoke-DbaQuery @connParams -Database $Database -ErrorAction Stop -EnableException -As PSObject -Query @"
SELECT TOP (1) i.index_id, i.name
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal = 1
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'[$Schema].[$Table]') AND i.is_disabled = 0 AND i.type IN (1, 2) AND i.has_filter = 0 AND c.name = N'$PartitionColumn'
ORDER BY i.index_id
"@) | Select-Object -First 1
			if ($seekIdx -and [int]$seekIdx.index_id -ne 1)
			{
				try
				{
					Invoke-DbaQuery @connParams -Database $Database -Query "SELECT TOP (0) * FROM [$Schema].[$Table] WITH (FORCESEEK) WHERE $(_PartitionPredicate $toCopy[0])" -ErrorAction Stop -EnableException | Out-Null
					$sourceHint = ' WITH (FORCESEEK)'
					Invoke-sqmLogging -Message "Partitionen werden per Index-Seek ueber '$($seekIdx.name)' aus der Quelle gelesen." -FunctionName $functionName -Level "INFO"
				}
				catch { Invoke-sqmLogging -Message "Seek ueber '$($seekIdx.name)' nicht moeglich ($($_.Exception.Message)) - Scan je Partition." -FunctionName $functionName -Level "WARNING" }
			}
		}

		$sw = [System.Diagnostics.Stopwatch]::StartNew()
		$totalCopied = 0
		$timeBudgetHit = $false
		$chunkIndex = 0
		$progressActivity = "Copying '$Schema.$Table' -> '$TargetDatabaseName.$TargetSchemaName.$TargetTableName'"
		foreach ($k in $toCopy)
		{
			if ($MaxDurationMinutes -gt 0 -and $sw.Elapsed.TotalMinutes -ge $MaxDurationMinutes)
			{
				$timeBudgetHit = $true
				Invoke-sqmLogging -Message "Zeitbudget ($MaxDurationMinutes Min.) erreicht - $totalCopied Zeile(n) in diesem Lauf kopiert. Erneuter Aufruf setzt automatisch fort." -FunctionName $functionName -Level "WARNING"
				break
			}
			$chunkIndex++
			$predicate = _PartitionPredicate $k
			$srcCnt = if ($srcCountByPart.ContainsKey($k)) { $srcCountByPart[$k] } else { [int64]0 }
			$dstCnt = if ($dstCountByPart.ContainsKey($k)) { $dstCountByPart[$k] } else { [int64]0 }
			Write-Progress -Id 1 -Activity $progressActivity -Status "Partition $k ($chunkIndex of $($toCopy.Count)) - $totalCopied row(s) copied so far" -PercentComplete ([int](100 * ($chunkIndex - 1) / $toCopy.Count))
			Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Partition $k ($chunkIndex of $($toCopy.Count)): $srcCnt row(s) ..."

			if ($dstCnt -gt 0)
			{
				# Rest eines abgebrochenen Laufs - erst leeren, sonst Duplikate. In Batches wegen Log.
				$deleted = 0
				do
				{
					$n = [int64](Invoke-DbaQuery @connParams -Database $TargetDatabaseName -Query "DELETE TOP (100000) FROM [$TargetSchemaName].[$TargetTableName] WHERE $predicate; SELECT @@ROWCOUNT AS Cnt;" -QueryTimeout 0 -ErrorAction Stop -EnableException -As PSObject)[0].Cnt
					$deleted += $n
				} while ($n -gt 0)
				Invoke-sqmLogging -Message "Partition $k : $deleted vorhandene Zeile(n) im Ziel geloescht vor Neukopie." -FunctionName $functionName -Level "WARNING"
			}

			$partWatch = [System.Diagnostics.Stopwatch]::StartNew()
			$copyResult = @(Copy-sqmTableData @copyBase -SourceQuery "SELECT * FROM [$Schema].[$Table]$sourceHint WHERE $predicate") | Select-Object -First 1
			$partWatch.Stop()
			if (-not $copyResult -or $copyResult.Status -ne 'Success') { throw "Partition $k konnte nicht kopiert werden: $(if ($copyResult) { $copyResult.Message } else { 'kein Ergebnis von Copy-sqmTableData' })" }
			$rows = [int64]$copyResult.RowsCopied
			$totalCopied += $rows
			$rate = if ($partWatch.Elapsed.TotalSeconds -gt 0) { [int64]($rows / $partWatch.Elapsed.TotalSeconds) } else { 0 }
			Invoke-sqmLogging -Message "Partition $k : $rows Zeile(n) in $([math]::Round($partWatch.Elapsed.TotalSeconds, 1)) s kopiert ($rate Zeilen/s)." -FunctionName $functionName -Level "INFO"
			Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Partition $k done: $rows row(s) in $([math]::Round($partWatch.Elapsed.TotalSeconds, 1)) s ($rate rows/s, running total: $totalCopied)."
		}
		if ($toCopy.Count -gt 0) { Write-Progress -Id 1 -Activity $progressActivity -Completed }

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
