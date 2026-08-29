<#
.SYNOPSIS
    Entfernt alle Partitionen einer Tabelle, deren Daten aelter als eine angegebene Aufbewahrung
    (z.B. 120 Monate/10 Jahre) sind - ad-hoc, sofort, fuer genau eine Tabelle.

.DESCRIPTION
    Der instanzweite SQL-Agent-Job (New-sqmPartitionRetentionJob) wendet -RetentionValue/
    -RetentionUnit aus master.dbo.sqm_PartitionRegistry automatisch auf ALLE registrierten
    Tabellen an, aber nur ueber seinen eigenen Zeitplan (Standard: woechentlich). Diese Funktion
    ist das manuelle Gegenstueck: EINE Tabelle, EIN sofortiger Aufruf, mit einem selbst gewaehlten
    Cutoff - fuer Tests, einmalige Aufraeumaktionen (z.B. "wir brauchen JETZT Platz"), oder um vor
    dem Einrichten des automatischen Jobs den Ablauf mit dem tatsaechlich gewuenschten Wert zu
    pruefen. Funktioniert unabhaengig davon, ob die Tabelle in der Registry eingetragen ist.

    Ruft intern wiederholt Invoke-sqmPartitionArchive auf (SWITCH PARTITION + optional Archivierung
    + MERGE RANGE - siehe dort fuer den vollen Ablauf), einmal pro Partition, von der aeltesten
    beginnend, bis keine verbleibende Partition (ausser der letzten Zukunfts-Catch-All-Partition)
    mehr aelter als der Cutoff ist. Jede Partition wird dabei entfernt (Boundary verschwindet,
    Partitionsanzahl sinkt) - im Gegensatz zu SQL Servers ALTER TABLE ... TRUNCATE PARTITION, das
    nur die Daten leeren wuerde, aber die Partition/Boundary selbst unveraendert liesse.

    Cutoff-Vergleich ohne Registry-Abhaengigkeit: der Boundary-Wert jeder Partition (aus
    Get-sqmPartitionStatus) wird direkt anhand seines .NET-Laufzeittyps ausgewertet - ein
    [datetime] wird direkt verglichen, ein String/Int-Surrogatschluessel wird anhand seiner
    Ziffernlaenge (6 = yyyyMM, 8 = yyyyMMdd) geparst. Kein -BoundaryType/-SurrogateDateFormat-
    Parameter noetig, funktioniert also auch fuer Tabellen, die nicht (mehr) registriert sind.

    Ein einziges ShouldProcess VOR dem Loop (mit der vorab ermittelten Anzahl zu entfernender
    Partitionen) statt einer Rueckfrage pro Partition - die einzelnen Invoke-sqmPartitionArchive-
    Aufrufe im Loop laufen mit -Confirm:$false, um doppelte Bestaetigungen zu vermeiden.

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER Database
    Datenbank der partitionierten Tabelle.
.PARAMETER Schema
    Schema.
.PARAMETER Table
    Tabellenname (muss bereits partitioniert sein).
.PARAMETER RetentionValue
    Aufbewahrungsdauer als Zahl, z.B. 120.
.PARAMETER RetentionUnit
    Months oder Years - zusammen mit -RetentionValue der Cutoff (z.B. 120 + Months = alles aelter
    als 10 Jahre wird entfernt).
.PARAMETER ArchiveDatabaseName
    Wenn angegeben: Daten jeder entfernten Partition vor dem Entfernen in diese Datenbank kopieren
    (muss auf derselben Instanz liegen) - direkt an Invoke-sqmPartitionArchive durchgereicht. Ohne
    Angabe werden die Daten nur entfernt (kein Archiv).
.PARAMETER ArchiveSchemaName
    Zielschema in der Archiv-Datenbank. Standard: gleiches Schema wie die Quelltabelle.
.PARAMETER ArchiveBatchSize
    Batchgroesse fuer die Kopie in die Archiv-Datenbank je Partition. Standard: 50000.
