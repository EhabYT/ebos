# EBOS personalization guard
#
# Microsoft has acknowledged that Windows updates from 27 August 2026 (KB5120998)
# onward - the servicing branch that Windows 11 26H2 (build 26300) sits on - reset
# mouse-cursor personalization to an oversized white default and drop custom desktop
# wallpapers to solid black. The wallpaper symptom is reported to come back after
# every sign-out or restart, so applying the settings once at install time is not
# enough on 26H2.
#
# This runs at each logon, compares the live settings against what EBOS installed,
# and puts back only what Windows actually threw away. Cursor values are written only
# when they differ. The wallpaper image is re-applied on every logon by design (see the
# wallpaper section), so this is not a zero-write check on a healthy system.

$ErrorActionPreference = 'SilentlyContinue'

$cursorDir = Join-Path $env:windir 'Cursors\EBOS'

# The playbook stores the wallpaper path UNEXPANDED, as %SystemRoot%\...  Keep
# both forms: the literal one is what gets written back (so the value keeps
# working if Windows is not on C:), the expanded one is only for comparing and
# for the file-exists test. Comparing an expanded path against the unexpanded
# registry value never matches, which made this guard rewrite the wallpaper on
# every single logon and bake in a hard-coded C:\Windows.
$wallpaperRef  = '%SystemRoot%\Web\Wallpaper\EBOS\wallpaper.png'
$wallpaper     = [Environment]::ExpandEnvironmentVariables($wallpaperRef)
# This guard runs at logon as the interactive user (Users group, limited token).
# %ProgramData%\EBOS is locked to SYSTEM/Administrators for write by phase 5, so
# a log there can never be written. Keep it in the user's own local profile.
$logFile   = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'EBOS') 'personalization-guard.log'

function Write-GuardLog([string]$m) {
    try {
        $dir = Split-Path $logFile -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $logFile -Value ((Get-Date).ToString('s') + '  ' + $m)
    } catch {}
}

