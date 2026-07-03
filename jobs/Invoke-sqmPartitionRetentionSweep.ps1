# ============================================================================
# Invoke-sqmPartitionRetentionSweep.ps1
# Wird von New-sqmPartitionRetentionJob als CmdExec-SQL-Agent-Job-Step
# aufgerufen (analog zu sqmSQLTool\jobs\Sync-Job.ps1 - ein Job fuer die ganze
# Instanz statt ein Job pro Tabelle). Loopt ueber alle aktiven
# sqm_PartitionRegistry-Eintraege mit konfigurierter Retention und entfernt
# (per Invoke-sqmPartitionArchive) alle Partitionen, deren gesamter
# Datenbereich vor dem Aufbewahrungs-Cutoff liegt.
#
# Wird bewusst NICHT als reine T-SQL-Prozedur implementiert (im Gegensatz zu
# sqm_ExtendPartitionWindow): das Nachbilden einer strukturell identischen
# Staging-Tabelle (Spalten/Indizes/IDENTITY/Constraint-Typ) fuer SWITCH
# PARTITION ist die technisch riskanteste Logik im gesamten Modul (siehe
# CHANGELOG - mehrere nicht offensichtliche SQL-Server-Eigenheiten mussten
# empirisch gefunden werden) und liegt bereits vollstaendig getestet in
# Invoke-sqmPartitionArchive vor. Sie in T-SQL zu duplizieren wuerde dieselben
# Fehlerquellen erneut riskieren, ohne einen Vorteil zu bieten.
#
# Jede Tabelle/Partition wird per try/catch isoliert behandelt (ein Fehler
# blockiert nicht die anderen), Fehler werden gesammelt und am Ende als
# einzelne Exception gemeldet (Job-Step schlaegt dann sichtbar fehl).
# ============================================================================
param (
    [Parameter(Mandatory = $false)]
    [string]$SqlInstance = $env:COMPUTERNAME
)

$ErrorActionPreference = 'Stop'
Import-Module sqmSQLTool -Force -ErrorAction Stop
Import-Module sqmPartitionTool -Force -ErrorAction Stop

Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - sqm_PartitionRetentionSweep gestartet auf '$SqlInstance'."

# Where-Object { $_.RetentionValue } allein reicht nicht: NULL-Werte aus SQL Server kommen in
# PowerShell als [DBNull]::Value zurueck, was in einem Boolean-Kontext WAHR ist (nur $null selbst
# ist falsy) - ohne den expliziten DBNull-Ausschluss wuerden auch Tabellen OHNE konfigurierte
# Retention hier landen.
$tables = Get-sqmPartitionRegistry -SqlInstance $SqlInstance -ActiveOnly |
    Where-Object { $_.RetentionValue -isnot [System.DBNull] -and $_.RetentionValue }

$processed = 0
$retiredPartitions = 0
$errors = [System.Collections.Generic.List[string]]::new()

foreach ($t in $tables)
{
    $processed++
    try
    {
        $cutoff = if ($t.RetentionUnit -eq 'Years') { (Get-Date).AddYears(-[int]$t.RetentionValue) } else { (Get-Date).AddMonths(-[int]$t.RetentionValue) }

        $archiveParams = @{
            SqlInstance     = $SqlInstance
            Database        = $t.DatabaseName
            Schema          = $t.SchemaName
            Table           = $t.TableName
            Confirm         = $false
            ErrorAction     = 'Stop'
            EnableException = $true
        }
        if ([bool]$t.ArchiveEnabled -and $t.ArchiveDatabaseName)
        {
            $archiveParams['ArchiveDatabaseName'] = $t.ArchiveDatabaseName
            if ($t.ArchiveSchemaName) { $archiveParams['ArchiveSchemaName'] = $t.ArchiveSchemaName }
            if ($t.ArchiveBatchSize) { $archiveParams['ArchiveBatchSize'] = [int]$t.ArchiveBatchSize }
        }

        # Status wird JEDE Iteration neu gelesen statt einmal vorab als Liste geplant: jedes
        # MERGE RANGE in Invoke-sqmPartitionArchive nummeriert alle nachfolgenden Partitionen um
        # eins runter - eine vorab geplante Liste von PartitionNumber-Werten waere nach der ersten
        # Entfernung bereits falsch (traf frueher tatsaechlich zu, siehe CHANGELOG).
        while ($true)
        {
            $status = Get-sqmPartitionStatus -SqlInstance $SqlInstance -Database $t.DatabaseName -Schema $t.SchemaName -Table $t.TableName |
                Sort-Object PartitionNumber
            if (-not $status -or $status.Count -le 1) { break }

            # Eine Partition ist vollstaendig abgelaufen, wenn ihre OBERE Grenze vor dem Cutoff liegt -
            # reines Vergleichen der UNTEREN Grenze wuerde Partitionen retirieren, die noch juengere
            # Daten enthalten. $status[0] ist immer die aelteste, nicht-zukuenftige Partition (bei
            # mehr als einer Partition insgesamt).
            $oldest = $status[0]
            $upperBoundary = $oldest.UpperBoundaryValue
            if (-not $upperBoundary) { break }

            # Roher Boundary-Wert ist nur bei BoundaryType='Date' bereits ein echtes Datum - bei
            # 'Int'/'Text' ist es ein Surrogatschluessel-String/-Zahl (z.B. 20240115 oder '202401'),
            # der erst gemaess SurrogateDateFormat geparst werden muss (naiver [datetime]-Cast eines
            # int64-Werts wie 20240115 wuerde als OLE-Automation-Datumsserial fehlinterpretiert).
            $upperBoundaryDate = if ($t.BoundaryType -eq 'Date')
            {
                [datetime]$upperBoundary
            }
            else
            {
                $fmt = if ($t.SurrogateDateFormat -isnot [System.DBNull] -and $t.SurrogateDateFormat) { [string]$t.SurrogateDateFormat } else { 'yyyyMMdd' }
                [datetime]::ParseExact([string]$upperBoundary, $fmt, $null)
            }
            if ($upperBoundaryDate -gt $cutoff) { break }

            $archiveParams['PartitionNumber'] = [int]$oldest.PartitionNumber
            $result = Invoke-sqmPartitionArchive @archiveParams
            $retiredPartitions++
            Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - '$($t.DatabaseName).$($t.SchemaName).$($t.TableName)' Partition $($result.PartitionNumber) entfernt ($($result.RowsRemoved) Zeile(n))."
        }

        Invoke-DbaQuery -SqlInstance $SqlInstance -Database master `
            -Query "UPDATE master.dbo.sqm_PartitionRegistry SET LastRetentionRunAt = SYSDATETIME() WHERE RegistryId = $($t.RegistryId);" `
            -ErrorAction Stop
    }
    catch
    {
        $msg = "[$($t.DatabaseName).$($t.SchemaName).$($t.TableName)] $($_.Exception.Message)"
        Write-Output "FEHLER: $msg"
        $errors.Add($msg)
    }
}

Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - sqm_PartitionRetentionSweep abgeschlossen: $processed Tabelle(n) geprueft, $retiredPartitions Partition(en) entfernt, $($errors.Count) Fehler."

if ($errors.Count -gt 0)
{
    throw "sqm_PartitionRetentionSweep: $($errors.Count) von $processed Tabelle(n) fehlgeschlagen: $($errors -join ' | ')"
}
