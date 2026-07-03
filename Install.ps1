<#
.SYNOPSIS
    Installs the sqmPartitionTool module into the PowerShell module path.

.DESCRIPTION
    Copies the module to either the system-wide module path (requires Admin)
    or the current user's personal module path (no Admin rights needed).

    The default scope is determined automatically:
      - Running as Administrator  -> AllUsers  ($env:ProgramFiles\WindowsPowerShell\Modules)
      - Running as normal user    -> CurrentUser ($HOME\Documents\WindowsPowerShell\Modules)
    Pass -Scope explicitly to override this behaviour.

    The required dependency 'dbatools' is ensured automatically in the SAME scope
    before the import test (installed from the PSGallery if missing). 'sqmSQLTool'
    is a required dependency too (Invoke-sqmLogging, Get-sqmSaLogin, WinForms theme)
    but is NOT on the PSGallery - it is only checked for and a clear error is shown
    if missing, pointing at sqmSQLTool's own Install.cmd.

.PARAMETER Scope
    Installation scope:
      CurrentUser  — installs to $HOME\Documents\WindowsPowerShell\Modules
      AllUsers     — installs to $env:ProgramFiles\WindowsPowerShell\Modules (requires Admin)
    Default: AllUsers when running as Administrator, CurrentUser otherwise.

.PARAMETER Source
    Source directory of the module. Defaults to the script's own directory.

.PARAMETER Destination
    Explicit destination path. Overrides -Scope when specified.

.EXAMPLE
    .\Install.ps1
    Installs for the current user — no Admin rights required.

.EXAMPLE
    .\Install.cmd
    Recommended when running from a cross-domain share (handles execution policy).

.EXAMPLE
    .\Install.ps1 -Scope AllUsers
    Installs system-wide — requires Admin rights.

.NOTES
    Uses robocopy /COPY:DAT to copy the module data. Note: /COPY:DAT does NOT strip
    the Zone.Identifier ADS (Mark-of-the-Web) - the subsequent Unblock-File pass on all
    destination files is what removes it.
#>
param(
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope       = '',          # auto-detected below
    [string]$Source      = $PSScriptRoot,
    [string]$Destination = ''
)

# ---------------------------------------------------------------------------
# 0. Scope auto-detect: Admin -> AllUsers, sonst CurrentUser
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
             [Security.Principal.WindowsBuiltInRole]'Administrator')

