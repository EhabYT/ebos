#Requires -Version 5.1
# Removes Windhawk components installed by this package and by hand:
#   1. windhawk-cli (service WindhawkCLI, install C:\Program Files\WindhawkCLI, task WindhawkCLI-Supervisor)
#   2. the official Windhawk GUI, if its NSIS uninstaller is found
#   3. the first-boot task WindhawkTransparentUI, if it was registered
#   4. legacy Task Manager acrylic artifacts (task \EBOS\TaskMgrAcrylic, shortcut, VBS, helper)
# windhawk-cli is removed with its own installer (--uninstall). That installer is checked against the
# pinned SHA-256 before it runs. If the file is not next to this script, the installed copy is not used.
# windhawk-cli removal is not fully tested on Windows. The legacy Task Manager task/file cleanup
# path was tested on Windows 11. Run only if you want Windhawk removed, from an elevated PowerShell.

$ErrorActionPreference = 'Stop'

$LogDir  = Join-Path $env:WINDIR 'EBOS'
$LogFile = Join-Path $LogDir 'windhawk-uninstall.log'

$CliInstallerName   = 'windhawk-cli-1.1.0-installer.exe'
$CliInstallerSha256 = '63962B290A3C63C45CF442BF3A99E91EE721AC151C7B3F774DEE4424F7A238AB'
$CliRoot            = 'C:\Program Files\WindhawkCLI'
$CliTaskName        = 'WindhawkCLI-Supervisor'
$UiTaskName         = 'WindhawkTransparentUI'
$TaskMgrTaskName    = 'TaskMgrAcrylic'
$TaskMgrTaskPath    = '\EBOS\'
$TaskMgrLauncher    = Join-Path $LogDir 'TaskMgr-Acrylic.vbs'
$TaskMgrHelper      = Join-Path $LogDir 'TaskMgr-Acrylic.ps1'
$TaskMgrCopyDir     = Join-Path $LogDir 'TaskMgr-Acryl'
$TaskMgrShortcut    = 'Task-Manager (Acryl).lnk'
$CommonStartMenu    = [Environment]::GetFolderPath('CommonStartMenu')
if (-not $CommonStartMenu) { $CommonStartMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu' }
$CommonDesktop      = [Environment]::GetFolderPath('CommonDesktopDirectory')
if (-not $CommonDesktop) { $CommonDesktop = Join-Path $env:PUBLIC 'Desktop' }
$TaskMgrStartMenu   = Join-Path (Join-Path $CommonStartMenu 'Programs\EBOS') $TaskMgrShortcut
$TaskMgrDesktop     = Join-Path $CommonDesktop $TaskMgrShortcut

function Write-WhLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
        Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message) -ErrorAction SilentlyContinue
    } catch {}
}

function Remove-WindhawkCli {
    $here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $installer = Join-Path $here $CliInstallerName
    $present = (Test-Path -LiteralPath (Join-Path $CliRoot 'whcli.exe')) -or
               [bool](Get-Service -Name 'WindhawkCLI' -ErrorAction SilentlyContinue) -or
               [bool](Get-ScheduledTask -TaskName $CliTaskName -ErrorAction SilentlyContinue)
    if (-not $present) {
        Write-WhLog 'windhawk-cli not found. Skipped.'
        return
    }
    if (-not (Test-Path -LiteralPath $installer)) {
        Write-WhLog "windhawk-cli is installed, but $CliInstallerName is not next to this script. Not removed. Use Settings > Apps or run the installer from the package with --uninstall."
        return
    }
    $actual = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
    if ($actual -ne $CliInstallerSha256) {
        Write-WhLog "SHA-256 mismatch for $CliInstallerName (got $actual). windhawk-cli not removed."
        return
    }
    $proc = Start-Process -FilePath $installer -ArgumentList @('--uninstall', '--silent') -Wait -PassThru -WindowStyle Hidden
    Write-WhLog ('Ran windhawk-cli --uninstall, exit code {0}' -f $proc.ExitCode)

    # The installer should remove the task. Remove it here too if it is still there.
    if (Get-ScheduledTask -TaskName $CliTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $CliTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-WhLog "Removed scheduled task $CliTaskName."
    }
}

