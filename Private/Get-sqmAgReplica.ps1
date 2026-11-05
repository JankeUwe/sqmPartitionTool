<#
.SYNOPSIS
    Liefert die AlwaysOn-Replikate (Name + Rolle) der Verfuegbarkeitsgruppen einer Instanz.

.DESCRIPTION
    Liest sys.availability_groups / sys.availability_replicas (Rolle aus
    sys.dm_hadr_availability_replica_states). Ohne -Database werden alle Verfuegbarkeitsgruppen
    der Instanz beruecksichtigt, mit -Database nur die Gruppe(n), die diese Datenbank enthalten.
    Ist HADR nicht aktiviert oder gehoert die Instanz keiner Gruppe an, kommt ein leeres Array
    zurueck - Aufrufer muessen diesen Fall wie "kein AlwaysOn" behandeln.

    Rolle: nur auf dem Primary (oder ueber den Listener) fuer alle Replikate bekannt; ueber ein
    Secondary abgefragt ist sie fuer fremde Replikate $null.

    Intern von New-sqmPartitionExtendJob/-RetentionJob (-AllReplicas), Sync-sqmPartitionRegistry
    und New-sqmPartitionFilegroupPlan benutzt.
#>
function Get-sqmAgReplica
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $false)]
		[string]$Database,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$dbFilter = ''
	if ($Database)
	{
		$dbFilter = "WHERE EXISTS (SELECT 1 FROM sys.availability_databases_cluster adc WHERE adc.group_id = ag.group_id AND adc.database_name = N'$($Database.Replace("'", "''"))')"
	}

	$query = @"
SELECT ag.name AS AvailabilityGroup,
       ar.replica_server_name AS ReplicaServerName,
       ars.role_desc AS Role,
       CAST(ISNULL(ars.is_local, 0) AS BIT) AS IsLocal
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
$dbFilter
ORDER BY ag.name, ar.replica_server_name;
"@

	# SERVERPROPERTY('IsHadrEnabled') <> 1 (oder Edition ohne AG) -> Sichten fehlen/leer: dann kein AlwaysOn.
	$hadr = @(Invoke-DbaQuery @connParams -Database master -Query "SELECT CAST(ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0) AS INT) AS H;" -ErrorAction Stop -EnableException -As PSObject) | Select-Object -First 1
	if (-not $hadr -or [int]$hadr.H -ne 1) { return @() }

	return @(Invoke-DbaQuery @connParams -Database master -Query $query -ErrorAction Stop -EnableException -As PSObject)
}
