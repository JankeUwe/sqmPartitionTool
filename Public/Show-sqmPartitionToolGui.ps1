function Show-sqmPartitionToolGui
{
<#
.SYNOPSIS
    WinForms-Assistent fuer die Partitionierung einer Tabelle (Schritt-fuer-Schritt).

.DESCRIPTION
    Reiner Wrapper ohne eigene Fachlogik - ruft ausschliesslich die bestehenden Core-Funktionen
    von sqmPartitionTool auf (gleiches Prinzip wie Show-sqmBackupExcludeForm in sqmSQLTool, dessen
    Dark-Theme/DataGridView-Styling hier wiederverwendet wird):

    Verbindung (Instanz+DB) -> Tabelle waehlen -> Spalte waehlen -> Min/Max-Vorschau ->
    Granularitaet + Filegroup-Strategie -> Boundary-Vorschau -> Archiv/Retention (optional) ->
    Zusammenfassung + Ausfuehren.

    Fuehrt am Ende einen von drei Pfaden aus, abhaengig von der in Schritt 1 gewaehlten Tabelle und
    den Optionen in Schritt 6 - fuer einen Wizard-Durchlauf schliessen sich alle drei gegenseitig aus:
    - Quelle NICHT partitioniert, "Migrate to archive database now" NICHT gewaehlt:
      Invoke-sqmTablePartitionConversion (In-Place-Partitionierung), optional direkt im Anschluss
      Register-sqmPartitionTable mit Retention/Archiv-Einstellungen fuer eine SPAETERE
      automatisierte Auslagerung einzelner Partitionen.
    - Quelle NICHT partitioniert, "Migrate to archive database now" gewaehlt:
      Invoke-sqmTableArchiveMigration (sofortige, monatsweise Migration der GESAMTEN Tabelle in eine
      partitionierte Kopie in der Archiv-Datenbank samt Cutover-View, siehe -CutoverToArchiveView
      dort).
    - Quelle BEREITS partitioniert (Schritt 1 blockiert diese Auswahl nicht mehr - Schritt 6 zeigt
      dann ausschliesslich einen "Copy to another database"-Bereich statt Migrate-now/Retention):
      Copy-sqmPartitionedTable (neu partitionierte, eigenstaendige Kopie in einer anderen Datenbank,
      OHNE Cutover - die Quelle bleibt unter ihrem bisherigen Schema vollstaendig unveraendert aktiv).

.PARAMETER SqlInstance
    SQL-Instanz, die beim Oeffnen vorbelegt wird.

.PARAMETER SqlCredential
    Optionale Anmeldedaten (PSCredential). Ohne Angabe: Windows-Authentifizierung.

.EXAMPLE
    Show-sqmPartitionToolGui

.EXAMPLE
    Show-sqmPartitionToolGui -SqlInstance "SQL01"

.NOTES
    Benoetigt: dbatools, sqmSQLTool (Invoke-sqmLogging), alle sqmPartitionTool-Core-Funktionen.
    Laeuft synchron im aktuellen Runspace (keine Hintergrund-Jobs) - konsistent mit
    Show-sqmBackupExcludeForm, es gibt keine automatisierten GUI-Tests fuer dieses Modul.
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [string]$SqlInstance,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$SqlCredential
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # ----- Farbpalette (identisch mit Show-sqmBackupExcludeForm / Show-sqmToolGui) ---------
    $cWindow  = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $cPanel   = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $cText    = [System.Drawing.Color]::FromArgb(220, 220, 220)
    $cDim     = [System.Drawing.Color]::FromArgb(153, 153, 153)
    $cBtn     = [System.Drawing.Color]::FromArgb(62, 62, 66)
    $cAccent  = [System.Drawing.Color]::FromArgb(0, 122, 204)
    $cBorder  = [System.Drawing.Color]::FromArgb(63, 63, 70)
    $cWarn    = [System.Drawing.Color]::FromArgb(220, 180, 60)
    $cErrTxt  = [System.Drawing.Color]::FromArgb(255, 100, 100)

    $styleButton = {
        param ($b)
        $b.FlatStyle = 'Flat'
        $b.BackColor = $cBtn
        $b.ForeColor = $cText
        $b.FlatAppearance.BorderColor = $cBorder
        $b.FlatAppearance.MouseOverBackColor = $cAccent
        $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    }

    $styleGrid = {
        param ($g)
        $g.BackgroundColor = $cWindow
        $g.ForeColor = $cText
        $g.GridColor = $cBorder
        $g.DefaultCellStyle.BackColor = $cWindow
        $g.DefaultCellStyle.ForeColor = $cText
        $g.DefaultCellStyle.SelectionBackColor = $cAccent
        $g.DefaultCellStyle.SelectionForeColor = $cText
        $g.ColumnHeadersDefaultCellStyle.BackColor = $cPanel
        $g.ColumnHeadersDefaultCellStyle.ForeColor = $cText
        $g.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $g.EnableHeadersVisualStyles = $false
        $g.RowHeadersVisible = $false
        $g.AllowUserToAddRows = $false
        $g.AllowUserToDeleteRows = $false
        $g.AutoSizeColumnsMode = 'Fill'
        $g.SelectionMode = 'FullRowSelect'
        $g.MultiSelect = $false
        $g.BorderStyle = 'None'
        $g.ColumnHeadersHeightSizeMode = 'DisableResizing'
        $g.ColumnHeadersHeight = 28
        $g.ReadOnly = $true
        $g.Dock = 'Fill'
    }

    # ----- Assistenten-Zustand ---------------------------------------------------------
    $script:wiz = [PSCustomObject]@{
        SqlInstance         = $null
        Database            = $null
        SchemaName          = $null
        TableName           = $null
        IsHeap              = $false
        SourceIsPartitioned = $false
        PartitionColumn     = $null
        DataType            = $null
        SuggestedGranularity = $null
        MinValue            = $null
        MaxValue            = $null
        IsEmpty             = $false
        Granularity         = 'Month'
        BoundaryType        = 'Date'
        SurrogateDateFormat = 'yyyyMMdd'
        FilegroupStrategy   = 'Single'
        FutureBufferPeriods = 3
        DataCompression     = 'None'
        AllowKeyChange      = $false
        Boundaries          = $null
        ArchiveEnabled      = $false
        ArchiveDatabaseName = $null
        RetentionValue      = $null
        RetentionUnit       = 'Months'
    }
    $script:connParams = @{}
    if ($SqlCredential) { $script:connParams['SqlCredential'] = $SqlCredential }
    $script:currentStep = 0

    # Datums- UND Dezimalwerte werden IMMER mit diesem unzweideutigen, kulturunabhaengigen Format
    # angezeigt statt dem System-/Session-Culture-abhaengigen Standard-ToString() - sonst kann
    # z.B. 06/16/2026 (en-US, Monat/Tag) mit einem dd/MM-Format verwechselt werden, oder ein
    # DataGridView rendert eine [decimal] mit Komma statt Punkt als Dezimaltrennzeichen (de-DE).
    # Gilt fuer JEDEN Wert, der direkt (nicht per String-Interpolation) an ein WinForms-Control
    # uebergeben wird - Interpolation in einem PowerShell-String nutzt bereits die Session-Culture
    # konsistent, aber DataGridView-Zellen und Label.Text-Zuweisungen rufen ToString() der
    # THREAD-Culture selbst auf.
    function _FormatDisplayValue($value)
    {
        if ($value -is [datetime]) { return $value.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
        if ($value -is [decimal] -or $value -is [double] -or $value -is [single]) { return $value.ToString('0.##', [System.Globalization.CultureInfo]::InvariantCulture) }
        return $value
    }
    $stepTitles = @(
        '1/8 - Connection', '2/8 - Select Table', '3/8 - Select Column', '4/8 - Min/Max Preview',
        '5/8 - Granularity && Filegroups', '6/8 - Boundary Preview', '7/8 - Archive && Retention (optional)',
        '8/8 - Summary && Execute'
    )

    # ----- Hauptfenster ------------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form
    $form.Text          = 'sqmPartitionTool - Partitioning Wizard | powershelldba.de'
    $form.Size          = New-Object System.Drawing.Size(980, 720)
    $form.MinimumSize   = New-Object System.Drawing.Size(780, 560)
    $form.StartPosition = 'CenterScreen'
    $form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.BackColor     = $cPanel
    $form.ForeColor     = $cText
    $form.KeyPreview    = $true

    # ----- Kopfzeile (Schritt-Titel) ------------------------------------------------------
    $pHead = New-Object System.Windows.Forms.Panel
    $pHead.Dock = 'Top'
    $pHead.Height = 32
    $pHead.BackColor = $cPanel

    $lblStep = New-Object System.Windows.Forms.Label
    $lblStep.AutoSize = $false
    $lblStep.Dock = 'Fill'
    $lblStep.TextAlign = 'MiddleLeft'
    $lblStep.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $lblStep.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $lblStep.ForeColor = $cText
    $lblStep.Text = $stepTitles[0]
    $pHead.Controls.Add($lblStep)

    # ----- Navigationsleiste (unten) ------------------------------------------------------
    $pNav = New-Object System.Windows.Forms.Panel
    $pNav.Dock = 'Bottom'
    $pNav.Height = 46
    $pNav.BackColor = $cPanel

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.AutoSize = $false
    $lblStatus.Location = New-Object System.Drawing.Point(8, 14)
    $lblStatus.Size = New-Object System.Drawing.Size(650, 22)
    $lblStatus.ForeColor = $cDim
    $lblStatus.Text = ''

    $btnBack = New-Object System.Windows.Forms.Button
    $btnBack.Text = '< Back'
    $btnBack.Location = New-Object System.Drawing.Point(680, 8)
    $btnBack.Size = New-Object System.Drawing.Size(90, 30)
    & $styleButton $btnBack

    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Text = 'Next >'
    $btnNext.Location = New-Object System.Drawing.Point(778, 8)
    $btnNext.Size = New-Object System.Drawing.Size(90, 30)
    & $styleButton $btnNext

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancel'
    $btnCancel.Location = New-Object System.Drawing.Point(876, 8)
    $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
    & $styleButton $btnCancel

    $pNav.Controls.Add($lblStatus)
    $pNav.Controls.Add($btnBack)
    $pNav.Controls.Add($btnNext)
    $pNav.Controls.Add($btnCancel)

    # ----- Inhaltsbereich (Dock=Fill), enthaelt alle Schritt-Panels ----------------------
    $pContent = New-Object System.Windows.Forms.Panel
    $pContent.Dock = 'Fill'
    $pContent.BackColor = $cPanel
    $pContent.Padding = New-Object System.Windows.Forms.Padding(10)

    function Set-Status
    {
        param ([string]$Text, [string]$Level = 'Info')
        $lblStatus.Text = $Text
        $lblStatus.ForeColor = switch ($Level) { 'Error' { $cErrTxt } 'Warn' { $cWarn } 'OK' { $cText } default { $cDim } }
        $form.Refresh()
    }

    # ===================================================================================
    # Schritt 0: Verbindung
    # ===================================================================================
    $p0 = New-Object System.Windows.Forms.Panel
    $p0.Dock = 'Fill'
    $p0.BackColor = $cPanel

    $lbl0a = New-Object System.Windows.Forms.Label
    $lbl0a.Text = 'SQL Instance:'
    $lbl0a.Location = New-Object System.Drawing.Point(4, 14)
    $lbl0a.AutoSize = $true
    $lbl0a.ForeColor = $cDim
    $txt0Instance = New-Object System.Windows.Forms.TextBox
    $txt0Instance.Location = New-Object System.Drawing.Point(140, 10)
    $txt0Instance.Size = New-Object System.Drawing.Size(260, 24)
    $txt0Instance.BackColor = $cWindow
    $txt0Instance.ForeColor = $cText
    $txt0Instance.BorderStyle = 'FixedSingle'
    $txt0Instance.Text = if ($SqlInstance) { $SqlInstance } else { $env:COMPUTERNAME }

    $btn0Connect = New-Object System.Windows.Forms.Button
    $btn0Connect.Text = 'Connect'
    $btn0Connect.Location = New-Object System.Drawing.Point(410, 8)
    $btn0Connect.Size = New-Object System.Drawing.Size(100, 28)
    & $styleButton $btn0Connect

    # Auth-Modus: Windows Authentication (Standard, ohne SqlCredential) oder SQL Server
    # Authentication (Login/Passwort -> SqlCredential). Ohne diese Wahl war die GUI bisher NUR per
    # Windows-Authentifizierung nutzbar - schlaegt fehl sobald keine Domaenen-/Vertrauensstellung
    # zum Zielrechner besteht (Workgroup) oder wenn dort nur SQL-Logins konfiguriert sind.
    $rad0Windows = New-Object System.Windows.Forms.RadioButton
    $rad0Windows.Text = 'Windows Authentication'
    $rad0Windows.Location = New-Object System.Drawing.Point(4, 44)
    $rad0Windows.Size = New-Object System.Drawing.Size(200, 22)
    $rad0Windows.ForeColor = $cText
    $rad0Windows.Checked = $true

    $rad0Sql = New-Object System.Windows.Forms.RadioButton
    $rad0Sql.Text = 'SQL Server Authentication'
    $rad0Sql.Location = New-Object System.Drawing.Point(210, 44)
    $rad0Sql.Size = New-Object System.Drawing.Size(210, 22)
    $rad0Sql.ForeColor = $cText

    $lbl0Login = New-Object System.Windows.Forms.Label
    $lbl0Login.Text = 'Login:'
    $lbl0Login.Location = New-Object System.Drawing.Point(4, 76)
    $lbl0Login.AutoSize = $true
    $lbl0Login.ForeColor = $cDim
    $txt0Login = New-Object System.Windows.Forms.TextBox
    $txt0Login.Location = New-Object System.Drawing.Point(140, 72)
    $txt0Login.Size = New-Object System.Drawing.Size(260, 24)
    $txt0Login.BackColor = $cWindow
    $txt0Login.ForeColor = $cText
    $txt0Login.BorderStyle = 'FixedSingle'
    $txt0Login.Enabled = $false

    $lbl0Password = New-Object System.Windows.Forms.Label
    $lbl0Password.Text = 'Password:'
    $lbl0Password.Location = New-Object System.Drawing.Point(4, 106)
    $lbl0Password.AutoSize = $true
    $lbl0Password.ForeColor = $cDim
    $txt0Password = New-Object System.Windows.Forms.TextBox
    $txt0Password.Location = New-Object System.Drawing.Point(140, 102)
    $txt0Password.Size = New-Object System.Drawing.Size(260, 24)
    $txt0Password.BackColor = $cWindow
    $txt0Password.ForeColor = $cText
    $txt0Password.BorderStyle = 'FixedSingle'
    $txt0Password.UseSystemPasswordChar = $true
    $txt0Password.Enabled = $false

    $rad0Windows.Add_CheckedChanged({
        $txt0Login.Enabled = -not $rad0Windows.Checked
        $txt0Password.Enabled = -not $rad0Windows.Checked
    })

    $lbl0b = New-Object System.Windows.Forms.Label
    $lbl0b.Text = 'Database:'
    $lbl0b.Location = New-Object System.Drawing.Point(4, 144)
    $lbl0b.AutoSize = $true
    $lbl0b.ForeColor = $cDim
    $cmb0Database = New-Object System.Windows.Forms.ComboBox
    $cmb0Database.Location = New-Object System.Drawing.Point(140, 140)
    $cmb0Database.Size = New-Object System.Drawing.Size(260, 24)
    $cmb0Database.BackColor = $cWindow
    $cmb0Database.ForeColor = $cText
    $cmb0Database.DropDownStyle = 'DropDownList'
    $cmb0Database.FlatStyle = 'Flat'

    $p0.Controls.Add($lbl0a)
    $p0.Controls.Add($txt0Instance)
    $p0.Controls.Add($btn0Connect)
    $p0.Controls.Add($rad0Windows)
    $p0.Controls.Add($rad0Sql)
    $p0.Controls.Add($lbl0Login)
    $p0.Controls.Add($txt0Login)
    $p0.Controls.Add($lbl0Password)
    $p0.Controls.Add($txt0Password)
    $p0.Controls.Add($lbl0b)
    $p0.Controls.Add($cmb0Database)

    $btn0Connect.Add_Click({
        Set-Status "Connecting to '$($txt0Instance.Text.Trim())' ..." 'Info'
        try
        {
            $script:connParams = @{}
            if ($rad0Sql.Checked)
            {
                if (-not $txt0Login.Text.Trim())
                {
                    Set-Status 'Error: Login darf bei SQL Server Authentication nicht leer sein.' 'Error'
                    return
                }
                $securePw = ConvertTo-SecureString $txt0Password.Text -AsPlainText -Force
                $script:connParams['SqlCredential'] = [System.Management.Automation.PSCredential]::new($txt0Login.Text.Trim(), $securePw)
            }

            # Fuer Schritt 1+ (Get-sqmPartitionCandidateTable & Co. - eigene sqmPartitionTool-
            # Funktionen, die intern Invoke-DbaQuery mit rohem Instanznamen + -SqlCredential nutzen)
            # reicht $script:connParams unveraendert wie bisher - empirisch verifiziert, dass diese
            # mit einem selbst signierten Zertifikat klaglos funktionieren, ohne -TrustServerCertificate.
            #
            # Get-DbaDatabase HIER in Schritt 0 ist die Ausnahme: mit rohem Instanznamen scheitert es
            # bei einem selbst signierten Zertifikat NICHT mit einer Exception, sondern loggt nur eine
            # WARNUNG und liefert STILLSCHWEIGEND 0 Datenbanken zurueck - das wuerde in der GUI
            # faelschlich als "0 database(s) found (OK)" erscheinen, ohne dass der eigentliche Fehler
            # sichtbar wird. Deshalb hier explizit ueber Connect-DbaInstance (+TrustServerCertificate)
            # verbinden und NUR fuer diesen einen Aufruf das verbundene Objekt verwenden - das wird
            # NICHT weitergereicht (ein verbundenes Objekt mit abweichender -Database an eine andere
            # Funktion weiterzugeben fiel bei Tests unerwartet auf Windows-Auth zurueck).
            $connectParams = @{ SqlInstance = $txt0Instance.Text.Trim(); TrustServerCertificate = $true }
            if ($script:connParams.ContainsKey('SqlCredential')) { $connectParams['SqlCredential'] = $script:connParams['SqlCredential'] }
            $serverConn = Connect-DbaInstance @connectParams -ErrorAction Stop

            $dbs = Get-DbaDatabase -SqlInstance $serverConn -ExcludeSystem -ErrorAction Stop | Sort-Object Name
            $cmb0Database.Items.Clear()
            foreach ($d in $dbs) { [void]$cmb0Database.Items.Add($d.Name) }
            if ($cmb0Database.Items.Count -gt 0) { $cmb0Database.SelectedIndex = 0 }
            Set-Status "$($dbs.Count) database(s) found." 'OK'
        }
        catch { Set-Status "Error: $($_.Exception.Message)" 'Error' }
    })

    # ===================================================================================
    # Schritt 1: Tabelle waehlen
    # ===================================================================================
    $p1 = New-Object System.Windows.Forms.Panel
    $p1.Dock = 'Fill'
    $p1.BackColor = $cPanel
    $grid1 = New-Object System.Windows.Forms.DataGridView
    & $styleGrid $grid1
    foreach ($c in @(
            @{ N = 'Schema'; H = 'Schema'; W = 100 }
            @{ N = 'Tabelle'; H = 'Table'; W = 200 }
            @{ N = 'Zeilen'; H = 'Rows'; W = 100 }
            @{ N = 'GroesseMB'; H = 'Size (MB)'; W = 100 }
            @{ N = 'Typ'; H = 'Type'; W = 90 }
            @{ N = 'Status'; H = 'Status'; W = 130 }
        ))
    {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c.N; $col.HeaderText = $c.H
        $grid1.Columns.Add($col) | Out-Null
    }
    $p1.Controls.Add($grid1)

    function Load-Step1
    {
        $grid1.Rows.Clear()
        Set-Status "Loading tables from '$($script:wiz.Database)' ..." 'Info'
        try
        {
            $cp = $script:connParams
            $tables = Get-sqmPartitionCandidateTable @cp -SqlInstance $script:wiz.SqlInstance -Database $script:wiz.Database -IncludeAlreadyPartitioned -ErrorAction Stop
            foreach ($t in $tables)
            {
                $status = if ($t.IsPartitioned) { 'already partitioned' } else { 'Candidate' }
                $rowIdx = $grid1.Rows.Add($t.SchemaName, $t.TableName, $t.RowCount, (_FormatDisplayValue $t.SizeMB), $(if ($t.IsHeap) { 'Heap' } else { 'Clustered' }), $status)
                if ($t.IsPartitioned) { $grid1.Rows[$rowIdx].DefaultCellStyle.ForeColor = $cDim }
            }
            Set-Status "$($tables.Count) table(s) found." 'OK'
        }
        catch { Set-Status "Error: $($_.Exception.Message)" 'Error' }
    }

    # ===================================================================================
    # Schritt 2: Spalte waehlen
    # ===================================================================================
    $p2 = New-Object System.Windows.Forms.Panel
    $p2.Dock = 'Fill'
    $p2.BackColor = $cPanel
    $grid2 = New-Object System.Windows.Forms.DataGridView
    & $styleGrid $grid2
    foreach ($c in @(
            @{ N = 'Spalte'; H = 'Column'; W = 200 }
            @{ N = 'Typ'; H = 'Data Type'; W = 120 }
            @{ N = 'Nullable'; H = 'Nullable'; W = 80 }
            @{ N = 'Kompatibel'; H = 'Compatible'; W = 100 }
        ))
    {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c.N; $col.HeaderText = $c.H
        $grid2.Columns.Add($col) | Out-Null
    }
    $p2.Controls.Add($grid2)

    function Load-Step2
    {
        $grid2.Rows.Clear()
        Set-Status "Loading columns from '$($script:wiz.SchemaName).$($script:wiz.TableName)' ..." 'Info'
        try
        {
            $cp = $script:connParams
            $cols = Get-sqmPartitionColumnCandidate @cp -SqlInstance $script:wiz.SqlInstance -Database $script:wiz.Database -Schema $script:wiz.SchemaName -Table $script:wiz.TableName -ErrorAction Stop
            foreach ($c in $cols)
            {
                $rowIdx = $grid2.Rows.Add($c.ColumnName, $c.DataType, $(if ($c.IsNullable) { 'Yes' } else { 'No' }), $(if ($c.IsPartitionTypeCompatible) { 'Yes' } else { 'No' }))
                if (-not $c.IsPartitionTypeCompatible) { $grid2.Rows[$rowIdx].DefaultCellStyle.ForeColor = $cDim }
            }
            Set-Status "$($cols.Count) column(s) found. Incompatible types are grayed out." 'OK'
        }
        catch { Set-Status "Error: $($_.Exception.Message)" 'Error' }
    }

    # ===================================================================================
    # Schritt 3: Min/Max-Vorschau
    # ===================================================================================
    $p3 = New-Object System.Windows.Forms.Panel
    $p3.Dock = 'Fill'
    $p3.BackColor = $cPanel

    $lbl3Info = New-Object System.Windows.Forms.Label
    $lbl3Info.Location = New-Object System.Drawing.Point(4, 8)
    $lbl3Info.Size = New-Object System.Drawing.Size(900, 90)
    $lbl3Info.ForeColor = $cText
    $lbl3Info.Text = ''

    $lbl3Manual = New-Object System.Windows.Forms.Label
    $lbl3Manual.Text = 'Table is empty - enter manual values (start[,end]), e.g. 2025-01-01:'
    $lbl3Manual.Location = New-Object System.Drawing.Point(4, 110)
    $lbl3Manual.AutoSize = $true
    $lbl3Manual.ForeColor = $cWarn
    $lbl3Manual.Visible = $false

    $txt3Start = New-Object System.Windows.Forms.TextBox
    $txt3Start.Location = New-Object System.Drawing.Point(4, 134)
    $txt3Start.Size = New-Object System.Drawing.Size(160, 24)
    $txt3Start.BackColor = $cWindow
    $txt3Start.ForeColor = $cText
    $txt3Start.BorderStyle = 'FixedSingle'
    $txt3Start.Visible = $false

    $txt3End = New-Object System.Windows.Forms.TextBox
    $txt3End.Location = New-Object System.Drawing.Point(174, 134)
    $txt3End.Size = New-Object System.Drawing.Size(160, 24)
    $txt3End.BackColor = $cWindow
    $txt3End.ForeColor = $cText
    $txt3End.BorderStyle = 'FixedSingle'
    $txt3End.Visible = $false

    $p3.Controls.Add($lbl3Info)
    $p3.Controls.Add($lbl3Manual)
    $p3.Controls.Add($txt3Start)
    $p3.Controls.Add($txt3End)

    function Load-Step3
    {
        Set-Status "Determining min/max of '$($script:wiz.PartitionColumn)' ..." 'Info'
        try
        {
            $cp = $script:connParams
            $range = Get-sqmPartitionColumnRange @cp -SqlInstance $script:wiz.SqlInstance -Database $script:wiz.Database -Schema $script:wiz.SchemaName -Table $script:wiz.TableName -Column $script:wiz.PartitionColumn -ErrorAction Stop
            $script:wiz.MinValue = $range.MinValue
            $script:wiz.MaxValue = $range.MaxValue
            $script:wiz.IsEmpty = $range.IsEmpty
            $script:wiz.SuggestedGranularity = $range.SuggestedGranularity

            if ($range.IsEmpty)
            {
                $lbl3Info.Text = "'$($script:wiz.SchemaName).$($script:wiz.TableName)' is empty (0 rows)."
                $lbl3Manual.Visible = $true; $txt3Start.Visible = $true; $txt3End.Visible = $true
                Set-Status 'Table is empty - manual start/end values required.' 'Warn'
            }
            else
            {
                $lbl3Manual.Visible = $false; $txt3Start.Visible = $false; $txt3End.Visible = $false
                $lbl3Info.Text = "Rows: $($range.RowCount)`r`nMinValue: $(_FormatDisplayValue $range.MinValue)`r`nMaxValue: $(_FormatDisplayValue $range.MaxValue)`r`n" +
                    $(if ($range.SuggestedGranularity) { "Suggested granularity: $($range.SuggestedGranularity) (adjustable in step 5)" } else { '' })
                Set-Status 'Min/max determined.' 'OK'
            }
        }
        catch { Set-Status "Error: $($_.Exception.Message)" 'Error' }
    }

    # ===================================================================================
    # Schritt 4: Granularitaet + Filegroup-Strategie
    # ===================================================================================
    $p4 = New-Object System.Windows.Forms.Panel
    $p4.Dock = 'Fill'
    $p4.BackColor = $cPanel

    $lbl4a = New-Object System.Windows.Forms.Label
    $lbl4a.Text = 'Granularity:'
    $lbl4a.Location = New-Object System.Drawing.Point(4, 12)
    $lbl4a.AutoSize = $true
    $lbl4a.ForeColor = $cDim
    $cmb4Gran = New-Object System.Windows.Forms.ComboBox
    $cmb4Gran.Location = New-Object System.Drawing.Point(140, 8)
    $cmb4Gran.Size = New-Object System.Drawing.Size(150, 24)
    $cmb4Gran.BackColor = $cWindow
    $cmb4Gran.ForeColor = $cText
    $cmb4Gran.DropDownStyle = 'DropDownList'
    [void]$cmb4Gran.Items.AddRange(@('Month', 'Quarter', 'Year'))

    $lbl4b = New-Object System.Windows.Forms.Label
    $lbl4b.Text = 'Filegroup Strategy:'
    $lbl4b.Location = New-Object System.Drawing.Point(4, 52)
    $lbl4b.AutoSize = $true
    $lbl4b.ForeColor = $cDim
    $cmb4Fg = New-Object System.Windows.Forms.ComboBox
    $cmb4Fg.Location = New-Object System.Drawing.Point(140, 48)
    $cmb4Fg.Size = New-Object System.Drawing.Size(150, 24)
    $cmb4Fg.BackColor = $cWindow
    $cmb4Fg.ForeColor = $cText
    $cmb4Fg.DropDownStyle = 'DropDownList'
    [void]$cmb4Fg.Items.AddRange(@('Single (recommended)', 'PerPeriod'))
    $cmb4Fg.SelectedIndex = 0

    $lbl4c = New-Object System.Windows.Forms.Label
    $lbl4c.Text = 'Future empty periods (buffer):'
    $lbl4c.Location = New-Object System.Drawing.Point(4, 92)
    $lbl4c.AutoSize = $true
    $lbl4c.ForeColor = $cDim
    $num4Buffer = New-Object System.Windows.Forms.NumericUpDown
    $num4Buffer.Location = New-Object System.Drawing.Point(220, 88)
    $num4Buffer.Size = New-Object System.Drawing.Size(60, 24)
    $num4Buffer.Minimum = 0
    $num4Buffer.Maximum = 60
    $num4Buffer.Value = 3
    $num4Buffer.BackColor = $cWindow
    $num4Buffer.ForeColor = $cText

    $lbl4e = New-Object System.Windows.Forms.Label
    $lbl4e.Text = 'Data Compression:'
    $lbl4e.Location = New-Object System.Drawing.Point(4, 132)
    $lbl4e.AutoSize = $true
    $lbl4e.ForeColor = $cDim
    $cmb4Comp = New-Object System.Windows.Forms.ComboBox
    $cmb4Comp.Location = New-Object System.Drawing.Point(140, 128)
    $cmb4Comp.Size = New-Object System.Drawing.Size(150, 24)
    $cmb4Comp.BackColor = $cWindow
    $cmb4Comp.ForeColor = $cText
    $cmb4Comp.DropDownStyle = 'DropDownList'
    [void]$cmb4Comp.Items.AddRange(@('None', 'Row', 'Page'))
    $cmb4Comp.SelectedIndex = 0

    $lbl4Warn = New-Object System.Windows.Forms.Label
    $lbl4Warn.Location = New-Object System.Drawing.Point(4, 170)
    $lbl4Warn.Size = New-Object System.Drawing.Size(900, 40)
    $lbl4Warn.ForeColor = $cWarn
    $lbl4Warn.Text = ''

    # Nur sichtbar, wenn die Partitionsspalte kein echter Datumstyp ist (Int-/Text-Surrogatschluessel,
    # z.B. YYYYMMDD oder YYYYMM als int/varchar) - siehe Confirm-StepAndAdvance Case 3.
    $lbl4d = New-Object System.Windows.Forms.Label
    $lbl4d.Text = 'Surrogate Date Format:'
    $lbl4d.Location = New-Object System.Drawing.Point(4, 222)
    $lbl4d.AutoSize = $true
    $lbl4d.ForeColor = $cDim
    $lbl4d.Visible = $false
    $cmb4Fmt = New-Object System.Windows.Forms.ComboBox
    $cmb4Fmt.Location = New-Object System.Drawing.Point(140, 218)
    $cmb4Fmt.Size = New-Object System.Drawing.Size(150, 24)
    $cmb4Fmt.BackColor = $cWindow
    $cmb4Fmt.ForeColor = $cText
    $cmb4Fmt.DropDownStyle = 'DropDownList'
    [void]$cmb4Fmt.Items.AddRange(@('yyyyMMdd (day)', 'yyyyMM (month)'))
    $cmb4Fmt.SelectedIndex = 0
    $cmb4Fmt.Visible = $false

    $p4.Controls.Add($lbl4a); $p4.Controls.Add($cmb4Gran)
    $p4.Controls.Add($lbl4b); $p4.Controls.Add($cmb4Fg)
    $p4.Controls.Add($lbl4c); $p4.Controls.Add($num4Buffer)
    $p4.Controls.Add($lbl4e); $p4.Controls.Add($cmb4Comp)
    $p4.Controls.Add($lbl4Warn)
    $p4.Controls.Add($lbl4d); $p4.Controls.Add($cmb4Fmt)

    function Update-Step4Warning
    {
        if ($cmb4Fg.SelectedIndex -eq 1 -and $cmb4Gran.SelectedItem -eq 'Month' -and -not $script:wiz.IsEmpty -and $script:wiz.MinValue -and $script:wiz.MaxValue)
        {
            try
            {
                $spanMonths = [math]::Ceiling(([datetime]$script:wiz.MaxValue - [datetime]$script:wiz.MinValue).TotalDays / 30) + [int]$num4Buffer.Value
                if ($spanMonths -gt 24)
                {
                    $lbl4Warn.Text = "Warning: Month + PerPeriod creates approx. $spanMonths filegroups/files for this time span - significantly more operational overhead than 'Single'. Consider 'Single' or a coarser granularity."
                    return
                }
            }
            catch { }
        }
        $lbl4Warn.Text = ''
    }
    $cmb4Gran.Add_SelectedIndexChanged({ Update-Step4Warning })
    $cmb4Fg.Add_SelectedIndexChanged({ Update-Step4Warning })
    $num4Buffer.Add_ValueChanged({ Update-Step4Warning })

    # ===================================================================================
    # Schritt 5: Boundary-Vorschau
    # ===================================================================================
    $p5 = New-Object System.Windows.Forms.Panel
    $p5.Dock = 'Fill'
    $p5.BackColor = $cPanel
    $grid5 = New-Object System.Windows.Forms.DataGridView
    & $styleGrid $grid5
    foreach ($c in @(
            @{ N = 'Periode'; H = 'Period'; W = 100 }
            @{ N = 'Boundary'; H = 'Boundary Value'; W = 150 }
            @{ N = 'Zukunft'; H = 'Future Buffer'; W = 100 }
        ))
    {
        $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c.N; $col.HeaderText = $c.H
        $grid5.Columns.Add($col) | Out-Null
    }
    $p5.Controls.Add($grid5)

    function Load-Step5
    {
        $grid5.Rows.Clear()
        try
        {
            $script:wiz.Granularity = [string]$cmb4Gran.SelectedItem
            $script:wiz.FilegroupStrategy = if ($cmb4Fg.SelectedIndex -eq 1) { 'PerPeriod' } else { 'Single' }
            $script:wiz.FutureBufferPeriods = [int]$num4Buffer.Value
            $script:wiz.DataCompression = if ($cmb4Comp.SelectedItem) { [string]$cmb4Comp.SelectedItem } else { 'None' }
            $dateTypesGui = @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
            $textTypesGui = @('char', 'varchar', 'nchar', 'nvarchar')
            $script:wiz.BoundaryType = if ($script:wiz.DataType -in $dateTypesGui) { 'Date' } elseif ($script:wiz.DataType -in $textTypesGui) { 'Text' } else { 'Int' }
            $script:wiz.SurrogateDateFormat = if ($cmb4Fmt.SelectedIndex -eq 1) { 'yyyyMM' } else { 'yyyyMMdd' }

            $minV = if ($script:wiz.IsEmpty) { $txt3Start.Text.Trim() } else { $script:wiz.MinValue }
            $maxV = if ($script:wiz.IsEmpty) { $(if ($txt3End.Text.Trim()) { $txt3End.Text.Trim() } else { $txt3Start.Text.Trim() }) } else { $script:wiz.MaxValue }

            $boundaries = Get-sqmPartitionBoundaryList -MinValue $minV -MaxValue $maxV -Granularity $script:wiz.Granularity -BoundaryType $script:wiz.BoundaryType -SurrogateDateFormat $script:wiz.SurrogateDateFormat -FutureBufferPeriods $script:wiz.FutureBufferPeriods -ErrorAction Stop
            $script:wiz.Boundaries = $boundaries
            foreach ($b in $boundaries)
            {
                $grid5.Rows.Add($b.PeriodLabel, (_FormatDisplayValue $b.BoundaryValue), $(if ($b.IsFutureBuffer) { 'Yes' } else { '' })) | Out-Null
            }
            Set-Status "$($boundaries.Count) boundary value(s) -> $($boundaries.Count + 1) partition(s)." 'OK'
        }
        catch { Set-Status "Error: $($_.Exception.Message)" 'Error' }
    }

    # ===================================================================================
    # Schritt 6: Archiv/Retention (optional)
    # ===================================================================================
    $p6 = New-Object System.Windows.Forms.Panel
    $p6.Dock = 'Fill'
    $p6.BackColor = $cPanel

    # "Migrate now" ist ein eigener, zur In-Place-Partitionierung EXKLUSIVER Ausfuehrungsmodus (ruft
    # Invoke-sqmTableArchiveMigration statt Invoke-sqmTablePartitionConversion auf) - im Unterschied
    # zu "Copy to an archive database before removal" weiter unten, das nur eine spaetere,
    # automatisierte Retention konfiguriert (die Quelltabelle wird trotzdem SOFORT in-place
    # partitioniert und bleibt dort; nur einzelne, ALTE Partitionen wandern spaeter schrittweise ins
    # Archiv). Beide Modi teilen sich dasselbe "Archive Database"-Feld weiter unten.
    $chk6MigrateNow = New-Object System.Windows.Forms.CheckBox
    $chk6MigrateNow.Text = 'Migrate to archive database now (source stays active, unpartitioned)'
    $chk6MigrateNow.Location = New-Object System.Drawing.Point(4, 8)
    $chk6MigrateNow.AutoSize = $true
    $chk6MigrateNow.ForeColor = $cText

    # Nur eingeblendet, wenn die Tabelle TATSAECHLICH eine explizite Schluesselangabe braucht (Heap
    # oder zusammengesetzter Schluessel mit mehr als 4 Spalten - siehe Test-Step6KeyColumnNeed unten).
    # Bei einem normalen einspaltigen oder 1-4-spaltigen zusammengesetzten Clustered Index/PK leitet
    # Invoke-sqmTableArchiveMigration den Schluessel automatisch ab - dann bleibt dieser Bereich
    # komplett ausgeblendet statt ein ungenutztes Feld anzuzeigen. Auswahl per CheckedListBox
    # (tatsaechliche Spalten der Tabelle) statt Freitext - kein Tippfehlerrisiko bei Spaltennamen.
    $lbl6Key = New-Object System.Windows.Forms.Label
    $lbl6Key.Text = 'Key Column(s) (table has no simple unique key - pick one):'
    $lbl6Key.Location = New-Object System.Drawing.Point(24, 40)
    $lbl6Key.AutoSize = $true
    $lbl6Key.ForeColor = $cDim
    $clb6Key = New-Object System.Windows.Forms.CheckedListBox
    $clb6Key.Location = New-Object System.Drawing.Point(24, 64)
    $clb6Key.Size = New-Object System.Drawing.Size(300, 84)
    $clb6Key.BackColor = $cWindow
    $clb6Key.ForeColor = $cText
    $clb6Key.CheckOnClick = $true
    $toolTip6Key = New-Object System.Windows.Forms.ToolTip
    $toolTip6Key.SetToolTip($clb6Key, 'Check the column(s) that together uniquely identify a row (up to 4). Only shown because this table has no single clustered index/PK that could be used automatically.')

    $chk6Retention = New-Object System.Windows.Forms.CheckBox
    $chk6Retention.Text = 'Set up automatic maintenance (sliding-window extension + retention)'
    $chk6Retention.Location = New-Object System.Drawing.Point(4, 40)
    $chk6Retention.AutoSize = $true
    $chk6Retention.ForeColor = $cText

    $lbl6a = New-Object System.Windows.Forms.Label
    $lbl6a.Text = 'Retention:'
    $lbl6a.Location = New-Object System.Drawing.Point(24, 76)
    $lbl6a.AutoSize = $true
    $lbl6a.ForeColor = $cDim
    $num6Retention = New-Object System.Windows.Forms.NumericUpDown
    $num6Retention.Location = New-Object System.Drawing.Point(140, 72)
    $num6Retention.Size = New-Object System.Drawing.Size(60, 24)
    $num6Retention.Minimum = 1
    $num6Retention.Maximum = 999
    $num6Retention.Value = 36
    $num6Retention.BackColor = $cWindow
    $num6Retention.ForeColor = $cText

    $cmb6Unit = New-Object System.Windows.Forms.ComboBox
    $cmb6Unit.Location = New-Object System.Drawing.Point(210, 72)
    $cmb6Unit.Size = New-Object System.Drawing.Size(100, 24)
    $cmb6Unit.BackColor = $cWindow
    $cmb6Unit.ForeColor = $cText
    $cmb6Unit.DropDownStyle = 'DropDownList'
    [void]$cmb6Unit.Items.AddRange(@('Months', 'Years'))
    $cmb6Unit.SelectedIndex = 0

    # Bezieht sich NUR auf die laufende, automatisierte Retention oben (nicht auf "Migrate to
    # archive database now" - dieser ganze Bereich ist in diesem Modus komplett ausgeblendet, siehe
    # Set-Step6Mode: sobald die Archiv-DB per Migrate-now aufgesetzt ist, laeuft jeder Zugriff nur
    # noch ueber die rueckwaertsverweisende View in die Archiv-DB - "wenn Partitionen spaeter
    # ablaufen" ergibt fuer die (dann gar nicht mehr existierende) Quelltabelle keinen Sinn mehr).
    $chk6Archive = New-Object System.Windows.Forms.CheckBox
    $chk6Archive.Text = 'When partitions expire later, move their data to an archive database first (instead of just deleting it)'
    $chk6Archive.Location = New-Object System.Drawing.Point(24, 108)
    $chk6Archive.AutoSize = $true
    $chk6Archive.ForeColor = $cText
    $toolTip6Archive = New-Object System.Windows.Forms.ToolTip
    $toolTip6Archive.SetToolTip($chk6Archive, "Applies to the ONGOING automated retention above: as old partitions age past the retention window, their data is copied to the archive database before the partition is dropped from this (in-place-partitioned) table. Unrelated to 'Migrate to archive database now' at the top, which moves the WHOLE table immediately instead.")

    # Wird in BEIDEN Modi verwendet (gemeinsames Feld) - Position wird von Set-Step6Mode je nach
    # Modus/ob der Key-Column-Bereich eingeblendet ist neu gesetzt.
    $lbl6b = New-Object System.Windows.Forms.Label
    $lbl6b.Text = 'Archive Database:'
    $lbl6b.AutoSize = $true
    $lbl6b.ForeColor = $cDim
    $txt6ArchiveDb = New-Object System.Windows.Forms.TextBox
    $txt6ArchiveDb.Size = New-Object System.Drawing.Size(200, 24)
    $txt6ArchiveDb.BackColor = $cWindow
    $txt6ArchiveDb.ForeColor = $cText
    $txt6ArchiveDb.BorderStyle = 'FixedSingle'

    # Eigener Bereich fuer eine bereits partitionierte Quelltabelle (Ablaufplan D, siehe
    # Copy-sqmPartitionedTable) - schliesst sich mit Migrate-now/Retention/Archive oben gegenseitig
    # aus (Set-Step6Mode blendet je nach $script:wiz.SourceIsPartitioned den passenden Bereich ein).
    $lbl6CopyInfo = New-Object System.Windows.Forms.Label
    $lbl6CopyInfo.Text = "This table is already partitioned - it will be COPIED (not converted) into a new, independently partitioned table in another database. The source stays fully active and unchanged (no rename, no cutover view)."
    $lbl6CopyInfo.Location = New-Object System.Drawing.Point(4, 8)
    $lbl6CopyInfo.Size = New-Object System.Drawing.Size(900, 40)
    $lbl6CopyInfo.ForeColor = $cText

    $lbl6TargetDb = New-Object System.Windows.Forms.Label
    $lbl6TargetDb.Text = 'Target Database:'
    $lbl6TargetDb.Location = New-Object System.Drawing.Point(4, 56)
    $lbl6TargetDb.AutoSize = $true
    $lbl6TargetDb.ForeColor = $cDim
    $txt6TargetDb = New-Object System.Windows.Forms.TextBox
    $txt6TargetDb.Location = New-Object System.Drawing.Point(140, 52)
    $txt6TargetDb.Size = New-Object System.Drawing.Size(200, 24)
    $txt6TargetDb.BackColor = $cWindow
    $txt6TargetDb.ForeColor = $cText
    $txt6TargetDb.BorderStyle = 'FixedSingle'

    $lbl6TargetTable = New-Object System.Windows.Forms.Label
    $lbl6TargetTable.Text = 'Target Table Name:'
    $lbl6TargetTable.Location = New-Object System.Drawing.Point(4, 88)
    $lbl6TargetTable.AutoSize = $true
    $lbl6TargetTable.ForeColor = $cDim
    $txt6TargetTable = New-Object System.Windows.Forms.TextBox
    $txt6TargetTable.Location = New-Object System.Drawing.Point(140, 84)
    $txt6TargetTable.Size = New-Object System.Drawing.Size(200, 24)
    $txt6TargetTable.BackColor = $cWindow
    $txt6TargetTable.ForeColor = $cText
    $txt6TargetTable.BorderStyle = 'FixedSingle'
    $toolTip6TargetTable = New-Object System.Windows.Forms.ToolTip
    $toolTip6TargetTable.SetToolTip($txt6TargetTable, 'Leave empty to keep the same table name in the target database.')

    # Eigene CheckedListBox statt $clb6Key wiederzuverwenden - die Ableitungsregel unterscheidet
    # sich (Copy-sqmPartitionedTable erlaubt fuer -KeyColumn nur einen einzelnen einspaltigen
    # Clustered Index/PK, waehrend Invoke-sqmTableArchiveMigration bis zu 4 Spalten automatisch
    # ableiten kann - ein gemeinsamer "needed"-Zustand waere hier irrefuehrend).
    $lbl6CopyKey = New-Object System.Windows.Forms.Label
    $lbl6CopyKey.Text = 'Key Column (table has no single-column unique key - pick one):'
    $lbl6CopyKey.Location = New-Object System.Drawing.Point(24, 120)
    $lbl6CopyKey.AutoSize = $true
    $lbl6CopyKey.ForeColor = $cDim
    $clb6CopyKey = New-Object System.Windows.Forms.CheckedListBox
    $clb6CopyKey.Location = New-Object System.Drawing.Point(24, 144)
    $clb6CopyKey.Size = New-Object System.Drawing.Size(300, 84)
    $clb6CopyKey.BackColor = $cWindow
    $clb6CopyKey.ForeColor = $cText
    $clb6CopyKey.CheckOnClick = $true
    $toolTip6CopyKey = New-Object System.Windows.Forms.ToolTip
    $toolTip6CopyKey.SetToolTip($clb6CopyKey, 'Check exactly ONE column that uniquely identifies a row on its own (used for resumable batch copying, not for the new partitioning itself). Only shown because this table has no single-column clustered index/PK.')

    $p6.Controls.Add($chk6MigrateNow)
    $p6.Controls.Add($lbl6Key); $p6.Controls.Add($clb6Key)
    $p6.Controls.Add($chk6Retention)
    $p6.Controls.Add($lbl6a); $p6.Controls.Add($num6Retention); $p6.Controls.Add($cmb6Unit)
    $p6.Controls.Add($chk6Archive)
    $p6.Controls.Add($lbl6b); $p6.Controls.Add($txt6ArchiveDb)
    $p6.Controls.Add($lbl6CopyInfo)
    $p6.Controls.Add($lbl6TargetDb); $p6.Controls.Add($txt6TargetDb)
    $p6.Controls.Add($lbl6TargetTable); $p6.Controls.Add($txt6TargetTable)
    $p6.Controls.Add($lbl6CopyKey); $p6.Controls.Add($clb6CopyKey)

    # Prueft (einmalig pro Tabellenwahl), ob die aktuell gewaehlte Tabelle einen Schluessel hat, aus
    # dem Invoke-sqmTableArchiveMigration automatisch ableiten kann (1-4-spaltiger Clustered
    # Index/PK) - exakt dieselbe Abfrage wie die Auto-Ableitung dort. Nur wenn NICHT (Heap oder mehr
    # als 4 Spalten) wird der Key-Column-Bereich ueberhaupt eingeblendet und mit den echten Spalten
    # der Tabelle befuellt.
    $script:step6KeyColumnNeeded = $false
    $script:step6KeyColumnChecked = $false
    function Test-Step6KeyColumnNeed
    {
        if ($script:step6KeyColumnChecked) { return }
        $script:step6KeyColumnChecked = $true
        try
        {
            $cp = $script:connParams
            $keyQuery = @"
SELECT c.name AS ColumnName
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'[$($script:wiz.SchemaName)].[$($script:wiz.TableName)]') AND i.index_id = 1
ORDER BY ic.key_ordinal
"@
            $keyRows = @(Invoke-DbaQuery @cp -SqlInstance $script:wiz.SqlInstance -Database $script:wiz.Database -Query $keyQuery -ErrorAction Stop)
            $script:step6KeyColumnNeeded = ($keyRows.Count -eq 0 -or $keyRows.Count -gt 4)

            if ($script:step6KeyColumnNeeded)
            {
                $colQuery = "SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'[$($script:wiz.SchemaName)].[$($script:wiz.TableName)]') ORDER BY column_id;"
                $colRows = @(Invoke-DbaQuery @cp -SqlInstance $script:wiz.SqlInstance -Database $script:wiz.Database -Query $colQuery -ErrorAction Stop)
                $clb6Key.Items.Clear()
                foreach ($c in $colRows) { [void]$clb6Key.Items.Add($c.name) }
            }
        }
        catch
        {
            # Unklar, ob noetig - sicherheitshalber einblenden, damit der Admin die Wahl hat, statt
            # stillschweigend auf eine fehlschlagende automatische Ableitung zu vertrauen.
            $script:step6KeyColumnNeeded = $true
        }
    }

    # Prueft (einmalig pro Tabellenwahl), ob Copy-sqmPartitionedTable die Batch-Kopier-Schluesselspalte
    # automatisch ableiten kann - ANDERE Regel als Test-Step6KeyColumnNeed oben (dort 1-4 Spalten
    # erlaubt): Copy-sqmPartitionedTable akzeptiert fuer die Auto-Ableitung nur einen einzelnen
    # einspaltigen Clustered Index/PK (siehe dortiger Kommentar zu 'ciKeyRows.Count -eq 1').
    $script:step6CopyKeyColumnNeeded = $false
    $script:step6CopyKeyColumnChecked = $false
    function Test-Step6CopyKeyColumnNeed
    {
        if ($script:step6CopyKeyColumnChecked) { return }
        $script:step6CopyKeyColumnChecked = $true
        try
        {
            $cp = $script:connParams
            $keyQuery = @"
SELECT c.name AS ColumnName
FROM sys.indexes i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE i.object_id = OBJECT_ID(N'[$($script:wiz.SchemaName)].[$($script:wiz.TableName)]') AND i.index_id = 1
ORDER BY ic.key_ordinal
"@
            $keyRows = @(Invoke-DbaQuery @cp -SqlInstance $script:wiz.SqlInstance -Database $script:wiz.Database -Query $keyQuery -ErrorAction Stop)
            $script:step6CopyKeyColumnNeeded = ($keyRows.Count -ne 1)

            if ($script:step6CopyKeyColumnNeeded)
            {
                $colQuery = "SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'[$($script:wiz.SchemaName)].[$($script:wiz.TableName)]') ORDER BY column_id;"
                $colRows = @(Invoke-DbaQuery @cp -SqlInstance $script:wiz.SqlInstance -Database $script:wiz.Database -Query $colQuery -ErrorAction Stop)
                $clb6CopyKey.Items.Clear()
                foreach ($c in $colRows) { [void]$clb6CopyKey.Items.Add($c.name) }
            }
        }
        catch { $script:step6CopyKeyColumnNeeded = $true }
    }

    function Set-Step6Mode
    {
        $copyMode = $script:wiz.SourceIsPartitioned
        $migrateNow = (-not $copyMode) -and $chk6MigrateNow.Checked

        # --- Ablaufplan D: bereits partitionierte Quelle -> nur der Copy-Bereich ist sichtbar -----
        $chk6MigrateNow.Visible = -not $copyMode
        $lbl6CopyInfo.Visible = $copyMode
        $lbl6TargetDb.Visible = $copyMode; $txt6TargetDb.Visible = $copyMode
        $lbl6TargetTable.Visible = $copyMode; $txt6TargetTable.Visible = $copyMode
        if ($copyMode) { Test-Step6CopyKeyColumnNeed }
        $showCopyKey = $copyMode -and $script:step6CopyKeyColumnNeeded
        $lbl6CopyKey.Visible = $showCopyKey; $clb6CopyKey.Visible = $showCopyKey

        if ($copyMode)
        {
            $lbl6Key.Visible = $false; $clb6Key.Visible = $false
            $chk6Retention.Visible = $false; $lbl6a.Visible = $false; $num6Retention.Visible = $false; $cmb6Unit.Visible = $false
            $chk6Archive.Visible = $false; $lbl6b.Visible = $false; $txt6ArchiveDb.Visible = $false
            return
        }

        # --- Ablaufplan A/B/C: unveraendertes bisheriges Verhalten --------------------------------
        if ($migrateNow) { Test-Step6KeyColumnNeed }
        $showKey = $migrateNow -and $script:step6KeyColumnNeeded

        $lbl6Key.Visible = $showKey; $clb6Key.Visible = $showKey

        $chk6Retention.Visible = -not $migrateNow
        $retOn = (-not $migrateNow) -and $chk6Retention.Checked
        $lbl6a.Visible = $retOn; $num6Retention.Visible = $retOn; $cmb6Unit.Visible = $retOn; $chk6Archive.Visible = -not $migrateNow
        $archOn = $retOn -and $chk6Archive.Checked
        $lbl6b.Visible = $migrateNow -or $archOn; $txt6ArchiveDb.Visible = $migrateNow -or $archOn

        # Archive-Database-Feld teilen sich beide Modi - Position haengt davon ab, ob der
        # Key-Column-Bereich gerade sichtbar ist (Migrate-now) bzw. bleibt an fester Stelle im
        # Retention-Modus (dort variiert die Y-Position nicht mit dem Inhalt darueber).
        if ($migrateNow)
        {
            $y = if ($showKey) { 156 } else { 40 }
            $lbl6b.Location = New-Object System.Drawing.Point(24, ($y + 4))
            $txt6ArchiveDb.Location = New-Object System.Drawing.Point(170, $y)
        }
        else
        {
            $lbl6b.Location = New-Object System.Drawing.Point(44, 144)
            $txt6ArchiveDb.Location = New-Object System.Drawing.Point(170, 140)
        }
    }
    $chk6MigrateNow.Add_CheckedChanged({ Set-Step6Mode })
    $chk6Retention.Add_CheckedChanged({ Set-Step6Mode })
    $chk6Archive.Add_CheckedChanged({ Set-Step6Mode })
    Set-Step6Mode

    # ===================================================================================
    # Schritt 7: Zusammenfassung + Ausfuehren
    # ===================================================================================
    $p7 = New-Object System.Windows.Forms.Panel
    $p7.Dock = 'Fill'
    $p7.BackColor = $cPanel

    $txt7Summary = New-Object System.Windows.Forms.TextBox
    $txt7Summary.Multiline = $true
    $txt7Summary.ReadOnly = $true
    $txt7Summary.ScrollBars = 'Vertical'
    $txt7Summary.Location = New-Object System.Drawing.Point(0, 0)
    $txt7Summary.Size = New-Object System.Drawing.Size(940, 220)
    $txt7Summary.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $txt7Summary.BackColor = $cWindow
    $txt7Summary.ForeColor = $cText
    $txt7Summary.BorderStyle = 'FixedSingle'
    $txt7Summary.Font = New-Object System.Drawing.Font('Consolas', 9)

    $btn7Execute = New-Object System.Windows.Forms.Button
    $btn7Execute.Text = 'Execute Now'
    $btn7Execute.Location = New-Object System.Drawing.Point(0, 232)
    $btn7Execute.Size = New-Object System.Drawing.Size(160, 32)
    & $styleButton $btn7Execute

    $txt7Log = New-Object System.Windows.Forms.TextBox
    $txt7Log.Multiline = $true
    $txt7Log.ReadOnly = $true
    $txt7Log.ScrollBars = 'Vertical'
    $txt7Log.Location = New-Object System.Drawing.Point(0, 276)
    $txt7Log.Size = New-Object System.Drawing.Size(940, 200)
    $txt7Log.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor
                      [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $txt7Log.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
    $txt7Log.ForeColor = $cText
    $txt7Log.BorderStyle = 'FixedSingle'
    $txt7Log.Font = New-Object System.Drawing.Font('Consolas', 8.5)

    $p7.Controls.Add($txt7Summary)
    $p7.Controls.Add($btn7Execute)
    $p7.Controls.Add($txt7Log)

    function Add-Log
    {
        param ([string]$Text)
        $txt7Log.AppendText("$(Get-Date -Format 'HH:mm:ss')  $Text`r`n")
    }

    function Load-Step7
    {
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("Instance             : $($script:wiz.SqlInstance)")
        $lines.Add("Database             : $($script:wiz.Database)")
        $lines.Add("Table                : $($script:wiz.SchemaName).$($script:wiz.TableName) ($(if ($script:wiz.IsHeap) { 'Heap' } else { 'Clustered' }))")
        $lines.Add("Partition Column     : $($script:wiz.PartitionColumn) ($($script:wiz.DataType))")
        $lines.Add("Granularity          : $($script:wiz.Granularity) | BoundaryType: $($script:wiz.BoundaryType)" +
            $(if ($script:wiz.BoundaryType -ne 'Date') { " | SurrogateDateFormat: $($script:wiz.SurrogateDateFormat)" } else { '' }))
        $lines.Add("Filegroup Strategy   : $($script:wiz.FilegroupStrategy) | Future Buffer: $($script:wiz.FutureBufferPeriods) period(s)")
        $lines.Add("Data Compression     : $($script:wiz.DataCompression)")
        if ($script:wiz.SourceIsPartitioned)
        {
            $targetTableForSummary = if ($txt6TargetTable.Text.Trim()) { $txt6TargetTable.Text.Trim() } else { $script:wiz.TableName }
            $lines.Add("Mode                 : COPY (new partitioning) -> '$($txt6TargetDb.Text.Trim()).$($script:wiz.SchemaName).$targetTableForSummary'")
            if ($clb6CopyKey.Visible -and $clb6CopyKey.CheckedItems.Count -gt 0) { $lines.Add("Key Column           : $($clb6CopyKey.CheckedItems[0]) (explicit)") }
            else { $lines.Add('Key Column           : (auto-derive from single-column clustered index/PK)') }
            $lines.Add("Partitions           : $($script:wiz.Boundaries.Count + 1) ($($script:wiz.Boundaries.Count) boundary value(s))")
            $lines.Add('                       Source table stays fully active and unchanged (no rename, no cutover).')
            $txt7Summary.Text = $lines -join "`r`n"
            return
        }
        if ($chk6MigrateNow.Checked)
        {
            $lines.Add("Mode                 : Migrate to archive database NOW -> '$($txt6ArchiveDb.Text.Trim())'")
            if ($clb6Key.Visible -and $clb6Key.CheckedItems.Count -gt 0) { $lines.Add("Key Column(s)        : $(($clb6Key.CheckedItems | ForEach-Object { $_ }) -join ', ') (explicit)") }
            else { $lines.Add('Key Column(s)        : (auto-derive from clustered index/PK)') }
            $lines.Add('                       Source table will be renamed and replaced by a view onto the')
            $lines.Add('                       archive copy once all closed periods are migrated (current,')
            $lines.Add('                       still-open period stays behind in the renamed table).')
        }
        else
        {
            $lines.Add("Partitions           : $($script:wiz.Boundaries.Count + 1) ($($script:wiz.Boundaries.Count) boundary value(s))")
            if ($chk6Retention.Checked)
            {
                $lines.Add("Automated Maintenance: Yes - Retention $($num6Retention.Value) $($cmb6Unit.SelectedItem)")
                if ($chk6Archive.Checked) { $lines.Add("Archiving            : Yes -> '$($txt6ArchiveDb.Text.Trim())'") }
                else { $lines.Add('Archiving            : No (delete only)') }
            }
            else { $lines.Add('Automated Maintenance: No (one-time conversion only)') }
        }
        $txt7Summary.Text = $lines -join "`r`n"
    }

    $btn7Execute.Add_Click({
        if ($script:wiz.SourceIsPartitioned)
        {
            if (-not $txt6TargetDb.Text.Trim())
            {
                [System.Windows.Forms.MessageBox]::Show("Please enter a Target Database name.", 'Missing input', 'OK', 'Warning') | Out-Null
                return
            }
            if ($clb6CopyKey.Visible -and $clb6CopyKey.CheckedItems.Count -eq 0)
            {
                [System.Windows.Forms.MessageBox]::Show("Please check exactly one Key Column - this table has no single-column clustered index/PK that could be derived automatically.", 'Missing input', 'OK', 'Warning') | Out-Null
                return
            }

            $targetTableName = if ($txt6TargetTable.Text.Trim()) { $txt6TargetTable.Text.Trim() } else { $script:wiz.TableName }
            $confirm = [System.Windows.Forms.MessageBox]::Show("Copy '$($script:wiz.SchemaName).$($script:wiz.TableName)' as a NEW, independently partitioned table into '$($txt6TargetDb.Text.Trim())'?`n`nThe source table is NOT modified - it stays active under its current partitioning.", 'Confirm', 'YesNo', 'Warning')
            if ($confirm -ne 'Yes') { return }

            $btn7Execute.Enabled = $false
            $btnBack.Enabled = $false
            $cp = $script:connParams
            Add-Log "Starting copy of '$($script:wiz.SchemaName).$($script:wiz.TableName)' -> '$($txt6TargetDb.Text.Trim()).$($script:wiz.SchemaName).$targetTableName' ..."
            try
            {
                $copyParams = @{
                    SqlInstance         = $script:wiz.SqlInstance
                    Database            = $script:wiz.Database
                    Schema              = $script:wiz.SchemaName
                    Table               = $script:wiz.TableName
                    TargetDatabaseName  = $txt6TargetDb.Text.Trim()
                    TargetTableName     = $targetTableName
                    PartitionColumn     = $script:wiz.PartitionColumn
                    Granularity         = $script:wiz.Granularity
                    BoundaryType        = $script:wiz.BoundaryType
                    SurrogateDateFormat = $script:wiz.SurrogateDateFormat
                    FilegroupStrategy   = $script:wiz.FilegroupStrategy
                    FutureBufferPeriods = $script:wiz.FutureBufferPeriods
                    DataCompression     = $script:wiz.DataCompression
                    Confirm             = $false
                    ErrorAction         = 'Stop'
                    EnableException     = $true
                }
                if ($clb6CopyKey.Visible -and $clb6CopyKey.CheckedItems.Count -gt 0) { $copyParams['KeyColumn'] = [string]$clb6CopyKey.CheckedItems[0] }
                $result = Copy-sqmPartitionedTable @cp @copyParams
                Add-Log "Copy completed: $($result.RowsCopied) row(s) copied, $($result.RowsVerified) row(s) verified in target, status $($result.Status)."
                Add-Log 'DONE.'
                [System.Windows.Forms.MessageBox]::Show("'$($script:wiz.SchemaName).$($script:wiz.TableName)' was copied successfully to '$($txt6TargetDb.Text.Trim())'.", 'Success', 'OK', 'Information') | Out-Null
            }
            catch
            {
                Add-Log "ERROR: $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Error during copy:`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
                $btnBack.Enabled = $true
                $btn7Execute.Enabled = $true
            }
            return
        }

        $migrateNow = $chk6MigrateNow.Checked
        if ($migrateNow -and -not $txt6ArchiveDb.Text.Trim())
        {
            [System.Windows.Forms.MessageBox]::Show("Please enter an Archive Database name.", 'Missing input', 'OK', 'Warning') | Out-Null
            return
        }

        $confirmText = if ($migrateNow)
        {
            "Migrate '$($script:wiz.SchemaName).$($script:wiz.TableName)' to archive database '$($txt6ArchiveDb.Text.Trim())' now?`n`nThe source table will be renamed and replaced by a view once all closed periods are migrated."
        }
        else
        {
            "Partition '$($script:wiz.SchemaName).$($script:wiz.TableName)' now?`n`nThis operation changes the table structure (index rebuild)."
        }
        $confirm = [System.Windows.Forms.MessageBox]::Show($confirmText, 'Confirm', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }

        $btn7Execute.Enabled = $false
        $btnBack.Enabled = $false
        $cp = $script:connParams

        if ($migrateNow)
        {
            Add-Log "Starting archive migration of '$($script:wiz.SchemaName).$($script:wiz.TableName)' -> '$($txt6ArchiveDb.Text.Trim())' ..."
            try
            {
                $archParams = @{
                    SqlInstance             = $script:wiz.SqlInstance
                    Database                = $script:wiz.Database
                    Schema                  = $script:wiz.SchemaName
                    Table                   = $script:wiz.TableName
                    ArchiveDatabaseName     = $txt6ArchiveDb.Text.Trim()
                    DateColumn              = $script:wiz.PartitionColumn
                    Granularity             = $script:wiz.Granularity
                    FilegroupStrategy       = $script:wiz.FilegroupStrategy
                    FutureBufferPeriods     = $script:wiz.FutureBufferPeriods
                    DataCompression         = $script:wiz.DataCompression
                    AllowKeyChange          = $true
                    PurgeSourceAfterArchive = $true
                    CutoverToArchiveView    = $true
                    Confirm                 = $false
                    ErrorAction             = 'Stop'
                    EnableException         = $true
                }
                if ($script:wiz.BoundaryType) { $archParams['BoundaryType'] = $script:wiz.BoundaryType; $archParams['SurrogateDateFormat'] = $script:wiz.SurrogateDateFormat }
                if ($clb6Key.Visible -and $clb6Key.CheckedItems.Count -gt 0)
                {
                    $archParams['KeyColumn'] = @($clb6Key.CheckedItems | ForEach-Object { $_ })
                }
                elseif ($clb6Key.Visible)
                {
                    [System.Windows.Forms.MessageBox]::Show("Please check at least one Key Column - this table has no simple unique key that could be derived automatically.", 'Missing input', 'OK', 'Warning') | Out-Null
                    $btn7Execute.Enabled = $true
                    $btnBack.Enabled = $true
                    return
                }
                $result = Invoke-sqmTableArchiveMigration @cp @archParams
                Add-Log "Migration completed: $($result.MonthsProcessed) month(s) processed, $($result.TotalRowsArchived) row(s) archived, $($result.RowsPurged) row(s) purged from source, status $($result.Status)."
                if ($result.CutoverPerformed)
                {
                    Add-Log "Cutover done: '$($script:wiz.SchemaName).$($script:wiz.TableName)' is now a view onto the archive copy. The renamed original table was kept, not dropped - check the log for its name and any residual (not-yet-archived) rows before dropping it."
                }
                else
                {
                    Add-Log 'Cutover not yet performed (not all requested periods are archived, or it already ran previously) - run again later to retry/continue.'
                }

                Add-Log 'DONE.'
                [System.Windows.Forms.MessageBox]::Show("'$($script:wiz.SchemaName).$($script:wiz.TableName)' migration to '$($txt6ArchiveDb.Text.Trim())' completed.", 'Success', 'OK', 'Information') | Out-Null
            }
            catch
            {
                Add-Log "ERROR: $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Error during archive migration:`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
                $btnBack.Enabled = $true
                $btn7Execute.Enabled = $true
            }
            return
        }

        Add-Log "Starting conversion of '$($script:wiz.SchemaName).$($script:wiz.TableName)' ..."
        try
        {
            $convParams = @{
                SqlInstance         = $script:wiz.SqlInstance
                Database            = $script:wiz.Database
                Schema              = $script:wiz.SchemaName
                Table               = $script:wiz.TableName
                PartitionColumn     = $script:wiz.PartitionColumn
                Granularity         = $script:wiz.Granularity
                BoundaryType        = $script:wiz.BoundaryType
                SurrogateDateFormat = $script:wiz.SurrogateDateFormat
                FilegroupStrategy   = $script:wiz.FilegroupStrategy
                FutureBufferPeriods = $script:wiz.FutureBufferPeriods
                DataCompression     = $script:wiz.DataCompression
                AllowKeyChange      = $true
                Confirm             = $false
                ErrorAction         = 'Stop'
                EnableException     = $true
            }
            if ($script:wiz.IsEmpty)
            {
                $convParams['ManualStartValue'] = $txt3Start.Text.Trim()
                if ($txt3End.Text.Trim()) { $convParams['ManualEndValue'] = $txt3End.Text.Trim() }
            }
            $result = Invoke-sqmTablePartitionConversion @cp @convParams
            Add-Log "Conversion completed: $($result.PartitionCount) partition(s), status $($result.Status)."

            if ($chk6Retention.Checked)
            {
                Add-Log 'Registering table for automated maintenance ...'
                $regParams = @{
                    SqlInstance           = $script:wiz.SqlInstance
                    Database              = $script:wiz.Database
                    Schema                = $script:wiz.SchemaName
                    Table                 = $script:wiz.TableName
                    PartitionColumn       = $script:wiz.PartitionColumn
                    PartitionFunctionName = $result.PartitionFunctionName
                    PartitionSchemeName   = $result.PartitionSchemeName
                    Granularity           = $script:wiz.Granularity
                    BoundaryType          = $script:wiz.BoundaryType
                    SurrogateDateFormat   = $script:wiz.SurrogateDateFormat
                    FilegroupStrategy     = $script:wiz.FilegroupStrategy
                    RetentionValue        = [int]$num6Retention.Value
                    RetentionUnit         = [string]$cmb6Unit.SelectedItem
                    DataCompression       = $script:wiz.DataCompression
                    Confirm               = $false
                    ErrorAction           = 'Stop'
                }
                if ($chk6Archive.Checked -and $txt6ArchiveDb.Text.Trim())
                {
                    $regParams['ArchiveEnabled'] = $true
                    $regParams['ArchiveDatabaseName'] = $txt6ArchiveDb.Text.Trim()
                }
                Register-sqmPartitionTable @cp @regParams | Out-Null
                Add-Log 'Registration completed. Maintenance jobs (New-sqmPartitionExtendJob / New-sqmPartitionRetentionJob) must be set up separately once, if not already in place.'
            }

            Add-Log 'DONE.'
            [System.Windows.Forms.MessageBox]::Show("'$($script:wiz.SchemaName).$($script:wiz.TableName)' was partitioned successfully.", 'Success', 'OK', 'Information') | Out-Null
        }
        catch
        {
            Add-Log "ERROR: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Error during conversion:`n$($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
            $btnBack.Enabled = $true
            $btn7Execute.Enabled = $true
        }
    })

    # ----- Alle Schritt-Panels registrieren ----------------------------------------------
    $panels = @($p0, $p1, $p2, $p3, $p4, $p5, $p6, $p7)
    foreach ($p in $panels) { $p.Visible = $false; $pContent.Controls.Add($p) }

    function Show-Step
    {
        param ([int]$Index)
        foreach ($p in $panels) { $p.Visible = $false }
        $panels[$Index].Visible = $true
        $lblStep.Text = $stepTitles[$Index]
        $btnBack.Enabled = ($Index -gt 0)
        $btnNext.Text = if ($Index -eq 7) { 'Finish' } else { 'Next >' }
        # KEIN Set-Status '' hier: Confirm-StepAndAdvance ruft VOR Show-Step die passende
        # Load-StepN-Funktion auf, die eine aussagekraeftige Statusmeldung setzt (z.B. "X
        # Tabelle(n) gefunden." oder eine Fehlermeldung) - ein Clear hier wuerde diese
        # Meldung sofort wieder loeschen, bevor der Anwender sie je sieht.
    }

    # ----- Validierung + Datenuebernahme pro Schritt vor dem Weiterschalten --------------
    function Confirm-StepAndAdvance
    {
        switch ($script:currentStep)
        {
            0 {
                if ([string]::IsNullOrWhiteSpace($txt0Instance.Text) -or -not $cmb0Database.SelectedItem)
                {
                    Set-Status 'Please enter an instance and click "Connect", then select a database.' 'Warn'
                    return $false
                }
                # Roher Instanzname + $script:connParams['SqlCredential'] (siehe Schritt 0) - nicht
                # das verbundene Objekt aus dem Connect-Schritt, das nur fuer den dortigen
                # Get-DbaDatabase-Aufruf noetig war (siehe Kommentar dort).
                $script:wiz.SqlInstance = $txt0Instance.Text.Trim()
                $script:wiz.Database = [string]$cmb0Database.SelectedItem
                Load-Step1
                return $true
            }
            1 {
                if ($grid1.SelectedRows.Count -eq 0) { Set-Status 'Please select a table.' 'Warn'; return $false }
                $r = $grid1.SelectedRows[0]
                $script:wiz.SchemaName = $r.Cells['Schema'].Value
                $script:wiz.TableName = $r.Cells['Tabelle'].Value
                $script:wiz.IsHeap = ($r.Cells['Typ'].Value -eq 'Heap')
                $script:wiz.SourceIsPartitioned = ($r.Cells['Status'].Value -eq 'already partitioned')
                $script:step6KeyColumnChecked = $false
                $script:step6CopyKeyColumnChecked = $false
                Set-Step6Mode
                if ($script:wiz.SourceIsPartitioned)
                {
                    Set-Status "'$($script:wiz.SchemaName).$($script:wiz.TableName)' is already partitioned - the wizard will offer to COPY it (new partitioning) to another database instead of converting it." 'Info'
                }
                Load-Step2
                return $true
            }
            2 {
                if ($grid2.SelectedRows.Count -eq 0) { Set-Status 'Please select a column.' 'Warn'; return $false }
                $r = $grid2.SelectedRows[0]
                if ($r.Cells['Kompatibel'].Value -ne 'Yes') { Set-Status 'This data type is not allowed for partition functions.' 'Warn'; return $false }
                $script:wiz.PartitionColumn = $r.Cells['Spalte'].Value
                $script:wiz.DataType = $r.Cells['Typ'].Value
                Load-Step3
                return $true
            }
            3 {
                if ($script:wiz.IsEmpty -and [string]::IsNullOrWhiteSpace($txt3Start.Text))
                {
                    Set-Status 'Please enter a manual start value.' 'Warn'; return $false
                }
                if ($script:wiz.SuggestedGranularity) { $cmb4Gran.SelectedItem = $script:wiz.SuggestedGranularity }
                elseif (-not $cmb4Gran.SelectedItem) { $cmb4Gran.SelectedIndex = 0 }
                Update-Step4Warning
                $isDateCol = $script:wiz.DataType -in @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')
                $lbl4d.Visible = -not $isDateCol
                $cmb4Fmt.Visible = -not $isDateCol
                return $true
            }
            4 { Load-Step5; return $true }
            5 { return $true }
            6 { Load-Step7; return $true }
            7 { $form.Close(); return $false }
        }
        return $true
    }

    $btnNext.Add_Click({
        if (Confirm-StepAndAdvance)
        {
            if ($script:currentStep -lt 7) { $script:currentStep++; Show-Step $script:currentStep }
        }
    })
    $btnBack.Add_Click({
        if ($script:currentStep -gt 0) { $script:currentStep--; Show-Step $script:currentStep; Set-Status '' }
    })
    $btnCancel.Add_Click({ $form.Close() })
    $form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $form.Close() } })

    # ----- Layout zusammenbauen -----------------------------------------------------------
    $form.Controls.Add($pContent)
    $form.Controls.Add($pNav)
    $form.Controls.Add($pHead)

    # Von PowerShell aus gestartete WinForms-Fenster erscheinen manchmal minimiert oder hinter
    # anderen Fenstern (der Prozess erbt den anfaenglichen Show-Command des aufrufenden Fensters
    # fuer sein erstes GUI-Fenster). Explizit Normal erzwingen und beim ersten Anzeigen kurz
    # TopMost setzen + aktivieren, um das Fenster zuverlaessig in den Vordergrund zu holen.
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Add_Shown({
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.TopMost = $true
        $form.Activate()
        $form.TopMost = $false
    })

    Show-Step 0
    [void]$form.ShowDialog()
}
