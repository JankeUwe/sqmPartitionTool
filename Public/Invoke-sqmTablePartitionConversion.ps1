<#
.SYNOPSIS
    Wandelt eine bestehende, nicht partitionierte Tabelle in eine partitionierte Tabelle um.

.DESCRIPTION
    Orchestriert den kompletten Ablauf: Pre-Flight-Pruefung (Test-sqmPartitionReadiness),
    Min/Max-Ermittlung (Get-sqmPartitionColumnRange, ausser bei manuellen Werten), Boundary-
    Berechnung (Get-sqmPartitionBoundaryList), Filegroup-Anlage (New-sqmPartitionFilegroupPlan),
    Partition Function/Scheme (New-sqmPartitionSchemeSet), und schliesslich das eigentliche
    Partitionieren der Tabelle:

    - Ist der Clustered Index ein PRIMARY KEY/UNIQUE-Constraint OHNE die Partitionsspalte im
      Schluessel: DROP CONSTRAINT + ADD CONSTRAINT ... PRIMARY KEY CLUSTERED (alte Spalte(n),
      Partitionsspalte) ON <scheme>(<Partitionsspalte>) - das ist der korrekte SQL-Server-Weg,
      NICHT ein blosses CREATE INDEX WITH DROP_EXISTING (das wuerde die Constraint-Definition
      nicht mitziehen). Erfordert -AllowKeyChange.
    - Ist der Clustered Index ein normaler Index (keine Constraint) oder enthaelt die
      Partitionsspalte bereits: CREATE (UNIQUE) CLUSTERED INDEX ... WITH (DROP_EXISTING=ON)
      ON <scheme>(<Partitionsspalte>).
    - Heap (kein Clustered Index): -Method Default legt einen neuen Clustered Index direkt auf
      dem Partition Scheme an; -Method NewTableSwap fuer sehr grosse Heaps (Tabellenkopie +
      Umbenennung).
    - -Method BatchedSwap (Heap UND indizierte/PK-Tabellen): fuer sehr grosse Tabellen auf
      SAN/Datentraeger mit wenig freiem Platz. Legt eine neue, leere partitionierte Kopie an und
      verschiebt die Daten SEGMENTWEISE (je Boundary-Periode, weiter unterteilt in -BatchSize)
      per atomarem 'DELETE ... OUTPUT ... INTO' (Quelle und Ziel in derselben Datenbank - kein
      separater Verify-Schritt noetig, im Unterschied zu Invoke-sqmTableArchiveMigration ueber
      Datenbankgrenzen hinweg). Optional -DataCompression und periodisches Shrinken
      (-ShrinkAfterEveryNSegments/-AggressiveShrink) der alten Tabelle, waehrend sie sich leert.
      Abschliessend sp_rename-Swap (alte, jetzt leere Tabelle -> "..._sqmPartOld", neue Tabelle ->
      Originalname). V1-Einschraenkung: bricht mit Fehler ab, wenn die Tabelle eingehende
      Fremdschluessel oder Trigger hat (siehe -Method Default/NewTableSwap fuer diese Faelle).

    Registriert die Tabelle danach in master.dbo.sqm_PartitionRegistry (Register-sqmPartitionTable),
    ausser -NoRegister ist gesetzt.

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER Database
    Zieldatenbank.
.PARAMETER Schema
    Schema der Tabelle.
.PARAMETER Table
    Tabellenname.
.PARAMETER PartitionColumn
    Partitionsspalte.
.PARAMETER Granularity
    Month, Quarter oder Year.
.PARAMETER BoundaryType
    Date (Standard bei date/datetime/datetime2/smalldatetime-Spalten), Int (numerischer
    Surrogatschluessel, z.B. int/bigint-Spalte) oder Text (char/varchar-Surrogatschluessel mit
    demselben Zahlenformat als String). Ohne Angabe wird aus dem Spaltentyp automatisch
    abgeleitet: Datumstypen -> Date, int/bigint/smallint/tinyint -> Int,
    char/varchar/nchar/nvarchar -> Text.
.PARAMETER SurrogateDateFormat
    Nur relevant bei BoundaryType Int oder Text: 'yyyyMMdd' (Standard, Tagesgenauigkeit) oder
    'yyyyMM' (Monatsgenauigkeit ohne Tag, z.B. wenn die Quellspalte selbst nur auf Monatsebene
    gefuehrt wird).
