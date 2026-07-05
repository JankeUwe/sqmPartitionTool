<#
.SYNOPSIS
	Gibt per DBCC SHRINKFILE Speicherplatz einer Datenbank-Datei(-Gruppe) auf dem Datentraeger frei.

.DESCRIPTION
	Wird von Invoke-sqmTableArchiveMigration (-PurgeSourceAfterArchive) und
	Invoke-sqmTablePartitionConversion (-Method BatchedSwap) verwendet, um nach dem Loeschen
	bereits sicher kopierter Zeilen den frei gewordenen Speicherplatz auf dem SAN/Datentraeger
	tatsaechlich zurueckzugewinnen - ohne das waere Platz zwar innerhalb der Datenbank frei, die
	Datei(en) auf der physischen Platte blieben aber genauso gross.

	Standardmaessig TRUNCATEONLY (schnell, keine Seitenverschiebung, gibt aber NUR am Dateiende
	freien Platz zurueck). -Aggressive fuehrt einen vollen DBCC SHRINKFILE ohne TRUNCATEONLY aus
	(verschiebt Seiten, gibt mehr Platz frei, fragmentiert dafuer die verbleibenden Indizes - ein
	Index-Rebuild danach ist empfehlenswert, sobald wieder genug Platz dafuer vorhanden ist).

	Ist -FilegroupName angegeben, werden NUR die Dateien dieser Filegroup geshrinkt (aufgeloest
	ueber sys.filegroups/sys.database_files). Ohne -FilegroupName werden ALLE Datendateien
	(type = 0) der Datenbank geshrinkt - das betrifft dann ggf. auch andere Tabellen/Objekte, die
	auf denselben Dateien liegen (wird geloggt).

.PARAMETER SqlInstance
	Ziel-Instanz.

.PARAMETER Database
	Datenbank, deren Datei(en) geshrinkt werden sollen.

.PARAMETER FilegroupName
	Optionale Filegroup - ohne Angabe werden alle Datendateien der Datenbank verwendet.

.PARAMETER Aggressive
	Voller DBCC SHRINKFILE (ohne TRUNCATEONLY) - verschiebt Seiten, mehr Platzgewinn, fragmentiert
	aber die verbleibenden Indizes.

.PARAMETER SqlCredential
	Optionales PSCredential.

.PARAMETER EnableException
	Fehler sofort als Ausnahme ausloesen.

.OUTPUTS
	Array von PSCustomObject je Datei: LogicalName, PhysicalName, SizeBeforeMB, SizeAfterMB, ReclaimedMB.

.NOTES
	Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool). Intern verwendet - normalerweise nicht
	direkt aufgerufen.
#>
function Invoke-sqmFileSpaceShrink
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $true)]
		[string]$Database,

		[Parameter(Mandatory = $false)]
		[string]$FilegroupName,

		[Parameter(Mandatory = $false)]
		[switch]$Aggressive,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = 'Invoke-sqmFileSpaceShrink'
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	try
	{
		# 1. Zieldatei(en) ermitteln -------------------------------------------------------------
		if ($FilegroupName)
		{
			$fileQuery = @"
SELECT df.name AS LogicalName, df.physical_name AS PhysicalName, df.size * 8.0 / 1024 AS SizeMB
FROM sys.database_files df
JOIN sys.filegroups fg ON fg.data_space_id = df.data_space_id
WHERE df.type = 0 AND fg.name = N'$FilegroupName';
"@
			$scopeDesc = "Filegroup '$FilegroupName'"
		}
		else
		{
			$fileQuery = "SELECT name AS LogicalName, physical_name AS PhysicalName, size * 8.0 / 1024 AS SizeMB FROM sys.database_files WHERE type = 0;"
			$scopeDesc = 'alle Datendateien'
		}

		$files = @(Invoke-DbaQuery @connParams -Query $fileQuery -ErrorAction Stop -EnableException)
		if ($files.Count -eq 0)
		{
			$msg = "Keine Datendatei(en) gefunden fuer '$Database' ($scopeDesc)."
			Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "WARNING"
			return @()
		}

		if (-not $FilegroupName)
		{
			Invoke-sqmLogging -Message "Kein -FilegroupName angegeben - shrinke ALLE Datendateien von '$Database' ($($files.Count) Datei(en)). Betrifft ggf. auch andere Tabellen/Objekte auf denselben Dateien." -FunctionName $functionName -Level "WARNING"
		}

		$shrinkMode = if ($Aggressive) { 'ohne TRUNCATEONLY (Seitenverschiebung, fragmentiert Indizes)' } else { 'mit TRUNCATEONLY (nur Dateiende, keine Fragmentierung)' }
		$action = "$($files.Count) Datendatei(en) von '$Database' shrinken ($shrinkMode)"
		if (-not $PSCmdlet.ShouldProcess($Database, $action)) { return @() }

		if ($Aggressive)
		{
			Invoke-sqmLogging -Message "AGGRESSIVER Shrink angefordert ($scopeDesc) - verschiebt Seiten und fragmentiert die verbleibenden Indizes. Ein Index-Rebuild danach wird empfohlen, sobald wieder Platz dafuer vorhanden ist." -FunctionName $functionName -Level "WARNING"
		}

		# 2. Je Datei shrinken ---------------------------------------------------------------------
		$results = [System.Collections.Generic.List[object]]::new()
		foreach ($f in $files)
		{
			$shrinkSql = if ($Aggressive) { "DBCC SHRINKFILE(N'$($f.LogicalName)');" } else { "DBCC SHRINKFILE(N'$($f.LogicalName)', TRUNCATEONLY);" }
			try
			{
				Invoke-DbaQuery @connParams -Query $shrinkSql -ErrorAction Stop -EnableException | Out-Null
			}
			catch
			{
				Invoke-sqmLogging -Message "DBCC SHRINKFILE fuer '$($f.LogicalName)' fehlgeschlagen: $($_.Exception.Message)" -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				continue
			}

			$sizeAfterRow = Invoke-DbaQuery @connParams -Query "SELECT size * 8.0 / 1024 AS SizeMB FROM sys.database_files WHERE name = N'$($f.LogicalName)';" -ErrorAction Stop -EnableException
			$sizeAfter = [decimal]$sizeAfterRow.SizeMB
			$reclaimed = [decimal]$f.SizeMB - $sizeAfter

			Invoke-sqmLogging -Message "'$($f.LogicalName)' geshrinkt: $([math]::Round([decimal]$f.SizeMB,1)) MB -> $([math]::Round($sizeAfter,1)) MB ($([math]::Round($reclaimed,1)) MB zurueckgewonnen)." -FunctionName $functionName -Level "INFO"

			$results.Add([PSCustomObject]@{
					LogicalName  = $f.LogicalName
					PhysicalName = $f.PhysicalName
					SizeBeforeMB = [decimal]$f.SizeMB
					SizeAfterMB  = $sizeAfter
					ReclaimedMB  = $reclaimed
				})
		}

		return $results.ToArray()
	}
	catch
	{
		$msg = "Fehler in ${functionName}: $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw }
		throw
	}
}
