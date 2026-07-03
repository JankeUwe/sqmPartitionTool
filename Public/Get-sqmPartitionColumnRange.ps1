<#
.SYNOPSIS
    Ermittelt Min/Max/Zeilenzahl der gewaehlten Partitionsspalte in den vorhandenen Daten.

.DESCRIPTION
    Direkte Umsetzung der Anforderung "bei bestehenden Daten Min/Max erkennen". Liefert zusaetzlich
    eine grobe Granularitaets-Empfehlung (nur ein Vorschlag, die Wahl bleibt immer explizit beim
    Aufrufer/der GUI): bei einer Zeitspanne unter ~2 Jahren wird Month vorgeschlagen, bis ~6 Jahre
    Quarter, darueber Year.

    Bei einer leeren Tabelle (0 Zeilen) sind MinValue/MaxValue $null - der Aufrufer (GUI/CLI) muss
    dann Grenzwerte manuell vorgeben (Invoke-sqmTablePartitionConversion -ManualStartValue).

.PARAMETER SqlInstance
    Ziel-Instanz.

.PARAMETER Database
    Zieldatenbank.

.PARAMETER Schema
    Schema der Tabelle.

.PARAMETER Table
    Tabellenname.

.PARAMETER Column
    Partitionsspalte.

.PARAMETER SqlCredential
    Optionales PSCredential.

.PARAMETER NoLock
    Fragt MIN/MAX/COUNT mit WITH (NOLOCK) ab (schneller auf grossen Tabellen, liest ggf. Dirty
    Reads). Standard: aus (konsistente Lesart).

.EXAMPLE
    Get-sqmPartitionColumnRange -SqlInstance "SQL01" -Database "Sales" -Schema "dbo" -Table "OrderHistory" -Column "OrderDate"

.NOTES
    Benoetigt: dbatools, Invoke-sqmLogging (sqmSQLTool).
#>
function Get-sqmPartitionColumnRange
{
	[CmdletBinding()]
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
		[string]$Column,

		[Parameter(Mandatory = $false)]
		[System.Management.Automation.PSCredential]$SqlCredential,

		[Parameter(Mandatory = $false)]
		[switch]$NoLock
	)

	$functionName = $MyInvocation.MyCommand.Name
	$connParams = @{ SqlInstance = $SqlInstance; Database = $Database }
	if ($SqlCredential) { $connParams['SqlCredential'] = $SqlCredential }

	$hint = if ($NoLock) { ' WITH (NOLOCK)' } else { '' }
	$query = "SELECT MIN([$Column]) AS MinValue, MAX([$Column]) AS MaxValue, COUNT(*) AS RowTotal FROM [$Schema].[$Table]$hint;"

	Invoke-sqmLogging -Message "Ermittle Min/Max von '$Schema.$Table.$Column' in '$Database' auf '$SqlInstance'." -FunctionName $functionName -Level "INFO"

	try
	{
		$row = Invoke-DbaQuery @connParams -Query $query -ErrorAction Stop
	}
	catch
	{
		$msg = "Fehler beim Ermitteln von Min/Max fuer '$Schema.$Table.$Column': $($_.Exception.Message)"
		Invoke-sqmLogging -Message $msg -FunctionName $functionName -Level "ERROR"
		throw
	}

	$rowCount = [int64]$row.RowTotal
	$minValue = $row.MinValue
	$maxValue = $row.MaxValue

	$suggestedGranularity = $null
	if ($rowCount -gt 0 -and $minValue -ne $null -and $maxValue -ne $null)
	{
		try
		{
			$spanDays = ([datetime]$maxValue - [datetime]$minValue).TotalDays
			$suggestedGranularity = if ($spanDays -lt 730) { 'Month' }
			elseif ($spanDays -lt 2190) { 'Quarter' }
			else { 'Year' }
		}
		catch
		{
			# Spalte ist kein Datumstyp (z.B. int-Surrogatschluessel) - keine Datums-basierte
			# Empfehlung moeglich, Aufrufer waehlt Granularitaet explizit.
			$suggestedGranularity = $null
		}
	}

	if ($rowCount -eq 0)
	{
		Invoke-sqmLogging -Message "'$Schema.$Table' ist leer - manuelle Start-/Endwerte erforderlich." -FunctionName $functionName -Level "WARNING"
	}

	return [PSCustomObject]@{
		SchemaName            = $Schema
		TableName             = $Table
		ColumnName            = $Column
		RowCount              = $rowCount
		MinValue              = $minValue
		MaxValue              = $maxValue
		IsEmpty               = ($rowCount -eq 0)
		SuggestedGranularity  = $suggestedGranularity
	}
}
