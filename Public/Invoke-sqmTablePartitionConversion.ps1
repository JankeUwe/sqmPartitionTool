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
    Date (Standard bei date/datetime/datetime2/smalldatetime-Spalten) oder Int (Surrogatschluessel
    im Format YYYYMMDD). Ohne Angabe wird aus dem Spaltentyp automatisch abgeleitet.
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
    Default (Standard) oder NewTableSwap (fuer sehr grosse Heaps - Tabellenkopie statt Online-
    Index-Aufbau).
.PARAMETER Online
    Versucht ONLINE=ON beim Index-Rebuild (nur Enterprise/Developer Edition). Faellt auf anderen
    Editionen automatisch mit Warnung auf OFFLINE zurueck.
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
		[ValidateSet('Date', 'Int')]
		[string]$BoundaryType,

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
		[ValidateSet('Default', 'NewTableSwap')]
		[string]$Method = 'Default',

		[Parameter(Mandatory = $false)]
		[switch]$Online,

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
		$colType = Invoke-DbaQuery @connParams -Query $typeQuery -ErrorAction Stop
		if (-not $colType) { throw "Spalte '$PartitionColumn' nicht gefunden." }

		$typeName = [string]$colType.TypeName
		$sqlDataType = switch ($typeName)
		{
			'datetime2' { "datetime2($($colType.scale))" }
			'decimal'   { "decimal($($colType.precision),$($colType.scale))" }
			'numeric'   { "numeric($($colType.precision),$($colType.scale))" }
			default     { $typeName }
		}

		$dateTypes = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
		if (-not $BoundaryType)
		{
			$BoundaryType = if ($typeName -in $dateTypes) { 'Date' } else { 'Int' }
			Invoke-sqmLogging -Message "BoundaryType nicht angegeben - aus Spaltentyp '$typeName' abgeleitet: $BoundaryType." -FunctionName $functionName -Level "INFO"
		}
		if ($BoundaryType -eq 'Int' -and $typeName -notin @('int', 'bigint', 'smallint'))
		{
			Invoke-sqmLogging -Message "BoundaryType 'Int' bei Spaltentyp '$typeName' - es wird ein YYYYMMDD-Format erwartet. Falls die Spalte kein Datums-Surrogatschluessel ist, ist Month/Quarter/Year-Granularitaet vermutlich nicht sinnvoll." -FunctionName $functionName -Level "WARNING"
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
		$boundaries = Get-sqmPartitionBoundaryList -MinValue $minValue -MaxValue $maxValue -Granularity $Granularity -BoundaryType $BoundaryType -FutureBufferPeriods $FutureBufferPeriods
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
				$edResult = Invoke-DbaQuery @connParams -Query "SELECT CAST(SERVERPROPERTY('EngineEdition') AS INT) AS EngineEdition" -ErrorAction Stop
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
		$ci = Invoke-DbaQuery @connParams -Query $clusteredIndexQuery -ErrorAction Stop

		$applyAction = "'$Schema.$Table' auf Partition Scheme '$($scheme.PartitionSchemeName)' umstellen"
		if (-not $PSCmdlet.ShouldProcess($Database, $applyAction))
		{
			return [PSCustomObject]@{
				SchemaName = $Schema; TableName = $Table; PartitionColumn = $PartitionColumn
				PartitionFunctionName = $scheme.PartitionFunctionName; PartitionSchemeName = $scheme.PartitionSchemeName
				PartitionCount = $scheme.PartitionCount; Status = 'WhatIf'; Registered = $false
			}
		}

		if ($ci)
		{
			$existingKeyCols = @($ci.KeyColumns -split ',')
			$keyColsWithPartition = if ($PartitionColumn -in $existingKeyCols) { $existingKeyCols } else { $existingKeyCols + $PartitionColumn }
			$keyColList = ($keyColsWithPartition | ForEach-Object { "[$_]" }) -join ', '

			if (($ci.is_primary_key -or $ci.is_unique_constraint) -and $PartitionColumn -notin $existingKeyCols)
			{
				# PK/UNIQUE-Constraint muss neu definiert werden (DROP_EXISTING allein reicht hier nicht,
				# die Constraint-Spaltenliste muss die Partitionsspalte mit enthalten).
				$constraintType = if ($ci.is_primary_key) { 'PRIMARY KEY' } else { 'UNIQUE' }
				$ddl = @"
ALTER TABLE [$Schema].[$Table] DROP CONSTRAINT [$($ci.IndexName)];
ALTER TABLE [$Schema].[$Table] ADD CONSTRAINT [$($ci.IndexName)] $constraintType CLUSTERED ($keyColList)
    ON [$($scheme.PartitionSchemeName)]([$PartitionColumn]);
"@
			}
			else
			{
				$uniqueKw = if ($ci.is_unique) { 'UNIQUE ' } else { '' }
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
