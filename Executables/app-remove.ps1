[CmdletBinding(DefaultParameterSetName = 'Packages')]
param(
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Packages')]
    [string[]]$Packages,

    # Unregister only: keep the provisioned copy and skip the explicit residue
    # and app-data purge. Used when a package should stop being registered for
    # the current users but must stay reinstallable.
    [Parameter(ParameterSetName = 'Packages')]
    [switch]$Unregister,

    # Authoritative remove-bloat pass. One call removes the curated consumer,
    # streaming, social and OEM bloat families, including provisioned-only
    # copies and their residue. Gaming tools and shared AppX frameworks are
    # deliberately not in this list.
    [Parameter(Mandatory = $true, ParameterSetName = 'Bloatware')]
    [switch]$Bloatware,

    [Parameter(ParameterSetName = 'Bloatware')]
    [string[]]$AdditionalPackages = @(),

    # Final phase-2 sweep. Reads the AppX snapshot taken before the playbook
    # started, computes which families disappeared, and finishes the job for
    # each of them (provisioned copy, staging keys, package folders, app data).
    [Parameter(Mandatory = $true, ParameterSetName = 'PurgeRemoved')]
    [switch]$PurgeRemoved,

    [Parameter(ParameterSetName = 'PurgeRemoved')]
    [string]$SnapshotFile = (Join-Path $env:TEMP 'ebos-appx-snapshot.txt'),

    # Do not delete per-user app data. Package and staging removal still run.
    [switch]$KeepUserData
)

$ErrorActionPreference = 'SilentlyContinue'

# Errors are written to a log file instead of being dropped silently.
$AppRemoveLog = Join-Path $env:WINDIR 'EBOS\app-remove.log'
function Write-AppLog {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $AppRemoveLog
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
        Add-Content -LiteralPath $AppRemoveLog -Value ('{0} {1}' -f (Get-Date -Format 's'), $Message) -ErrorAction SilentlyContinue
    } catch {}
}

$AppxStoreRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
$AppxDeprovisionedRoot = Join-Path $AppxStoreRoot 'Deprovisioned'
$AppModelUserRoot = 'Registry::HKEY_USERS'
$script:FailedCount = 0
$script:PurgedDataCount = 0

# Authoritative remove-bloat list. Patterns are substrings matched against the
# package name, package family, package full name and provisioned display name,
# so no wildcards belong here.
#
# Keep gaming/streaming production tools (Discord, OBS, Streamlabs, Twitch,
# Steam, Epic Games, etc.) and shared AppX framework packages (VCLibs,
# .NET Native, UI.Xaml, WindowsAppRuntime, Microsoft.GamingServices) out of
# this list. Microsoft.GamingServices in particular is a dependency of Store
# games and is therefore not removed by remove-xbox either.
$script:BloatwarePatterns = @(
    # Streaming, music, social, shopping and consumer apps.
    'Spotify',
    'Netflix',
    'TikTok',
    'WhatsApp',
    'Messenger',
    'Disney.37853FC22B2CE',   # Disney+; do not match every Disney game
    'Disney+',
    'DisneyMagicKingdoms',
    'Hulu',
    'PrimeVideo',
    'Amazon.com.Amazon',
    'HBO',
    'Paramount',
    'Peacock',
    'Crunchyroll',
    'Pandora',
    'iHeartRadio',
    'Plex',
    'TuneInRadio',
    'SlingTV',
    'Shazam',
    'Viber',
    'WinZip',
    'NYTCrossword',
    'Duolingo',
    'Fitbit',
    'Flipboard',
    'EclipseManager',
    'ActiproSoftwareLLC',
    'CyberLinkMediaSuite',
    'PicsArt',
    'PolarrPhotoEditor',
    'PhototasticCollage',
    'DrawboardPDF',
    'AutodeskSketchBook',
    'XING',
    'Wunderlist',
    'OneCalendar',
    'ACGMediaPlayer',
    'LiveWallpaper',
    'Asphalt8',
    'CaesarsSlots',
    'COOKINGFEVER',
    'HiddenCity',
    'MarchofEmpires',
    'RoyalRevolt',
    'FarmVille2',
    'BlipStudio',
    'CandyCrush',
    'BubbleWitch',
    'FarmHeroes',
    'BookingApp',
    'Facebook',
    'Instagram',
    'Twitter',
    '7EE7776C.LinkedInforWindows',
    'SkypeApp',
    'AppleMusic',
    'iTunes',
    'AdobePhotoshopExpress',

    # Microsoft inbox apps already covered by remove-bloat.
    'Microsoft.549981C3F5F10',
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.BingSearch',
    'MicrosoftCorporationII.Bing',
    'Clipchamp.Clipchamp',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MSPaint',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MicrosoftStickyNotes',
    'Microsoft.Office.OneNote',
    'Microsoft.OutlookForWindows',
    'Microsoft.OutlookPWA',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.StartExperiencesApp',
    'Microsoft.Todos',
    'Microsoft.Whiteboard',
    'Microsoft.WidgetsPlatformRuntime',
    'Microsoft.Windows.PeopleExperienceHost',
    'Microsoft.Windows.SecureAssessmentBrowser',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsCamera',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
    'MicrosoftWindows.Client.WebExperience',
    'microsoft.windowscommunicationsapps',
    'Microsoft.Windows.DevHome',
    'Microsoft.MicrosoftEdgeDevToolsClient',
    'Microsoft.MicrosoftPowerBIForWindows',
    'Microsoft.MixedReality.Portal',
    'Microsoft.Office.Word',
    'Microsoft.Office.Excel',
    'Microsoft.Office.PowerPoint',
    'Microsoft.Flipgrid',
    'MicrosoftCorporationII.MailforSurfaceHub',
    'Microsoft.MicrosoftTeamsforSurfaceHub',
    'Microsoft.M365Companions',
    'Microsoft.MicrosoftJournal',
    'Microsoft.PCManager',
    'Microsoft.Office.Sway',
    'Microsoft.NetworkSpeedTest',
    'Microsoft.Windows.AIHub',
    'king.com.CandyCrushSaga',
    'king.com.CandyCrushSodaSaga',
    'king.com.BubbleWitch3Saga',
    'king.com.FarmHeroesSaga',

    # OEM bloat: specific apps, not the whole vendor suite. Gaming control
    # centres such as OMEN Gaming Hub are intentionally absent.
    'AD2F1837.HPAIExperienceCenter',
    'AD2F1837.HPConnectedMusic',
    'AD2F1837.HPConnectedPhoto',
    'AD2F1837.HPDesktopSupportUtilities',
    'AD2F1837.HPEasyClean',
    'AD2F1837.HPFileViewer',
    'AD2F1837.HPJumpStarts',
    'AD2F1837.HPPCHardwareDiagnostics',
    'AD2F1837.HPPowerManager',
    'AD2F1837.HPPrinterControl',
    'AD2F1837.HPPrivacySettings',
    'AD2F1837.HPQuickDrop',
    'AD2F1837.HPQuickTouch',
    'AD2F1837.HPRegistration',
    'AD2F1837.HPSupportAssistant',
    'AD2F1837.HPSureShieldAI',
    'AD2F1837.HPSystemInformation',
    'AD2F1837.HPWelcome',
    'AD2F1837.HPWorkWell',
    'AD2F1837.myHP',
    'DellInc.DellDigitalDelivery',
    'DellInc.DellMobileConnect',
    'DellInc.DellSupportAssist',
    'E046963F.LenovoCompanion',
    'LenovoCompanyLimited.LenovoVantageService'
)