.PARAMETER FilegroupStrategy
    Single (Standard) oder PerPeriod.
.PARAMETER FutureBufferPeriods
    Anzahl vorausschauend leer angelegter Perioden. Standard: 3.
.PARAMETER ManualStartValue
    Manueller Start-Grenzwert bei leerer Tabelle (Get-sqmPartitionColumnRange kann dann kein
    Min/Max liefern). Pflicht wenn die Tabelle leer ist.
.PARAMETER ManualEndValue
    Manueller End-Grenzwert bei leerer Tabelle. Ohne Angabe wird ManualStartValue auch als
    Endwert verwendet (Einzelperiode + FutureBufferPeriods).
.PARAMETER AllowKeyChange
    Bestaetigt explizit, dass ein PRIMARY KEY/UNIQUE-Constraint um die Partitionsspalte erweitert
    werden darf (Pflicht, wenn Test-sqmPartitionReadiness das verlangt - siehe Warnungen dort).
.PARAMETER Method
    Default (Standard), NewTableSwap (fuer sehr grosse Heaps - Tabellenkopie statt Online-
    Index-Aufbau) oder BatchedSwap (fuer sehr grosse Tabellen mit wenig freiem Speicherplatz -
    segmentweises Kopieren+Loeschen statt einer einzelnen grossen Operation, siehe DESCRIPTION).
.PARAMETER Online
    Versucht ONLINE=ON beim Index-Rebuild (nur Enterprise/Developer Edition). Faellt auf anderen
    Editionen automatisch mit Warnung auf OFFLINE zurueck. Ohne Wirkung bei -Method BatchedSwap.
.PARAMETER BatchSize
    Nur -Method BatchedSwap: Zeilen pro Kopier-/Loeschbatch *innerhalb* eines Boundary-Segments.
    Standard: 50000.
.PARAMETER DataCompression
    Nur -Method BatchedSwap: None (Standard), Row oder Page. Wird direkt nach dem Anlegen der
    neuen (noch leeren) partitionierten Kopie angewendet (ALTER TABLE ... REBUILD
    PARTITION = ALL WITH (DATA_COMPRESSION = ...) - CREATE TABLE kennt keine Kompressions-Klausel).
.PARAMETER ShrinkAfterEveryNSegments
    Nur -Method BatchedSwap: nach wie vielen geleerten Boundary-Segmenten DBCC SHRINKFILE (siehe
    -AggressiveShrink) auf den Datendateien der aktuellen Filegroup der ALTEN Tabelle ausgefuehrt
    wird. Standard: 1 (nach jedem Segment).
.PARAMETER AggressiveShrink
    Nur -Method BatchedSwap: standardmaessig TRUNCATEONLY (schnell, keine Fragmentierung, gibt
    aber nur am Dateiende freien Platz zurueck). Mit diesem Schalter voller Shrink (mehr
    Platzgewinn, fragmentiert die verbleibenden Indizes - Rebuild danach empfohlen).
.PARAMETER NoRegister
    Tabelle NICHT in sqm_PartitionRegistry eintragen (z.B. fuer einmalige/manuell verwaltete
    Partitionierungen ohne automatische Wartungs-Jobs).
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    Invoke-sqmTablePartitionConversion -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
        -Table "OrderHistory" -PartitionColumn "OrderDate" -Granularity Month

