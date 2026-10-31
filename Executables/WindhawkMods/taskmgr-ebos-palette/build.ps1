<#
.SYNOPSIS
    Builds the taskmgr-ebos-palette Windhawk mod DLL.

.DESCRIPTION
    Windhawk normally compiles .wh.cpp sources itself, but this mod is shipped
    as a precompiled local mod so the playbook can install it with
    `whcli install-local` without a compiler on the target machine.

    The output name must match the mod version: 1.0_64.dll for `@version 1.0`.
    The DLL is linked with /MT so it does not depend on the Visual C++
    redistributable.

    After building, update $ExpectedTaskMgrPaletteSha256 in
    Executables/Install-WindhawkTransparentUI.ps1 with the printed hash.

.PARAMETER VsDevCmd
    Optional path to vcvars64.bat. Auto-detected from Visual Studio when omitted.

.PARAMETER WindhawkLib
    Optional path to the 64-bit windhawk.lib. Auto-detected from the installed
    WindhawkCLI engine when omitted.

.PARAMETER OutputPath
    Optional output DLL path. Defaults to 1.0_64.dll next to the source.

.PARAMETER SkipHashCheck
    Only prints the hash instead of failing when it differs from the hash the
    installer currently pins. Use after an intentional rebuild.
#>
[CmdletBinding()]
param(
    [string]$VsDevCmd,
    [string]$WindhawkLib,
    [string]$OutputPath,
    [switch]$SkipHashCheck
)

$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$source = Join-Path $here 'taskmgr-ebos-palette.wh.cpp'
$expectedSha256 = '8696480CE611DEB9A319DC801731D22844B6C4038539F254C986C07E9B33630A'

if (-not (Test-Path -LiteralPath $source)) {
    throw "Source not found: $source"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $here '1.0_64.dll'
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)

function Find-VsDevCmd {
    # Prefer the VS 2022 toolset: the shipped 1.0_64.dll was built with MSVC
    # 14.44, and a newer compiler produces a different binary (and SHA-256).
    foreach ($edition in @('Community', 'Professional', 'Enterprise', 'BuildTools')) {
        $candidate = Join-Path $env:ProgramFiles "Microsoft Visual Studio\2022\$edition\VC\Auxiliary\Build\vcvars64.bat"
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $installPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
        if ($installPath) {
            $candidate = Join-Path $installPath 'VC\Auxiliary\Build\vcvars64.bat'
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    foreach ($root in @(
        "${env:ProgramFiles}\Microsoft Visual Studio\18",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022"
    )) {
        foreach ($edition in @('Community', 'Professional', 'Enterprise', 'BuildTools')) {
            $candidate = Join-Path $root "$edition\VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path -LiteralPath $candidate) {
                return $candidate
            }
        }
    }

    return $null
}

function Find-WindhawkLib {
    $roots = @(
        (Join-Path $env:ProgramFiles 'WindhawkCLI\Engine'),
        'C:\ProgramData\WindhawkCLI\Engine'
    )
    $candidates = foreach ($root in $roots) {
        if (Test-Path -LiteralPath $root) {
            Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $lib = Join-Path $_.FullName '64\windhawk.lib'
                    if (Test-Path -LiteralPath $lib) {
                        [pscustomobject]@{ Version = $_.Name; Path = $lib }
                    }
                }
        }
    }

    $best = $candidates |
        Sort-Object -Property @{ Expression = { try { [version]$_.Version } catch { [version]'0.0' } } } -Descending |
        Select-Object -First 1
    if ($best) {
        return $best.Path
    }

    return $null
}

if (-not $VsDevCmd) {
    $VsDevCmd = Find-VsDevCmd
    if (-not $VsDevCmd) {
        throw 'vcvars64.bat was not found. Install the Visual Studio C++ build tools or pass -VsDevCmd.'
    }
}
if (-not (Test-Path -LiteralPath $VsDevCmd)) {
    throw "vcvars64.bat not found: $VsDevCmd"
}

if (-not $WindhawkLib) {
    $WindhawkLib = Find-WindhawkLib
    if (-not $WindhawkLib) {
        throw 'windhawk.lib was not found. Install WindhawkCLI or pass -WindhawkLib.'
    }
}
if (-not (Test-Path -LiteralPath $WindhawkLib)) {
    throw "windhawk.lib not found: $WindhawkLib"
}

$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$baseName = [IO.Path]::GetFileNameWithoutExtension($source)
$intermediates = @(
    (Join-Path $outputDir "$baseName.obj"),
    (Join-Path $outputDir "$baseName.exp"),
    (Join-Path $outputDir "$baseName.lib"),
    (Join-Path $outputDir "$baseName.pdb")
)
foreach ($file in $intermediates) {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

Write-Host "Compiler:    $VsDevCmd"
Write-Host "windhawk.lib: $WindhawkLib"
Write-Host "Source:      $source"
Write-Host "Output:      $OutputPath"

$compile = 'call "' + $VsDevCmd + '" >nul && cl /nologo /LD /MT /O2 /EHsc /DNDEBUG /Brepro ' +
    '/DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /D_WIN32_WINNT=0x0A00 ' +
    '"' + $source + '" ' +
    '/link /Brepro /MACHINE:X64 /OUT:"' + $OutputPath + '" ' +
    'user32.lib gdi32.lib "' + $WindhawkLib + '"'

Push-Location $outputDir
try {
    & cmd.exe /d /c $compile 2>&1 | ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($exitCode -ne 0) {
    throw "cl.exe failed with exit code $exitCode."
}

foreach ($file in $intermediates) {
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash
$length = (Get-Item -LiteralPath $OutputPath).Length
Write-Host ''
Write-Host "Built:  $OutputPath"
Write-Host "Size:   $length bytes"
Write-Host "SHA256: $hash"

if ($hash -ne $expectedSha256) {
    $message = "SHA-256 differs from the hash pinned in Install-WindhawkTransparentUI.ps1 ($expectedSha256)."
    if ($SkipHashCheck) {
        Write-Warning $message
    } else {
        throw "$message Re-run with -SkipHashCheck if this rebuild is intentional, then update the installer hash."
    }
} else {
    Write-Host 'SHA-256 matches the installer pin.'
}