function Test-PackageIdentifier {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return ($Value -match '^[A-Za-z0-9][A-Za-z0-9._-]*$')
}

function Test-PackageNameMatchesFamily {
    param([string]$Name, [string]$Family)

    if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Family)) { return $false }
    if ($Name -eq $Family) { return $true }

    $parts = @($Family -split '_')
    if ($parts.Count -lt 2) { return $false }

    # A full package name inserts version/architecture/resource id between the
    # package name and the publisher id. Matching the publisher as well avoids
    # deleting residue of a different family that shares the same short name.
    $packageName = [regex]::Escape($parts[0])
    $publisherId = [regex]::Escape($parts[$parts.Count - 1])
    return ($Name -match ('^' + $packageName + '_.*_' + $publisherId + '$'))
}

function Get-FamilyNameFromPackageName {
    param([string]$PackageName)
    if ([string]::IsNullOrWhiteSpace($PackageName)) { return $null }
    $parts = @($PackageName -split '_')
    if ($parts.Count -ge 2) {
        $family = $parts[0] + '_' + $parts[$parts.Count - 1]
        if (Test-PackageIdentifier $family) { return $family }
    }
    if (Test-PackageIdentifier $PackageName) { return $PackageName }
    return $null
}

function Get-InstalledPackages {
    try { return @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue) } catch { return @() }
}

function Get-ProvisionedPackages {
    try { return @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue) } catch { return @() }
}

function Get-ProvisionedPackagesResult {
    # PurgeRemoved must distinguish "no provisioned packages left" from "query
    # failed". Get-ProvisionedPackages swallows errors, which would otherwise
    # make every staged-only family look removed.
    try {
        $packages = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
        return @{ Success = $true; Packages = $packages }
    } catch {
        Write-AppLog ("Provisioned package query failed: {0}" -f $_.Exception.Message)
        return @{ Success = $false; Packages = @() }
    }
}

function Test-AnyPattern {
    param([object[]]$Values, [string[]]$Patterns)
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        # Callers pass substrings such as 'Microsoft.OneDrive'; keep the old
        # contains-style matching instead of requiring an exact package name.
        $needle = '*' + $pattern + '*'
        foreach ($value in $Values) {
            if ([string]::IsNullOrWhiteSpace([string]$value)) { continue }
            if ([string]$value -like $needle) { return $true }
        }
    }
    return $false
}

function New-WorkEntry {
    param([string]$Family)
    return @{
        Family      = $Family
        Installed   = New-Object System.Collections.ArrayList
        Provisioned = New-Object System.Collections.ArrayList
    }
}

