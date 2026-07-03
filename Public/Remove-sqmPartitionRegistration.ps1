<#
.SYNOPSIS
    Entfernt eine Tabelle aus der sqmPartitionTool-Wartungsregistrierung.

.DESCRIPTION
    Setzt IsActive=0 (Standard, reversibel - die Historie/Konfiguration bleibt erhalten und die
    Tabelle kann jederzeit wieder aktiviert werden) oder loescht den Registry-Eintrag ganz
    (-Purge). Die Tabelle SELBST bleibt in jedem Fall partitioniert - dies entfernt nur die
    automatische Wartung durch sqm_ExtendPartitionWindow/sqm_RetirePartitionWindow, keine
    Partitionierungs-DDL wird rueckgaengig gemacht.

.PARAMETER SqlInstance
    Ziel-Instanz.
.PARAMETER DatabaseName
    Datenbank der Tabelle.
.PARAMETER SchemaName
    Schema.
.PARAMETER TableName
    Tabellenname.
.PARAMETER Purge
    Loescht den Registry-Eintrag vollstaendig statt nur IsActive=0 zu setzen.
.PARAMETER SqlCredential
    Optionales PSCredential.

.EXAMPLE
    Remove-sqmPartitionRegistration -SqlInstance "SQL01" -DatabaseName "Sales" -SchemaName "dbo" -TableName "OrderHistory"

.EXAMPLE
    Remove-sqmPartitionRegistration -SqlInstance "SQL01" -DatabaseName "Sales" -SchemaName "dbo" -TableName "OrderHistory" -Purge

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool).
#>
function Remove-sqmPartitionRegistration
{
	[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$SqlInstance,

		[Parameter(Mandatory = $true)]
		[string]$DatabaseName,

		[Parameter(Mandatory = $true)]
		[string]$SchemaName,

		[Parameter(Mandatory = $true)]
		[string]$TableName,

		[Parameter(Mandatory = $false)]
		[switch]$Purge,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$action = if ($Purge) { "Registry-Eintrag fuer '$SchemaName.$TableName' endgueltig loeschen" }
	else { "'$SchemaName.$TableName' deaktivieren (IsActive=0)" }

	if (-not $PSCmdlet.ShouldProcess($DatabaseName, $action)) { return }

	$sql = if ($Purge)
	{
		"DELETE FROM master.dbo.sqm_PartitionRegistry WHERE DatabaseName = N'$DatabaseName' AND SchemaName = N'$SchemaName' AND TableName = N'$TableName';"
	}
	else
	{
		"UPDATE master.dbo.sqm_PartitionRegistry SET IsActive = 0 WHERE DatabaseName = N'$DatabaseName' AND SchemaName = N'$SchemaName' AND TableName = N'$TableName';"
	}

	try
	{
		Invoke-DbaQuery @connParams -Database master -Query $sql -ErrorAction Stop
		Invoke-sqmLogging -Message "$action - erfolgreich." -FunctionName $functionName -Level "INFO"
	}
	catch
	{
		$msg = "Fehler bei '$action': $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		throw
	}

	return [PSCustomObject]@{
		DatabaseName = $DatabaseName
		SchemaName   = $SchemaName
		TableName    = $TableName
		Purged       = [bool]$Purge
	}
}
