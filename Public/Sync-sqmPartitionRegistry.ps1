<#
.SYNOPSIS
    Gleicht master.dbo.sqm_PartitionRegistry von einer Instanz auf die anderen AlwaysOn-Replikate ab.

.DESCRIPTION
    Die Registry liegt in master und wird von AlwaysOn NICHT repliziert. Nach einem Failover hat
    der neue Primary sonst keine (oder eine veraltete) Registry, und die Wartungs-Jobs
    (sqmPartitionExtendWindow / sqmPartitionRetentionWindow) wuerden ins Leere laufen.

    Diese Funktion liest die Registry der Quell-Instanz (-SqlInstance, normalerweise der Primary
    oder der Listener) und gleicht sie per MERGE auf die Ziele ab:
      - fehlende Zeilen werden eingefuegt, abweichende Konfigurationsspalten aktualisiert,
      - Zeilen, die auf dem Ziel existieren, aber in der Quelle fehlen, werden entfernt
        (Quelle ist massgeblich; mit -NoDelete abschaltbar),
      - die Laufzeit-Spalten LastExtendedAt/LastRetentionRunAt werden NICHT ueberschrieben
        (jedes Replikat fuehrt sie fuer seine eigenen Job-Laeufe).
    Die Registry-Tabelle wird auf dem Ziel bei Bedarf angelegt (Install-sqmPartitionMaintenanceProcs).

    Ohne -TargetInstance werden alle anderen Replikate der Verfuegbarkeitsgruppe(n) der Quelle
    ermittelt. Ohne AlwaysOn passiert nichts (Rueckgabe: leer).

    Nach jeder Aenderung an der Registry (Register-sqmPartitionTable, Remove-sqmPartitionRegistration,
    Konvertierung) erneut ausfuehren.

.PARAMETER SqlInstance
    Quell-Instanz (Primary oder Listener).
.PARAMETER TargetInstance
    Explizite Ziel-Instanz(en). Ohne Angabe: alle anderen AG-Replikate der Quelle.
.PARAMETER NoDelete
    Zeilen, die nur auf dem Ziel existieren, nicht entfernen.
.PARAMETER SqlCredential
    Optionales PSCredential (fuer Quelle und Ziele).

.EXAMPLE
    Sync-sqmPartitionRegistry -SqlInstance "AGLISTENER01" -WhatIf

.EXAMPLE
    Sync-sqmPartitionRegistry -SqlInstance "SQL01" -TargetInstance "SQL02"
#>
function Sync-sqmPartitionRegistry
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $false)]
		[string[]]$TargetInstance,

		[Parameter(Mandatory = $false)]
		[switch]$NoDelete,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$functionName = $MyInvocation.MyCommand.Name
	$mod = Get-Module -Name sqmPartitionTool

	if (-not $TargetInstance)
	{
		$replicaParams = @{ SqlInstance = $SqlInstance }
		if ($SqlCredential) { $replicaParams['SqlCredential'] = $SqlCredential }
		$replicas = @(& $mod { param($p) Get-sqmAgReplica @p } $replicaParams)
		if ($replicas.Count -eq 0)
		{
			Invoke-sqmLogging -Message "'$SqlInstance' gehoert keiner Verfuegbarkeitsgruppe an - keine Registry-Synchronisation noetig." -FunctionName $functionName -Level "INFO"
			return @()
		}
		# Die Quelle selbst herausfiltern (IsLocal aus Sicht der verbundenen Instanz; beim Listener
		# ist das der Primary).
		$TargetInstance = @($replicas | Where-Object { -not $_.IsLocal } | Select-Object -ExpandProperty ReplicaServerName -Unique)
		if ($TargetInstance.Count -eq 0) { return @() }
	}

	$getParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $getParams['SqlCredential'] = $SqlCredential }
	$rows = @(Get-sqmPartitionRegistry @getParams)

	function _Lit($v, [bool]$isString)
	{
		if ($null -eq $v -or $v -is [System.DBNull]) { return 'NULL' }
		if ($isString) { return "N'" + ([string]$v).Replace("'", "''") + "'" }
		return [string][int]$v
	}

	$valueRows = foreach ($r in $rows)
	{
		'(' + (@(
				(_Lit $r.DatabaseName $true), (_Lit $r.SchemaName $true), (_Lit $r.TableName $true),
				(_Lit $r.PartitionColumn $true), (_Lit $r.PartitionFunctionName $true), (_Lit $r.PartitionSchemeName $true),
				(_Lit $r.Granularity $true), (_Lit $r.BoundaryType $true), (_Lit $r.SurrogateDateFormat $true),
				(_Lit $r.FilegroupStrategy $true), (_Lit $r.FutureBufferPeriods $false),
				(_Lit $r.RetentionValue $false), (_Lit $r.RetentionUnit $true),
				(_Lit $r.ArchiveEnabled $false), (_Lit $r.ArchiveDatabaseName $true), (_Lit $r.ArchiveSchemaName $true),
				(_Lit $r.ArchiveBatchSize $false), (_Lit $r.DataCompression $true), (_Lit $r.IsActive $false)
			) -join ', ') + ')'
	}

	$cols = 'DatabaseName, SchemaName, TableName, PartitionColumn, PartitionFunctionName, PartitionSchemeName, Granularity, BoundaryType, SurrogateDateFormat, FilegroupStrategy, FutureBufferPeriods, RetentionValue, RetentionUnit, ArchiveEnabled, ArchiveDatabaseName, ArchiveSchemaName, ArchiveBatchSize, DataCompression, IsActive'
	$deleteClause = if ($NoDelete) { '' } else { 'WHEN NOT MATCHED BY SOURCE THEN DELETE' }

	# Leere Quelle: typisierte Leer-Menge, damit MERGE (und ggf. DELETE) trotzdem laeuft.
	$sourceBlock = if ($valueRows) { "USING (VALUES`n" + ($valueRows -join ",`n") + "`n) AS src ($cols)" }
	else { "USING (SELECT $cols FROM master.dbo.sqm_PartitionRegistry WHERE 1 = 0) AS src" }

	$mergeSql = @"
