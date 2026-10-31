<#
.SYNOPSIS
  Unattended Windhawk provisioning (windhawk-cli 1.1.0, unofficial fork).
  Installs the engine from a local, hash-checked installer and applies blurred glass to the
  Windows 11 taskbar (Taskbar Styler), File Explorer (File Explorer Styler), the Start menu
  (Start Menu Styler), the notification center/action center (Notification Center Styler) and
  the Settings app (Settings Styler), plus native blur for classic Win32 windows
  (Translucent Windows). The Playbook additionally keeps the taskbar small and icon-only;
  no window titles or app names are shown.
  Fork: https://github.com/hansonxyz/windhawk-cli (Release v1.1.0)

  The installer must sit next to this script: windhawk-cli-1.1.0-installer.exe
  Its SHA-256 is checked before it runs. The installer itself is not downloaded; the mods are
  fetched from the official catalog by whcli.

.NOTES
  Real test passed on 2026-10-21/22 and 2026-10-27 (Windows 11 build 26300) including Settings,
  notification center (blurred glass), Quick Settings, Explorer, classic windows and packaged
  AppContainer processes; see CHANGELOG.md.
  - Authenticode signature of the installer is self-signed and not verified. Trust rests on the pinned SHA-256.
  - Taskbar targets follow the mod's built-in "TranslucentTaskbar" theme. Its shared
    $CommonBgBrush is overridden with the same BlurAmount=25 glass brush as the Start menu, so
    the taskbar, tray flyouts, menus and input switcher blur consistently instead of turning
    fully transparent. Legacy pure-transparent controlStyles[0..7] values are deleted on every
    run so upgrades cannot keep the old look.
  - File Explorer uses the mod's integrated "Translucent Explorer11" theme (including tooltips).
    Dark-theme resource overrides and direct command-bar styles keep the icon glyphs and
    TextLabels white instead of the default disabled gray.
  - The current Windows 11 Task Manager is pinned in the mod's process rules
    (RuledPrograms -> Taskmgr.exe) so its XAML shell keeps the acrylic effect. Its blur tint
    (AccentBlurBehind=25323232) matches the Start menu's #25323232 glass and stays active when
    the window is not focused. Its Processes page is a classic SysListView32, so its surface
    color comes from the classic palette in Executables/ebos-dark.theme: a deep EBOS navy
    (Window=10 24 42), never solid black. The normal Ctrl+Shift+Esc UI is therefore themed
    natively; no separate shortcut or scheduled task is created.
  - The Start menu uses the mod's integrated "TranslucentStartMenu" theme; the mod picks the
    classic or new layout variant by itself. Its brush is the shared reference for the taskbar
    and notification center: <WindhawkBlur BlurAmount="25" TintColor="#25323232"/>.
  - The notification center and action center use the mod's integrated "TranslucentShell" theme.
    $CommonBgBrush is overridden with the shared Start menu glass brush.
  - The Settings app uses the mod's integrated "Translucent Settings11" theme (acrylic window
    background), kept at the theme default so it matches the Start menu's dark blurred glass. It
    replaces the earlier pane-only transparent background; stale disabled controlStyles and
    Background=Transparent values are removed on every run.
  - Classic Win32 windows, menus and tooltips use the "Translucent Windows" mod (native blur).
    Its include list is '*' so every process, including third-party Win32 programs, gets the
    effect. Games with anti-cheat remain a caveat: the Fortnite rule opts that client out and the
    installer refuses to apply while a known anti-cheat process is running. Packaged Store/UWP
    app content keeps its native Mica/Acrylic because the mod does not target UWP/WinUI windows.
    The
    engine also loads in AppContainer processes (see Grant-AppContainerReadAccess), so Windows
    shell surfaces hosted by packaged processes, such as the notification center, are styled.
    The mod is enabled only after its settings and that include list are stored. The game guard
    and the Fortnite rule remain as defense in depth, mainly for upgrades from builds that
    injected into every process.
  - If a real (stock) Windhawk is installed, whcli adopts it (deferential mode) and the mods are
    written to its store; otherwise windhawk-cli runs standalone. An explicit --root would bypass
    that cooperation, so it is only passed in standalone mode.
  - After applying, the exported profile is checked: mods installed and enabled, settings present.
  - Older EBOS builds shipped a Task-Manager (Acryl) shortcut, VBS launcher, elevated helper
    and the scheduled task \EBOS\TaskMgrAcrylic. Those files are removed on every run; Task
    Manager now uses only the native Taskmgr.exe process rule and the local palette mod.
  - A leftover development mod (taskmgr-ebos-glass-dev) and its %TEMP%\ebos-taskmgr-glass.*
    files are removed as well, so the Task Manager look does not depend on an INI or a helper.
  - Log: %WINDIR%\EBOS\windhawk-transparent.log
  - The script restarts explorer.exe, which closes open Explorer windows, and closes a running
    Task Manager so the new native process rule takes effect on the next launch.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$RegisterFirstBootTask
)

$ErrorActionPreference = 'Stop'

