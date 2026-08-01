<#
.SYNOPSIS
    Berechnet die Boundary-Werte fuer eine Partition Function aus Min/Max/Granularitaet.

.DESCRIPTION
    Reine Funktion ohne Datenbankzugriff (gut isoliert testbar). Erzeugt eine RANGE-RIGHT-
    Boundary-Liste (linksinklusiv: [boundary, naechste_boundary) - das Standardmuster fuer
    Sliding-Window-Partitionierung, siehe Microsoft-Dokumentation) von der Periode, die MinValue
    enthaelt, bis zur Periode, die MaxValue enthaelt, plus -FutureBufferPeriods zusaetzliche,
    leere Perioden danach.

    N Boundary-Werte ergeben immer N+1 Partitionen. Die letzte Partition (>= letzter Boundary-
    Wert) ist absichtlich die "Zukunfts-Catch-All"-Partition und bleibt leer, bis
    sqm_ExtendPartitionWindow sie per SPLIT RANGE weiter aufteilt (Sliding-Window-Invariante:
    die rechteste Partition bleibt immer leer).

.PARAMETER MinValue
    Kleinster vorkommender Wert der Partitionsspalte (aus Get-sqmPartitionColumnRange oder manuell
    bei leerer Tabelle).

.PARAMETER MaxValue
    Groesster vorkommender Wert der Partitionsspalte.

.PARAMETER Granularity
    Month, Quarter oder Year.

.PARAMETER BoundaryType
    Date (echte date/datetime2-Spalte), Int (numerischer Surrogatschluessel, z.B. 20240115 oder
    202401) oder Text (char/varchar-Surrogatschluessel mit demselben Zahlenformat als String, z.B.
    '20240115' oder '202401'). Bei Int/Text werden MinValue/MaxValue im per -SurrogateDateFormat
    angegebenen Format erwartet/zurueckgegeben.

.PARAMETER SurrogateDateFormat
    Nur relevant bei BoundaryType Int oder Text: Format des Datums-Surrogatschluessels.
    'yyyyMMdd' (Standard, Tagesgenauigkeit, z.B. 20240115) oder 'yyyyMM' (Monatsgenauigkeit ohne
    Tag, z.B. 202401 - typisch wenn die Quellspalte selbst nur auf Monatsebene gefuehrt wird).

.PARAMETER FutureBufferPeriods
    Anzahl zusaetzlicher, leerer Perioden nach der letzten Datenperiode. Standard: 3.

.EXAMPLE
    Get-sqmPartitionBoundaryList -MinValue '2023-01-15' -MaxValue '2024-11-03' -Granularity Month -BoundaryType Date

.EXAMPLE
    Get-sqmPartitionBoundaryList -MinValue 20230115 -MaxValue 20241103 -Granularity Quarter -BoundaryType Int -FutureBufferPeriods 2

.EXAMPLE
    # Varchar-Surrogatschluessel im YYYYMM-Format (nur Monatsgenauigkeit)
    Get-sqmPartitionBoundaryList -MinValue '202301' -MaxValue '202411' -Granularity Month -BoundaryType Text -SurrogateDateFormat yyyyMM

.NOTES
    Keine Datenbankabhaengigkeit - reine Berechnungsfunktion, primäres Ziel für Unit-Tests.
