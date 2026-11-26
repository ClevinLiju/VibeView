<#
.SYNOPSIS
    Loads the Visual Studio x64 developer environment (MSVC link.exe, LIB, INCLUDE, Windows SDK) into the
    current PowerShell session, if it is not loaded already.

.DESCRIPTION
    Swift on Windows (SwiftPM in 6.4) looks for the MSVC `link` tool on PATH, so `swift build` fails with
    "toolchain is invalid: could not find CLI tool `link`" in a plain terminal. Dot-source this script
    (build.ps1 and stage-engine.ps1 do it for you) or use a "Developer PowerShell for VS 2022" window.

    -ExportGitHubEnv writes every variable that changed to $env:GITHUB_ENV, so later GitHub Actions
    steps inherit the environment.

.EXAMPLE
    . scripts\windows\vsdevenv.ps1
#>
[CmdletBinding()]
param([switch]$ExportGitHubEnv, [switch]$Force)

function Test-MsvcLinkOnPath {
    # Git for Windows ships a GNU `link.exe` in usr\bin, which is not what Swift wants.
    $l = Get-Command link.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -match '\\VC\\Tools\\MSVC\\' } | Select-Object -First 1
    return [bool]$l
}

# The Swift installer sets SDKROOT (and PATH) for the user. A terminal opened before the install does not
# see them, and swift then fails with "unable to load standard library for target ...".
if (-not $env:SDKROOT) {
    $sdk = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
    if (-not $sdk) { $sdk = [Environment]::GetEnvironmentVariable('SDKROOT', 'Machine') }
    if ($sdk) { $env:SDKROOT = $sdk; Write-Verbose "SDKROOT=$sdk (from the registry)" }
}
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') + ';' + $env:Path
}

if ((Test-MsvcLinkOnPath) -and $env:VSINSTALLDIR -and -not $Force) {
    Write-Verbose 'Visual Studio developer environment already loaded'
} else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsPath = $null
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
    }
    if (-not $vsPath) {
        throw 'Visual Studio (Build Tools) with the C++ x64 tools was not found. Run scripts\windows\install-prereqs.ps1.'
    }
    $before = @{}
    if ($ExportGitHubEnv) { Get-ChildItem env: | ForEach-Object { $before[$_.Name] = $_.Value } }

    # VsDevCmd.bat runs vswhere.exe by name; without the Installer folder on PATH it prints
    # '"vswhere.exe" is not recognized ...' on stderr (harmless, but it looks like a failure).
    $installerDir = Split-Path $vswhere
    if (($env:Path -split ';') -notcontains $installerDir) { $env:Path = "$env:Path;$installerDir" }

    $devShell = Join-Path $vsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
    if (Test-Path $devShell) {
        Import-Module $devShell
        Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64 -no_logo' | Out-Null
    } else {
        # Older installs: run vcvars64.bat and import its environment.
        $vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
        if (-not (Test-Path $vcvars)) { throw "Neither DevShell nor vcvars64.bat found under $vsPath" }
        cmd /c "`"$vcvars`" >nul && set" | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
        }
    }
    if (-not (Test-MsvcLinkOnPath)) { throw "Loaded the VS environment from $vsPath, but MSVC link.exe is still not on PATH" }
    Write-Verbose "Visual Studio developer environment loaded from $vsPath"

    if ($ExportGitHubEnv -and $env:GITHUB_ENV) {
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($v in (Get-ChildItem env:)) {
            if (-not $before.ContainsKey($v.Name) -or $before[$v.Name] -ne $v.Value) { $lines.Add("$($v.Name)=$($v.Value)") }
        }
        [IO.File]::AppendAllText($env:GITHUB_ENV, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "exported $($lines.Count) variables to GITHUB_ENV"
    }
}
