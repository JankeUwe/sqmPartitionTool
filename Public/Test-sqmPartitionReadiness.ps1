<#
.SYNOPSIS
    Pre-Flight-Pruefung, ob eine Tabelle sicher partitioniert werden kann.

.DESCRIPTION
    Prueft vor einer Konvertierung:
    - Tabelle existiert und ist nicht bereits partitioniert
    - Partitionsspalte existiert, Datentyp ist fuer Partition Functions zulaessig
    - Clustered Index vorhanden oder Heap (beides unterstuetzt, wird nur gemeldet)
    - Ist der Clustered Index ein PRIMARY KEY/UNIQUE-Constraint, DER DIE PARTITIONSSPALTE NICHT
      ENTHAELT: kritische Warnung - SQL Server verlangt, dass ein zur Partitionierung verwendeter
      eindeutiger Index die Partitionsspalte enthaelt. Das aendert die Eindeutigkeits-Semantik
      (z.B. PK wird zusammengesetzt) und erfordert -AllowKeyChange bei
      Invoke-sqmTablePartitionConversion.
    - Fremdschluessel, die auf diese Tabelle verweisen (Warnung, kein Blocker - erschwert aber
      spaeter SWITCH PARTITION).
    - Freier Speicherplatz in der Datenbank (grobe Schaetzung, ca. 1.2x Tabellengroesse fuer den
      Index-Rebuild noetig).

    Gibt ein Ergebnisobjekt mit IsReady (bool), Errors (blockierend) und Warnings (nicht
    blockierend, aber zu beachten) zurueck.

.PARAMETER SqlInstance
    Ziel-Instanz.

.PARAMETER Database
    Zieldatenbank.

.PARAMETER Schema
    Schema der Tabelle.

.PARAMETER Table
    Tabellenname.

.PARAMETER PartitionColumn
    Geplante Partitionsspalte.

.PARAMETER SqlCredential
    Optionales PSCredential.

.EXAMPLE
    Test-sqmPartitionReadiness -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" -PartitionColumn "OrderDate"

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), Get-sqmPartitionCandidateTable,
    Get-sqmPartitionColumnCandidate.
