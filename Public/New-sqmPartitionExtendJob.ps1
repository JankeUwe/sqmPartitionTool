<#
.SYNOPSIS
    Legt den instanzweiten SQL-Agent-Job zur automatischen Sliding-Window-Erweiterung an.

.DESCRIPTION
    Erstellt EINEN Job fuer die ganze Instanz (nicht pro Tabelle), der taeglich
    master.dbo.sqm_ExtendPartitionWindow ausfuehrt (T-SQL-Subsystem). Die Prozedur selbst loopt
    ueber alle aktiven sqm_PartitionRegistry-Eintraege - neue Tabellen werden automatisch
    beruecksichtigt, ohne den Job neu anzulegen.

    Stellt Install-sqmPartitionMaintenanceProcs sicher (Registry-Tabelle + Prozedur werden bei
    Bedarf angelegt/aktualisiert), bevor der Job erstellt wird.

.PARAMETER SqlInstance
    Ziel-Instanz. Standard: aktueller Computername.
.PARAMETER JobName
    Job-Name. Standard: 'sqmPartitionExtendWindow'.
.PARAMETER ScheduleTime
    Taegliche Startzeit im Format 'HH:mm'. Standard: '02:00'.
.PARAMETER JobCategory
    Job-Kategorie. Standard: 'Database Maintenance'.
.PARAMETER Update
    Ueberschreibt einen bestehenden Job gleichen Namens (Step-Command/Schedule werden neu
    geschrieben, sonst idempotent - ein zweiter Aufruf ohne -Update meldet nur den bestehenden
    Job zurueck).
.PARAMETER SqlCredential
    Optionales PSCredential.
.PARAMETER EnableException
    Fehler sofort als Ausnahme ausloesen.

.EXAMPLE
    New-sqmPartitionExtendJob -SqlInstance "SQL01"

.EXAMPLE
    New-sqmPartitionExtendJob -SqlInstance "SQL01" -ScheduleTime "03:30" -Update

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool), Install-sqmPartitionMaintenanceProcs
    (privat). sqm_ExtendPartitionWindow deckt nur FilegroupStrategy 'Single' automatisch ab -
    siehe Kommentar in sql\sqm_ExtendPartitionWindow.proc.sql.
#>
function New-sqmPartitionExtendJob
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $false)]
		[string]$SqlInstance = $env:COMPUTERNAME,

		[Parameter(Mandatory = $false)]
		[string]$JobName = 'sqmPartitionExtendWindow',

		[Parameter(Mandatory = $false)]
		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]$ScheduleTime = '02:00',

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
		$installParams = @{ SqlInstance = $SqlInstance; EnableException = $true }
		if ($SqlCredential) { $installParams['SqlCredential'] = $SqlCredential }
		$mod = Get-Module -Name sqmPartitionTool
		& $mod { param($p) Install-sqmPartitionMaintenanceProcs @p } $installParams | Out-Null

		$command = "EXEC master.dbo.sqm_ExtendPartitionWindow;"
		$existingCat = Get-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue
		if (-not $existingCat) { New-DbaAgentJobCategory @connParams -Category $JobCategory -ErrorAction SilentlyContinue | Out-Null }

		$existingJob = Get-DbaAgentJob @connParams -Job $JobName -ErrorAction SilentlyContinue
		if ($existingJob -and -not $Update)
		{
			Invoke-sqmLogging -Message "Job '$JobName' existiert bereits - unveraendert (kein -Update)." -FunctionName $functionName -Level "INFO"
			return [PSCustomObject]@{ SqlInstance = $SqlInstance; JobName = $JobName; Status = 'AlreadyExists' }
		}

		$action = if ($existingJob) { "Job '$JobName' aktualisieren" } else { "Job '$JobName' anlegen (taeglich $ScheduleTime)" }
		if (-not $PSCmdlet.ShouldProcess($SqlInstance, $action)) { return [PSCustomObject]@{ SqlInstance = $SqlInstance; JobName = $JobName; Status = 'WhatIf' } }

		if ($existingJob)
		{
			Set-DbaAgentJobStep @connParams -Job $JobName -StepName 'ExtendPartitionWindow' -Command $command -EnableException -ErrorAction Stop | Out-Null
		}
		else
		{
			$saLogin = Get-sqmSaLogin -SqlInstance $SqlInstance -SqlCredential $SqlCredential
			if (-not $saLogin) { $saLogin = 'sa' }

			New-DbaAgentJob @connParams -Job $JobName -Category $JobCategory -OwnerLogin $saLogin `
				-Description "sqmPartitionTool: erweitert taeglich das Sliding Window aller aktiven sqm_PartitionRegistry-Eintraege." `
				-EnableException -ErrorAction Stop | Out-Null

			New-DbaAgentJobStep @connParams -Job $JobName -StepName 'ExtendPartitionWindow' -StepId 1 `
				-Subsystem TransactSql -Command $command -Database 'master' `
				-OnSuccessAction QuitWithSuccess -OnFailAction QuitWithFailure `
				-EnableException -ErrorAction Stop | Out-Null

			$timeParts = $ScheduleTime -split ':'
			$startTime = '{0:D2}{1:D2}00' -f [int]$timeParts[0], [int]$timeParts[1]
			New-DbaAgentSchedule @connParams -Job $JobName -Schedule "sch_$JobName" -Force `
				-FrequencyType Daily -FrequencyInterval 1 -StartTime $startTime -ErrorAction Stop | Out-Null
		}

		$msg = "Job '$JobName' $(if ($existingJob) { 'aktualisiert' } else { "angelegt (taeglich $ScheduleTime)" })."
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "INFO"

		return [PSCustomObject]@{
			SqlInstance  = $SqlInstance
			JobName      = $JobName
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