if (-not ('EbosSpi' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class EbosSpi {
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SpiStr(uint uiAction, uint uiParam, string pvParam, uint fWinIni);

    [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    public static extern bool SpiPtr(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);

    [DllImport("user32.dll")]
    public static extern int GetSysColor(int nIndex);

    [DllImport("user32.dll")]
    public static extern bool SetSysColors(int cElements, int[] lpaElements, int[] lpaRgbValues);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
'@ -ErrorAction SilentlyContinue
}

try {
# ------------------------------------------------------------------ theme ----
# Windows 11 26H2 can reset personalization after servicing. The visible
# failure was a dark app mode combined with a stale classic palette: plain
# GDI controls such as Task Manager's SysListView32 painted light text on a
# solid black surface inside an otherwise translucent window. Keep the EBOS
# palette (same values as Executables/ebos-dark.theme) in the user hive and
# push it into the running session, so classic surfaces stay readable even
# when Windows forgets the active theme.
$ebosPalette = [ordered]@{
    'Scrollbar'             = @(12, 28, 48)
    'Background'            = @(6, 16, 30)
    'ActiveTitle'           = @(8, 24, 44)
    'InactiveTitle'         = @(6, 16, 30)
    'Menu'                  = @(10, 20, 34)
    'Window'                = @(10, 24, 42)
    'WindowFrame'           = @(64, 96, 128)
    'MenuText'              = @(255, 255, 255)
    'WindowText'            = @(255, 255, 255)
    'TitleText'             = @(255, 255, 255)
    'ActiveBorder'          = @(36, 72, 112)
    'InactiveBorder'        = @(16, 34, 56)
    'AppWorkspace'          = @(6, 14, 26)
    'Hilight'               = @(0, 122, 255)
    'HilightText'           = @(255, 255, 255)
    'ButtonFace'            = @(10, 24, 42)
    'ButtonShadow'          = @(4, 10, 18)
    'GrayText'              = @(168, 184, 204)
    'ButtonText'            = @(255, 255, 255)
    'InactiveTitleText'     = @(200, 214, 230)
    'ButtonHilight'         = @(48, 80, 116)
    'ButtonDkShadow'        = @(2, 6, 12)
    'ButtonLight'           = @(16, 34, 56)
    'InfoText'              = @(255, 255, 255)
    'InfoWindow'            = @(12, 28, 48)
    'ButtonAlternateFace'   = @(10, 24, 42)
    'HotTrackingColor'      = @(95, 200, 255)
    'GradientActiveTitle'   = @(8, 24, 44)
    'GradientInactiveTitle' = @(6, 16, 30)
    'MenuHilight'           = @(0, 122, 255)
    'MenuBar'               = @(6, 16, 30)
}

$themeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
if (-not (Test-Path $themeKey)) { New-Item -Path $themeKey -Force | Out-Null }
$themeFixed = 0
foreach ($name in @('AppsUseLightTheme', 'SystemUsesLightTheme')) {
    $have = (Get-ItemProperty -Path $themeKey -Name $name -ErrorAction SilentlyContinue).$name
    if ($have -ne 0) {
        New-ItemProperty -Path $themeKey -Name $name -Value 0 -PropertyType DWord -Force | Out-Null
        $themeFixed++
    }
}
$haveTransparency = (Get-ItemProperty -Path $themeKey -Name 'EnableTransparency' -ErrorAction SilentlyContinue).EnableTransparency
if ($haveTransparency -ne 1) {
    New-ItemProperty -Path $themeKey -Name 'EnableTransparency' -Value 1 -PropertyType DWord -Force | Out-Null
    $themeFixed++
}

$colorsKey = 'HKCU:\Control Panel\Colors'
if (-not (Test-Path $colorsKey)) { New-Item -Path $colorsKey -Force | Out-Null }
$paletteFixed = 0
foreach ($name in $ebosPalette.Keys) {
    $want = ($ebosPalette[$name] -join ' ')
    $have = [string](Get-ItemProperty -Path $colorsKey -Name $name -ErrorAction SilentlyContinue).$name
    if ($have -ne $want) {
        New-ItemProperty -Path $colorsKey -Name $name -Value $want -PropertyType String -Force | Out-Null
        $paletteFixed++
    }
}

# The registry alone does not repaint open windows, and Windows may have loaded
# the old palette at logon. Compare the live system color table and apply the
# EBOS values when they differ; SetSysColors redraws every classic control.
$colorIndex = @{
    'Scrollbar' = 0; 'Background' = 1; 'ActiveTitle' = 2; 'InactiveTitle' = 3;
    'Menu' = 4; 'Window' = 5; 'WindowFrame' = 6; 'MenuText' = 7; 'WindowText' = 8;
    'TitleText' = 9; 'ActiveBorder' = 10; 'InactiveBorder' = 11;
    'AppWorkspace' = 12; 'Hilight' = 13; 'HilightText' = 14; 'ButtonFace' = 15;
    'ButtonShadow' = 16; 'GrayText' = 17; 'ButtonText' = 18;
    'InactiveTitleText' = 19; 'ButtonHilight' = 20; 'ButtonDkShadow' = 21;
    'ButtonLight' = 22; 'InfoText' = 23; 'InfoWindow' = 24;
    'ButtonAlternateFace' = 25; 'HotTrackingColor' = 26;
    'GradientActiveTitle' = 27; 'GradientInactiveTitle' = 28;
    'MenuHilight' = 29; 'MenuBar' = 30
}
$paletteDirty = $false
foreach ($name in $ebosPalette.Keys) {
    $c = $ebosPalette[$name]
    $want = [int]$c[0] -bor ([int]$c[1] -shl 8) -bor ([int]$c[2] -shl 16)
    if ([int][EbosSpi]::GetSysColor([int]$colorIndex[$name]) -ne $want) {
        $paletteDirty = $true
        break
    }
}
if ($paletteDirty) {
    $indices = New-Object int[] $ebosPalette.Count
    $values  = New-Object int[] $ebosPalette.Count
    $i = 0
    foreach ($name in $ebosPalette.Keys) {
        $c = $ebosPalette[$name]
        $indices[$i] = [int]$colorIndex[$name]
        $values[$i]  = [int]$c[0] -bor ([int]$c[1] -shl 8) -bor ([int]$c[2] -shl 16)
        $i++
    }
    if ([EbosSpi]::SetSysColors($indices.Length, $indices, $values)) {
        Write-GuardLog ("applied EBOS classic palette ({0} entries)" -f $indices.Length)
    }
}

if ($themeFixed -gt 0 -or $paletteDirty) {
    $r = [IntPtr]::Zero
    [void][EbosSpi]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, 'ImmersiveColorSet', 0x0002, 5000, [ref]$r)
    if ($themeFixed -gt 0) { Write-GuardLog ("restored {0} theme mode value(s)" -f $themeFixed) }
    if ($paletteFixed -gt 0) { Write-GuardLog ("restored {0} classic palette value(s)" -f $paletteFixed) }
}

# ---------------------------------------------------------------- cursors ----
$roles = [ordered]@{
    'Arrow'       = 'ebos-arrow.ani'
    'Help'        = 'ebos-help.ani'
    'AppStarting' = 'ebos-appstarting.ani'
    'Wait'        = 'ebos-wait.ani'
    'Crosshair'   = 'ebos-cross.ani'
    'IBeam'       = 'ebos-ibeam.ani'
    'NWPen'       = 'ebos-pen.ani'
    'No'          = 'ebos-no.ani'
    'SizeNS'      = 'ebos-sizens.ani'
    'SizeWE'      = 'ebos-sizewe.ani'
    'SizeNWSE'    = 'ebos-sizenwse.ani'
    'SizeNESW'    = 'ebos-sizenesw.ani'
    'SizeAll'     = 'ebos-sizeall.ani'
    'UpArrow'     = 'ebos-up.ani'
    'Hand'        = 'ebos-hand.ani'
    'Pin'         = 'ebos-pin.ani'
    'Person'      = 'ebos-person.ani'
}

$ck = 'HKCU:\Control Panel\Cursors'
$cursorFixed = 0

if (Test-Path $cursorDir) {
    if (-not (Test-Path $ck)) { New-Item -Path $ck -Force | Out-Null }
    foreach ($role in $roles.Keys) {
        $file = Join-Path $cursorDir $roles[$role]
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $want = '%SystemRoot%\Cursors\EBOS\' + $roles[$role]
        # read raw so REG_EXPAND_SZ is not expanded before the comparison
        $have = $null
        try {
            $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Cursors')
            if ($rk) {
                $have = $rk.GetValue($role, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $rk.Close()
            }
        } catch {}
        if ($have -ne $want) {
            Set-ItemProperty -Path $ck -Name $role -Value $want -Type ExpandString -Force
            $cursorFixed++
        }
    }
    # Read the default value through the raw key: Get-ItemProperty exposes it as
    # '(default)' in lower case, so a '(Default)' property lookup silently misses.
    $haveDefault = $null
    try {
        $rk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Cursors')
        if ($rk) { $haveDefault = $rk.GetValue('', $null); $rk.Close() }
    } catch {}
    if ($haveDefault -ne 'EBOS') {
        # Phase 3: Der Standardwert ist der unbenannte Wert. Set-ItemProperty mit '(Default)' legt dagegen einen
        # Wert namens '(Default)' an und setzt den Standardwert nicht. Deshalb ueber den Registry-Schluessel schreiben.
        try {
            $wk = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Control Panel\Cursors', $true)
            if ($wk) { $wk.SetValue('', 'EBOS', [Microsoft.Win32.RegistryValueKind]::String); $wk.Close() }
        } catch { Write-GuardLog ('Standard-Cursorschema konnte nicht gesetzt werden: ' + $_.Exception.Message) }
        $cursorFixed++
    }
    # Same reasoning as the installer: an inherited CursorBaseSize makes a
    # correct scheme look wrong, and the 26H2 branch resets personalization.
    $haveSize = (Get-ItemProperty -Path $ck -Name 'CursorBaseSize').CursorBaseSize
    if ($haveSize -ne 32) {
        Set-ItemProperty -Path $ck -Name 'CursorBaseSize' -Value 32 -Type DWord -Force
        $cursorFixed++
    }

    if ($cursorFixed -gt 0) {
        # SPI_SETCURSORS = 0x0057, SPIF_SENDCHANGE = 0x02
        [void][EbosSpi]::SpiPtr(0x0057, 0, [IntPtr]::Zero, 0x02)
        Write-GuardLog ("restored $cursorFixed cursor value(s)")
    }
}

# -------------------------------------------------------------- wallpaper ----
$wallFixed = $false

if (Test-Path -LiteralPath $wallpaper) {
    $dk = 'HKCU:\Control Panel\Desktop'
    $have = (Get-ItemProperty -Path $dk -Name 'Wallpaper').Wallpaper
    $haveExp = if ($have) { [Environment]::ExpandEnvironmentVariables($have) } else { '' }
    if ($haveExp -ne $wallpaper) {
        Set-ItemProperty -Path $dk -Name 'Wallpaper' -Value $wallpaperRef -Type String -Force
        $wallFixed = $true
    }
    if ((Get-ItemProperty -Path $dk -Name 'WallpaperStyle').WallpaperStyle -ne '10') {
        Set-ItemProperty -Path $dk -Name 'WallpaperStyle' -Value '10' -Type String -Force
        $wallFixed = $true
    }
    # Deliberately NOT touching Control Panel\Colors\Background: a black desktop
    # colour is a legitimate user choice and the regression is a failure to LOAD
    # personalization, not a colour change. Guessing there would overwrite a
    # preference rather than repair a fault.
    #
    # The reported symptom is the wallpaper reverting after every sign-out, so the
    # image is pushed through SPI on every logon rather than only when the registry
    # looks wrong - the registry can read correct while nothing is on screen.
    # SPI_SETDESKWALLPAPER = 0x0014, SPIF_UPDATEINIFILE|SPIF_SENDCHANGE = 0x03
    [void][EbosSpi]::SpiStr(0x0014, 0, $wallpaper, 0x03)
    if ($wallFixed) { Write-GuardLog 'repaired wallpaper registry values' }
}
} catch {
    Write-GuardLog ('FEHLER: ' + $_.Exception.Message)
}
exit 0