function Remove-TransparentUiTask {
    if (Get-ScheduledTask -TaskName $UiTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $UiTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-WhLog "Removed scheduled task $UiTaskName."
    }
}

function Remove-TaskManagerAcrylicShortcut {
    foreach ($taskPath in @($TaskMgrTaskPath, '\')) {
        if (Get-ScheduledTask -TaskName $TaskMgrTaskName -TaskPath $taskPath -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskMgrTaskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
            Write-WhLog "Removed scheduled task $taskPath$TaskMgrTaskName."
        }
    }
    foreach ($path in @($TaskMgrStartMenu, $TaskMgrDesktop, $TaskMgrLauncher, $TaskMgrHelper)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Write-WhLog "Removed $path."
        }
    }
    if (Test-Path -LiteralPath $TaskMgrCopyDir) {
        Remove-Item -LiteralPath $TaskMgrCopyDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-WhLog "Removed $TaskMgrCopyDir."
    }
    $startMenuDir = Split-Path -Parent $TaskMgrStartMenu
    if ((Test-Path -LiteralPath $startMenuDir) -and
        -not (Get-ChildItem -LiteralPath $startMenuDir -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $startMenuDir -Force -ErrorAction SilentlyContinue
    }
}

function Remove-AppContainerReadAccess {
    # Install-WindhawkTransparentUI.ps1 grants ALL APPLICATION PACKAGES (S-1-15-2-1)
    # read access to the engine data folder so packaged Windows apps can keep the
    # engine loaded. Undo that grant when the engine is removed; otherwise every
    # packaged app keeps read access to a folder that no longer serves a purpose.
    $sid = 'S-1-15-2-1'
    foreach ($p in @(
        (Join-Path $env:ProgramData 'WindhawkCLI\Engine'),
        (Join-Path $env:ProgramData 'Windhawk\Engine')
    )) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            & icacls.exe $p /remove:g ('*' + $sid) /T /C /Q | Out-Null
            Write-WhLog ("Removed AppContainer read access from {0} (icacls exit {1})." -f $p, $LASTEXITCODE)
        } catch {
            Write-WhLog ("Could not remove AppContainer read access from {0}: {1}" -f $p, $_.Exception.Message)
        }
    }
}

function Remove-OfficialWindhawk {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Windhawk\uninstall.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Windhawk\uninstall.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Windhawk\uninstall.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    if (-not $candidates) {
        Write-WhLog 'No official Windhawk uninstaller found in the standard folders. Nothing removed.'
        return
    }
    foreach ($uninst in $candidates) {
        $proc = Start-Process -FilePath $uninst -ArgumentList @('/S') -Wait -PassThru -WindowStyle Hidden
        Write-WhLog ('Ran {0}, exit code {1}' -f $uninst, $proc.ExitCode)
    }
}

try { Remove-WindhawkCli } catch { Write-WhLog ('windhawk-cli uninstall failed: {0}' -f $_.Exception.Message) }
try { Remove-TransparentUiTask } catch { Write-WhLog ('Transparent UI task cleanup failed: {0}' -f $_.Exception.Message) }
try { Remove-TaskManagerAcrylicShortcut } catch { Write-WhLog ('Task Manager shortcut cleanup failed: {0}' -f $_.Exception.Message) }
try { Remove-OfficialWindhawk } catch { Write-WhLog ('Official Windhawk uninstall failed: {0}' -f $_.Exception.Message) }
try { Remove-AppContainerReadAccess } catch { Write-WhLog ('AppContainer ACE cleanup failed: {0}' -f $_.Exception.Message) }

$global:LASTEXITCODE = 0