.EXAMPLE
    Invoke-sqmTablePartitionConversion -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
        -Table "OrderHistory" -PartitionColumn "OrderDate" -Granularity Quarter `
        -FilegroupStrategy PerPeriod -AllowKeyChange -Online

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), alle uebrigen sqmPartitionTool-Core-
    Funktionen.
#>
function Invoke-sqmTablePartitionConversion
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
		$ManualStartValue,

		[Parameter(Mandatory = $false)]
		$ManualEndValue,

		[Parameter(Mandatory = $false)]
		[switch]$AllowKeyChange,

		[Parameter(Mandatory = $false)]
		[ValidateSet('Default', 'NewTableSwap', 'BatchedSwap')]
		[string]$Method = 'Default',

		[Parameter(Mandatory = $false)]
		[switch]$Online,

		[Parameter(Mandatory = $false)]
		[ValidateRange(100, 1000000)]
		[int]$BatchSize = 50000,

		[Parameter(Mandatory = $false)]
		[ValidateSet('None', 'Row', 'Page')]
		[string]$DataCompression = 'None',

		[Parameter(Mandatory = $false)]
		[ValidateRange(1, 1000)]
		[int]$ShrinkAfterEveryNSegments = 1,

		[Parameter(Mandatory = $false)]
		[switch]$AggressiveShrink,

		[Parameter(Mandatory = $false)]
		[switch]$NoRegister,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	try
	{
		# =========================================================================================
		# 1. Pre-Flight
		# =========================================================================================
		$readyParams = @{ SqlInstance = $SqlInstance; Database = $Database; Schema = $Schema; Table = $Table; PartitionColumn = $PartitionColumn }
		if ($SqlCredential) { $readyParams['SqlCredential'] = $SqlCredential }
		$readiness = Test-sqmPartitionReadiness @readyParams

		if (-not $readiness.IsReady)
		{
			$msg = "Pre-Flight-Pruefung fehlgeschlagen: $($readiness.Errors -join ' | ')"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}
		if ($readiness.RequiresAllowKeyChange -and -not $AllowKeyChange)
		{
			$msg = "'$Schema.$Table' hat einen PRIMARY KEY/UNIQUE-Constraint, der '$PartitionColumn' nicht enthaelt. " +
			"Der Schluessel muss dafuer erweitert werden (aendert die Eindeutigkeits-Semantik) - " +
			"mit -AllowKeyChange explizit bestaetigen. Details: $($readiness.Warnings -join ' | ')"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			throw $msg
		}
		foreach ($w in $readiness.Warnings) { Invoke-sqmLogging -Message "Warnung: $w" -FunctionName $functionName -Level "WARNING" }

		# -Method BatchedSwap baut eine NEUE Tabelle auf und benennt sie an die Stelle der alten -
		# eingehende Fremdschluessel/Trigger werden dabei NICHT automatisch mituebernommen (V1-
		# Einschraenkung, siehe DESCRIPTION). Frueh abbrechen statt erst mitten im Umbau zu scheitern.
		if ($Method -eq 'BatchedSwap')
		{
			$fkCheckQuery = "SELECT fk.name AS ForeignKeyName, OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id) AS ReferencingTable FROM sys.foreign_keys fk WHERE fk.referenced_object_id = OBJECT_ID(N'[$Schema].[$Table]');"
			$incomingFks = @(Invoke-DbaQuery @connParams -Query $fkCheckQuery -ErrorAction Stop -As PSObject)
			if ($incomingFks.Count -gt 0)
			{
				$fkList = ($incomingFks | ForEach-Object { "$($_.ReferencingTable) ($($_.ForeignKeyName))" }) -join '; '
				$msg = "-Method BatchedSwap unterstuetzt aktuell keine Tabellen mit eingehenden Fremdschluesseln: $fkList. Fremdschluessel vorher entfernen oder -Method Default/NewTableSwap verwenden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw $msg
			}

			$triggerCheckQuery = "SELECT name FROM sys.triggers WHERE parent_id = OBJECT_ID(N'[$Schema].[$Table]') AND parent_class = 1;"
			$triggers = @(Invoke-DbaQuery @connParams -Query $triggerCheckQuery -ErrorAction Stop -As PSObject)
			if ($triggers.Count -gt 0)
			{
				$triggerList = ($triggers | ForEach-Object { $_.name }) -join ', '
				$msg = "-Method BatchedSwap unterstuetzt aktuell keine Tabellen mit Triggern: $triggerList. Trigger vorher entfernen oder -Method Default/NewTableSwap verwenden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw $msg
			}
		}

		# =========================================================================================
		# 2. Spaltentyp + BoundaryType ermitteln
		# =========================================================================================
		$typeQuery = @"
SELECT ty.name AS TypeName, c.precision, c.scale, c.max_length
FROM sys.columns c
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'$Schema' AND t.name = N'$Table' AND c.name = N'$PartitionColumn'
"@
		$colType = Invoke-DbaQuery @connParams -Query $typeQuery -ErrorAction Stop -As PSObject
		if (-not $colType) { throw "Spalte '$PartitionColumn' nicht gefunden." }

		$typeName = [string]$colType.TypeName
		$sqlDataType = switch ($typeName)
		{
			'datetime2' { "datetime2($($colType.scale))" }
			'decimal'   { "decimal($($colType.precision),$($colType.scale))" }
			'numeric'   { "numeric($($colType.precision),$($colType.scale))" }
			'char'      { "char($($colType.max_length))" }
			'varchar'   { if ([int]$colType.max_length -eq -1) { 'varchar(max)' } else { "varchar($($colType.max_length))" } }
			'nchar'     { "nchar($([int]$colType.max_length / 2))" }
			'nvarchar'  { if ([int]$colType.max_length -eq -1) { 'nvarchar(max)' } else { "nvarchar($([int]$colType.max_length / 2))" } }
			default     { $typeName }
		}

		$dateTypes = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
		$intTypes = @('int', 'bigint', 'smallint', 'tinyint')
		$textTypes = @('char', 'varchar', 'nchar', 'nvarchar')
		if (-not $BoundaryType)
		{
			$BoundaryType = if ($typeName -in $dateTypes) { 'Date' } elseif ($typeName -in $textTypes) { 'Text' } else { 'Int' }
			Invoke-sqmLogging -Message "BoundaryType nicht angegeben - aus Spaltentyp '$typeName' abgeleitet: $BoundaryType (SurrogateDateFormat: $SurrogateDateFormat)." -FunctionName $functionName -Level "INFO"
		}
		if ($BoundaryType -eq 'Int' -and $typeName -notin $intTypes)
		{
			Invoke-sqmLogging -Message "BoundaryType 'Int' bei Spaltentyp '$typeName' - es wird ein $SurrogateDateFormat-Format erwartet. Falls die Spalte kein Datums-Surrogatschluessel ist, ist Month/Quarter/Year-Granularitaet vermutlich nicht sinnvoll." -FunctionName $functionName -Level "WARNING"
		}
		if ($BoundaryType -eq 'Text' -and $typeName -notin $textTypes)
		{
			Invoke-sqmLogging -Message "BoundaryType 'Text' bei Spaltentyp '$typeName' - es wird ein $SurrogateDateFormat-Format als String erwartet." -FunctionName $functionName -Level "WARNING"
		}

		# =========================================================================================
		# 3. Min/Max ermitteln (oder manuelle Werte bei leerer Tabelle)
		# =========================================================================================
		if ($ManualStartValue)
		{
			$minValue = $ManualStartValue
			$maxValue = if ($ManualEndValue) { $ManualEndValue } else { $ManualStartValue }
			Invoke-sqmLogging -Message "Manuelle Grenzwerte verwendet: $minValue bis $maxValue." -FunctionName $functionName -Level "INFO"
		}
		else
		{
			$rangeParams = @{ SqlInstance = $SqlInstance; Database = $Database; Schema = $Schema; Table = $Table; Column = $PartitionColumn }
			if ($SqlCredential) { $rangeParams['SqlCredential'] = $SqlCredential }
			$range = Get-sqmPartitionColumnRange @rangeParams

			if ($range.IsEmpty)
			{
				$msg = "'$Schema.$Table' ist leer und -ManualStartValue wurde nicht angegeben - Grenzwerte koennen nicht ermittelt werden."
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw $msg
			}
			$minValue = $range.MinValue
			$maxValue = $range.MaxValue
		}

		# =========================================================================================
		# 4. Boundary-Liste
		# =========================================================================================
		$boundaries = Get-sqmPartitionBoundaryList -MinValue $minValue -MaxValue $maxValue -Granularity $Granularity -BoundaryType $BoundaryType -SurrogateDateFormat $SurrogateDateFormat -FutureBufferPeriods $FutureBufferPeriods
		Invoke-sqmLogging -Message "$($boundaries.Count) Boundary(s) berechnet -> $($boundaries.Count + 1) Partition(en)." -FunctionName $functionName -Level "INFO"

		# =========================================================================================
		# 5. Filegroups + Partition Function/Scheme
		# =========================================================================================
		$fgParams = @{ SqlInstance = $SqlInstance; Database = $Database; TableName = $Table; BoundaryList = $boundaries; FilegroupStrategy = $FilegroupStrategy }
		if ($SqlCredential) { $fgParams['SqlCredential'] = $SqlCredential }
		$fgPlan = New-sqmPartitionFilegroupPlan @fgParams -Confirm:$false

		$schemeParams = @{
			SqlInstance     = $SqlInstance
			Database        = $Database
			TableName       = $Table
			PartitionColumn = $PartitionColumn
			SqlDataType     = $sqlDataType
			BoundaryList    = $boundaries
			FilegroupNames  = $fgPlan.FilegroupNames
		}
		if ($SqlCredential) { $schemeParams['SqlCredential'] = $SqlCredential }
		$scheme = New-sqmPartitionSchemeSet @schemeParams -Confirm:$false

		# =========================================================================================
		# 6. Tabelle auf das Partition Scheme umstellen
		# =========================================================================================
		$onlineEdition = $false
		if ($Online)
		{
			try
			{
				$edResult = Invoke-DbaQuery @connParams -Query "SELECT CAST(SERVERPROPERTY('EngineEdition') AS INT) AS EngineEdition" -ErrorAction Stop -As PSObject
				$onlineEdition = ([int]$edResult.EngineEdition -eq 3)
				if (-not $onlineEdition)
				{
					Invoke-sqmLogging -Message "-Online angefordert, aber EngineEdition ist nicht Enterprise/Developer - falle zurueck auf OFFLINE." -FunctionName $functionName -Level "WARNING"
				}
			}
			catch { $onlineEdition = $false }
		}
		$onlineClause = if ($onlineEdition) { 'ON' } else { 'OFF' }

		$clusteredIndexQuery = @"
SELECT i.name AS IndexName, i.is_unique, i.is_primary_key, i.is_unique_constraint,
       STRING_AGG(c.name, ',') WITHIN GROUP (ORDER BY ic.key_ordinal) AS KeyColumns
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = N'$Schema' AND t.name = N'$Table' AND i.index_id = 1
GROUP BY i.name, i.is_unique, i.is_primary_key, i.is_unique_constraint
"@
		$ci = Invoke-DbaQuery @connParams -Query $clusteredIndexQuery -ErrorAction Stop -As PSObject

		$applyAction = "'$Schema.$Table' auf Partition Scheme '$($scheme.PartitionSchemeName)' umstellen"
		if (-not $PSCmdlet.ShouldProcess($Database, $applyAction))
		{
			return [PSCustomObject]@{
				SchemaName = $Schema; TableName = $Table; PartitionColumn = $PartitionColumn
				PartitionFunctionName = $scheme.PartitionFunctionName; PartitionSchemeName = $scheme.PartitionSchemeName
				PartitionCount = $scheme.PartitionCount; Status = 'WhatIf'; Registered = $false
			}
		}

		if ($Method -eq 'BatchedSwap')
		{
			Invoke-sqmLogging -Message "-Method BatchedSwap fuer '$Schema.$Table' - segmentweises Kopieren+Loeschen (atomar je Batch, keine eingehenden Fremdschluessel/Trigger vorhanden)." -FunctionName $functionName -Level "INFO"

			$swapTable = "${Table}_sqmPartNew"
			Invoke-DbaQuery @connParams -Query "IF OBJECT_ID(N'[$Schema].[$swapTable]') IS NOT NULL DROP TABLE [$Schema].[$swapTable];" -ErrorAction Stop -EnableException -As PSObject | Out-Null

			$defParams = @{
				SqlInstance         = $SqlInstance
				Database            = $Database
				Schema              = $Schema
				Table               = $Table
				TargetTable         = $swapTable
				PartitionSchemeName = $scheme.PartitionSchemeName
				PartitionColumn     = $PartitionColumn
			}
			if ($SqlCredential) { $defParams['SqlCredential'] = $SqlCredential }
			$tableDef = Get-sqmTableDefinitionSql @defParams -EnableException

			Invoke-DbaQuery @connParams -Query $tableDef.CreateTableSql -ErrorAction Stop -EnableException
			foreach ($idxDdl in $tableDef.IndexSql)
			{
				Invoke-DbaQuery @connParams -Query $idxDdl -ErrorAction Stop -EnableException
			}
			Invoke-sqmLogging -Message "Neue partitionierte Tabelle '$swapTable' angelegt (Struktur von '$Schema.$Table' uebernommen)." -FunctionName $functionName -Level "INFO"

			if ($DataCompression -ne 'None')
			{
				Invoke-sqmLogging -Message "$DataCompression-Kompression wird auf '$swapTable' angewendet - alle Partitionen werden gebuendelt (kann bei grossen Tabellen mehrere Stunden dauern)." -FunctionName $functionName -Level "WARNING"
				try
				{
					$compressionSql = "ALTER TABLE [$Schema].[$swapTable] REBUILD PARTITION = ALL WITH (DATA_COMPRESSION = $($DataCompression.ToUpper()));"
					Invoke-DbaQuery @connParams -Query $compressionSql -ErrorAction Stop -EnableException -As PSObject | Out-Null
					Invoke-sqmLogging -Message "$DataCompression-Kompression auf '$swapTable' abgeschlossen (alle Partitionen)." -FunctionName $functionName -Level "INFO"
				}
				catch
				{
					Invoke-sqmLogging -Message "Fehler bei Kompressionsanwendung (Umbau wird fortgesetzt): $($_.Exception.Message). Kompression kann spaeter manuell mit ALTER TABLE ... REBUILD PARTITION angewendet werden." -FunctionName $functionName -Level "WARNING"
				}
			}

			# Aktuelle Filegroup der ALTEN Tabelle ermitteln - Ziel fuer periodisches Shrinken waehrend
			# sie sich leert (unpartitioniert, liegt also auf genau einer Filegroup).
			$oldFgQuery = @"
SELECT DISTINCT fg.name AS FilegroupName
FROM sys.partitions p
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
JOIN sys.filegroups fg ON fg.data_space_id = au.data_space_id
WHERE p.object_id = OBJECT_ID(N'[$Schema].[$Table]') AND p.index_id IN (0, 1);
"@
			$oldFgRows = @(Invoke-DbaQuery @connParams -Query $oldFgQuery -ErrorAction Stop)
			$oldFilegroupName = if ($oldFgRows.Count -gt 0) { $oldFgRows[0].FilegroupName } else { $null }

			function _BoundaryLiteral($value, [string]$boundaryType)
			{
				switch ($boundaryType)
				{
					'Date'    { return "'$(([datetime]$value).ToString('yyyy-MM-dd'))'" }
					'Text'    { return "'$value'" }
					default   { return "$value" }
				}
			}

			# Segmentgrenzen aus der bereits berechneten Boundary-Liste: [null,b0), [b0,b1), ..., [bN-1,null).
			# Erstes und letztes Segment sind durch die Sliding-Window-Konstruktion immer leer (siehe
			# Get-sqmPartitionBoundaryList) - kein Sonderfall noetig, sie liefern einfach 0 Zeilen.
			$segmentBounds = [System.Collections.Generic.List[object]]::new()
			$prevBoundary = $null
			foreach ($b in $boundaries)
			{
				$segmentBounds.Add([PSCustomObject]@{ Start = $prevBoundary; End = $b.BoundaryValue })
				$prevBoundary = $b.BoundaryValue
			}
			$segmentBounds.Add([PSCustomObject]@{ Start = $prevBoundary; End = $null })

			$colListSql = ($tableDef.ColumnNames | ForEach-Object { "[$_]" }) -join ', '
			$colListDeleted = ($tableDef.ColumnNames | ForEach-Object { "DELETED.[$_]" }) -join ', '

			$totalMoved = 0
			$segmentsDone = 0
			foreach ($seg in $segmentBounds)
			{
				$whereParts = [System.Collections.Generic.List[string]]::new()
				if ($null -ne $seg.Start) { $whereParts.Add("[$PartitionColumn] >= $(_BoundaryLiteral $seg.Start $BoundaryType)") }
				if ($null -ne $seg.End) { $whereParts.Add("[$PartitionColumn] < $(_BoundaryLiteral $seg.End $BoundaryType)") }
				$whereClause = if ($whereParts.Count -gt 0) { "WHERE " + ($whereParts -join ' AND ') } else { '' }

				$segMoved = 0
				$rowsAffected = 1
				while ($rowsAffected -gt 0)
				{
					$moveBody = "DELETE TOP ($BatchSize) FROM [$Schema].[$Table] OUTPUT $colListDeleted INTO [$Schema].[$swapTable] ($colListSql) $whereClause; SELECT @@ROWCOUNT AS Cnt;"
					$moveSql = if ($tableDef.HasIdentity)
					{
						"SET IDENTITY_INSERT [$Schema].[$swapTable] ON; $moveBody SET IDENTITY_INSERT [$Schema].[$swapTable] OFF;"
					}
					else { $moveBody }

					$rowsAffected = [int64](Invoke-DbaQuery @connParams -Query $moveSql -ErrorAction Stop -EnableException -As PSObject)[0].Cnt
					$segMoved += $rowsAffected
				}

				$totalMoved += $segMoved
				$segmentsDone++
				if ($segMoved -gt 0)
				{
					Invoke-sqmLogging -Message "Segment $segmentsDone/$($segmentBounds.Count) : $segMoved Zeile(n) verschoben." -FunctionName $functionName -Level "INFO"

					if ($segmentsDone % $ShrinkAfterEveryNSegments -eq 0)
					{
						try
						{
							$shrinkParams = @{ SqlInstance = $SqlInstance; Database = $Database; Confirm = $false; EnableException = $true }
							if ($oldFilegroupName) { $shrinkParams['FilegroupName'] = $oldFilegroupName }
							if ($SqlCredential) { $shrinkParams['SqlCredential'] = $SqlCredential }
							if ($AggressiveShrink) { $shrinkParams['Aggressive'] = $true }
							$mod = Get-Module -Name sqmPartitionTool
							& $mod { param($p) Invoke-sqmFileSpaceShrink @p } $shrinkParams | Out-Null
						}
						catch
						{
							# Shrink ist ein "Nice-to-have" fuer Plattenplatz, kein Abbruchgrund - das
							# eigentliche Verschieben der Daten ist bereits sicher erfolgt.
							Invoke-sqmLogging -Message "Shrink nach Segment $segmentsDone fehlgeschlagen (Umbau wird fortgesetzt): $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
						}
					}
				}
			}

			Invoke-sqmLogging -Message "Alle Segmente verschoben ($totalMoved Zeile(n) insgesamt) - '$Schema.$Table' ist jetzt leer." -FunctionName $functionName -Level "INFO"

			# Swap: alte (jetzt leere) Tabelle beiseite, neue an ihre Stelle - analog -Method
			# NewTableSwap (Original bleibt als "..._sqmPartOld" erhalten, kein automatisches Drop).
			Invoke-DbaQuery @connParams -Query "EXEC sp_rename N'[$Schema].[$Table]', N'${Table}_sqmPartOld';" -ErrorAction Stop -EnableException
			Invoke-DbaQuery @connParams -Query "EXEC sp_rename N'[$Schema].[$swapTable]', N'$Table';" -ErrorAction Stop -EnableException
			Invoke-sqmLogging -Message "$applyAction - erfolgreich (BatchedSwap: '$Schema.$Table' -> '${Table}_sqmPartOld' [leer], '$swapTable' -> '$Schema.$Table')." -FunctionName $functionName -Level "INFO"
		}
		else
		{
			if ($ci)
			{
				if (-not $ci.KeyColumns) { throw "Clustered Index hat keine Schluesselspalten (unerwartet)." }
				$existingKeyCols = @($ci.KeyColumns -split ',')
				$keyColsWithPartition = if ($PartitionColumn -in $existingKeyCols) { $existingKeyCols } else { $existingKeyCols + $PartitionColumn }
				$keyColList = ($keyColsWithPartition | ForEach-Object { "[$_]" }) -join ', '

				if ((($ci.is_primary_key ?? $false) -or ($ci.is_unique_constraint ?? $false)) -and $PartitionColumn -notin $existingKeyCols)
				{
					# PK/UNIQUE-Constraint muss neu definiert werden (DROP_EXISTING allein reicht hier nicht,
					# die Constraint-Spaltenliste muss die Partitionsspalte mit enthalten).
					$constraintType = if ($ci.is_primary_key ?? $false) { 'PRIMARY KEY' } else { 'UNIQUE' }
					$ddl = @"
ALTER TABLE [$Schema].[$Table] DROP CONSTRAINT [$($ci.IndexName)];
ALTER TABLE [$Schema].[$Table] ADD CONSTRAINT [$($ci.IndexName)] $constraintType CLUSTERED ($keyColList)
    ON [$($scheme.PartitionSchemeName)]([$PartitionColumn]);
"@
				}
				else
				{
					$uniqueKw = if ($ci.is_unique ?? $false) { 'UNIQUE ' } else { '' }
					$ddl = @"
CREATE ${uniqueKw}CLUSTERED INDEX [$($ci.IndexName)]
    ON [$Schema].[$Table] ($keyColList)
    WITH (DROP_EXISTING = ON, ONLINE = $onlineClause)
    ON [$($scheme.PartitionSchemeName)]([$PartitionColumn]);
"@
				}
			}
			else
			{
				# Heap
				if ($Method -eq 'NewTableSwap')
				{
					Invoke-sqmLogging -Message "-Method NewTableSwap fuer Heap '$Schema.$Table' - Basisvariante (Tabellenkopie ohne vollstaendige Constraint-/Trigger-/Berechtigungs-Uebernahme, fuer sehr grosse Heaps als Alternative zum direkten Index-Aufbau)." -FunctionName $functionName -Level "WARNING"
					$tmpTable = "${Table}_sqmPartTmp"
					$ddl = @"
SELECT * INTO [$Schema].[$tmpTable] FROM [$Schema].[$Table] WHERE 1 = 0;
CREATE CLUSTERED INDEX [IX_${Table}_$PartitionColumn] ON [$Schema].[$tmpTable] ([$PartitionColumn])
    ON [$($scheme.PartitionSchemeName)]([$PartitionColumn]);
INSERT INTO [$Schema].[$tmpTable] WITH (TABLOCK) SELECT * FROM [$Schema].[$Table];
EXEC sp_rename N'[$Schema].[$Table]', N'${Table}_sqmPartOld';
EXEC sp_rename N'[$Schema].[$tmpTable]', N'$Table';
"@
				}
				else
				{
					$ddl = @"
CREATE CLUSTERED INDEX [IX_${Table}_$PartitionColumn]
    ON [$Schema].[$Table] ([$PartitionColumn])
    WITH (ONLINE = $onlineClause)
    ON [$($scheme.PartitionSchemeName)]([$PartitionColumn]);
"@
				}
			}

			try
			{
				Invoke-DbaQuery @connParams -Query $ddl -ErrorAction Stop
				Invoke-sqmLogging -Message "$applyAction - erfolgreich." -FunctionName $functionName -Level "INFO"
			}
			catch
			{
				$msg = "Fehler beim Umstellen von '$Schema.$Table' auf das Partition Scheme: $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				throw
			}
		}

		# =========================================================================================
		# 7. Registrieren
		# =========================================================================================
		$registered = $false
		if (-not $NoRegister)
		{
			$regParams = @{
				SqlInstance           = $SqlInstance
				Database              = $Database
				Schema                = $Schema
				Table                 = $Table
				PartitionColumn       = $PartitionColumn
				PartitionFunctionName = $scheme.PartitionFunctionName
				PartitionSchemeName   = $scheme.PartitionSchemeName
				Granularity           = $Granularity
				BoundaryType          = $BoundaryType
				SurrogateDateFormat   = $SurrogateDateFormat
				FilegroupStrategy     = $FilegroupStrategy
				FutureBufferPeriods   = $FutureBufferPeriods
			}
			if ($SqlCredential) { $regParams['SqlCredential'] = $SqlCredential }
			Register-sqmPartitionTable @regParams -Confirm:$false | Out-Null
			$registered = $true
		}

		return [PSCustomObject]@{
			SchemaName            = $Schema
			TableName             = $Table
			PartitionColumn       = $PartitionColumn
			PartitionFunctionName = $scheme.PartitionFunctionName
			PartitionSchemeName   = $scheme.PartitionSchemeName
			PartitionCount        = $scheme.PartitionCount
			FilegroupStrategy     = $FilegroupStrategy
			Status                = 'Success'
			Registered            = $registered
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