if ($Scope -eq '') {
    $Scope = if ($isAdmin) { 'AllUsers' } else { 'CurrentUser' }
    Write-Host "Auto-detected Scope: $Scope" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# 1. Zielpfad bestimmen
# ---------------------------------------------------------------------------
if (-not $Destination) {
    if ($Scope -eq 'AllUsers') {
        $Destination = "$env:ProgramFiles\WindowsPowerShell\Modules\sqmPartitionTool"
    } else {
        $docsPath    = [Environment]::GetFolderPath('MyDocuments')
        $Destination = Join-Path $docsPath "WindowsPowerShell\Modules\sqmPartitionTool"
    }
}

# ---------------------------------------------------------------------------
# 2. Doppel-Installation erkennen und warnen
# ---------------------------------------------------------------------------
$docsPath_     = [Environment]::GetFolderPath('MyDocuments')
$pathUser      = Join-Path $docsPath_ "WindowsPowerShell\Modules\sqmPartitionTool"
$pathAllUsers  = "$env:ProgramFiles\WindowsPowerShell\Modules\sqmPartitionTool"
$existsUser    = Test-Path $pathUser
$existsAll     = Test-Path $pathAllUsers

if ($existsUser -and $existsAll -and $Scope -eq 'AllUsers') {
    # Running as Admin installing AllUsers — remove the CurrentUser copy automatically
    Write-Host "Both installations detected. Removing CurrentUser copy..." -ForegroundColor Yellow
    Write-Host "  $pathUser" -ForegroundColor Gray
    Remove-Item $pathUser -Recurse -Force
    Write-Host "CurrentUser installation removed." -ForegroundColor Green
    Write-Host ""
    $existsUser = $false

} elseif ($existsUser -and $existsAll) {
    # CurrentUser install, both exist — warn, cannot auto-remove AllUsers without Admin
    Write-Warning "sqmPartitionTool is installed in BOTH locations:"
    Write-Warning "  CurrentUser : $pathUser"
    Write-Warning "  AllUsers    : $pathAllUsers"
    Write-Warning "PowerShell loads the CurrentUser version — the AllUsers copy is ignored."
    Write-Warning "To remove the AllUsers copy (requires Admin):"
    Write-Warning "  Remove-Item '$pathAllUsers' -Recurse -Force"
    Write-Host ""

} elseif ($Scope -eq 'CurrentUser' -and $existsAll) {
    Write-Warning "An AllUsers installation already exists at: $pathAllUsers"
    Write-Warning "After this install, PowerShell will load the CurrentUser version and ignore AllUsers."
    Write-Host ""

} elseif ($Scope -eq 'AllUsers' -and $existsUser) {
    # Running as Admin — remove the CurrentUser copy automatically
    Write-Host "CurrentUser installation detected. Removing to avoid conflicts..." -ForegroundColor Yellow
    Write-Host "  $pathUser" -ForegroundColor Gray
    Remove-Item $pathUser -Recurse -Force
    Write-Host "CurrentUser installation removed." -ForegroundColor Green
    Write-Host ""
    $existsUser = $false
}

# ---------------------------------------------------------------------------
# 3. Scope-Hinweis und Admin-Check
# ---------------------------------------------------------------------------
if ($Scope -eq 'AllUsers') {
    if (-not $isAdmin) {
        Write-Warning "Scope 'AllUsers' requires Administrator rights."
        Write-Warning "Run Install.cmd as Administrator, or use:  .\Install.ps1  (installs for current user only)"
        exit 1
    }
} else {
    # CurrentUser — Hinweis auf systemweite Installation
    Write-Host ""
    if ($isAdmin) {
        Write-Host "INFO: You are running as Administrator." -ForegroundColor Cyan
        Write-Host "      Installing for the current user only ($env:USERNAME)." -ForegroundColor Cyan
        Write-Host "      To install system-wide for ALL users, run:" -ForegroundColor Cyan
        Write-Host "        Install.cmd AllUsers" -ForegroundColor White
    } else {
        Write-Host "INFO: Installing for the current user only ($env:USERNAME)." -ForegroundColor Cyan
        Write-Host "      To install system-wide for ALL users, re-run as Administrator:" -ForegroundColor Cyan
        Write-Host "        Right-click Install.cmd > 'Run as administrator'" -ForegroundColor White
        Write-Host "        or: Install.cmd AllUsers  (in an elevated PowerShell)" -ForegroundColor White
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# 3b. Abhaengigkeit 'sqmSQLTool' pruefen (KEIN PSGallery-Modul - nur Check+Warnung)
#     Muss im GLEICHEN Scope liegen wie die Zielinstallation, sonst findet eine
#     AllUsers-Session ein nur in CurrentUser installiertes sqmSQLTool nicht.
# ---------------------------------------------------------------------------
$auSqlTool = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\sqmSQLTool'
$cuSqlTool = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\sqmSQLTool'
$sqlToolInScope = if ($Scope -eq 'AllUsers') { Test-Path $auSqlTool } else { (Test-Path $cuSqlTool) -or (Test-Path $auSqlTool) }

if (-not $sqlToolInScope) {
    Write-Warning "sqmSQLTool wurde im Scope '$Scope' nicht gefunden - sqmPartitionTool benoetigt es"
    Write-Warning "zwingend (Logging, WinForms-Theme, SA-Login-Ermittlung) und wird ohne es nicht laden."
    Write-Warning "sqmSQLTool ist nicht auf der PSGallery - bitte zuerst installieren:"
    Write-Warning "  sqmSQLTool\Install.cmd$(if ($Scope -eq 'AllUsers') { ' AllUsers' })"
    Write-Host ""
}

# ---------------------------------------------------------------------------
# 4. Modul kopieren
#    /COPY:DAT  -> Data, Attributes, Timestamps (KEIN Zone.Identifier-Strip!
#                  das erledigt der Unblock-File-Schritt 5)
#    /XD .git   -> exclude git directory
#    /XF        -> exclude meta files
# ---------------------------------------------------------------------------
Write-Host "Installing sqmPartitionTool to: $Destination" -ForegroundColor Cyan
robocopy $Source $Destination /E /PURGE /NJH /NJS /NDL /COPY:DAT `
    /XD .git tests bin `
    /XF .gitignore README.md LICENSE `
          Install.cmd Install.ps1 `
          "*.TempPoint.*" "*.RestorePoint.*" "*.psproj" "*.psproj.psbuild" "*.psprojs" `
          "desktop.ini" "Tester.ps1" "Test-Module*.ps1" `
          "coverage.xml" "testresults.xml"

# ---------------------------------------------------------------------------
# 5. Zone.Identifier auf dem Ziel entfernen
# ---------------------------------------------------------------------------
Write-Host "Unblocking files..." -ForegroundColor Cyan
Get-ChildItem -Path $Destination -Recurse -File | ForEach-Object {
    Unblock-File -Path $_.FullName -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 5b. dbatools-Abhaengigkeit im PASSENDEN Scope sicherstellen
#     sqmPartitionTool.psd1 hat RequiredModules = @('dbatools','sqmSQLTool') -> ohne
#     dbatools schlaegt der Import-Test (Schritt 6) fehl. Installation im GLEICHEN
#     Scope wie sqmPartitionTool, sonst Scope-Mismatch.
# ---------------------------------------------------------------------------
$auDbatools = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\dbatools'
$cuDbatools = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\dbatools'
if ($Scope -eq 'AllUsers') {
    $dbatoolsInScope = Test-Path $auDbatools                       # AllUsers braucht dbatools systemweit
} else {
    $dbatoolsInScope = (Test-Path $cuDbatools) -or (Test-Path $auDbatools)  # CurrentUser: beides ok
}

Write-Host "Pruefe Abhaengigkeit 'dbatools' (Scope $Scope)..." -ForegroundColor Cyan
if ($dbatoolsInScope) {
    Write-Host "  dbatools im passenden Scope vorhanden." -ForegroundColor Gray
} else {
    Write-Host "  dbatools fehlt im Scope '$Scope' - installiere von der PSGallery..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope $Scope -Force -ErrorAction Stop | Out-Null } catch {}
        Install-Module dbatools -Scope $Scope -Force -AllowClobber -ErrorAction Stop
        Write-Host "  dbatools installiert (-Scope $Scope)." -ForegroundColor Green
    } catch {
        Write-Warning "  dbatools-Installation fehlgeschlagen: $_"
        Write-Warning "  Bitte manuell nachholen:  Install-Module dbatools -Scope $Scope -Force -AllowClobber"
    }
}

# ---------------------------------------------------------------------------
# 6. Import testen
# ---------------------------------------------------------------------------
Write-Host "Testing module import..." -ForegroundColor Cyan
$importOk = $false
try {
    # Expliziter Pfad zur .psd1 verhindert dass eine alte Version aus PSModulePath geladen wird
    $psd1Path = Join-Path $Destination "sqmPartitionTool.psd1"
    Import-Module $psd1Path -Force -WarningAction SilentlyContinue -ErrorAction Stop
    $version = (Get-Module sqmPartitionTool).Version
    Write-Host "sqmPartitionTool v$version successfully loaded." -ForegroundColor Green
    Write-Host "Scope: $Scope  |  Path: $Destination" -ForegroundColor Gray
    $importOk = $true
} catch {
    Write-Warning "Import failed: $_"
    if (-not $sqlToolInScope) {
        Write-Warning "(Erwartet - sqmSQLTool fehlt noch im Scope '$Scope', siehe Hinweis oben.)"
    }
}

if ($importOk) {
    Write-Host ""
    Write-Host "Naechste Schritte:" -ForegroundColor Cyan
    Write-Host "  Show-sqmPartitionToolGui -SqlInstance ""SQL01""            # GUI-Assistent" -ForegroundColor Gray
    Write-Host "  New-sqmPartitionExtendJob -SqlInstance ""SQL01""           # Wartungs-Job: Sliding-Window-Erweiterung" -ForegroundColor Gray
    Write-Host "  New-sqmPartitionRetentionJob -SqlInstance ""SQL01""        # Wartungs-Job: Retention/Archivierung" -ForegroundColor Gray
}