$InstallerName           = 'windhawk-cli-1.1.0-installer.exe'
$ExpectedInstallerSha256 = '63962B290A3C63C45CF442BF3A99E91EE721AC151C7B3F774DEE4424F7A238AB'
$Root                    = 'C:\Program Files\WindhawkCLI'
$Whcli                   = Join-Path $Root 'whcli.exe'
$TaskbarModId            = 'windows-11-taskbar-styler'
$ExplorerModId           = 'windows-11-file-explorer-styler'
$StartMenuModId          = 'windows-11-start-menu-styler'
$NotificationModId       = 'windows-11-notification-center-styler'
$SettingsModId           = 'windows-11-settings-styler'
$AllWindowsModId         = 'translucent-windows'
# Companion mod built from Executables/WindhawkMods/taskmgr-ebos-palette. The global mod's
# custom rendering hard-codes COLOR_WINDOW/COLOR_BTNFACE to black, which turns Task Manager's
# classic SysListView32 solid black. This mod is injected into Taskmgr.exe only and overrides
# those two lookups with the EBOS palette; it is applied from Wh_ModAfterInit so it wins against
# the global mod regardless of load order.
$TaskMgrPaletteModId     = 'taskmgr-ebos-palette'
$TaskMgrPaletteDirName   = 'WindhawkMods\taskmgr-ebos-palette'
$TaskMgrPaletteDllName   = '1.0_64.dll'
$ExpectedTaskMgrPaletteSha256 = '8696480CE611DEB9A319DC801731D22844B6C4038539F254C986C07E9B33630A'
# Windhawk splits this on '|', expands environment variables and lets '*' cross backslashes.
# Universal scope: every process gets the global acrylic treatment, including third-party
# Win32 programs outside %SystemRoot% and %ProgramFiles%\WindowsApps. Games with anti-cheat
# remain a caveat; the Fortnite rule below disables the visual changes for that client and
# the installer refuses to run while a known anti-cheat process is active.
$AllWindowsIncludePattern = '*'
# Application Package Authority\ALL APPLICATION PACKAGES. Packaged Windows apps run in an
# AppContainer, and the Windhawk engine unloads itself there unless that SID can read the
# engine's data folder (engine.ini, mod DLLs, mod settings). See Grant-AppContainerReadAccess.
$AppContainerReadSid     = 'S-1-15-2-1'
# One glass recipe for every shell surface. The Start Menu Styler's "TranslucentStartMenu" theme
# uses <WindhawkBlur BlurAmount="25" TintColor="#25323232"/>; feeding the same brush to the
# taskbar and notification center keeps their blur radius and tint identical to the Start menu.
# These are raw registry values: whcli set-setting drops the quotes the XAML brush needs.
$ShellGlassBrush         = '<WindhawkBlur BlurAmount="25" TintColor="#25323232"/>'
$TaskbarGlassConstant    = 'CommonBgBrush=' + $ShellGlassBrush
$NotificationGlassBrush  = 'CommonBgBrush=' + $ShellGlassBrush
$TaskName                = 'WindhawkTransparentUI'
$LogDir                  = Join-Path $env:WINDIR 'EBOS'
$LogFile                 = Join-Path $LogDir 'windhawk-transparent.log'
$ScriptPath              = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $null }
# Where whcli writes. An explicit --root wins over cooperative mode, so it is only used while
# windhawk-cli is standalone; Set-WhcliTarget drops it when a stock Windhawk is adopted.
$WhcliTarget             = @('--root', $Root)
$ActiveRoot              = $Root
$ActiveService           = 'WindhawkCLI'
# Task Manager is styled natively by the global Taskmgr.exe process rule and the local
# taskmgr-ebos-palette mod. These paths only exist so upgrades can remove the abandoned
# Task-Manager (Acryl) shortcut, VBS launcher, elevated helper and scheduled task.
$LegacyTaskMgrLauncherName = 'TaskMgr-Acrylic.vbs'
$LegacyTaskMgrLauncherPath = Join-Path $LogDir $LegacyTaskMgrLauncherName
$LegacyTaskMgrHelperName   = 'TaskMgr-Acrylic.ps1'
$LegacyTaskMgrHelperPath   = Join-Path $LogDir $LegacyTaskMgrHelperName
$LegacyTaskMgrTaskName     = 'TaskMgrAcrylic'
$LegacyTaskMgrTaskPath     = '\EBOS\'
$LegacyTaskMgrCopyDir      = Join-Path $LogDir 'TaskMgr-Acryl'
$LegacyTaskMgrShortcutName = 'Task-Manager (Acryl).lnk'
$LegacyTaskMgrDevModId     = 'taskmgr-ebos-glass-dev'
$CommonStartMenu           = [Environment]::GetFolderPath('CommonStartMenu')
if (-not $CommonStartMenu) { $CommonStartMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu' }
$CommonDesktop             = [Environment]::GetFolderPath('CommonDesktopDirectory')
if (-not $CommonDesktop) { $CommonDesktop = Join-Path $env:PUBLIC 'Desktop' }
$LegacyTaskMgrStartMenuDir = Join-Path (Join-Path $CommonStartMenu 'Programs') 'EBOS'
$LegacyTaskMgrStartMenuLnk = Join-Path $LegacyTaskMgrStartMenuDir $LegacyTaskMgrShortcutName
$LegacyTaskMgrDesktopLnk   = Join-Path $CommonDesktop $LegacyTaskMgrShortcutName

function Write-WhLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message) -ErrorAction SilentlyContinue
    } catch {}
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = if ($identity.User) { $identity.User.Value } else { '' }
    # AME phase 7 runs as TrustedInstaller (S-1-5-80-*). That token is elevated,
    # but IsInRole(Administrator) can be false for it; requesting elevation from
    # the AME worker would fail or spawn an unusable second process. SYSTEM is
    # equally privileged. Normal user launches still go through the UAC prompt.
    if ($identity.IsSystem -or $sid -match '^S-1-5-80-') { return }
    $wp = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
    if (-not $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if (-not $ScriptPath) { throw 'Cannot determine the script path for elevation.' }
        Write-Host 'Requesting elevation...' -ForegroundColor Yellow
        $psExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
        $elevatedArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath))
        if ($RegisterFirstBootTask) { $elevatedArgs += '-RegisterFirstBootTask' }
        Start-Process $psExe -Verb RunAs -ArgumentList $elevatedArgs
        exit
    }
}

function Get-WhcliMode {
    if (-not (Test-Path -LiteralPath $Whcli)) { throw "whcli.exe not found at $Whcli." }
    # With 'Stop', Windows PowerShell turns a redirected native stderr line into a terminating
    # NativeCommandError. Relax the preference only while the output is captured.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $Whcli cooperation 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousEap
    }
    if ($exitCode -ne 0) { throw "whcli cooperation failed with exit code $exitCode" }
    $mode = $null
    $stockRoot = $null
    $stock = $null
    foreach ($line in $lines) {
        $text = [string]$line
        if ($text -match '^\s*Mode:\s*(\S+)') { $mode = $Matches[1]; continue }
        if ($text -match '^\s*Stock root:\s*(.+?)\s*$') { $stockRoot = $Matches[1]; continue }
        if ($text -match '^\s*Stock:\s*(.+?)\s*$') { $stock = $Matches[1] }
    }
    if (-not $mode) { throw 'Could not parse the output of "whcli cooperation".' }
    [pscustomobject]@{ Mode = $mode; StockRoot = $stockRoot; Stock = $stock }
}

function Set-WhcliTarget {
    $state = Get-WhcliMode
    if ($state.Mode -eq 'Deferential') {
        if (-not $state.StockRoot) {
            throw 'whcli is in Deferential mode but reports no stock root. Run "whcli reclaim" and retry.'
        }
        $stockIni = Join-Path $state.StockRoot 'windhawk.ini'
        if (-not (Test-Path -LiteralPath $stockIni)) {
            throw ('whcli is in Deferential mode but ' + $stockIni + ' is missing. Run "whcli reclaim" and retry.')
        }
        # An explicit --root overrides the cooperative target: mods would land in the CLI store
        # while the stock engine reads its own.
        $script:WhcliTarget = @()
        $script:ActiveRoot = $state.StockRoot
        $script:ActiveService = 'Windhawk'
    } else {
        $script:WhcliTarget = @('--root', $Root)
        $script:ActiveRoot = $Root
        $script:ActiveService = 'WindhawkCLI'
    }
    Write-WhLog ('Mode {0}; target {1}; service {2}' -f $state.Mode, $script:ActiveRoot, $script:ActiveService)
}

function Update-WhcliCooperation {
    # Adopt a live stock Windhawk so later commands write where its engine reads. Exit code 1
    # only means there is nothing to cooperate with; standalone mode is then correct.
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Whcli cooperate 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousEap
    }
    foreach ($line in $output) { Write-WhLog ('cooperate: ' + [string]$line) }
    if ($exitCode -ne 0) { Write-WhLog ("cooperate exited $exitCode; no stock Windhawk adopted.") }
    Set-WhcliTarget
}

