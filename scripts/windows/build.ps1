<#
.SYNOPSIS
    End-to-end Windows build: engine + Electron front end + NSIS installer.

.DESCRIPTION
    1. Checks prerequisites (Swift, Visual Studio C++ tools + Windows SDK, Node.js/npm) with friendly errors.
    2. Runs stage-engine.ps1 (swift build -c release, stage vibeview-engine.exe + runtime DLLs into windows\engine\).
    3. npm ci (npm install when there is no package-lock.json) and npm run dist in windows\.
    4. Prints the installer path (windows\dist\VibeView-Setup-<version>.exe).

    Install missing prerequisites with scripts\windows\install-prereqs.ps1.

.PARAMETER Version
    Overrides the app version stamped into the installer (default: windows\package.json). CI passes the tag.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\windows\build.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('release', 'debug')]
    [string]$Configuration = 'release',
    [string]$ScratchPath = '.build-win',
    [string]$Version = '',
    [switch]$SkipEngine,
    [switch]$SkipNpmInstall
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$WinDir = Join-Path $RepoRoot 'windows'

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Stop-WithError([string]$msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

# --- Prerequisites ------------------------------------------------------------------------------
Write-Step 'Checking prerequisites'
$problems = New-Object System.Collections.Generic.List[string]

# Picks up SDKROOT/PATH from a just-finished Swift install and loads the VS x64 developer environment.
try { . (Join-Path $PSScriptRoot 'vsdevenv.ps1') } catch { Write-Host "    note: $($_.Exception.Message)" -ForegroundColor Yellow }

# Swift, Visual Studio and the Windows SDK are needed only to build the engine (not with -SkipEngine).
$swift = Get-Command swift -ErrorAction SilentlyContinue
if ($SkipEngine) {
    Write-Host '    -SkipEngine: reusing windows\engine\ (Swift and Visual Studio not required)'
} elseif (-not $swift) {
    $problems.Add('Swift toolchain not found on PATH. Install it with: winget install --id Swift.Toolchain -e   (then open a new terminal)')
} else {
    $sv = (& swift --version 2>$null | Select-Object -First 1)
    Write-Host "    swift: $sv"
    if ($sv -match 'version (\d+)\.' -and [int]$Matches[1] -lt 6) { $problems.Add("Swift 6 or later is required (found: $sv)") }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = $null
if (Test-Path $vswhere) { $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1 }
if ($SkipEngine) {
} elseif (-not $vs) {
    $problems.Add('Visual Studio (Build Tools) with the "Desktop development with C++" workload was not found. Swift on Windows needs its linker and the Windows SDK. See scripts\windows\install-prereqs.ps1.')
} else {
    Write-Host "    Visual Studio: $vs"
}
$sdkRoot = 'C:\Program Files (x86)\Windows Kits\10\Lib'
if (-not $SkipEngine -and (-not (Test-Path $sdkRoot) -or -not (Get-ChildItem $sdkRoot -Directory -Filter '10.*' -ErrorAction SilentlyContinue))) {
    $problems.Add('Windows 10/11 SDK not found (C:\Program Files (x86)\Windows Kits\10). Add the Windows SDK component in the Visual Studio Installer.')
}

$node = Get-Command node -ErrorAction SilentlyContinue
$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $node -or -not $npm) {
    $problems.Add('Node.js (with npm) not found. Install the LTS release with: winget install --id OpenJS.NodeJS.LTS -e')
} else {
    $nv = (& node --version)
    Write-Host "    node: $nv"
    if ($nv -match '^v(\d+)\.' -and [int]$Matches[1] -lt 18) { $problems.Add("Node.js 18 or later is required (found $nv)") }
}
if (-not (Test-Path (Join-Path $WinDir 'package.json'))) { $problems.Add("windows\package.json is missing; is this a full checkout?") }

if ($problems.Count -gt 0) {
    Write-Host ''
    Write-Host 'Missing prerequisites:' -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Run  powershell -ExecutionPolicy Bypass -File scripts\windows\install-prereqs.ps1  and open a new terminal.'
    exit 1
}

# --- Engine -------------------------------------------------------------------------------------
if (-not $SkipEngine) {
    Write-Step 'Staging the engine'
    & (Join-Path $PSScriptRoot 'stage-engine.ps1') -Configuration $Configuration -ScratchPath $ScratchPath
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'stage-engine.ps1 failed' }
} elseif (-not (Test-Path (Join-Path $WinDir 'engine\vibeview-engine.exe'))) {
    Stop-WithError 'windows\engine\vibeview-engine.exe is missing; run without -SkipEngine'
}

