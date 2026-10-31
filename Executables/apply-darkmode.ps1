$ErrorActionPreference = 'SilentlyContinue'
function Write-EbosLog([string]$Message) {
    try {
        $dir = Join-Path $env:WINDIR 'EBOS'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $dir 'apply-darkmode.log') -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message) -ErrorAction SilentlyContinue
    } catch {}
}
Write-EbosLog 'start'
try {

$personalizationMarker = Join-Path $env:windir 'EBOS\.personalization-applied'
if (Test-Path $personalizationMarker) {
    $global:LASTEXITCODE = 0
    exit 0
}

$sids = @('.DEFAULT')
try {
    $sids += (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' } |
        ForEach-Object { $_.PSChildName })
} catch {}

foreach ($sid in $sids) {
    $key = 'Registry::HKEY_USERS\' + $sid + '\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'AppsUseLightTheme'    -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name 'SystemUsesLightTheme' -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $key -Name 'ColorPrevalence'      -Value 0 -PropertyType DWord -Force | Out-Null
}

# Classic Win32 palette, kept in sync with Executables/ebos-dark.theme. A dark
# app mode with a light or black inherited palette is what made Task Manager's
# SysListView32 unreadable; the logon guard repairs the live color table, this
# seeds every profile (including .DEFAULT) so the first session is correct.
$ebosPalette = [ordered]@{
    'Scrollbar'             = '12 28 48'
    'Background'            = '6 16 30'
    'ActiveTitle'           = '8 24 44'
    'InactiveTitle'         = '6 16 30'
    'Menu'                  = '10 20 34'
    'Window'                = '10 24 42'
    'WindowFrame'           = '64 96 128'
    'MenuText'              = '255 255 255'
    'WindowText'            = '255 255 255'
    'TitleText'             = '255 255 255'
    'ActiveBorder'          = '36 72 112'
    'InactiveBorder'        = '16 34 56'
    'AppWorkspace'          = '6 14 26'
    'Hilight'               = '0 122 255'
    'HilightText'           = '255 255 255'
    'ButtonFace'            = '10 24 42'
    'ButtonShadow'          = '4 10 18'
    'GrayText'              = '168 184 204'
    'ButtonText'            = '255 255 255'
    'InactiveTitleText'     = '200 214 230'
    'ButtonHilight'         = '48 80 116'
    'ButtonDkShadow'        = '2 6 12'
    'ButtonLight'           = '16 34 56'
    'InfoText'              = '255 255 255'
    'InfoWindow'            = '12 28 48'
    'ButtonAlternateFace'   = '10 24 42'
    'HotTrackingColor'      = '95 200 255'
    'GradientActiveTitle'   = '8 24 44'
    'GradientInactiveTitle' = '6 16 30'
    'MenuHilight'           = '0 122 255'
    'MenuBar'               = '6 16 30'
}
if (Test-Path 'Registry::HKEY_USERS\AME_UserHive_Default') {
    $sids += 'AME_UserHive_Default'
}
foreach ($sid in $sids) {
    $colorsKey = 'Registry::HKEY_USERS\' + $sid + '\Control Panel\Colors'
    if (-not (Test-Path $colorsKey)) { New-Item -Path $colorsKey -Force | Out-Null }
    foreach ($name in $ebosPalette.Keys) {
        New-ItemProperty -Path $colorsKey -Name $name -Value $ebosPalette[$name] -PropertyType String -Force | Out-Null
    }
}

if (-not ('Win32.NativeMethods' -as [type])) {
    Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto, SetLastError = true)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
'@
}

$HWND_BROADCAST   = [IntPtr]0xffff
$WM_SETTINGCHANGE = 0x001A
$SMTO_ABORTIFHUNG = 0x0002
$result = [IntPtr]::Zero

[void][Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [IntPtr]::Zero, 'ImmersiveColorSet', $SMTO_ABORTIFHUNG, 5000, [ref]$result)
[void][Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [IntPtr]::Zero, 'Environment',       $SMTO_ABORTIFHUNG, 5000, [ref]$result)
} catch {
    Write-EbosLog ('FEHLER: ' + $_.Exception.Message)
}
Write-EbosLog 'ende'