.PARAMETER DataCompression
    None (Standard), Row oder Page - nur relevant, wenn die Archiv-Tabelle in diesem Lauf neu
    angelegt wird (siehe Invoke-sqmPartitionArchive).
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    Invoke-sqmPartitionRetention -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
        -Table "OrderHistory" -RetentionValue 120 -RetentionUnit Months

.EXAMPLE
    # 10 Jahre, mit Archivierung statt reinem Loeschen
    Invoke-sqmPartitionRetention -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" `
        -Table "OrderHistory" -RetentionValue 10 -RetentionUnit Years -ArchiveDatabaseName "SalesArchive"

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), Invoke-sqmPartitionArchive,
    Get-sqmPartitionStatus. Aktualisiert master.dbo.sqm_PartitionRegistry.LastRetentionRunAt fuer
    die Tabelle, falls dort ein Eintrag existiert (rein informativ, keine Voraussetzung).
#>
function Invoke-sqmPartitionRetention
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
		[int]$RetentionValue,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Months', 'Years')]
		[string]$RetentionUnit,

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
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }
	if (-not $ArchiveSchemaName) { $ArchiveSchemaName = $Schema }

	# Boundary-Wert (aus Get-sqmPartitionStatus) anhand seines Laufzeittyps in ein datetime fuer den
	# Cutoff-Vergleich umwandeln - kein Registry-Lookup fuer BoundaryType/SurrogateDateFormat noetig.
	# Ziffernlaenge des Surrogatschluessels entscheidet zwischen yyyyMM (6) und yyyyMMdd (8), analog
	# zu den beiden einzigen -SurrogateDateFormat-Werten, die dieses Modul ueberhaupt kennt.
	function _BoundaryToDate($value)
	{
		if ($value -is [datetime]) { return $value }
		$s = ([string]$value).Trim()
		$fmt = if ($s.Length -le 6) { 'yyyyMM' } else { 'yyyyMMdd' }
		return [datetime]::ParseExact($s.PadLeft($fmt.Length, '0'), $fmt, $null)
	}

	try
	{
		$cutoff = if ($RetentionUnit -eq 'Years') { (Get-Date).AddYears(-$RetentionValue) } else { (Get-Date).AddMonths(-$RetentionValue) }

		$statusParams = @{ SqlInstance = $SqlInstance; Database = $Database; Schema = $Schema; Table = $Table }
		if ($SqlCredential) { $statusParams['SqlCredential'] = $SqlCredential }
		$status = Get-sqmPartitionStatus @statusParams | Sort-Object PartitionNumber
		if (-not $status) { throw "'$Schema.$Table' ist nicht partitioniert." }

		# Vorab-Zaehlung fuer EINE ShouldProcess-Rueckfrage (statt einer pro Partition) - die letzte
		# Partition (Zukunfts-Catch-All) wird nie mitgezaehlt/entfernt, siehe Invoke-sqmPartitionArchive.
		$toRemove = 0
		for ($i = 0; $i -lt $status.Count - 1; $i++)
		{
			if ((_BoundaryToDate $status[$i].UpperBoundaryValue) -gt $cutoff) { break }
			$toRemove++
		}

		if ($toRemove -eq 0)
		{
			Invoke-sqmLogging -Message "'$Schema.$Table': keine Partition aelter als $($cutoff.ToString('yyyy-MM-dd')) ($RetentionValue $RetentionUnit) - nichts zu tun." -FunctionName $functionName -Level "INFO"
			return [PSCustomObject]@{
				SchemaName = $Schema; TableName = $Table; Cutoff = $cutoff
				PartitionsRemoved = 0; RowsRemoved = 0; ArchivedRows = 0; Results = @(); Status = 'NothingToDo'
			}
		}

		$action = "$toRemove Partition(en) von '$Schema.$Table' aelter als $($cutoff.ToString('yyyy-MM-dd')) ($RetentionValue $RetentionUnit) entfernen" +
		$(if ($ArchiveDatabaseName) { " (mit Archivierung nach '$ArchiveDatabaseName.$ArchiveSchemaName.$Table')" } else { '' })
		if (-not $PSCmdlet.ShouldProcess($Database, $action))
		{
			return [PSCustomObject]@{
				SchemaName = $Schema; TableName = $Table; Cutoff = $cutoff
				PartitionsRemoved = 0; RowsRemoved = 0; ArchivedRows = 0; Results = @(); Status = 'WhatIf'
			}
		}
		Invoke-sqmLogging -Message $action -FunctionName $functionName -Level "INFO"

		$archiveParams = @{
			SqlInstance = $SqlInstance; Database = $Database; Schema = $Schema; Table = $Table
			ArchiveBatchSize = $ArchiveBatchSize; DataCompression = $DataCompression
			Confirm = $false; ErrorAction = 'Stop'; EnableException = $true
		}
		if ($SqlCredential) { $archiveParams['SqlCredential'] = $SqlCredential }
		if ($ArchiveDatabaseName)
		{
			$archiveParams['ArchiveDatabaseName'] = $ArchiveDatabaseName
			$archiveParams['ArchiveSchemaName'] = $ArchiveSchemaName
		}

		# Status wird JEDE Iteration neu gelesen statt einmal vorab geplant - jedes MERGE RANGE
		# nummeriert alle nachfolgenden Partitionen um eins runter (siehe sqm_PartitionRetentionSweep).
		$results = [System.Collections.Generic.List[PSCustomObject]]::new()
		$removedCount = 0
		while ($removedCount -lt $toRemove)
		{
			$liveStatus = Get-sqmPartitionStatus @statusParams | Sort-Object PartitionNumber
			if (-not $liveStatus -or $liveStatus.Count -le 1) { break }
			$oldest = $liveStatus[0]
			if ((_BoundaryToDate $oldest.UpperBoundaryValue) -gt $cutoff) { break }

			$archiveParams['PartitionNumber'] = [int]$oldest.PartitionNumber
			$result = Invoke-sqmPartitionArchive @archiveParams
			$results.Add($result)
			$removedCount++
			Invoke-sqmLogging -Message "'$Schema.$Table': Partition $($result.PartitionNumber) entfernt ($($result.RowsRemoved) Zeile(n))." -FunctionName $functionName -Level "INFO"
		}

		# LastRetentionRunAt ist rein informativ (zeigt in der Registry, dass diese Tabelle gerade
		# manuell bereinigt wurde) - kein Fehlschlag des eigentlichen Vorgangs, falls kein Eintrag
		# existiert oder das Update selbst scheitert.
		try
		{
			$regUpdate = "UPDATE master.dbo.sqm_PartitionRegistry SET LastRetentionRunAt = SYSDATETIME() " +
			"WHERE DatabaseName = N'$Database' AND SchemaName = N'$Schema' AND TableName = N'$Table' " +
			"AND EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'master.dbo.sqm_PartitionRegistry') AND type = 'U');"
			Invoke-DbaQuery @connParams -Database master -Query $regUpdate -ErrorAction Stop
		}
		catch { }

		Invoke-sqmLogging -Message "'$Schema.$Table': $removedCount Partition(en) entfernt, $(($results | Measure-Object -Property RowsRemoved -Sum).Sum) Zeile(n) insgesamt." -FunctionName $functionName -Level "INFO"

		return [PSCustomObject]@{
			SchemaName        = $Schema
			TableName         = $Table
			Cutoff            = $cutoff
			PartitionsRemoved = $removedCount
			RowsRemoved       = [int64](($results | Measure-Object -Property RowsRemoved -Sum).Sum)
			ArchivedRows      = [int64](($results | Measure-Object -Property ArchivedRows -Sum).Sum)
			Results           = $results
			Status            = 'Success'
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
