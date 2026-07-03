<#
.SYNOPSIS
    Deployt/aktualisiert die sqmPartitionTool-Infrastruktur (Registry-Tabelle + Wartungs-Prozeduren) in master.

.DESCRIPTION
    Liest alle .sql-Dateien aus dem sql\-Ordner des Moduls und fuehrt sie gegen master auf der
    Zielinstanz aus. Jede Datei wird an "GO"-Zeilen in einzelne Batches zerlegt (Invoke-DbaQuery
    versteht "GO" nicht als Batch-Trenner). Tabellen-DDL nutzt CREATE-IF-NOT-EXISTS (idempotent,
    bestehende Registry-Daten bleiben erhalten); Prozeduren nutzen CREATE OR ALTER (immer aktuell).

    Wird intern von New-sqmPartitionExtendJob, New-sqmPartitionRetentionJob und
    Invoke-sqmTablePartitionConversion aufgerufen - normalerweise nicht direkt zu benutzen.

.PARAMETER SqlInstance
    Ziel-Instanz.

.PARAMETER SqlCredential
    Optionales PSCredential.

.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen statt nur zu loggen.
#>
function Install-sqmPartitionMaintenanceProcs
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = 'Install-sqmPartitionMaintenanceProcs'
	$sqlDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'sql'

	if (-not (Test-Path $sqlDir))
	{
		$msg = "sql-Ordner nicht gefunden: $sqlDir"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		if ($EnableException) { throw $msg }
		return $false
	}

	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	# Deploy-Reihenfolge: Registry-Tabelle zuerst (Prozeduren verweisen darauf),
	# danach alphabetisch alle uebrigen .sql-Dateien.
	$files = Get-ChildItem -Path $sqlDir -Filter '*.sql' -File
	$registryFile = $files | Where-Object { $_.Name -eq 'sqm_PartitionRegistry.table.sql' }
	$otherFiles   = $files | Where-Object { $_.Name -ne 'sqm_PartitionRegistry.table.sql' } | Sort-Object Name
	$orderedFiles = @($registryFile) + @($otherFiles) | Where-Object { $_ }

	$allOk = $true
	foreach ($file in $orderedFiles)
	{
		$raw = Get-Content -Path $file.FullName -Raw
		# In Batches an "GO" auf eigener Zeile zerlegen (case-insensitive, optionale Leerzeichen)
		$batches = [regex]::Split($raw, '(?im)^\s*GO\s*$') | ForEach-Object { $_.Trim() } | Where-Object { $_ }

		foreach ($batch in $batches)
		{
			try
			{
				Invoke-DbaQuery @connParams -Database master -Query $batch -ErrorAction Stop
			}
			catch
			{
				$msg = "Fehler beim Deployen von '$($file.Name)' auf '$SqlInstance': $($_.Exception.Message)"
				Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
				if ($EnableException) { throw }
				$allOk = $false
			}
		}

		if ($allOk)
		{
			Invoke-sqmLogging -Message "'$($file.Name)' auf '$SqlInstance' deployed." -FunctionName $functionName -Level "INFO"
		}
	}

	return $allOk
}