function Get-MatchedWork {
    param(
        [string[]]$Patterns,
        [bool]$IncludeProvisioned = $true
    )

    $work = @{}
    foreach ($pkg in (Get-InstalledPackages)) {
        $family = [string]$pkg.PackageFamilyName
        if (-not (Test-PackageIdentifier $family)) { continue }
        if (-not (Test-AnyPattern -Values @($pkg.Name, $pkg.PackageFamilyName, $pkg.PackageFullName) -Patterns $Patterns)) { continue }
        if (-not $work.ContainsKey($family)) { $work[$family] = New-WorkEntry -Family $family }
        [void]$work[$family].Installed.Add($pkg)
    }

    if (-not $IncludeProvisioned) { return $work }

    foreach ($prov in (Get-ProvisionedPackages)) {
        $fullName = [string]$prov.PackageName
        $family = Get-FamilyNameFromPackageName $fullName
        if (-not (Test-PackageIdentifier $family)) { continue }
        if (-not (Test-AnyPattern -Values @($prov.DisplayName, $fullName, $family) -Patterns $Patterns)) { continue }
        if (-not $work.ContainsKey($family)) { $work[$family] = New-WorkEntry -Family $family }
        [void]$work[$family].Provisioned.Add($prov)
    }

    return $work
}

function Get-PackageUserSids {
    param($PackageRecord)
    $sids = New-Object System.Collections.ArrayList
    try {
        foreach ($userRec in @($PackageRecord.PackageUserInformation)) {
            if (-not $userRec) { continue }
            $candidates = @()
            try { $candidates += [string]$userRec.UserSecurityID } catch {}
            try { $candidates += [string]$userRec.UserSecurityID.SID } catch {}
            try { $candidates += [string]$userRec.UserSecurityID.Value } catch {}
            foreach ($sid in $candidates) {
                # UserSecurityID is a string SID on most builds, but some older
                # Appx module versions expose a nested object instead.
                if ($sid -match '^S-1-[0-9]+-[0-9-]+$') { [void]$sids.Add($sid) }
            }
        }
    } catch {}
    return @($sids | Sort-Object -Unique)
}

function Stop-ProcessBounded {
    param([int]$ProcessId, [int]$TimeoutMs = 5000)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = [System.IO.Path]::Combine($env:windir, 'System32', 'taskkill.exe')
        $psi.Arguments = '/F /T /PID ' + $ProcessId
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        if (-not $proc.WaitForExit($TimeoutMs)) { try { $proc.Kill() } catch {} }
    } catch {}
}