function Wait-ForWhcli {
    param([int]$TimeoutSec = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Whcli) {
            $state = $null
            try { $state = Get-WhcliMode } catch { Write-WhLog ('Cooperation query failed: ' + $_.Exception.Message) }
            if ($state) {
                if ($state.Mode -eq 'Deferential') {
                    if (-not $state.StockRoot -or -not (Test-Path -LiteralPath (Join-Path $state.StockRoot 'windhawk.ini'))) {
                        if ($state.Stock -eq 'GONE (uninstalled)') {
                            # whcli owns the config; take the engine back instead of failing forever.
                            Write-WhLog 'Stock Windhawk is gone; reclaiming the CLI engine.'
                            $previousEap = $ErrorActionPreference
                            $ErrorActionPreference = 'Continue'
                            try {
                                $reclaim = @(& $Whcli reclaim 2>&1)
                                $reclaimCode = $LASTEXITCODE
                            } finally {
                                $ErrorActionPreference = $previousEap
                            }
                            foreach ($line in $reclaim) { Write-WhLog ('reclaim: ' + [string]$line) }
                            if ($reclaimCode -ne 0) { throw "whcli reclaim failed with exit code $reclaimCode" }
                            Start-Sleep -Seconds 3
                            continue
                        }
                        throw ('whcli is in Deferential mode but the stock install is unusable (' + $state.StockRoot + '). Run "whcli reclaim" and retry.')
                    }
                    $svc = Get-Service -Name 'Windhawk' -ErrorAction SilentlyContinue
                    if (-not $svc) {
                        throw 'whcli is in Deferential mode but the Windhawk service is missing.'
                    }
                    if ($svc.Status -ne 'Running') {
                        try { Start-Service -Name 'Windhawk' -ErrorAction Stop } catch {}
                    }
                    & $Whcli status --service Windhawk | Out-Null
                    if ($LASTEXITCODE -eq 0) { return }
                } else {
                    & $Whcli status --root $Root | Out-Null
                    if ($LASTEXITCODE -eq 0) { return }
                    $svc = Get-Service -Name 'WindhawkCLI' -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -ne 'Running') {
                        try { Start-Service -Name 'WindhawkCLI' -ErrorAction Stop } catch {}
                    }
                }
            }
        } else {
            # The installer normally starts the service; nudge it while the binary appears.
            $svc = Get-Service -Name 'WindhawkCLI' -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') {
                try { Start-Service -Name 'WindhawkCLI' -ErrorAction Stop } catch {}
            }
        }
        Start-Sleep -Seconds 3
    }
    throw "windhawk-cli did not become ready within $TimeoutSec seconds."
}

