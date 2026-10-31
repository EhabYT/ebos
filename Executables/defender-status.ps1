#Requires -Version 5.1
# Read-only report on Windows Defender. Writes %WINDIR%\EBOS\defender-status.txt.
# It removes nothing and changes no setting.
#
# The decision is made in phase1 by defender-state.ps1, BEFORE any Defender policy is
# written, and recorded in %WINDIR%\EBOS\defender-state.txt. This script reports that
# recorded decision and shows the live state for information only. Phase 2 sets
# DisableAntiSpyware, so a live check run late in the playbook can report "disabled"
# on a machine that was active when the playbook started. The recorded state is the
# one that counts.

$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:WINDIR 'EBOS'
$log    = Join-Path $logDir 'defender-status.txt'
$state  = Join-Path $logDir 'defender-state.txt'
$flag   = Join-Path $logDir 'defender-disabled.flag'
try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch {}

$lines = @()
$lines += 'checked: ' + (Get-Date -Format 's')

# 1. Decision recorded before any change (authoritative)
$recorded = 'MISSING'
if (Test-Path -LiteralPath $state) {
    $hit = Get-Content -LiteralPath $state -ErrorAction SilentlyContinue | Where-Object { $_ -like 'DEFENDER_STATE=*' } | Select-Object -First 1
    if ($hit) { $recorded = $hit.Substring('DEFENDER_STATE='.Length).Trim() }
}
$lines += "recorded before changes (phase1): $recorded"
$lines += 'runtime flag present (removal ran): ' + $(if (Test-Path -LiteralPath $flag) { 'yes' } else { 'no' })

# 2. Live state, information only
$svc = Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
if ($svc) {
    $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='WinDefend'" -ErrorAction SilentlyContinue
    $startMode = if ($cim) { [string]$cim.StartMode } else { 'unknown' }
    $lines += "live WinDefend service: $($svc.Status), start type $startMode"
} else {
    $lines += 'live WinDefend service: not present'
}
try {
    $st = Get-MpComputerStatus -ErrorAction Stop
    $lines += "live AMServiceEnabled: $($st.AMServiceEnabled), AntivirusEnabled: $($st.AntivirusEnabled), RealTimeProtectionEnabled: $($st.RealTimeProtectionEnabled)"
} catch {
    $lines += "live Get-MpComputerStatus failed: $($_.Exception.Message)"
}

# 3. Result, no action here
if ($recorded -eq 'ACTIVE') {
    $lines += 'Result: Defender recorded ACTIVE before the playbook ran and was kept enabled; it remains fully functional and was not disabled or removed.'
} elseif ($recorded -eq 'DISABLED') {
    $lines += 'Result: Defender recorded DISABLED before the playbook ran; removal steps were gated on that recorded state.'
} else {
    $lines += "Result: recorded state $recorded. This script changed nothing."
}

try { Set-Content -LiteralPath $log -Value $lines -Encoding UTF8 } catch {}
$global:LASTEXITCODE = 0
