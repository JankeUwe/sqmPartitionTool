<#
.SYNOPSIS
    Deployt/aktualisiert die Invoke-sqmTableArchiveMigration-Infrastruktur (Log-Tabelle + Batch-Prozedur) in einer Quelldatenbank.

.DESCRIPTION
    Liest alle .sql-Dateien aus dem sql\archive\-Unterordner des Moduls und fuehrt sie gegen
    -Database (die QUELLDATENBANK der jeweiligen Migration) aus - im Unterschied zu
    Install-sqmPartitionMaintenanceProcs, das seine .sql-Dateien aus sql\ direkt liest und immer
    nach master deployed. Getrennter Ordner + getrennter Installer, damit
    Install-sqmPartitionMaintenanceProcs (das sql\ nicht rekursiv durchsucht) diese Dateien nicht
    versehentlich mit nach master deployed.

    Jede Datei wird an "GO"-Zeilen in einzelne Batches zerlegt (Invoke-DbaQuery versteht "GO" nicht
    als Batch-Trenner). Tabellen-DDL nutzt CREATE-IF-NOT-EXISTS (idempotent, bestehende Log-Daten
    bleiben erhalten); die Prozedur nutzt CREATE OR ALTER (immer aktuell).

    Wird intern von Invoke-sqmTableArchiveMigration aufgerufen - normalerweise nicht direkt zu
    benutzen.

.PARAMETER SqlInstance
    Ziel-Instanz.

.PARAMETER Database
    Quelldatenbank, in die deployed wird.

.PARAMETER SqlCredential
    Optionales PSCredential.

.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen statt nur zu loggen.
#>
function Install-sqmArchiveMigrationInfra
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $true)]
		[string]$Database,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = 'Install-sqmArchiveMigrationInfra'
	$sqlDir = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'sql') 'archive'

	if (-not (Test-Path $sqlDir))
	{
		$msg = "sql\archive-Ordner nicht gefunden: $sqlDir"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw $msg }
		return $false
	}

	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	# Deploy-Reihenfolge: Log-Tabelle zuerst (die Prozedur verweist darauf), danach alphabetisch
	# alle uebrigen .sql-Dateien.
	$files = Get-ChildItem -Path $sqlDir -Filter '*.sql' -File
	$logTableFile = $files | Where-Object { $_.Name -eq 'sqm_ArchiveMonthLog.table.sql' }
	$otherFiles   = $files | Where-Object { $_.Name -ne 'sqm_ArchiveMonthLog.table.sql' } | Sort-Object Name
	$orderedFiles = @($logTableFile) + @($otherFiles) | Where-Object { $_ }

	$allOk = $true
	foreach ($file in $orderedFiles)
	{
		$raw = Get-Content -Path $file.FullName -Raw
		$batches = [regex]::Split($raw, '(?im)^\s*GO\s*$') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

		foreach ($batch in $batches)
		{
			try
			{
				Invoke-DbaQuery @connParams -Database $Database -Query $batch -ErrorAction Stop
			}
			catch
			{
				$msg = "Fehler beim Deployen von '$($file.Name)' auf '$SqlInstance.$Database': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				$allOk = $false
			}
		}

		if ($allOk)
		{
			Invoke-sqmLogging -Message "'$($file.Name)' auf '$SqlInstance.$Database' deployed." -FunctionName $functionName -Level "INFO"
		}
	}

	return $allOk
}