function Invoke-Whcli {
    param([string[]]$Arguments, [switch]$NoTarget)
    # Do not assign the if-expression directly: with a single argument and an empty target
    # (deferential mode), PowerShell unrolls the one-element array to a string and splatting
    # passes each character as a separate argument.
    $allArgs = @()
    if ($NoTarget) {
        $allArgs = @($Arguments)
    } else {
        $allArgs = @($Arguments) + @($script:WhcliTarget)
    }
    & $Whcli @allArgs
    if ($LASTEXITCODE -ne 0) {
        Write-WhLog ("whcli {0} failed with exit code {1}" -f ($Arguments -join ' '), $LASTEXITCODE)
        throw "whcli $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Set-WhSettings {
    param([string]$ModId, [System.Collections.Specialized.OrderedDictionary]$Settings)
    foreach ($key in $Settings.Keys) {
        Invoke-Whcli -Arguments @('set-setting', $ModId, $key, [string]$Settings[$key])
    }
}

function Get-WhRegistryBase {
    param([Parameter(Mandatory)][string]$InstallRoot)

    # The engine reads its mod store from the registry path named in windhawk.ini. Stock Windhawk
    # and windhawk-cli use different keys (SOFTWARE\Windhawk vs SOFTWARE\WindhawkCLI), so derive
    # the key from the active install instead of hard-coding one.
    $iniPath = Join-Path $InstallRoot 'windhawk.ini'
    if (-not (Test-Path -LiteralPath $iniPath)) {
        throw "windhawk.ini not found at $iniPath; cannot locate the Windhawk mod store."
    }
    $registryKey = $null
    foreach ($line in Get-Content -LiteralPath $iniPath) {
        if ($line -match '^\s*RegistryKey\s*=\s*(.+?)\s*$') {
            $registryKey = $Matches[1]
            break
        }
    }
    if (-not $registryKey) {
        throw "RegistryKey is missing from $iniPath."
    }
    switch -Regex ($registryKey) {
        '(?i)^HKEY_LOCAL_MACHINE\\(.+)$' { return 'HKLM:\' + $Matches[1] }
        '(?i)^HKLM\\(.+)$'              { return 'HKLM:\' + $Matches[1] }
        '(?i)^HKEY_CURRENT_USER\\(.+)$' { return 'HKCU:\' + $Matches[1] }
        '(?i)^HKCU\\(.+)$'              { return 'HKCU:\' + $Matches[1] }
        '(?i)^HKEY_USERS\\(.+)$'        { return 'HKU:\' + $Matches[1] }
        '(?i)^HKU\\(.+)$'               { return 'HKU:\' + $Matches[1] }
        default { throw "Unsupported RegistryKey '$registryKey' in $iniPath." }
    }
}

function Resolve-WhModKey {
    param([Parameter(Mandatory)][string]$ModId)

    $regBase = Get-WhRegistryBase -InstallRoot $script:ActiveRoot
    $modKey = Join-Path $regBase ('Engine\Mods\' + $ModId)
    if (-not (Test-Path -LiteralPath $modKey)) {
        throw "Windhawk mod registry key not found: $modKey"
    }
    return $modKey
}

function Get-WhDataPath {
    param([Parameter(Mandatory)][string]$InstallRoot)

    # The engine keeps its mod DLLs, mod settings and writable files under AppDataPath, which
    # engine.ini defines. Do not guess %ProgramData%\WindhawkCLI: a stock install uses another
    # folder, and the AppContainer ACE has to land on the folder the running engine actually uses.
    $iniPath = Join-Path $InstallRoot 'windhawk.ini'
    if (-not (Test-Path -LiteralPath $iniPath)) {
        throw "windhawk.ini not found at $iniPath; cannot locate the Windhawk data folder."
    }
    $enginePath = 'Engine'
    foreach ($line in Get-Content -LiteralPath $iniPath) {
        if ($line -match '^\s*EnginePath\s*=\s*(.+?)\s*$') { $enginePath = $Matches[1]; break }
    }
    $engineIni = Join-Path (Join-Path $InstallRoot $enginePath) 'engine.ini'
    if (-not (Test-Path -LiteralPath $engineIni)) {
        throw "engine.ini not found at $engineIni; cannot locate the Windhawk data folder."
    }
    $appDataPath = $null
    foreach ($line in Get-Content -LiteralPath $engineIni) {
        if ($line -match '^\s*AppDataPath\s*=\s*(.+?)\s*$') { $appDataPath = $Matches[1]; break }
    }
    if (-not $appDataPath) {
        throw "AppDataPath is missing from $engineIni."
    }
    return [Environment]::ExpandEnvironmentVariables($appDataPath)
}

function Get-FileSystemAccessRules {
    param([Parameter(Mandatory)][string]$Path)

    # Get-Acl exposes IdentityReference as NTAccount (a localized display name), which cannot be
    # compared to S-1-15-2-1 and may fail to Translate for the package authority. Ask for rules
    # whose identity is a SecurityIdentifier so the SID is available directly.
    $acl = Get-Acl -LiteralPath $Path
    return @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
}

function Test-AppContainerReadAccess {
    param([Parameter(Mandatory)][string]$Path)

    # A matching SID is not enough: an explicit Deny ACE for the same SID would make the
    # grant ineffective, and the engine needs at least the Read bits (RX adds Execute).
    $rules = @(Get-FileSystemAccessRules -Path $Path | Where-Object {
        $_.IdentityReference.Value -eq $AppContainerReadSid -and
        (($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Read) -ne 0)
    })
    $allow = @($rules | Where-Object { $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow })
    $deny  = @($rules | Where-Object { $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny })
    return (($allow.Count -gt 0) -and ($deny.Count -eq 0))
}

function Grant-AppContainerReadAccess {
    param([Parameter(Mandatory)][string]$Path)

    # Packaged Windows apps run in an AppContainer. The engine DLL loads there, but it cannot
    # read its data folder unless ALL APPLICATION PACKAGES has read access, so it fails
    # initialization and unloads itself. Windows surfaces hosted by packaged processes (the
    # notification center in ShellExperienceHost.exe, Microsoft Store apps) then never get a mod.
    # Program Files already grants this SID read access; ProgramData does not.
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Windhawk data folder not found: $Path"
    }
    if (Test-AppContainerReadAccess -Path $Path) {
        Write-WhLog ("AppContainer read access already present: {0}" -f $Path)
        return
    }
    & icacls $Path /grant ('*' + $AppContainerReadSid + ':(OI)(CI)(RX)') /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed for $Path (exit code $LASTEXITCODE)."
    }
    # The ACL can be briefly stale right after icacls /T returns, which produced a false
    # "not stored" failure on 2026-10-27 even though the ACE was present on the next run.
    $stored = $false
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        if (Test-AppContainerReadAccess -Path $Path) { $stored = $true; break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $stored) {
        throw "AppContainer read access was not stored on $Path."
    }
    Write-WhLog ("Granted AppContainer read access: {0}" -f $Path)
}

function Open-WhRegistryKeyWritable {
    param([Parameter(Mandatory)][string]$ProviderPath)

    # Get-Item returns a read-only RegistryKey; SetValue/DeleteValue on it throw
    # UnauthorizedAccessException. Re-open the same key with write access. Value names such as
    # "styleConstants[0]" must stay literal, so use the .NET API and never the provider's -Name.
    $item = Get-Item -LiteralPath $ProviderPath
    $fullName = $item.Name
    $sep = $fullName.IndexOf('\')
    if ($sep -lt 1) {
        throw "Unsupported registry path: $fullName"
    }
    $hiveName = $fullName.Substring(0, $sep)
    $subPath = $fullName.Substring($sep + 1)
    $hive = switch ($hiveName) {
        'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_CURRENT_USER'  { [Microsoft.Win32.Registry]::CurrentUser }
        'HKEY_USERS'         { [Microsoft.Win32.Registry]::Users }
        default { throw "Unsupported registry hive: $hiveName" }
    }
    $key = $hive.OpenSubKey($subPath, $true)
    if ($null -eq $key) {
        throw "Cannot open registry key for writing: $fullName"
    }
    return $key
}

function Set-WhModRawSetting {
    param(
        [Parameter(Mandatory)][string]$ModId,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    # whcli set-setting stores strings but drops the quotes around XAML attribute values, which
    # makes brushes such as <WindhawkBlur BlurAmount="25" .../> invalid. Write the REG_SZ directly.
    # Use RegistryKey.GetValue/SetValue: the provider's -Name parameters treat "[0]" as a wildcard.
    $modKey = Resolve-WhModKey -ModId $ModId
    $settingsKey = Join-Path $modKey 'Settings'
    if (-not (Test-Path -LiteralPath $settingsKey)) {
        New-Item -Path $settingsKey -Force | Out-Null
    }
    $key = Open-WhRegistryKeyWritable -ProviderPath $settingsKey
    try {
        $key.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]::String)
        $stored = [string]$key.GetValue($Name, $null)
    } finally {
        $key.Close()
    }
    if ($stored -ne $Value) {
        throw "Setting $Name for $ModId was not stored correctly (got '$stored')."
    }
    Write-WhLog ("Raw setting {0} for {1} stored." -f $Name, $ModId)
}

function Remove-WhModRawSetting {
    param(
        [Parameter(Mandatory)][string]$ModId,
        [Parameter(Mandatory)][string]$Name
    )

    $modKey = Resolve-WhModKey -ModId $ModId
    $settingsKey = Join-Path $modKey 'Settings'
    if (-not (Test-Path -LiteralPath $settingsKey)) { return }
    $key = Open-WhRegistryKeyWritable -ProviderPath $settingsKey
    try {
        if ($null -eq $key.GetValue($Name, $null)) { return }
        $key.DeleteValue($Name, $false)
    } finally {
        $key.Close()
    }
    Write-WhLog ("Removed raw setting {0} from {1}." -f $Name, $ModId)
}

function Get-WhModSettingNames {
    param([Parameter(Mandatory)][string]$ModId)

    $modKey = Resolve-WhModKey -ModId $ModId
    $settingsKey = Join-Path $modKey 'Settings'
    if (-not (Test-Path -LiteralPath $settingsKey)) { return @() }
    # Enumeration only; Get-Item hands back a read-only key, which is enough here.
    return @((Get-Item -LiteralPath $settingsKey).GetValueNames())
}

function Remove-WhModSettingValues {
    param(
        [Parameter(Mandatory)][string]$ModId,
        [Parameter(Mandatory)][string[]]$NameLike
    )

    # Indexed settings such as controlStyles[0].target are individual REG_SZ values. Remove them
    # by pattern so upgrades from the old pure-transparent builds cannot leave rules behind that
    # override the selected theme. Use the .NET API: the provider's -Name treats '[' as a wildcard.
    $stale = @(Get-WhModSettingNames -ModId $ModId | Where-Object {
        $valueName = $_
        $matched = $false
        foreach ($pattern in $NameLike) {
            if ($valueName -like $pattern) { $matched = $true; break }
        }
        $matched
    })
    if ($stale.Count -eq 0) { return }
    $settingsKey = Join-Path (Resolve-WhModKey -ModId $ModId) 'Settings'
    $key = Open-WhRegistryKeyWritable -ProviderPath $settingsKey
    try {
        foreach ($valueName in $stale) {
            $key.DeleteValue($valueName, $false)
            Write-WhLog ("Removed stale setting {0} from {1}." -f $valueName, $ModId)
        }
    } finally {
        $key.Close()
    }
}

function Set-WhModInclude {
    param(
        [Parameter(Mandatory)][string]$ModId,
        [Parameter(Mandatory)][string]$IncludePattern
    )

    $modKey = Resolve-WhModKey -ModId $ModId
    $current = [string](Get-ItemProperty -LiteralPath $modKey -Name 'Include' -ErrorAction SilentlyContinue).Include
    if ($current -eq $IncludePattern) {
        Write-WhLog ("Include for {0} already set: {1}" -f $ModId, $IncludePattern)
        return
    }
    # whcli has no command for Include; the engine reads this REG_SZ from the mod's registry key.
    Set-ItemProperty -LiteralPath $modKey -Name 'Include' -Value $IncludePattern -Type String -ErrorAction Stop
    $stored = [string](Get-ItemProperty -LiteralPath $modKey -Name 'Include' -ErrorAction Stop).Include
    if ($stored -ne $IncludePattern) {
        throw "Include for $ModId was not stored correctly (got '$stored', expected '$IncludePattern')."
    }
    Write-WhLog ("Include for {0} set: {1}" -f $ModId, $IncludePattern)
}

function Remove-LegacyTaskManagerArtifacts {
    # Task Manager is now styled only by the Taskmgr.exe process rule and the local
    # taskmgr-ebos-palette mod. Older builds additionally registered a separate legacy
    # Task Manager (shortcut -> VBS -> elevated helper -> scheduled task). Remove all of
    # that, plus the abandoned taskmgr-ebos-glass-dev mod whose INI lived in %TEMP%.
    Get-Process -Name 'Taskmgr' -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

    if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
        foreach ($taskPath in @($LegacyTaskMgrTaskPath, '\')) {
            if (Get-ScheduledTask -TaskName $LegacyTaskMgrTaskName -TaskPath $taskPath -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $LegacyTaskMgrTaskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
                Write-WhLog "Removed legacy Task Manager task $taskPath$LegacyTaskMgrTaskName."
            }
        }
    }

    foreach ($path in @($LegacyTaskMgrStartMenuLnk, $LegacyTaskMgrDesktopLnk, $LegacyTaskMgrLauncherPath, $LegacyTaskMgrHelperPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            Write-WhLog "Removed legacy Task Manager file $path."
        }
    }
    if (Test-Path -LiteralPath $LegacyTaskMgrCopyDir) {
        Remove-Item -LiteralPath $LegacyTaskMgrCopyDir -Recurse -Force -ErrorAction Stop
        Write-WhLog "Removed legacy Task Manager private copy $LegacyTaskMgrCopyDir."
    }
    if ((Test-Path -LiteralPath $LegacyTaskMgrStartMenuDir) -and
        -not (Get-ChildItem -LiteralPath $LegacyTaskMgrStartMenuDir -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $LegacyTaskMgrStartMenuDir -Force -ErrorAction Stop
    }

    $legacyDevModKey = Join-Path (Get-WhRegistryBase -InstallRoot $script:ActiveRoot) ('Engine\Mods\' + $LegacyTaskMgrDevModId)
    if (Test-Path -LiteralPath $legacyDevModKey) {
        Invoke-Whcli -Arguments @('uninstall', $LegacyTaskMgrDevModId)
        Write-WhLog "Removed legacy Task Manager dev mod $LegacyTaskMgrDevModId."
    }
    foreach ($name in @('ebos-taskmgr-glass.ini', 'ebos-taskmgr-glass.log')) {
        $path = Join-Path ([IO.Path]::GetTempPath()) $name
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Write-WhLog "Removed legacy Task Manager dev file $path."
        }
    }
}

# Taskbar: select the mod's built-in "TranslucentTaskbar" theme instead of hand-written pure
# Transparent fills. The theme blurs the background, tray overflow, menus and input switcher as
# one surface. Its own $CommonBgBrush is BlurAmount=18; the raw setting below replaces it with
# the shared Start menu glass (BlurAmount=25). No catch-all "Rectangle" rule: that also matched
# running indicators and hover backgrounds.
# The user chose to keep the XAML diagnostics slot. Values alert/block/allow.
$TaskbarSettings = [ordered]@{
    'theme'                   = 'TranslucentTaskbar'
    'xamlDiagnosticsHandling' = 'block'
}
# Raw REG_SZ value; the quotes around the brush attributes must survive, so write it directly.
$TaskbarRawSettings = [ordered]@{
    'styleConstants[0]' = $TaskbarGlassConstant
}

# Settings app: select the mod's integrated "Translucent Settings11" theme. It brings the acrylic
# window background, style constants and resource overrides; no extra control styles are needed.
# Older builds wrote a disabled controlStyles[0] target and a Background=Transparent pane override,
# which conflict with the theme; those are removed on every run.
$SettingsSettings = [ordered]@{
    'theme' = 'Translucent_Settings11'
}

# Global windows: native blur for classic Win32 windows, context menus and tooltips. The include
# list is '*' so every process gets the treatment, including third-party Win32 programs. The
# Fortnite rule and the game guard stay as a safety net for anti-cheat clients.
# AccentBlurBehind is AARRGGBB. 0x25 alpha / RGB 0x32 is the same tint as the shared
# #25323232 shell glass, so classic and third-party windows match the shell surfaces.
$AllWindowsSettings = [ordered]@{
    'RenderingMod.ThemeBackground'                      = '1'
    'RenderingMod.AccentColorControls'                  = '1'
    'RenderingMod.Syscolors'                            = '0'
    'BackgroundEffects.type'                            = 'acrylicblur'
    'BackgroundEffects.AccentBlurBehind'                = '25323232'
    'FlyoutsEffects'                                    = '1'
    'RuledPrograms[0].target'                           = 'FortniteClient-Win64-Shipping.exe'
    'RuledPrograms[0].RenderingMod.ThemeBackground'     = '0'
    'RuledPrograms[0].RenderingMod.AccentColorControls' = '0'
    'RuledPrograms[0].BackgroundEffects.type'           = 'none'
    # Task Manager keeps its own XAML shell, but the Processes page is a classic
    # SysListView32. ThemeBackground=1 is required for the custom rendering that
    # makes the shell acrylic. It also installs the mod's GetSysColor hooks,
    # which hard-code COLOR_WINDOW/COLOR_BTNFACE to RGB(0,0,0); the local
    # taskmgr-ebos-palette mod (installed below) is applied afterwards and
    # restores the EBOS navy palette in that process. Do not set this back to 0:
    # that disables the shell rendering and leaves an opaque task list.
    'RuledPrograms[1].target'                           = 'Taskmgr.exe'
    'RuledPrograms[1].RenderingMod.ThemeBackground'     = '1'
    'RuledPrograms[1].RenderingMod.AccentColorControls' = '0'
    'RuledPrograms[1].BackgroundEffects.type'           = 'acrylicblur'
    # 0x25 alpha / RGB 0x32 is the same tint as the shared #25323232 shell glass.
    # AccentBlurBehind stays applied when Task Manager is not the active window.
    'RuledPrograms[1].BackgroundEffects.AccentBlurBehind' = '25323232'
}

# File Explorer: select the mod's built-in "Translucent Explorer11" theme instead of copying its
# control styles by hand. The integrated theme is the maintained source of truth; the previous
# hand-copied list was missing the acrylic ToolTip rule. Selecting a theme also avoids passing
# the theme's quoted AcrylicBrush XAML through PowerShell's native-argument layer.
# The resource overrides repair the one part the theme leaves dim: WinUI paints the command
# bar icon glyphs and their TextLabels with AppBarButtonForeground/TextFillColorSecondary,
# which reads as disabled gray on the dark glass. Force primary/secondary text to near-white
# so "Neu", "Sortieren", "Anzeigen" and "Details" keep WCAG contrast on every wallpaper.
# These values contain quoted XAML attributes, so they are written raw below; whcli
# set-setting would drop the quotes and store invalid XAML.
$ExplorerSettings = [ordered]@{
    'theme'                          = 'Translucent Explorer11'
    'backgroundTranslucentEffect'    = 'acrylic'
    'xamlDiagnosticsHandling'        = 'block'
    # Belt-and-braces: style the command bar items directly. The mod's selector
    # parser splits only on " > ", so a CSS-style space descendant selector is
    # invalid and would be discarded. Target the element types without a parent
    # chain; the Foreground inherits into the icon glyph and the TextLabel.
    'controlStyles[0].target'        = 'Microsoft.UI.Xaml.Controls.AppBarButton'
    'controlStyles[0].styles[0]'     = 'Foreground=#FFFFFF'
    'controlStyles[1].target'        = 'Microsoft.UI.Xaml.Controls.CommandBar#FileExplorerCommandBar > * > Microsoft.UI.Xaml.Controls.TextBlock#TextLabel'
    'controlStyles[1].styles[0]'     = 'Foreground=#FFFFFF'
    'controlStyles[2].target'        = 'Microsoft.UI.Xaml.Controls.FontIcon'
    'controlStyles[2].styles[0]'     = 'Foreground=#FFFFFF'
}

# Raw REG_SZ values; the quotes around #FFFFFF are part of the XAML and must survive.
$ExplorerRawSettings = [ordered]@{
    'themeResourceVariables[0]' = 'AppBarButtonForeground@Dark:=<SolidColorBrush Color="#FFFFFF"/>'
    'themeResourceVariables[1]' = 'CommandBarForeground@Dark:=<SolidColorBrush Color="#FFFFFF"/>'
    'themeResourceVariables[2]' = 'TextFillColorPrimaryBrush@Dark:=<SolidColorBrush Color="#FFFFFF"/>'
    'themeResourceVariables[3]' = 'TextFillColorSecondaryBrush@Dark:=<SolidColorBrush Color="#F2FFFFFF"/>'
    'themeResourceVariables[4]' = 'TextFillColorTertiaryBrush@Dark:=<SolidColorBrush Color="#D8FFFFFF"/>'
}

# Start menu: select the mod's built-in "TranslucentStartMenu" theme. The mod contains both a
# new-layout and a classic-layout variant and chooses one based on the actual Start menu.
$StartMenuSettings = [ordered]@{
    'theme' = 'TranslucentStartMenu'
}

# Notification center / action center: select the mod's integrated "TranslucentShell" theme.
# It covers notifications, calendar, quick settings and their jump lists/flyouts.
$NotificationSettings = [ordered]@{
    'theme' = 'TranslucentShell'
}

trap {
    Write-WhLog ('FAILED: ' + $_.Exception.Message)
    # A bare 'throw' loses the message under Windows PowerShell 5.1 and prints "ScriptHalted".
    throw $_
}

Assert-Admin
Write-WhLog ("Start (root={0})" -f $Root)

# --- 1. Verify and run the local installer (engine only if not yet installed) ---
$here = if ($ScriptPath) { Split-Path -Parent $ScriptPath } else { (Get-Location).Path }
$installer = Join-Path $here $InstallerName
if (-not (Test-Path -LiteralPath $installer)) {
    throw "$InstallerName not found next to the script ($here)."
}
$actual = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
if ($actual -ne $ExpectedInstallerSha256) {
    throw "SHA-256 mismatch for $InstallerName. Expected $ExpectedInstallerSha256, got $actual. Not run."
}

if (-not (Test-Path -LiteralPath $Whcli)) {
    Write-Host "Installing windhawk-cli silently..." -ForegroundColor Cyan
    $installArgs = @('--silent', '--auto-updates', '--add-defender-exclusion')
    # A leftover install directory (failed or partial uninstall) makes the installer refuse a
    # plain install. --update replaces the remains instead of timing out in Wait-ForWhcli.
    if (Test-Path -LiteralPath $Root) { $installArgs += '--update' }
    Write-WhLog ('Running installer: ' + ($installArgs -join ' '))
    $proc = Start-Process -FilePath $installer -ArgumentList $installArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and ($installArgs -contains '--update')) {
        Write-WhLog ("Installer --update failed ({0}); retrying without --update" -f $proc.ExitCode)
        $proc = Start-Process -FilePath $installer -ArgumentList @('--silent', '--auto-updates', '--add-defender-exclusion') -Wait -PassThru
    }
    if ($proc.ExitCode -ne 0) {
        throw "windhawk-cli installer exit code $($proc.ExitCode)"
    }
} else {
    Write-Host 'windhawk-cli already installed.' -ForegroundColor Green
}

Wait-ForWhcli
# Adopt a stock Windhawk if present. This also selects the write target for every later call.
Update-WhcliCooperation

# Remove the abandoned shortcut/helper/scheduled task and the dev mod with the INI first.
# Task Manager is styled natively after this, so no auxiliary launcher survives an upgrade.
Write-Host 'Removing legacy Task Manager launchers and dev artifacts...' -ForegroundColor Cyan
Remove-LegacyTaskManagerArtifacts

# Packaged Windows apps (notification center, Store apps) can only keep the engine loaded when
# ALL APPLICATION PACKAGES can read the engine's data folder. Do this before the final restart so
# the next injection into ShellExperienceHost.exe already succeeds.
Write-Host 'Allowing packaged Windows apps to load the Windhawk engine...' -ForegroundColor Cyan
Grant-AppContainerReadAccess -Path (Get-WhDataPath -InstallRoot $ActiveRoot)

# --- 2. Install mods ---
# The global include list is '*', so the game guard still matters: applying while Fortnite or
# an anti-cheat process is running would inject the mod into it. Close those processes first.
$gameProcesses = @(Get-Process -Name 'Fortnite*', 'EasyAntiCheat*', 'BattlEye*', 'BEService' -ErrorAction SilentlyContinue)
if ($gameProcesses.Count -gt 0) {
    $names = ($gameProcesses | Select-Object -ExpandProperty ProcessName -Unique) -join ', '
    throw "Close these processes before applying the global Translucent Windows mod: $names"
}
Write-Host "Installing mod: $TaskbarModId" -ForegroundColor Cyan
Invoke-Whcli -Arguments @('install', $TaskbarModId)
Write-Host "Installing mod: $ExplorerModId" -ForegroundColor Cyan
Invoke-Whcli -Arguments @('install', $ExplorerModId)
Write-Host "Installing mod: $StartMenuModId" -ForegroundColor Cyan
Invoke-Whcli -Arguments @('install', $StartMenuModId)
Write-Host "Installing mod: $NotificationModId" -ForegroundColor Cyan
Invoke-Whcli -Arguments @('install', $NotificationModId)
Write-Host "Installing mod: $SettingsModId" -ForegroundColor Cyan
Invoke-Whcli -Arguments @('install', $SettingsModId)
Write-Host "Installing mod: $AllWindowsModId (disabled until configured)" -ForegroundColor Cyan
Invoke-Whcli -Arguments @('install', $AllWindowsModId, '--disabled')

# The companion palette mod is a local, precompiled Windhawk mod. It must be installed from
# the playbook folder because it is not in the public catalog. Verify the binary before the
# engine copies it into its mod store.
$taskMgrPaletteDir = Join-Path $here $TaskMgrPaletteDirName
$taskMgrPaletteDll = Join-Path $taskMgrPaletteDir $TaskMgrPaletteDllName
if (-not (Test-Path -LiteralPath $taskMgrPaletteDll)) {
    throw "Task Manager palette mod not found: $taskMgrPaletteDll"
}
$taskMgrPaletteHash = (Get-FileHash -LiteralPath $taskMgrPaletteDll -Algorithm SHA256).Hash
if ($taskMgrPaletteHash -ne $ExpectedTaskMgrPaletteSha256) {
    throw "SHA-256 mismatch for $TaskMgrPaletteDllName. Expected $ExpectedTaskMgrPaletteSha256, got $taskMgrPaletteHash. Not installed."
}
Write-Host "Installing local mod: $TaskMgrPaletteModId (disabled until scoped)" -ForegroundColor Cyan
Invoke-Whcli -Arguments @('install-local', $taskMgrPaletteDir, '--disabled')

# --- 3. Apply settings ---
Write-Host 'Applying taskbar glass settings...' -ForegroundColor Cyan
# Delete the old pure-transparent fill/tray rules before selecting the theme.
Remove-WhModSettingValues -ModId $TaskbarModId -NameLike @('controlStyles*')
Set-WhSettings -ModId $TaskbarModId -Settings $TaskbarSettings
foreach ($key in $TaskbarRawSettings.Keys) {
    Set-WhModRawSetting -ModId $TaskbarModId -Name $key -Value $TaskbarRawSettings[$key]
}

Write-Host 'Applying File Explorer glass settings...' -ForegroundColor Cyan
Set-WhSettings -ModId $ExplorerModId -Settings $ExplorerSettings
foreach ($key in $ExplorerRawSettings.Keys) {
    Set-WhModRawSetting -ModId $ExplorerModId -Name $key -Value $ExplorerRawSettings[$key]
}

Write-Host 'Applying Start menu glass settings...' -ForegroundColor Cyan
Set-WhSettings -ModId $StartMenuModId -Settings $StartMenuSettings

Write-Host 'Applying notification center glass settings...' -ForegroundColor Cyan
Set-WhSettings -ModId $NotificationModId -Settings $NotificationSettings
# The theme's $CommonBgBrush defaults to about 15% tint (BlurAmount=18); replace it with the same
# BlurAmount=25 glass the Start menu uses. The theme consumes the style constant, so drop the
# theme-resource override older builds wrote.
Set-WhModRawSetting -ModId $NotificationModId -Name 'styleConstants[0]' -Value $NotificationGlassBrush
Remove-WhModRawSetting -ModId $NotificationModId -Name 'themeResourceVariables[0]'

Write-Host 'Applying Settings app glass theme...' -ForegroundColor Cyan
# The integrated theme styles the pane itself; old disabled/Transparent overrides must not remain.
Remove-WhModSettingValues -ModId $SettingsModId -NameLike @('controlStyles*', 'Background')
Set-WhSettings -ModId $SettingsModId -Settings $SettingsSettings

Write-Host 'Applying global window transparency settings...' -ForegroundColor Cyan
Set-WhSettings -ModId $AllWindowsModId -Settings $AllWindowsSettings

# Give the global mod its universal scope before it is enabled. The include list lives only
# in the registry (whcli has no command for it); writing it while the mod is still disabled
# guarantees that the first injection already uses the all-process scope.
Write-Host 'Applying global window transparency to all processes...' -ForegroundColor Cyan
Set-WhModInclude -ModId $AllWindowsModId -IncludePattern $AllWindowsIncludePattern

# The palette mod only belongs in Task Manager. Set the include while it is still disabled so
# the first injection is already scoped to taskmgr.exe.
Write-Host 'Restricting Task Manager palette mod to Taskmgr.exe...' -ForegroundColor Cyan
Set-WhModInclude -ModId $TaskMgrPaletteModId -IncludePattern 'taskmgr.exe'

# Load the global mod only after its settings and include list are stored.
Write-Host "Enabling mod: $AllWindowsModId" -ForegroundColor Cyan
Invoke-Whcli -Arguments @('enable', $AllWindowsModId)
Write-Host "Enabling mod: $TaskMgrPaletteModId" -ForegroundColor Cyan
Invoke-Whcli -Arguments @('enable', $TaskMgrPaletteModId)

# Refresh the cooperation mirror now that the settings are in the active store.
Update-WhcliCooperation

# --- 3b. Verify the mods are installed/enabled and the settings were stored ---
$checkFile = Join-Path $env:TEMP 'whcli-profile-check.json'
Remove-Item -LiteralPath $checkFile -Force -ErrorAction SilentlyContinue
# export takes --from, not --root; auto-detection could otherwise pick the wrong install.
Invoke-Whcli -Arguments @('export', '--from', $ActiveRoot, '--out', $checkFile, '--no-bundle') -NoTarget
$exportProfile = Get-Content -LiteralPath $checkFile -Raw | ConvertFrom-Json
$mods = @{}
foreach ($m in @($exportProfile.mods)) { if ($m) { $mods[$m.id] = $m } }
$problems = @()
foreach ($id in @($TaskbarModId, $ExplorerModId, $StartMenuModId, $NotificationModId, $SettingsModId, $AllWindowsModId, $TaskMgrPaletteModId)) {
    if (-not $mods.ContainsKey($id)) { $problems += "not installed: $id"; continue }
    if ($mods[$id].disabled) { $problems += "disabled: $id" }
}
$explorerEntry = $mods[$ExplorerModId]
if ($explorerEntry) {
    foreach ($key in $ExplorerSettings.Keys) {
        if ([string]$explorerEntry.settings.$key -ne [string]$ExplorerSettings[$key]) {
            $problems += "Explorer setting mismatch: $key"
        }
    }
}
# The quoted XAML brushes cannot survive whcli's argument handling; read them raw.
$explorerSettingsKey = Join-Path (Resolve-WhModKey -ModId $ExplorerModId) 'Settings'
if (Test-Path -LiteralPath $explorerSettingsKey) {
    $explorerKey = Open-WhRegistryKeyWritable -ProviderPath $explorerSettingsKey
    try {
        foreach ($key in $ExplorerRawSettings.Keys) {
            $storedBrush = [string]$explorerKey.GetValue($key, $null)
            if ($storedBrush -ne $ExplorerRawSettings[$key]) {
                $problems += "Explorer raw setting mismatch: $key"
            }
        }
    } finally {
        $explorerKey.Close()
    }
} else {
    $problems += 'Explorer settings key missing'
}
$taskbarEntry = $mods[$TaskbarModId]
if ($taskbarEntry) {
    foreach ($key in $TaskbarSettings.Keys) {
        if ([string]$taskbarEntry.settings.$key -ne [string]$TaskbarSettings[$key]) {
            $problems += "Taskbar setting mismatch: $key"
        }
    }
}
# whcli export cannot represent the quoted brush; read the raw REG_SZ back.
$taskbarSettingsKey = Join-Path (Resolve-WhModKey -ModId $TaskbarModId) 'Settings'
if (Test-Path -LiteralPath $taskbarSettingsKey) {
    $taskbarKey = Open-WhRegistryKeyWritable -ProviderPath $taskbarSettingsKey
    try {
        $storedTaskbarGlass = [string]$taskbarKey.GetValue('styleConstants[0]', $null)
        if ($storedTaskbarGlass -ne $TaskbarGlassConstant) {
            $problems += "Taskbar glass brush mismatch: '$storedTaskbarGlass'"
        }
    } finally {
        $taskbarKey.Close()
    }
} else {
    $problems += 'Taskbar settings key missing'
}
# Old builds wrote individual pure-transparent rules; any survivor overrides the theme.
$staleTaskbarStyles = @(Get-WhModSettingNames -ModId $TaskbarModId | Where-Object { $_ -like 'controlStyles*' })
if ($staleTaskbarStyles.Count -gt 0) {
    $problems += ('Stale taskbar control styles still present: ' + ($staleTaskbarStyles -join ', '))
}
$startMenuEntry = $mods[$StartMenuModId]
if ($startMenuEntry) {
    foreach ($key in $StartMenuSettings.Keys) {
        if ([string]$startMenuEntry.settings.$key -ne [string]$StartMenuSettings[$key]) {
            $problems += "Start menu setting mismatch: $key"
        }
    }
}
$notificationEntry = $mods[$NotificationModId]
if ($notificationEntry) {
    foreach ($key in $NotificationSettings.Keys) {
        if ([string]$notificationEntry.settings.$key -ne [string]$NotificationSettings[$key]) {
            $problems += "Notification center setting mismatch: $key"
        }
    }
}
# whcli export cannot represent the brush value, so read the raw REG_SZ back.
$notificationSettingsKey = Join-Path (Resolve-WhModKey -ModId $NotificationModId) 'Settings'
if (Test-Path -LiteralPath $notificationSettingsKey) {
    $storedGlass = [string](Get-Item -LiteralPath $notificationSettingsKey).GetValue('styleConstants[0]', $null)
    if ($storedGlass -ne $NotificationGlassBrush) {
        $problems += "Notification glass brush mismatch: '$storedGlass'"
    }
    # Older builds also wrote the same brush as a theme resource. The theme reads the style
    # constant, so a leftover duplicate would mask future changes; it must stay absent.
    $storedResourceGlass = [string](Get-Item -LiteralPath $notificationSettingsKey).GetValue('themeResourceVariables[0]', $null)
    if ($storedResourceGlass) {
        $problems += "Duplicate notification resource brush still present: '$storedResourceGlass'"
    }
} else {
    $problems += 'Notification settings key missing'
}
$settingsEntry = $mods[$SettingsModId]
if ($settingsEntry) {
    foreach ($key in $SettingsSettings.Keys) {
        if ([string]$settingsEntry.settings.$key -ne [string]$SettingsSettings[$key]) {
            $problems += "Settings app setting mismatch: $key"
        }
    }
}
# The theme supersedes the old pane-only override; check that both stale forms are gone.
$staleSettingsStyles = @(Get-WhModSettingNames -ModId $SettingsModId | Where-Object {
    $_ -like 'controlStyles*' -or $_ -eq 'Background'
})
if ($staleSettingsStyles.Count -gt 0) {
    $problems += ('Stale Settings app styles still present: ' + ($staleSettingsStyles -join ', '))
}
$allWindowsEntry = $mods[$AllWindowsModId]
if ($allWindowsEntry) {
    foreach ($key in $AllWindowsSettings.Keys) {
        if ([string]$allWindowsEntry.settings.$key -ne [string]$AllWindowsSettings[$key]) {
            $problems += "Global windows setting mismatch: $key"
        }
    }
}
# whcli export does not carry Include, so verify the universal scope directly in the store.
$allWindowsKey = Resolve-WhModKey -ModId $AllWindowsModId
$storedInclude = [string](Get-ItemProperty -LiteralPath $allWindowsKey -Name 'Include' -ErrorAction SilentlyContinue).Include
if ($storedInclude -ne $AllWindowsIncludePattern) {
    $problems += "Global windows include mismatch: '$storedInclude'"
}
$taskMgrPaletteKey = Resolve-WhModKey -ModId $TaskMgrPaletteModId
$storedTaskMgrInclude = [string](Get-ItemProperty -LiteralPath $taskMgrPaletteKey -Name 'Include' -ErrorAction SilentlyContinue).Include
if ($storedTaskMgrInclude -ne 'taskmgr.exe') {
    $problems += "Task Manager palette include mismatch: '$storedTaskMgrInclude'"
}
# Task Manager must be native: no old shortcut, helper, scheduled task or dev mod.
if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
    foreach ($taskPath in @($LegacyTaskMgrTaskPath, '\')) {
        if (Get-ScheduledTask -TaskName $LegacyTaskMgrTaskName -TaskPath $taskPath -ErrorAction SilentlyContinue) {
            $problems += "Legacy Task Manager task still registered: $taskPath$LegacyTaskMgrTaskName"
        }
    }
}
foreach ($path in @($LegacyTaskMgrStartMenuLnk, $LegacyTaskMgrDesktopLnk, $LegacyTaskMgrLauncherPath, $LegacyTaskMgrHelperPath)) {
    if (Test-Path -LiteralPath $path) {
        $problems += "Legacy Task Manager artifact still present: $path"
    }
}
if (Test-Path -LiteralPath $LegacyTaskMgrCopyDir) {
    $problems += "Legacy Task Manager private copy still present: $LegacyTaskMgrCopyDir"
}
$legacyDevModKey = Join-Path (Get-WhRegistryBase -InstallRoot $ActiveRoot) ('Engine\Mods\' + $LegacyTaskMgrDevModId)
if (Test-Path -LiteralPath $legacyDevModKey) {
    $problems += "Legacy Task Manager dev mod still installed: $LegacyTaskMgrDevModId"
}
foreach ($name in @('ebos-taskmgr-glass.ini', 'ebos-taskmgr-glass.log')) {
    $path = Join-Path ([IO.Path]::GetTempPath()) $name
    if (Test-Path -LiteralPath $path) {
        $problems += "Legacy Task Manager dev file still present: $path"
    }
}
# The AppContainer ACE is what keeps the engine loaded in ShellExperienceHost.exe and packaged
# Windows apps. Re-read the ACL instead of trusting the earlier grant.
$whDataPath = Get-WhDataPath -InstallRoot $ActiveRoot
if (-not (Test-AppContainerReadAccess -Path $whDataPath)) {
    $problems += "AppContainer read ACE missing on $whDataPath"
}
if ($problems.Count -gt 0) {
    throw "Windhawk verification failed: $($problems -join '; ') (profile: $checkFile)"
}
Write-Host 'Windhawk mods and settings verified.' -ForegroundColor Green

# --- 4. Apply live ---
try {
    Invoke-Whcli -Arguments @('restart')
} catch {
    # Fall back to the service whcli reported for the active mode (stock or standalone engine).
    Write-WhLog ('whcli restart failed: ' + $_.Exception.Message)
    $svc = Get-Service -Name $ActiveService -ErrorAction SilentlyContinue
    if (-not $svc) { throw }
    if ($svc.Status -eq 'Running') {
        Restart-Service -Name $ActiveService -Force -ErrorAction Stop
    } else {
        Start-Service -Name $ActiveService -ErrorAction Stop
    }
    Write-WhLog ("Restarted service $ActiveService directly.")
}
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
    Start-Process -FilePath 'explorer.exe'
    Write-WhLog 'explorer.exe was not restarted automatically; started it.'
}

Write-Host 'Done. Taskbar, File Explorer, Start menu, notification center, Settings and Task Manager use the blurred glass; global window transparency is applied. Task Manager is the normal Ctrl+Shift+Esc app; no separate shortcut or scheduled task is used.' -ForegroundColor Green
Write-WhLog 'Done; native Task Manager glass applied, legacy launcher artifacts removed.'

# --- 5. Optional first-boot task (runs this script as SYSTEM, removes itself afterwards) ---
if ($RegisterFirstBootTask) {
    if (-not $ScriptPath) { throw 'Cannot register the first-boot task without a script path.' }
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Write-Host "Registered first-boot task: $TaskName" -ForegroundColor Green
    Write-WhLog "Registered first-boot task: $TaskName"
} elseif (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-WhLog "Unregistered first-boot task: $TaskName"
}

$global:LASTEXITCODE = 0
