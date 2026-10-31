$ErrorActionPreference = 'SilentlyContinue'
function Write-EbosLog([string]$Message) {
    try {
        $dir = Join-Path $env:WINDIR 'EBOS'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath (Join-Path $dir 'defender-restart-notice.log') -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message) -ErrorAction SilentlyContinue
    } catch {}
}
Write-EbosLog 'start'
try {
try { Unregister-ScheduledTask -TaskName 'EBOSDefenderRestartNotice' -Confirm:$false } catch {}
try { & schtasks.exe /Delete /TN EBOSDefenderRestartNotice /F 2>$null | Out-Null } catch {}
& shutdown.exe /r /t 20 /c "Your PC will restart once more in 20 seconds to complete the final cleanup. Enjoy your new lightweight Windows."
} catch {
    Write-EbosLog ('FEHLER: ' + $_.Exception.Message)
}
Write-EbosLog 'ende'
