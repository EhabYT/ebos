#Requires -Version 5.1
# Stage 1 of automatic Defender handling. READ-ONLY.
# Runs at the very start of phase1, before phase2 writes any Defender policy,
# so the state is captured as the machine was found.
#
# Writes %WINDIR%\EBOS\defender-state.txt with a line:
#   DEFENDER_STATE=ACTIVE | DISABLED | ABSENT
#
# Later stages read this file and only remove Defender when it says DISABLED.
# Any error, or any doubt, yields ACTIVE: the fail-safe is to keep Defender.
#
# DISABLED = Defender was switched off on purpose:
#   - WinDefend service start type is Disabled, or
#   - policy DisableAntiSpyware = 1, or
#   - Get-MpComputerStatus reports AMServiceEnabled = False.
# ACTIVE   = Defender runs, or another antivirus (passive mode) is in charge.
#            Passive mode is NOT treated as disabled: Defender is not turned off there.
# ABSENT   = no WinDefend service at all (already removed). Nothing to do.

$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:WINDIR 'EBOS'
$log    = Join-Path $logDir 'defender-state.txt'
try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch {}

$reasons = @()
$state   = 'ACTIVE'

try {
    $svc = Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
    if (-not $svc) {
        $state = 'ABSENT'
        $reasons += 'WinDefend service not present'
    } else {
        $cim = Get-CimInstance -ClassName Win32_Service -Filter "Name='WinDefend'" -ErrorAction SilentlyContinue
        $startMode = if ($cim) { [string]$cim.StartMode } else { 'unknown' }
        $reasons += "WinDefend start type: $startMode, status: $($svc.Status)"

        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Name 'DisableAntiSpyware' -ErrorAction SilentlyContinue
        $policyValue = if ($policy) { [string]$policy.DisableAntiSpyware } else { 'not set' }
        $reasons += "DisableAntiSpyware policy: $policyValue"

        $amEnabled = $null
        $runningMode = 'unknown'
        try {
            $st = Get-MpComputerStatus -ErrorAction Stop
            $amEnabled   = [bool]$st.AMServiceEnabled
            $runningMode = [string]$st.AMRunningMode
            $reasons += "AMServiceEnabled: $amEnabled, AMRunningMode: $runningMode"
        } catch {
            $reasons += "Get-MpComputerStatus failed: $($_.Exception.Message)"
        }

        $isDisabled = ($startMode -eq 'Disabled') -or ($policyValue -eq '1') -or ($amEnabled -eq $false)

        # Passive mode: another antivirus is active. Defender is not switched off here.
        $isPassive = ($runningMode -match 'Passive')

        if ($isPassive) {
            $state = 'ACTIVE'
            $reasons += 'Passive mode (another antivirus is active): kept'
        } elseif ($isDisabled) {
            $state = 'DISABLED'
        } else {
            $state = 'ACTIVE'
        }
    }
} catch {
    $state = 'ACTIVE'
    $reasons += "Detection error, kept as ACTIVE: $($_.Exception.Message)"
}

$lines = @()
$lines += 'checked: ' + (Get-Date -Format 's')
$lines += "DEFENDER_STATE=$state"
$lines += $reasons
try { Set-Content -LiteralPath $log -Value $lines -Encoding UTF8 } catch {}

# Flag file read by every runtime-gated Defender step (cmd and PowerShell).
# Present only when the state is DISABLED. Removed in every other case.
$flag = Join-Path $logDir 'defender-disabled.flag'
try {
    if ($state -eq 'DISABLED') {
        Set-Content -LiteralPath $flag -Value 'DISABLED' -Encoding ASCII
    } elseif (Test-Path -LiteralPath $flag) {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }
} catch {}
$global:LASTEXITCODE = 0
