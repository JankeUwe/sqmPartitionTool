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

    Fuehrt am Ende Invoke-sqmTablePartitionConversion aus und bietet optional direkt im Anschluss
    Register-sqmPartitionTable mit Retention/Archiv-Einstellungen an.

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
        PartitionColumn     = $null
        DataType            = $null
        SuggestedGranularity = $null
        MinValue            = $null
        MaxValue            = $null
        IsEmpty             = $false
        Granularity         = 'Month'
        BoundaryType        = 'Date'
        FilegroupStrategy   = 'Single'
        FutureBufferPeriods = 3
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

    $lbl0b = New-Object System.Windows.Forms.Label
    $lbl0b.Text = 'Database:'
    $lbl0b.Location = New-Object System.Drawing.Point(4, 54)
    $lbl0b.AutoSize = $true
    $lbl0b.ForeColor = $cDim
    $cmb0Database = New-Object System.Windows.Forms.ComboBox
    $cmb0Database.Location = New-Object System.Drawing.Point(140, 50)
    $cmb0Database.Size = New-Object System.Drawing.Size(260, 24)
    $cmb0Database.BackColor = $cWindow
    $cmb0Database.ForeColor = $cText
    $cmb0Database.DropDownStyle = 'DropDownList'
    $cmb0Database.FlatStyle = 'Flat'

    $p0.Controls.Add($lbl0a)
    $p0.Controls.Add($txt0Instance)
    $p0.Controls.Add($btn0Connect)
    $p0.Controls.Add($lbl0b)
    $p0.Controls.Add($cmb0Database)

    $btn0Connect.Add_Click({
        Set-Status "Connecting to '$($txt0Instance.Text.Trim())' ..." 'Info'
        try
        {
            $cp = $script:connParams
            $dbs = Get-DbaDatabase @cp -SqlInstance $txt0Instance.Text.Trim() -ExcludeSystem -ErrorAction Stop | Sort-Object Name
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

    $lbl4Warn = New-Object System.Windows.Forms.Label
    $lbl4Warn.Location = New-Object System.Drawing.Point(4, 130)
    $lbl4Warn.Size = New-Object System.Drawing.Size(900, 40)
    $lbl4Warn.ForeColor = $cWarn
    $lbl4Warn.Text = ''

    $p4.Controls.Add($lbl4a); $p4.Controls.Add($cmb4Gran)
    $p4.Controls.Add($lbl4b); $p4.Controls.Add($cmb4Fg)
    $p4.Controls.Add($lbl4c); $p4.Controls.Add($num4Buffer)
    $p4.Controls.Add($lbl4Warn)

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
            $script:wiz.BoundaryType = if ($script:wiz.DataType -in @('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')) { 'Date' } else { 'Int' }

            $minV = if ($script:wiz.IsEmpty) { $txt3Start.Text.Trim() } else { $script:wiz.MinValue }
            $maxV = if ($script:wiz.IsEmpty) { $(if ($txt3End.Text.Trim()) { $txt3End.Text.Trim() } else { $txt3Start.Text.Trim() }) } else { $script:wiz.MaxValue }

            $boundaries = Get-sqmPartitionBoundaryList -MinValue $minV -MaxValue $maxV -Granularity $script:wiz.Granularity -BoundaryType $script:wiz.BoundaryType -FutureBufferPeriods $script:wiz.FutureBufferPeriods -ErrorAction Stop
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

    $chk6Retention = New-Object System.Windows.Forms.CheckBox
    $chk6Retention.Text = 'Set up automatic maintenance (sliding-window extension + retention)'
    $chk6Retention.Location = New-Object System.Drawing.Point(4, 8)
    $chk6Retention.AutoSize = $true
    $chk6Retention.ForeColor = $cText

    $lbl6a = New-Object System.Windows.Forms.Label
    $lbl6a.Text = 'Retention:'
    $lbl6a.Location = New-Object System.Drawing.Point(24, 44)
    $lbl6a.AutoSize = $true
    $lbl6a.ForeColor = $cDim
    $num6Retention = New-Object System.Windows.Forms.NumericUpDown
    $num6Retention.Location = New-Object System.Drawing.Point(140, 40)
    $num6Retention.Size = New-Object System.Drawing.Size(60, 24)
    $num6Retention.Minimum = 1
    $num6Retention.Maximum = 999
    $num6Retention.Value = 36
    $num6Retention.BackColor = $cWindow
    $num6Retention.ForeColor = $cText

    $cmb6Unit = New-Object System.Windows.Forms.ComboBox
    $cmb6Unit.Location = New-Object System.Drawing.Point(210, 40)
    $cmb6Unit.Size = New-Object System.Drawing.Size(100, 24)
    $cmb6Unit.BackColor = $cWindow
    $cmb6Unit.ForeColor = $cText
    $cmb6Unit.DropDownStyle = 'DropDownList'
    [void]$cmb6Unit.Items.AddRange(@('Months', 'Years'))
    $cmb6Unit.SelectedIndex = 0

    $chk6Archive = New-Object System.Windows.Forms.CheckBox
    $chk6Archive.Text = 'Copy to an archive database before removal (same instance)'
    $chk6Archive.Location = New-Object System.Drawing.Point(24, 76)
    $chk6Archive.AutoSize = $true
    $chk6Archive.ForeColor = $cText

    $lbl6b = New-Object System.Windows.Forms.Label
    $lbl6b.Text = 'Archive Database:'
    $lbl6b.Location = New-Object System.Drawing.Point(44, 108)
    $lbl6b.AutoSize = $true
    $lbl6b.ForeColor = $cDim
    $txt6ArchiveDb = New-Object System.Windows.Forms.TextBox
    $txt6ArchiveDb.Location = New-Object System.Drawing.Point(170, 104)
    $txt6ArchiveDb.Size = New-Object System.Drawing.Size(200, 24)
    $txt6ArchiveDb.BackColor = $cWindow
    $txt6ArchiveDb.ForeColor = $cText
    $txt6ArchiveDb.BorderStyle = 'FixedSingle'

    $p6.Controls.Add($chk6Retention)
    $p6.Controls.Add($lbl6a); $p6.Controls.Add($num6Retention); $p6.Controls.Add($cmb6Unit)
    $p6.Controls.Add($chk6Archive)
    $p6.Controls.Add($lbl6b); $p6.Controls.Add($txt6ArchiveDb)

    function Set-Step6Enabled
    {
        $en = $chk6Retention.Checked
        $lbl6a.Enabled = $en; $num6Retention.Enabled = $en; $cmb6Unit.Enabled = $en; $chk6Archive.Enabled = $en
        $archEn = $en -and $chk6Archive.Checked
        $lbl6b.Enabled = $archEn; $txt6ArchiveDb.Enabled = $archEn
    }
    $chk6Retention.Add_CheckedChanged({ Set-Step6Enabled })
    $chk6Archive.Add_CheckedChanged({ Set-Step6Enabled })
    Set-Step6Enabled

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
        $lines.Add("Granularity          : $($script:wiz.Granularity) | BoundaryType: $($script:wiz.BoundaryType)")
        $lines.Add("Filegroup Strategy   : $($script:wiz.FilegroupStrategy) | Future Buffer: $($script:wiz.FutureBufferPeriods) period(s)")
        $lines.Add("Partitions           : $($script:wiz.Boundaries.Count + 1) ($($script:wiz.Boundaries.Count) boundary value(s))")
        if ($chk6Retention.Checked)
        {
            $lines.Add("Automated Maintenance: Yes - Retention $($num6Retention.Value) $($cmb6Unit.SelectedItem)")
            if ($chk6Archive.Checked) { $lines.Add("Archiving            : Yes -> '$($txt6ArchiveDb.Text.Trim())'") }
            else { $lines.Add('Archiving            : No (delete only)') }
        }
        else { $lines.Add('Automated Maintenance: No (one-time conversion only)') }
        $txt7Summary.Text = $lines -join "`r`n"
    }

    $btn7Execute.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Partition '$($script:wiz.SchemaName).$($script:wiz.TableName)' now?`n`nThis operation changes the table structure (index rebuild).",
            'Confirm Partitioning', 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { return }

        $btn7Execute.Enabled = $false
        $btnBack.Enabled = $false
        Add-Log "Starting conversion of '$($script:wiz.SchemaName).$($script:wiz.TableName)' ..."
        try
        {
            $cp = $script:connParams
            $convParams = @{
                SqlInstance         = $script:wiz.SqlInstance
                Database            = $script:wiz.Database
                Schema              = $script:wiz.SchemaName
                Table               = $script:wiz.TableName
                PartitionColumn     = $script:wiz.PartitionColumn
                Granularity         = $script:wiz.Granularity
                BoundaryType        = $script:wiz.BoundaryType
                FilegroupStrategy   = $script:wiz.FilegroupStrategy
                FutureBufferPeriods = $script:wiz.FutureBufferPeriods
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
                    FilegroupStrategy     = $script:wiz.FilegroupStrategy
                    RetentionValue        = [int]$num6Retention.Value
                    RetentionUnit         = [string]$cmb6Unit.SelectedItem
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
                $script:wiz.SqlInstance = $txt0Instance.Text.Trim()
                $script:wiz.Database = [string]$cmb0Database.SelectedItem
                Load-Step1
                return $true
            }
            1 {
                if ($grid1.SelectedRows.Count -eq 0) { Set-Status 'Please select a table.' 'Warn'; return $false }
                $r = $grid1.SelectedRows[0]
                if ($r.Cells['Status'].Value -eq 'already partitioned')
                {
                    Set-Status 'This table is already partitioned - please select another one.' 'Warn'; return $false
                }
                $script:wiz.SchemaName = $r.Cells['Schema'].Value
                $script:wiz.TableName = $r.Cells['Tabelle'].Value
                $script:wiz.IsHeap = ($r.Cells['Typ'].Value -eq 'Heap')
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