MERGE master.dbo.sqm_PartitionRegistry AS tgt
$sourceBlock
    ON tgt.DatabaseName = src.DatabaseName AND tgt.SchemaName = src.SchemaName AND tgt.TableName = src.TableName
WHEN MATCHED THEN UPDATE SET
    PartitionColumn = src.PartitionColumn, PartitionFunctionName = src.PartitionFunctionName,
    PartitionSchemeName = src.PartitionSchemeName, Granularity = src.Granularity, BoundaryType = src.BoundaryType,
    SurrogateDateFormat = src.SurrogateDateFormat, FilegroupStrategy = src.FilegroupStrategy,
    FutureBufferPeriods = src.FutureBufferPeriods, RetentionValue = src.RetentionValue, RetentionUnit = src.RetentionUnit,
    ArchiveEnabled = src.ArchiveEnabled, ArchiveDatabaseName = src.ArchiveDatabaseName,
    ArchiveSchemaName = src.ArchiveSchemaName, ArchiveBatchSize = src.ArchiveBatchSize,
    DataCompression = src.DataCompression, IsActive = src.IsActive
WHEN NOT MATCHED BY TARGET THEN INSERT ($cols)
    VALUES (src.DatabaseName, src.SchemaName, src.TableName, src.PartitionColumn, src.PartitionFunctionName, src.PartitionSchemeName,
            src.Granularity, src.BoundaryType, src.SurrogateDateFormat, src.FilegroupStrategy, src.FutureBufferPeriods,
            src.RetentionValue, src.RetentionUnit, src.ArchiveEnabled, src.ArchiveDatabaseName, src.ArchiveSchemaName,
            src.ArchiveBatchSize, src.DataCompression, src.IsActive)
$deleteClause;
"@

	$results = [System.Collections.Generic.List[object]]::new()
	foreach ($target in $TargetInstance)
	{
		$action = "Registry ($($rows.Count) Zeile(n)) von '$SqlInstance' abgleichen"
		if (-not $PSCmdlet.ShouldProcess($target, $action))
		{
			$results.Add([PSCustomObject]@{ SourceInstance = $SqlInstance; TargetInstance = $target; Rows = $rows.Count; Status = 'WhatIf' })
			continue
		}
		try
		{
			$tp = @{ SqlInstance = $target }
			if ($SqlCredential) { $tp['SqlCredential'] = $SqlCredential }
			$installParams = @{ SqlInstance = $target; EnableException = $true }
			if ($SqlCredential) { $installParams['SqlCredential'] = $SqlCredential }
			& $mod { param($p) Install-sqmPartitionMaintenanceProcs @p } $installParams | Out-Null

			Invoke-DbaQuery @tp -Database master -Query $mergeSql -ErrorAction Stop -EnableException
			Invoke-sqmLogging -Message "Registry von '$SqlInstance' auf '$target' abgeglichen ($($rows.Count) Zeile(n))." -FunctionName $functionName -Level "INFO"
			$results.Add([PSCustomObject]@{ SourceInstance = $SqlInstance; TargetInstance = $target; Rows = $rows.Count; Status = 'Synced' })
		}
		catch
		{
			$msg = "Registry-Abgleich auf '$target' fehlgeschlagen: $($_.Exception.Message)"
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
			$results.Add([PSCustomObject]@{ SourceInstance = $SqlInstance; TargetInstance = $target; Rows = $rows.Count; Status = "Failed: $($_.Exception.Message)" })
		}
	}
	return $results.ToArray()
}
