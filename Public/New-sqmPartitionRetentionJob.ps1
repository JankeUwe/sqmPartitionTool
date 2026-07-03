<#
.SYNOPSIS
    Legt den instanzweiten SQL-Agent-Job zur automatischen Partitions-Retention/Archivierung an.

.DESCRIPTION
    Erstellt EINEN Job fuer die ganze Instanz (nicht pro Tabelle), der woechentlich (Standard:
    Sonntag) jobs\Invoke-sqmPartitionRetentionSweep.ps1 per CmdExec-Step ausfuehrt. Das Skript
    loopt ueber alle aktiven sqm_PartitionRegistry-Eintraege mit konfigurierter Retention und
    entfernt (optional archiviert) per Invoke-sqmPartitionArchive alle vollstaendig abgelaufenen
    Partitionen - neue registrierte Tabellen werden automatisch beruecksichtigt, ohne den Job
    neu anzulegen.

    Nutzt bewusst PowerShell/Invoke-sqmPartitionArchive statt einer T-SQL-Prozedur (siehe
    Kommentar in jobs\Invoke-sqmPartitionRetentionSweep.ps1) - die Staging-Tabellen-Nachbildung
    fuer SWITCH PARTITION ist die riskanteste Logik im Modul und liegt dort bereits getestet vor.

    Woechentlich statt taeglich (wie beim Extend-Job), da eine Verzoegerung bei der Retention
    unkritisch ist (siehe Projektplan).

.PARAMETER SqlInstance
    Ziel-Instanz. Standard: aktueller Computername.
.PARAMETER JobName
    Job-Name. Standard: 'sqmPartitionRetentionWindow'.
.PARAMETER ScheduleTime
    Woechentliche Startzeit im Format 'HH:mm'. Standard: '03:00'.
.PARAMETER ScheduleDay
    Wochentag. Standard: 'Sunday'.
.PARAMETER JobCategory
    Job-Kategorie. Standard: 'Database Maintenance'.
.PARAMETER Update
    Ueberschreibt einen bestehenden Job gleichen Namens.
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    New-sqmPartitionRetentionJob -SqlInstance "SQL01"

.EXAMPLE
    New-sqmPartitionRetentionJob -SqlInstance "SQL01" -ScheduleDay Saturday -ScheduleTime "23:00" -Update

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool). Das Wrapper-Skript wird nach
    "C:\Program Files\WindowsPowerShell\Modules\sqmPartitionTool\jobs\
    Invoke-sqmPartitionRetentionSweep.ps1" deployed (analog zu sqmSQLTool\jobs\Sync-Job.ps1).
#>
function New-sqmPartitionRetentionJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[string]$JobName = 'sqmPartitionRetentionWindow',

		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]$ScheduleTime = '03:00',

		[Parameter(Mandatory = $false)]
		[ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
		[string]$ScheduleDay = 'Sunday',

		[Parameter(Mandatory = $false)]
		[string]$JobCategory = 'Database Maintenance',

		[Parameter(Mandatory = $false)]
		[switch]$Update,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$EnableException
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	try
	{
		# Wrapper-Skript an den installierten Modulpfad kopieren (Quelle liegt im Modul selbst).
		$modulePath = 'C:\Program Files\WindowsPowerShell\Modules\sqmPartitionTool'
		$jobsDir = Join-Path $modulePath 'jobs'
		if (-not (Test-Path $jobsDir)) { New-Item -ItemType Directory -Path $jobsDir -Force | Out-Null }
		$sourceScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'jobs\Invoke-sqmPartitionRetentionSweep.ps1'
		$deployedScript = Join-Path $jobsDir 'Invoke-sqmPartitionRetentionSweep.ps1'
		if (Test-Path $sourceScript) { Copy-Item -Path $sourceScript -Destination $deployedScript -Force }

		$psExePath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
		$command = "$psExePath -NoProfile -ExecutionPolicy Bypass -File `"$deployedScript`" -SqlInstance `"$SqlInstance`""

		$existingCat = Get-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue
		if (-not $existingCat) { New-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue | Out-Null }

		$existingJob = Get-DbaAgentJob @connParams -Job $JobName -ErrorAction SilentlyContinue
		if ($existingJob -and -not $Update)
		{
			Invoke-sqmLogging -Message "Job '$JobName' existiert bereits - unveraendert (kein -Update)." -FunctionName $functionName -Level "INFO"
			return [PSCustomObject]@{ SqlInstance = $SqlInstance; JobName = $JobName; Status = 'AlreadyExists' }
		}

		$action = if ($existingJob) { "Job '$JobName' aktualisieren" } else { "Job '$JobName' anlegen (woechentlich $ScheduleDay $ScheduleTime)" }
		if (-not $PSCmdlet.ShouldProcess($SqlInstance, $action)) { return [PSCustomObject]@{ SqlInstance = $SqlInstance; JobName = $JobName; Status = 'WhatIf' } }

		if ($existingJob)
		{
			Set-DbaAgentJobStep @connParams -Job $JobName -StepName 'RetentionSweep' -Command $command -EnableException -ErrorAction Stop | Out-Null
		}
		else
		{
			$saLogin = Get-sqmSaLogin -SqlInstance $SqlInstance -SqlCredential $SqlCredential
			if (-not $saLogin) { $saLogin = 'sa' }

			New-DbaAgentJob @connParams -Job $JobName -Category $JobCategory -OwnerLogin $saLogin `
				-Description "sqmPartitionTool: entfernt/archiviert woechentlich abgelaufene Partitionen aller aktiven sqm_PartitionRegistry-Eintraege mit Retention." `
				-EnableException -ErrorAction Stop | Out-Null

			New-DbaAgentJobStep @connParams -Job $JobName -StepName 'RetentionSweep' -StepId 1 `
				-Subsystem CmdExec -Command $command `
				-OnSuccessAction QuitWithSuccess -OnFailAction QuitWithFailure `
				-EnableException -ErrorAction Stop | Out-Null

			$timeParts = $ScheduleTime -split ':'
			$startTime = '{0:D2}{1:D2}00' -f [int]$timeParts[0], [int]$timeParts[1]
			New-DbaAgentSchedule @connParams -Job $JobName -Schedule "sch_$JobName" -Force `
				-FrequencyType Weekly -FrequencyInterval $ScheduleDay -StartTime $startTime -ErrorAction Stop | Out-Null
		}

		$msg = "Job '$JobName' $(if ($existingJob) { 'aktualisiert' } else { "angelegt (woechentlich $ScheduleDay $ScheduleTime)" })."
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"

		return [PSCustomObject]@{
			SqlInstance  = $SqlInstance
			JobName      = $JobName
			ScheduleDay  = $ScheduleDay
			ScheduleTime = $ScheduleTime
			Status       = if ($existingJob) { 'Updated' } else { 'Created' }
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
