# set-wallpaper.ps1
# Setzt Desktop-Hintergrund (Mode Desktop) oder Sperrbildschirm (Mode LockScreen).
# Aenderung in Phase 3: Fehlerbehandlung, Logging und Aufraeumen des Temp-Files.
# Die Logik selbst ist unveraendert.

param (
    [Parameter(Mandatory)][ValidateSet("Desktop","LockScreen")][string]$Mode,
    [Parameter(Mandatory)][string]$ImagePath
)

$ErrorActionPreference = 'Stop'

# Log-Datei im EBOS-Verzeichnis, damit Fehler nachvollziehbar sind.
$logDir = Join-Path $env:WINDIR 'EBOS'
$logFile = Join-Path $logDir 'set-wallpaper.log'
try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch { }

function Write-Log([string]$msg) {
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mode, $msg
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

$tmp = $null
try {
    Write-Log "Start, Bild: $ImagePath"

    if (-not (Test-Path -LiteralPath $ImagePath)) {
        throw "Bild nicht gefunden: $ImagePath"
    }
    $img = (Get-Item -LiteralPath $ImagePath -Force).FullName

    if ($Mode -eq "Desktop") {
        # Pro geladenem Benutzer-Hive den Wallpaper-Pfad setzen.
        Get-ChildItem "Registry::HKU" | ForEach-Object {
            try {
                [Microsoft.Win32.Registry]::SetValue("$($_.Name)\Control Panel\Desktop","WallPaper",$img,[Microsoft.Win32.RegistryValueKind]::String)
            } catch {
                Write-Log "Hive $($_.Name) uebersprungen: $($_.Exception.Message)"
            }
        }
        $cs = 'using System.Runtime.InteropServices; public class WPHelper { [DllImport("user32.dll",SetLastError=true,CharSet=CharSet.Auto)] static extern int SystemParametersInfo(int a,int b,string c,int d); public static void Set(string p){SystemParametersInfo(20,0,p,3);} }'
        if (-not ([System.Management.Automation.PSTypeName]'WPHelper').Type) { Add-Type -TypeDefinition $cs }
        [WPHelper]::Set($img)
        Write-Log "Desktop-Hintergrund gesetzt."
    }
    else {
        # Sperrbildschirm: Datei in denselben Ordner kopieren, weil die WinRT-API einen Dateiverweis braucht.
        $tmp = Join-Path ([IO.Path]::GetDirectoryName($img)) ([Guid]::NewGuid().ToString() + [IO.Path]::GetExtension($img))
        Copy-Item -LiteralPath $img -Destination $tmp -Force

        [Windows.System.UserProfile.LockScreen,Windows.System.UserProfile,ContentType=WindowsRuntime] | Out-Null
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        function Await($op,$rt) { $t = $m.MakeGenericMethod($rt).Invoke($null,@($op)); $t.Wait(-1)|Out-Null; $t.Result }
        function AwaitV($op) { $t = ([System.WindowsRuntimeSystemExtensions].GetMethods()|Where-Object{$_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and -not $_.IsGenericMethod})[0].Invoke($null,@($op)); $t.Wait(-1)|Out-Null }

        [Windows.Storage.StorageFile,Windows.Storage,ContentType=WindowsRuntime] | Out-Null
        $f = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
        AwaitV ([Windows.System.UserProfile.LockScreen]::SetImageFileAsync($f))

        [Microsoft.Win32.Registry]::SetValue("HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Personalization","LockScreenImage",$img,[Microsoft.Win32.RegistryValueKind]::String)
        Write-Log "Sperrbildschirm gesetzt."
    }
    exit 0
}
catch {
    Write-Log "FEHLER: $($_.Exception.Message)"
    exit 1
}
finally {
    # Temp-Kopie immer entfernen, auch bei Fehler.
    if ($tmp -and (Test-Path -LiteralPath $tmp)) {
        try { Remove-Item -LiteralPath $tmp -Force } catch { Write-Log "Temp-Datei nicht entfernt: $tmp" }
    }
}