#>
function Get-sqmPartitionBoundaryList
{
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory = $true)]
		$MinValue,

		[Parameter(Mandatory = $true)]
		$MaxValue,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Month', 'Quarter', 'Year')]
		[string]$Granularity,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Date', 'Int', 'Text')]
		[string]$BoundaryType,

		[Parameter(Mandatory = $false)]
		[ValidateSet('yyyyMMdd', 'yyyyMM')]
		[string]$SurrogateDateFormat = 'yyyyMMdd',

		[Parameter(Mandatory = $false)]
		[ValidateRange(0, 60)]
		[int]$FutureBufferPeriods = 3
	)

	function _ToDateTime($value, [string]$boundaryType, [string]$dateFormat)
	{
		if ($boundaryType -in @('Int', 'Text'))
		{
			return [datetime]::ParseExact([string]$value, $dateFormat, $null)
		}
		if ($value -is [datetime]) { return $value }
		# Bare [datetime]-Cast ignoriert bei mehrdeutigen Strings (z.B. '1.06.2026') die aktuelle
		# Kultur und parst nach invarianter Monat.Tag.Jahr-Reihenfolge statt Tag.Monat.Jahr (de-DE) -
		# verfaelscht MinValue/MaxValue lautlos, wenn Tag <= 12 ist. Explizit mit Get-Culture parsen.
		return [datetime]::Parse([string]$value, (Get-Culture))
	}

	function _PeriodStart([datetime]$date, [string]$granularity)
	{
		switch ($granularity)
		{
			'Month'   { return [datetime]::new($date.Year, $date.Month, 1) }
			# PowerShell's "/" ist immer Fliesskomma-Division und [int] rundet (statt abzuschneiden) -
			# [int](5/3) ergibt 2, nicht 1 wie bei einer ganzzahligen Division in C#/T-SQL. Ohne
			# [math]::Floor() landen die letzten Monate jedes Quartals (Maerz/Juni/September/Dezember)
			# im FALSCHEN, naechsten Quartal (bei Dezember sogar Monat 13 -> Exception).
			'Quarter' { $qStartMonth = ([math]::Floor(($date.Month - 1) / 3.0) * 3) + 1; return [datetime]::new($date.Year, $qStartMonth, 1) }
			'Year'    { return [datetime]::new($date.Year, 1, 1) }
		}
	}

	function _AddPeriod([datetime]$date, [string]$granularity, [int]$count)
	{
		switch ($granularity)
		{
			'Month'   { return $date.AddMonths($count) }
			'Quarter' { return $date.AddMonths($count * 3) }
			'Year'    { return $date.AddYears($count) }
		}
	}

	function _PeriodLabel([datetime]$date, [string]$granularity)
	{
		switch ($granularity)
		{
			'Month'   { return $date.ToString('yyyy-MM') }
			'Quarter' { $q = [int]([math]::Floor(($date.Month - 1) / 3.0)) + 1; return "$($date.Year)-Q$q" }
			'Year'    { return $date.ToString('yyyy') }
		}
	}

	$minDate = _ToDateTime $MinValue $BoundaryType $SurrogateDateFormat
	$maxDate = _ToDateTime $MaxValue $BoundaryType $SurrogateDateFormat

	if ($maxDate -lt $minDate)
	{
		throw "MaxValue ($MaxValue) liegt vor MinValue ($MinValue)."
	}

	$minPeriod = _PeriodStart $minDate $Granularity
	$maxPeriod = _PeriodStart $maxDate $Granularity

	$periodDates = [System.Collections.Generic.List[datetime]]::new()
	$current = $minPeriod
	while ($current -le $maxPeriod)
	{
		$periodDates.Add($current)
		$current = _AddPeriod $current $Granularity 1
	}
	# $current zeigt jetzt auf die erste Periode NACH den vorhandenen Daten -
	# ab hier die FutureBufferPeriods zusaetzlichen, leeren Perioden anhaengen.
	for ($i = 0; $i -lt $FutureBufferPeriods; $i++)
	{
		$periodDates.Add($current)
		$current = _AddPeriod $current $Granularity 1
	}

	$index = 0
	$results = foreach ($pd in $periodDates)
	{
		$boundaryValue = switch ($BoundaryType)
		{
			'Int'  { [int64]$pd.ToString($SurrogateDateFormat) }
			'Text' { $pd.ToString($SurrogateDateFormat) }
			default { $pd }
		}
		[PSCustomObject]@{
			PeriodIndex   = $index
			PeriodStart   = $pd
			PeriodLabel   = _PeriodLabel $pd $Granularity
			BoundaryValue = $boundaryValue
			IsFutureBuffer = ($pd -gt $maxPeriod)
		}
		$index++
	}

	return $results
}