function Stop-PackageProcesses {
    param([string[]]$InstallRoots)

    $roots = @()
    foreach ($root in @($InstallRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $roots += ($root.TrimEnd('\') + '\')
    }
    if ($roots.Count -eq 0) { return }

    foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
        $procPath = $null
        try { $procPath = [string]$proc.Path } catch {}
        if ([string]::IsNullOrWhiteSpace($procPath)) { continue }
        foreach ($root in $roots) {
            if ($procPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                if ($proc.Id -eq $PID) { break }
                Stop-ProcessBounded -ProcessId $proc.Id
                Write-AppLog ("Stopped {0} ({1})" -f $proc.Name, $procPath)
                break
            }
        }
    }
}

function Clear-NonRemovableFlag {
    param($PackageRecord)

    $family = [string]$PackageRecord.PackageFamilyName
    if (-not (Test-PackageIdentifier $family)) { return }

    $isNonRemovable = $false
    try { $isNonRemovable = [bool]$PackageRecord.NonRemovable } catch {}

    # The per-package IsNonRemovable value is what several inbox apps check.
    # Clear it even when the NonRemovable property looks false, because some
    # images only carry the registry value.
    $fullName = [string]$PackageRecord.PackageFullName
    if (Test-PackageIdentifier $fullName) {
        try {
            $appKey = Join-Path (Join-Path $AppxStoreRoot 'Applications') $fullName
            if (Test-Path -LiteralPath $appKey) {
                Remove-ItemProperty -LiteralPath $appKey -Name 'IsNonRemovable' -Force -ErrorAction SilentlyContinue
                $regPath = ([string]$appKey).Replace('HKLM:', 'HKLM')
                & reg.exe delete $regPath /v IsNonRemovable /f 2>&1 | Out-Null
            }
        } catch {}
    }

    if (-not $isNonRemovable) { return }

    try {
        if (-not (Get-Command Set-NonRemovableAppsPolicy -ErrorAction SilentlyContinue)) { return }
        Set-NonRemovableAppsPolicy -Online -PackageFamilyName $family -NonRemovable 0 -ErrorAction Stop | Out-Null
        Write-AppLog ("Cleared NonRemovable: {0}" -f $family)
    } catch {
        Write-AppLog ("Clear NonRemovable failed for {0}: {1}" -f $family, $_.Exception.Message)
    }
}

function Ensure-DeprovisionMarker {
    param([string]$FamilyName)
    if (-not (Test-PackageIdentifier $FamilyName)) { return }
    try {
        $deprovKey = Join-Path $AppxDeprovisionedRoot $FamilyName
        if (-not (Test-Path -LiteralPath $deprovKey)) {
            New-Item -Path $deprovKey -Force -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {}
}

function Remove-AppxStoreKey {
    param([string]$Category, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $key = $null
    try {
        $key = Join-Path (Join-Path $AppxStoreRoot $Category) $Name
        if (-not (Test-Path -LiteralPath $key)) { return }
        Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $key)) { return }
        # Some AppxAllUserStore keys are ACL-protected against the PowerShell
        # provider. reg.exe can still remove them when running as TrustedInstaller.
        $regPath = ([string]$key).Replace('HKLM:', 'HKLM')
        & reg.exe delete $regPath /f 2>&1 | Out-Null
    } catch {}
    if ($key -and (Test-Path -LiteralPath $key)) {
        Write-AppLog ("Store key still present: {0}" -f $key)
    }
}

function Remove-RegistryKeyTree {
    param($Key)
    if (-not $Key) { return }
    $regPath = ([string]$Key.Name).Replace('HKEY_LOCAL_MACHINE', 'HKLM')
    try { Remove-Item -LiteralPath $Key.PSPath -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    if (Test-Path -LiteralPath $Key.PSPath) {
        try { & reg.exe delete $regPath /f 2>&1 | Out-Null } catch {}
    }
    if (Test-Path -LiteralPath $Key.PSPath) {
        Write-AppLog ("Residue key still present: {0}" -f $regPath)
    } else {
        Write-AppLog ("Removed residue key {0}" -f $regPath)
    }
}

function Block-PackageReinstall {
    param([string]$FamilyName, [string[]]$FullNames)

    Ensure-DeprovisionMarker -FamilyName $FamilyName

    # InboxApplications is what Windows uses to stage inbox apps again. Removing
    # the key here is what stops a removed app from returning with a feature
    # update or a new user profile.
    foreach ($fullName in @($FullNames)) {
        Remove-AppxStoreKey -Category 'InboxApplications' -Name $fullName
    }
    Remove-AppxStoreKey -Category 'InboxApplications' -Name $FamilyName
}

function Remove-ProvisionedPackageRecord {
    param($Record)

    $fullName = [string]$Record.PackageName
    if ([string]::IsNullOrWhiteSpace($fullName)) { return $false }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $fullName -ErrorAction Stop | Out-Null
            Remove-AppxStoreKey -Category 'InboxApplications' -Name $fullName
            # Applications\<fullname> is state for the installed package and is
            # removed together with the residue after the family is really gone.
            Write-AppLog ("Removed provisioned package {0}" -f $fullName)
            return $true
        } catch {
            Write-AppLog ("Provisioned removal failed (attempt {0}/2) for {1}: {2}" -f $attempt, $fullName, $_.Exception.Message)
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
    return $false
}

function Invoke-AppxRemoval {
    param(
        [string]$FullName,
        [string]$Scope
    )

    $params = @{ Package = $FullName; ErrorAction = 'Stop' }
    if ($Scope -eq 'AllUsers') {
        $params['AllUsers'] = $true
    } elseif ($Scope) {
        # Remove-AppxPackage only accepts SIDs for -User; preserve switches
        # belong to the current-user parameter sets and cannot be combined.
        $params['User'] = $Scope
    }

    Remove-AppxPackage @params
}

function Remove-InstalledRecord {
    param(
        $PackageRecord,
        [string]$Scope
    )

    $fullName = [string]$PackageRecord.PackageFullName
    if ([string]::IsNullOrWhiteSpace($fullName)) { return $false }

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Invoke-AppxRemoval -FullName $fullName -Scope $Scope
            Write-AppLog ("Removed {0} for {1}" -f $fullName, $Scope)
            return $true
        } catch {
            Write-AppLog ("Remove failed (attempt {0}/2) for {1} ({2}): {3}" -f $attempt, $fullName, $Scope, $_.Exception.Message)
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
    return $false
}

function Remove-PathForced {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $true }

    # Most folders are owned by the user and delete on the first attempt.
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        return $true
    } catch {}

    # icacls accepts well-known SIDs, so this works on every UI language.
    # takeown /D expects a localized answer ('Y' on English, 'J' on German)
    # and fails before doing anything when the answer does not match.
    # Restore inherited permissions first. This also removes explicit ACEs that
    # can block deletion of a package folder stuck mid-uninstall.
    try { & icacls.exe $Path /reset /T /C /Q 2>&1 | Out-Null } catch {}

    $currentSid = $null
    try { $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch {}
    if ($currentSid) {
        # Grant before the ownership change: if this process is not elevated,
        # the filtered Administrators group cannot use its new ACE, but the
        # current user keeps full control and can still delete the folder.
        try { & icacls.exe $Path /grant ('*' + $currentSid + ':(OI)(CI)F') /T /C /Q 2>&1 | Out-Null } catch {}
    }
    try { & icacls.exe $Path /setowner '*S-1-5-32-544' /T /C /Q 2>&1 | Out-Null } catch {}
    try { & icacls.exe $Path /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null } catch {}

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    } catch {
        Write-AppLog ("Forced delete failed for {0}: {1}" -f $Path, $_.Exception.Message)
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Remove-PackageData {
    param([string]$FamilyName)

    if (-not (Test-PackageIdentifier $FamilyName)) { return }

    $profiles = New-Object System.Collections.ArrayList
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    try {
        Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -notin @('Public', 'Default', 'Default User', 'All Users', 'WDAGUtilityAccount')) {
                [void]$profiles.Add($_.FullName)
            }
        }
    } catch {}
    # ProfileList also covers profiles whose folder was moved off C:\Users.
    try {
        Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^S-1-5-21-' } |
            ForEach-Object {
                $imagePath = [string](Get-ItemProperty -LiteralPath $_.PSPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
                if (-not [string]::IsNullOrWhiteSpace($imagePath)) { [void]$profiles.Add($imagePath) }
            }
    } catch {}
    [void]$profiles.Add((Join-Path $usersRoot 'Default'))
    if ($env:USERPROFILE) { [void]$profiles.Add($env:USERPROFILE) }

    $seen = @{}
    foreach ($profilePath in @($profiles)) {
        if ([string]::IsNullOrWhiteSpace($profilePath)) { continue }
        $profileKey = $profilePath.ToLowerInvariant()
        if ($seen.ContainsKey($profileKey)) { continue }
        $seen[$profileKey] = $true

        $targets = @(
            (Join-Path $profilePath ('AppData\Local\Packages\' + $FamilyName)),
            (Join-Path $profilePath ('AppData\Local\Microsoft\Windows\Application Shortcuts\' + $FamilyName))
        )
        foreach ($dir in $targets) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            if (Remove-PathForced -Path $dir) {
                $script:PurgedDataCount++
                Write-AppLog ("Purged app data {0}" -f $dir)
            } else {
                Write-AppLog ("App data still present: {0}" -f $dir)
            }
        }
    }
}

function Remove-PackageResidue {
    param(
        [string]$FamilyName,
        [string[]]$FullNames
    )

    if (-not (Test-PackageIdentifier $FamilyName)) { return }

    # Remove the exact staging keys for the recorded full names first.
    foreach ($fullName in @($FullNames)) {
        if ([string]::IsNullOrWhiteSpace($fullName)) { continue }
        foreach ($category in @('Applications', 'InboxApplications', 'EndOfLife')) {
            Remove-AppxStoreKey -Category $category -Name $fullName
        }
    }

    $packageRoots = @()
    if ($env:ProgramW6432) { $packageRoots += (Join-Path $env:ProgramW6432 'WindowsApps') }
    if ($env:ProgramFiles) { $packageRoots += (Join-Path $env:ProgramFiles 'WindowsApps') }
    $packageRoots += (Join-Path $env:ProgramData 'Microsoft\Windows\AppRepository\Packages')
    $packageRoots = @($packageRoots | Select-Object -Unique)

    foreach ($root in $packageRoots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
            Test-PackageNameMatchesFamily -Name ([string]$_.Name) -Family $FamilyName
        } | ForEach-Object {
            $dir = $_.FullName
            if (Remove-PathForced -Path $dir) {
                Write-AppLog ("Removed residue folder {0}" -f $dir)
            } else {
                Write-AppLog ("Residue folder still present: {0}" -f $dir)
            }
        }
    }

    $registryBases = @(
        (Join-Path $AppxStoreRoot 'Applications'),
        (Join-Path $AppxStoreRoot 'InboxApplications'),
        (Join-Path $AppxStoreRoot 'EndOfLife'),
        (Join-Path $AppxStoreRoot 'Staged'),
        (Join-Path $AppxStoreRoot 'Config'),
        (Join-Path $AppxStoreRoot 'UpdatedApplications'),
        (Join-Path $AppxStoreRoot 'Deleted\EndOfLife'),
        (Join-Path $AppxStoreRoot 'Deleted\Upgrade'),
        (Join-Path $AppxStoreRoot 'DeferredRemoval'),
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateChange\PackageList',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData',
        'HKLM:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages',
        'HKLM:\SOFTWARE\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData',
        'HKLM:\SOFTWARE\Classes\ActivatableClasses\Package'
    )
    # Deleted/Upgrade/DeferredRemoval group their package entries by user SID.
    foreach ($container in @('Deleted\EndOfLife', 'Deleted\Upgrade', 'DeferredRemoval')) {
        $parent = Join-Path $AppxStoreRoot $container
        if (-not (Test-Path -LiteralPath $parent)) { continue }
        Get-ChildItem -LiteralPath $parent -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^S-1-[0-9]+-[0-9-]+$' } |
            ForEach-Object { $registryBases += [string]$_.PSPath }
    }
    # Per-user package state lives under AppxAllUserStore\S-1-*. It normally
    # disappears with Remove-AppxPackage, but a failed unregister can leave it.
    $registryBases += @(Get-ChildItem -LiteralPath $AppxStoreRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-1-[0-9]+-[0-9-]+$' } |
        ForEach-Object { [string]$_.PSPath })

    foreach ($base in $registryBases) {
        if (-not $base -or -not (Test-Path -LiteralPath $base)) { continue }
        Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object {
            Test-PackageNameMatchesFamily -Name ([string]$_.PSChildName) -Family $FamilyName
        } | ForEach-Object {
            Remove-RegistryKeyTree -Key $_
        }
    }

    # Per-user AppModel state also lives in the loaded user hives. Repository
    # keys use full package names, SystemAppData keys the family name; both are
    # matched by publisher-exact family, so a same-named app stays.
    try {
        Get-ChildItem -LiteralPath $AppModelUserRoot -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^S-1-5-21-' -and $_.PSChildName -notmatch '_Classes$' } |
            ForEach-Object {
                $appModel = $AppModelUserRoot + '\' + $_.PSChildName + '\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel'
                foreach ($leaf in @('SystemAppData', 'Repository\Packages', 'StateChange\PackageList')) {
                    $base = $appModel + '\' + $leaf
                    Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue | Where-Object {
                        Test-PackageNameMatchesFamily -Name ([string]$_.PSChildName) -Family $FamilyName
                    } | ForEach-Object {
                        Remove-RegistryKeyTree -Key $_
                    }
                }
            }
    } catch {}
}

function Remove-PackageFamily {
    param(
        $Entry,
        [bool]$KeepProvisioned
    )

    $family = [string]$Entry.Family
    if (-not (Test-PackageIdentifier $family)) { return }

    $installed = @($Entry.Installed)
    $provisioned = @($Entry.Provisioned)
    $fullNames = @($installed | ForEach-Object { [string]$_.PackageFullName } | Where-Object { $_ } | Sort-Object -Unique)

    Write-AppLog ("Processing {0}: {1} installed, {2} provisioned" -f $family, $installed.Count, $provisioned.Count)
    if (-not $KeepProvisioned) {
        Block-PackageReinstall -FamilyName $family -FullNames $fullNames
    }

    $installRoots = @()
    foreach ($pkg in $installed) {
        try { if ($pkg.InstallLocation) { $installRoots += [string]$pkg.InstallLocation } } catch {}
    }
    Stop-PackageProcesses -InstallRoots $installRoots
    Start-Sleep -Milliseconds 250

    if (-not $KeepProvisioned) {
        foreach ($pkg in $installed) {
            Clear-NonRemovableFlag -PackageRecord $pkg
        }
    }

    foreach ($pkg in $installed) {
        $pkgSids = @(Get-PackageUserSids -PackageRecord $pkg)
        $allSidsRemoved = $true
        foreach ($sid in $pkgSids) {
            if (-not (Remove-InstalledRecord -PackageRecord $pkg -Scope $sid)) { $allSidsRemoved = $false }
        }
        # -AllUsers is the fallback when the user list is unavailable or one
        # per-user removal failed. Avoid a redundant second pass otherwise.
        if (-not $allSidsRemoved -or $pkgSids.Count -eq 0) {
            [void](Remove-InstalledRecord -PackageRecord $pkg -Scope 'AllUsers')
        }
    }

    if (-not $KeepProvisioned) {
        foreach ($prov in $provisioned) {
            [void](Remove-ProvisionedPackageRecord -Record $prov)
        }
    }
}

function Invoke-PackageRemoval {
    param(
        [string[]]$Patterns,
        [bool]$KeepProvisioned,
        [bool]$PurgeResidue,
        [bool]$PurgeData
    )

    $families = @{}

    # Two rounds: the first uses the pre-removal snapshot, the second catches
    # packages that were locked or had their files held open during round one.
    for ($round = 1; $round -le 2; $round++) {
        $work = Get-MatchedWork -Patterns $Patterns -IncludeProvisioned (-not $KeepProvisioned)
        if ($work.Count -eq 0) { break }

        $label = 'families'
        if ($work.Count -eq 1) { $label = 'family' }
        Write-AppLog ("Round {0}: {1} package {2} matched" -f $round, $work.Count, $label)
        foreach ($family in @($work.Keys)) {
            $families[$family] = $work[$family]
            Remove-PackageFamily -Entry $work[$family] -KeepProvisioned $KeepProvisioned
        }
        Start-Sleep -Milliseconds 500
    }

    $installedFamilies = @((Get-InstalledPackages) | ForEach-Object { [string]$_.PackageFamilyName } | Where-Object { $_ } | Sort-Object -Unique)
    $provisionedResult = Get-ProvisionedPackagesResult
    $provisionedFamilies = @($provisionedResult.Packages | ForEach-Object { Get-FamilyNameFromPackageName ([string]$_.PackageName) } | Where-Object { $_ } | Sort-Object -Unique)
    $provisionedQueryOk = [bool]$provisionedResult.Success

    # A failed AppX query would make every family look removed and the residue
    # pass could delete folders of packages that are still installed.
    if ($families.Count -gt 0 -and $installedFamilies.Count -eq 0) {
        Write-AppLog 'ABORT cleanup: post-removal Get-AppxPackage returned no packages'
        return
    }

    # A failed DISM query would hide a provisioned copy that is still staged;
    # removing its folder then would leave a broken provisioned package behind.
    if (-not $KeepProvisioned -and -not $provisionedQueryOk) {
        Write-AppLog 'ABORT cleanup: post-removal Get-AppxProvisionedPackage failed'
        return
    }
    $hadProvisionedTargets = $false
    foreach ($entry in $families.Values) {
        if (@($entry.Provisioned).Count -gt 0) { $hadProvisionedTargets = $true; break }
    }
    if (-not $KeepProvisioned -and $hadProvisionedTargets -and $provisionedFamilies.Count -eq 0) {
        Write-AppLog 'ABORT cleanup: Get-AppxProvisionedPackage returned no packages while provisioned targets existed'
        return
    }

    foreach ($family in @($families.Keys)) {
        if ($installedFamilies -contains $family) {
            if (-not $KeepProvisioned) {
                $script:FailedCount++
                Write-AppLog ("STILL INSTALLED after removal: {0}" -f $family)
            }
            continue
        }
        if (-not $KeepProvisioned -and ($provisionedFamilies -contains $family)) {
            $script:FailedCount++
            Write-AppLog ("STILL PROVISIONED after removal: {0}" -f $family)
            continue
        }

        # Unregister-only mode keeps the provisioned copy and must not mark the
        # family as deprovisioned, otherwise reinstalling for new users breaks.
        if ($KeepProvisioned) { continue }

        $entry = $families[$family]
        $fullNames = @()
        $fullNames += @($entry.Installed | ForEach-Object { [string]$_.PackageFullName })
        $fullNames += @($entry.Provisioned | ForEach-Object { [string]$_.PackageName })
        $fullNames = @($fullNames | Where-Object { $_ } | Sort-Object -Unique)

        Ensure-DeprovisionMarker -FamilyName $family
        if ($PurgeResidue) { Remove-PackageResidue -FamilyName $family -FullNames $fullNames }
        if ($PurgeData) { Remove-PackageData -FamilyName $family }
    }

    Write-AppLog ("Summary: {0} families processed, {1} failures, {2} app-data folders purged" -f $families.Count, $script:FailedCount, $script:PurgedDataCount)
}

function Invoke-PurgeRemoved {
    param(
        [string]$Path,
        [bool]$KeepData
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        Write-AppLog ("PurgeRemoved: snapshot not found: {0}" -f $Path)
        return
    }

    # Snapshot lines are 'I:<family>' for installed and 'P:<family>' for
    # provisioned families. Older snapshots have no prefix and count as
    # installed; comment lines record a failed query.
    $beforeInstalled = New-Object System.Collections.ArrayList
    $beforeProvisioned = New-Object System.Collections.ArrayList
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $value = ([string]$line).Trim()
        if (-not $value -or $value.StartsWith('#')) { continue }

        $scope = 'I'
        $family = $value
        if ($value -match '^([IPip]):(.*)$') {
            $scope = $Matches[1].ToUpperInvariant()
            $family = $Matches[2].Trim()
        }
        if (-not (Test-PackageIdentifier $family)) { continue }

        if ($scope -eq 'P') { [void]$beforeProvisioned.Add($family) }
        else { [void]$beforeInstalled.Add($family) }
    }
    $beforeInstalled = @($beforeInstalled | Sort-Object -Unique)
    $beforeProvisioned = @($beforeProvisioned | Sort-Object -Unique)
    if ($beforeInstalled.Count -eq 0 -and $beforeProvisioned.Count -eq 0) {
        Write-AppLog 'PurgeRemoved: snapshot is empty, nothing to do'
        return
    }

    $current = @(Get-InstalledPackages)
    if ($current.Count -eq 0) {
        # A failed AppX query would otherwise make every family look removed and
        # the residue pass could delete still-installed packages.
        Write-AppLog 'PurgeRemoved: ABORT - current Get-AppxPackage returned no packages'
        return
    }

    $provisionedResult = Get-ProvisionedPackagesResult
    $currentProvisioned = @($provisionedResult.Packages)
    $provisionedQueryOk = [bool]$provisionedResult.Success
    # An empty result is treated as unverified: it is either a failed query or a
    # legitimate "everything staged is gone". Without a second source we cannot
    # tell, so staged-only families must never be counted as removed from it.
    $provisionedTrusted = $provisionedQueryOk -and ($currentProvisioned.Count -gt 0)
    if (-not $provisionedQueryOk) {
        Write-AppLog 'PurgeRemoved: WARNING - provisioned package query failed; staged-only families are left alone'
    } elseif (-not $provisionedTrusted) {
        Write-AppLog 'PurgeRemoved: WARNING - provisioned package query returned no packages; staged-only families are left alone'
    }

    $afterInstalled = @($current | ForEach-Object { [string]$_.PackageFamilyName } | Where-Object { $_ } | Sort-Object -Unique)
    $afterProvisioned = @($currentProvisioned | ForEach-Object { Get-FamilyNameFromPackageName ([string]$_.PackageName) } | Where-Object { $_ } | Sort-Object -Unique)

    $removedInstalled = @($beforeInstalled | Where-Object { $afterInstalled -notcontains $_ })
    $removedProvisioned = @()
    if ($provisionedTrusted) {
        $removedProvisioned = @($beforeProvisioned | Where-Object { $afterProvisioned -notcontains $_ })
    }
    $removedFamilies = @(@($removedInstalled) + @($removedProvisioned) |
        Where-Object { $_ } | Sort-Object -Unique)
    Write-AppLog ("PurgeRemoved: {0} installed and {1} staged-only families vanished during apply" -f $removedInstalled.Count, $removedProvisioned.Count)
    if ($removedFamilies.Count -eq 0) { return }

    # Drop the staged/provisioned copies of everything that disappeared. This is
    # the gap that used to bring apps back for new users and after updates.
    foreach ($prov in $currentProvisioned) {
        $family = Get-FamilyNameFromPackageName ([string]$prov.PackageName)
        if (-not $family) { continue }
        if ($removedFamilies -contains $family) {
            [void](Remove-ProvisionedPackageRecord -Record $prov)
        }
    }

    # Belt and braces: every Deprovisioned marker must not have a provisioned
    # package behind it, even for apps that were not installed in this image.
    $markers = @()
    try {
        $markers = @(Get-ChildItem -LiteralPath $AppxDeprovisionedRoot -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.PSChildName })
    } catch {}
    if ($markers.Count -gt 0) {
        $markerResult = Get-ProvisionedPackagesResult
        if (-not [bool]$markerResult.Success) {
            Write-AppLog 'PurgeRemoved: WARNING - provisioned query failed, deprovision markers left untouched'
        } else {
            foreach ($prov in @($markerResult.Packages)) {
                $family = Get-FamilyNameFromPackageName ([string]$prov.PackageName)
                if (-not $family) { continue }
                if (($markers -contains $family) -and ($removedFamilies -notcontains $family)) {
                    [void](Remove-ProvisionedPackageRecord -Record $prov)
                }
            }
        }
    }

    $installedAfter = @(Get-InstalledPackages)
    if ($installedAfter.Count -eq 0) {
        Write-AppLog 'PurgeRemoved: ABORT residue - post-removal Get-AppxPackage returned no packages'
        return
    }
    $installedFamilies = @($installedAfter | ForEach-Object { [string]$_.PackageFamilyName } | Where-Object { $_ } | Sort-Object -Unique)

    $provisionedAfterResult = Get-ProvisionedPackagesResult
    $provisionedAfter = @($provisionedAfterResult.Packages)
    $provisionedAfterOk = [bool]$provisionedAfterResult.Success
    $provisionedFamilies = @($provisionedAfter | ForEach-Object { Get-FamilyNameFromPackageName ([string]$_.PackageName) } | Where-Object { $_ } | Sort-Object -Unique)

    $cleanedCount = 0
    foreach ($family in $removedFamilies) {
        if (-not (Test-PackageIdentifier $family)) { continue }

        if ($installedFamilies -contains $family) {
            Write-AppLog ("PurgeRemoved: still installed, skipping residue: {0}" -f $family)
            continue
        }
        if (-not $provisionedAfterOk) {
            Write-AppLog ("PurgeRemoved: provisioned state unverified, skipping residue: {0}" -f $family)
            continue
        }
        if (($beforeProvisioned -contains $family) -and ($provisionedAfter.Count -eq 0)) {
            # The snapshot saw a staged copy, but the follow-up query is empty.
            # Do not treat that as proof that the staged copy is gone.
            Write-AppLog ("PurgeRemoved: staged state unverified, skipping residue: {0}" -f $family)
            continue
        }
        if ($provisionedFamilies -contains $family) {
            Write-AppLog ("PurgeRemoved: still provisioned, skipping residue: {0}" -f $family)
            continue
        }

        Ensure-DeprovisionMarker -FamilyName $family
        Remove-PackageResidue -FamilyName $family -FullNames @()
        if (-not $KeepData) { Remove-PackageData -FamilyName $family }
        $cleanedCount++
    }

    Write-AppLog ("PurgeRemoved summary: {0} families processed, {1} cleaned, {2} app-data folders purged" -f $removedFamilies.Count, $cleanedCount, $script:PurgedDataCount)
}

if ($PSCmdlet.ParameterSetName -eq 'PurgeRemoved') {
    Invoke-PurgeRemoved -Path $SnapshotFile -KeepData ([bool]$KeepUserData)
} else {
    $keepProvisioned = $false
    if ($PSCmdlet.ParameterSetName -eq 'Bloatware') {
        $patterns = @($script:BloatwarePatterns) + @($AdditionalPackages)
    } else {
        $patterns = @($Packages)
        $keepProvisioned = [bool]$Unregister
    }
    $patterns = @($patterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($patterns.Count -eq 0) {
        Write-AppLog 'No package patterns supplied'
    } else {
        $purgeResidue = -not $keepProvisioned
        $purgeData = (-not $keepProvisioned) -and (-not [bool]$KeepUserData)
        Invoke-PackageRemoval -Patterns $patterns -KeepProvisioned $keepProvisioned -PurgeResidue $purgeResidue -PurgeData $purgeData
    }
}

$global:LASTEXITCODE = 0