#>
function Test-sqmPartitionReadiness
{
	[CmdletBinding()]
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

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$errorsList = [System.Collections.Generic.List[string]]::new()
	$warningsList = [System.Collections.Generic.List[string]]::new()

	Invoke-sqmLogging -Message "Pre-Flight-Pruefung '$Schema.$Table' (Spalte '$PartitionColumn') auf '$SqlInstance'." -FunctionName $functionName -Level "INFO"

	# 1. Tabelle existiert, nicht bereits partitioniert
	$candParams = @{ SqlInstance = $SqlInstance; Database = $Database; IncludeAlreadyPartitioned = $true }
	if ($SqlCredential) { $candParams['SqlCredential'] = $SqlCredential }
	$tableInfo = Get-sqmPartitionCandidateTable @candParams | Where-Object { $_.SchemaName -eq $Schema -and $_.TableName -eq $Table } | Select-Object -First 1

	if (-not $tableInfo)
	{
		$errorsList.Add("Tabelle '$Schema.$Table' nicht gefunden in '$Database'.")
	}
	else
	{
		if ($tableInfo.IsPartitioned)
		{
			$errorsList.Add("Tabelle '$Schema.$Table' ist bereits partitioniert.")
		}
	}

	# 2. Partitionsspalte existiert und ist typkompatibel
	$colParams = @{ SqlInstance = $SqlInstance; Database = $Database; Schema = $Schema; Table = $Table }
	if ($SqlCredential) { $colParams['SqlCredential'] = $SqlCredential }
	$columns = Get-sqmPartitionColumnCandidate @colParams
	$targetCol = $columns | Where-Object { $_.ColumnName -eq $PartitionColumn } | Select-Object -First 1

	if (-not $targetCol)
	{
		$errorsList.Add("Spalte '$PartitionColumn' nicht in '$Schema.$Table' gefunden.")
	}
	else
	{
		if (-not $targetCol.IsPartitionTypeCompatible)
		{
			$errorsList.Add("Datentyp '$($targetCol.DataType)' von '$PartitionColumn' ist fuer Partition Functions nicht zulaessig (LOB/XML/CLR/timestamp).")
		}
		if ($targetCol.IsNullable)
		{
			$warningsList.Add("'$PartitionColumn' ist NULL-faehig - NULL-Werte landen bei RANGE RIGHT in der am weitesten links liegenden Partition.")
		}

		# 3. Clustered Index / PK-Pruefung - hoechstes Risiko
		if ($tableInfo -and $tableInfo.HasClusteredIndex)
		{
			if ($targetCol.ClusteredIndexIsPk -and -not $targetCol.IsPrimaryKeyColumn)
			{
				$warningsList.Add("Clustered Index ist ein PRIMARY KEY/UNIQUE-Constraint, der '$PartitionColumn' NICHT enthaelt. SQL Server verlangt, dass ein zur Partitionierung genutzter eindeutiger Index die Partitionsspalte enthaelt - der PK wird zusammengesetzt (bestehende PK-Spalte(n) + '$PartitionColumn'). Erfordert -AllowKeyChange bei Invoke-sqmTablePartitionConversion.")
			}
		}
		else
		{
			$warningsList.Add("'$Schema.$Table' ist ein Heap (kein Clustered Index). Es wird ein neuer Clustered Index auf '$PartitionColumn' angelegt (oder -Method NewTableSwap fuer sehr grosse Heaps).")
		}
	}

	# 4. Fremdschluessel, die auf diese Tabelle verweisen
	try
	{
		$fkQuery = @"
SELECT fk.name AS ForeignKeyName, OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id) AS ReferencingTable
FROM sys.foreign_keys fk
WHERE fk.referenced_object_id = OBJECT_ID(N'$Schema.$Table')
"@
		$fks = Invoke-DbaQuery @connParams -Query $fkQuery -ErrorAction Stop
		if ($fks)
		{
			$fkList = ($fks | ForEach-Object { "$($_.ReferencingTable) ($($_.ForeignKeyName))" }) -join '; '
			$warningsList.Add("Fremdschluessel verweisen auf diese Tabelle: $fkList - kann spaeteres SWITCH PARTITION (Retention/Archivierung) erschweren.")
		}
	}
	catch
	{
		Invoke-sqmLogging -Message "Fremdschluessel-Pruefung fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
	}

	# 5. Freier Speicherplatz (grobe Schaetzung: ~1.2x Tabellengroesse fuer den Rebuild)
	if ($tableInfo)
	{
		try
		{
			$spaceQuery = @"
SELECT SUM(size * 8.0 / 1024) AS AllocatedMB,
       SUM(CASE WHEN max_size = -1 THEN 999999 ELSE (max_size - size) * 8.0 / 1024 END) AS FreeGrowthMB
FROM sys.database_files WHERE type = 0
"@
			$space = Invoke-DbaQuery @connParams -Query $spaceQuery -ErrorAction Stop
			$neededMB = [decimal]$tableInfo.SizeMB * 1.2
			if ($space -and $neededMB -gt 0 -and [decimal]$space.FreeGrowthMB -lt $neededMB -and [decimal]$space.FreeGrowthMB -lt 999999)
			{
				$warningsList.Add("Geschaetzter Platzbedarf fuer den Index-Rebuild (~$([math]::Round($neededMB,0)) MB) koennte den verfuegbaren Wachstumsspielraum der Datendateien uebersteigen - vor der Konvertierung pruefen.")
			}
		}
		catch
		{
			Invoke-sqmLogging -Message "Speicherplatz-Pruefung fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "WARNING"
		}
	}

	$isReady = ($errorsList.Count -eq 0)

	if (-not $isReady)
	{
		Invoke-sqmLogging -Message "Pre-Flight-Pruefung NICHT bestanden: $($errorsList -join ' | ')" -FunctionName $functionName -Level "ERROR"
	}
	elseif ($warningsList.Count -gt 0)
	{
		Invoke-sqmLogging -Message "Pre-Flight-Pruefung mit Warnungen bestanden: $($warningsList -join ' | ')" -FunctionName $functionName -Level "WARNING"
	}
	else
	{
		Invoke-sqmLogging -Message "Pre-Flight-Pruefung bestanden, keine Auffaelligkeiten." -FunctionName $functionName -Level "INFO"
	}

	return [PSCustomObject]@{
		SchemaName      = $Schema
		TableName       = $Table
		PartitionColumn = $PartitionColumn
		IsReady         = $isReady
		RequiresAllowKeyChange = [bool]($warningsList -match 'AllowKeyChange')
		IsHeap          = $tableInfo -and -not $tableInfo.HasClusteredIndex
		Errors          = $errorsList.ToArray()
		Warnings        = $warningsList.ToArray()
	}
}