# --- Front end + installer ----------------------------------------------------------------------
Push-Location $WinDir
try {
    if (-not $SkipNpmInstall) {
        # npm ci deletes node_modules first. If a dev copy of Electron from it is running, the delete stops
        # half-way (EBUSY) and leaves node_modules broken for that session too, so refuse up front.
        $nm = (Join-Path $WinDir 'node_modules').ToLowerInvariant()
        $busy = @(Get-Process electron -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.ToLowerInvariant().StartsWith($nm) })
        if ($busy.Count -gt 0) {
            Stop-WithError ("Electron from windows\node_modules is running (pid $(($busy | ForEach-Object Id) -join ', ')). " +
                'Close it (npm run dev / smoke tests) or pass -SkipNpmInstall.')
        }
        if (Test-Path 'package-lock.json') {
            Write-Step 'npm ci'
            & npm ci
        } else {
            Write-Host 'warning: windows\package-lock.json is missing; using npm install (not reproducible)' -ForegroundColor Yellow
            Write-Step 'npm install'
            & npm install
        }
        if ($LASTEXITCODE -ne 0) { Stop-WithError "npm install failed (exit $LASTEXITCODE)" }
    }
    # electron-builder needs winCodeSign (rcedit, to stamp the icon and version into VibeView.exe). Its
    # archive holds two macOS symlinks, and 7-Zip can't create symlinks without Developer Mode or admin
    # rights, so electron-builder's own extraction fails on a normal account. Pre-extract it here,
    # ignoring only those symlink errors; electron-builder then finds the folder and skips the download.
    $wcsVersion = 'winCodeSign-2.6.0'   # matches electron-builder 25.x
    $wcsDir = Join-Path $env:LOCALAPPDATA "electron-builder\Cache\winCodeSign\$wcsVersion"
    if ($env:ELECTRON_BUILDER_CACHE) { $wcsDir = Join-Path $env:ELECTRON_BUILDER_CACHE "winCodeSign\$wcsVersion" }
    if (-not (Test-Path (Join-Path $wcsDir 'rcedit-x64.exe'))) {
        Write-Step "Preparing $wcsVersion"
        $sevenZip = Join-Path $WinDir 'node_modules\7zip-bin\win\x64\7za.exe'
        if (-not (Test-Path $sevenZip)) { Stop-WithError "$sevenZip is missing; run without -SkipNpmInstall" }
        $archive = Join-Path $env:TEMP "$wcsVersion.7z"
        $url = "https://github.com/electron-userland/electron-builder-binaries/releases/download/$wcsVersion/$wcsVersion.7z"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
        } catch { Stop-WithError "could not download $url ($($_.Exception.Message))" }
        $tmp = "$wcsDir.tmp"
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # 7za writes the symlink errors to stderr
        try { $out = & $sevenZip x -bd -y $archive "-o$tmp" 2>&1 | Out-String } finally { $ErrorActionPreference = $eap }
        $realErrors = @($out -split "`r?`n" | Where-Object { $_ -match '^ERROR:' -and $_ -notmatch 'symbolic link' })
        if (-not (Test-Path (Join-Path $tmp 'rcedit-x64.exe')) -or $realErrors.Count -gt 0) {
            Stop-WithError "extracting $wcsVersion failed:`n$out"
        }
        if (Test-Path $wcsDir) { Remove-Item $wcsDir -Recurse -Force }
        Move-Item $tmp $wcsDir
        Remove-Item $archive -Force -ErrorAction SilentlyContinue
        Write-Host "    $wcsDir"
    }

    Write-Step 'npm run dist'
    # Arguments after `--` go to electron-builder. Never let it publish on its own (CI attaches the
    # installer to the release itself).
    $distArgs = @('run', 'dist', '--', '--publish', 'never')
    if ($Version) {
        $Version = $Version.TrimStart('v')
        $distArgs += "-c.extraMetadata.version=$Version"
    }
    & npm @distArgs
    if ($LASTEXITCODE -ne 0) { Stop-WithError "npm run dist failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }

$setup = Get-ChildItem (Join-Path $WinDir 'dist') -Filter 'VibeView-Setup-*.exe' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $setup) { Stop-WithError 'electron-builder finished but no windows\dist\VibeView-Setup-*.exe was found' }
Write-Host ''
Write-Step 'Done'
Write-Host "    Installer: $($setup.FullName)" -ForegroundColor Green
Get-ChildItem (Join-Path $WinDir 'dist') -Filter 'VibeView-*.zip' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "    Portable zip: $($_.FullName)" }
