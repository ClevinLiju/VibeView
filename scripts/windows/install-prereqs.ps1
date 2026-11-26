<#
.SYNOPSIS
    Installs the Windows build prerequisites for VibeView with winget.

.DESCRIPTION
    - Visual Studio 2022 Build Tools with the C++ workload (MSVC, linker) and a Windows 11 SDK
      (Swift on Windows uses the MSVC linker, the UCRT and the Windows SDK headers/libs)
    - Swift toolchain (Swift.Toolchain)
    - Node.js LTS (OpenJS.NodeJS.LTS) for the Electron front end
    - Git (Git.Git)

    Already-installed packages are skipped. Use -DryRun to print the commands without running them.
    Open a new terminal afterwards so PATH picks up the new tools, then run scripts\windows\build.ps1.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\windows\install-prereqs.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$SkipVisualStudio,
    [switch]$SkipSwift,
    [switch]$SkipNode,
    [switch]$SkipGit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host 'error: winget was not found. Install "App Installer" from the Microsoft Store (or update Windows), then rerun.' -ForegroundColor Red
    exit 1
}

# VS Build Tools: the C++ workload plus the x64 MSVC tools and a Windows 11 SDK, installed without UI.
$vsOverride = '--wait --passive --norestart ' +
    '--add Microsoft.VisualStudio.Workload.VCTools ' +
    '--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 ' +
    '--add Microsoft.VisualStudio.Component.Windows11SDK.22621 ' +
    '--includeRecommended'

$packages = @()
if (-not $SkipVisualStudio) { $packages += , @('Microsoft.VisualStudio.2022.BuildTools', @('--override', $vsOverride)) }
if (-not $SkipSwift)        { $packages += , @('Swift.Toolchain', @()) }
if (-not $SkipNode)         { $packages += , @('OpenJS.NodeJS.LTS', @()) }
if (-not $SkipGit)          { $packages += , @('Git.Git', @()) }

$common = @('--exact', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
$failed = @()
foreach ($p in $packages) {
    $id = $p[0]; $extra = $p[1]
    $installed = $false
    if (-not $DryRun) {
        & winget list --id $id --exact --accept-source-agreements --disable-interactivity *> $null
        $installed = ($LASTEXITCODE -eq 0)
    }
    if ($installed) { Write-Step "$id is already installed; skipping"; continue }
    $argList = @('install', '--id', $id) + $common + $extra
    $shown = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    if ($DryRun) { Write-Host "winget $shown"; continue }
    Write-Step "winget $shown"
    & winget @argList
    # -1978335189 (0x8A15002B): no applicable upgrade / already installed.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
        Write-Host "warning: winget exited with $LASTEXITCODE for $id" -ForegroundColor Yellow
        $failed += $id
    }
}

if ($DryRun) { Write-Host ''; Write-Host '(dry run: nothing was installed)'; exit 0 }
Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "Some installs failed: $($failed -join ', '). Rerun this script, or install them by hand (see docs\WINDOWS.md)." -ForegroundColor Red
    exit 1
}
Write-Host 'Prerequisites installed. Open a NEW terminal (PATH changed), then run:' -ForegroundColor Green
Write-Host '    powershell -ExecutionPolicy Bypass -File scripts\windows\build.ps1'
