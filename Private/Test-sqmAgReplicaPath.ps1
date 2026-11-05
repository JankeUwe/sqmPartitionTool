<#
.SYNOPSIS
    Prueft, ob ein Verzeichnis auf allen anderen Replikaten der Verfuegbarkeitsgruppe(n) einer Datenbank existiert.

.DESCRIPTION
    ALTER DATABASE ... ADD FILE wird per Log auf die Secondaries repliziert und legt dort die Datei
    am IDENTISCHEN Pfad an. Fehlt das Verzeichnis (oder hat das Dienstkonto dort keine Rechte),
    wird die Datenbank auf dem Secondary suspendiert. Diese Funktion prueft das VOR dem ADD FILE.

    Rueckgabe: Liste der Replikate (Name), auf denen der Pfad fehlt/nicht pruefbar ist. Leeres
    Array = alles ok ODER die Datenbank gehoert keiner Verfuegbarkeitsgruppe an.
    -SqlInstance muss der Primary (bzw. der Listener) sein.
#>
function Test-sqmAgReplicaPath
{
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $true)]
		[string]$Database,

		[Parameter(Mandatory = $true)]
		[string]$Path,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$replicas = @(Get-sqmAgReplica -SqlInstance $SqlInstance -Database $Database -SqlCredential $SqlCredential)
	if ($replicas.Count -eq 0) { return @() }

	$serverDir = if ($Path -match '^[A-Za-z]:$') { "$Path\" } else { $Path }
	$missing = [System.Collections.Generic.List[string]]::new()

	foreach ($r in ($replicas | Where-Object { $_.Role -ne 'PRIMARY' } | Select-Object -ExpandProperty ReplicaServerName -Unique))
	{
		$p = @{ SqlInstance = $r }
		if ($SqlCredential) { $p['SqlCredential'] = $SqlCredential }
		try
		{
			$probe = @(Invoke-DbaQuery @p -Database master -Query "EXEC master.dbo.xp_fileexist N'$($serverDir.Replace("'", "''"))';" -ErrorAction Stop -EnableException -As PSObject) | Select-Object -First 1
			if ([int]$probe.'File is a Directory' -ne 1) { $missing.Add("$r (Verzeichnis fehlt)") }
		}
		catch
		{
			$missing.Add("$r (nicht pruefbar: $($_.Exception.Message))")
		}
	}

	return $missing.ToArray()
}
