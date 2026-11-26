<#
.SYNOPSIS
    Builds vibeview-engine.exe and stages it, with every DLL it needs, into windows\engine\.

.DESCRIPTION
    1. swift build -c <Configuration> --product vibeview-engine --scratch-path <ScratchPath>
    2. Copies vibeview-engine.exe into windows\engine\ (electron-builder ships that folder as resources\engine\).
    3. Walks the PE import tables (regular + delay-load) of the exe and, recursively, of every DLL found
       in the Swift runtime directory, and copies that closure (swiftCore, Foundation*, _FoundationICU,
       swiftDispatch, dispatch, BlocksRuntime, swift_Concurrency, swiftCRT, swiftWinSDK, ...).
    4. Copies the MSVC C++ runtime DLLs the closure imports (vcruntime140*.dll, msvcp140*.dll) from the
       Visual Studio redist folder (app-local deployment), unless -NoMsvcRuntime is given.
    5. Runs `vibeview-engine.exe --version` and `--selftest` from the staged folder with PATH reduced to
       the Windows system directories, so a missing DLL shows up here and not on a user's machine.

    Works in Windows PowerShell 5.1 and PowerShell 7. Needs only the Swift toolchain (dumpbin is used
    as a cross-check when Visual Studio is found, but is not required).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\windows\stage-engine.ps1
.EXAMPLE
    scripts\windows\stage-engine.ps1 -Configuration debug -ScratchPath .build-dbg -SkipBuild
#>
[CmdletBinding()]
param(
    [ValidateSet('release', 'debug')]
    [string]$Configuration = 'release',
    [string]$ScratchPath = '.build-win',
    [string]$OutDir = '',
    [switch]$SkipBuild,
    [switch]$SkipVerify,
    [switch]$NoMsvcRuntime
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'windows\engine' }
if (-not [IO.Path]::IsPathRooted($ScratchPath)) { $ScratchPath = Join-Path $RepoRoot $ScratchPath }

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Stop-WithError([string]$msg) { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

# --- PE import reader ---------------------------------------------------------------------------
function Get-PEImports {
    <# Returns the DLL names a PE file imports (import table + delay-load table). #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $b = [IO.File]::ReadAllBytes($Path)
    if ($b.Length -lt 64 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { throw "$Path is not a PE file" }
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ([BitConverter]::ToUInt32($b, $pe) -ne 0x00004550) { throw "$Path has no PE signature" }
    $nSections = [BitConverter]::ToUInt16($b, $pe + 6)
    $optSize = [BitConverter]::ToUInt16($b, $pe + 20)
    $opt = $pe + 24
    $magic = [BitConverter]::ToUInt16($b, $opt)
    if ($magic -eq 0x20B) { $dirBase = $opt + 112 } elseif ($magic -eq 0x10B) { $dirBase = $opt + 96 } else { throw "$Path`: unknown optional header" }
    $secBase = $opt + $optSize
    $sections = @()
    for ($i = 0; $i -lt $nSections; $i++) {
        $s = $secBase + 40 * $i
        $sections += New-Object PSObject -Property @{
            VA = [BitConverter]::ToUInt32($b, $s + 12); VSize = [BitConverter]::ToUInt32($b, $s + 8)
            Raw = [BitConverter]::ToUInt32($b, $s + 20); RawSize = [BitConverter]::ToUInt32($b, $s + 16)
        }
    }
    $toOffset = {
        param([uint32]$rva)
        foreach ($s in $sections) {
            $size = [Math]::Max([uint32]$s.VSize, [uint32]$s.RawSize)
            if ($rva -ge $s.VA -and $rva -lt ($s.VA + $size)) { return [int]($rva - $s.VA + $s.Raw) }
        }
        return -1
    }
    $readName = {
        param([int]$off)
        $end = $off; while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
        return [Text.Encoding]::ASCII.GetString($b, $off, $end - $off)
    }
    $names = New-Object System.Collections.Generic.List[string]
    # Directory 1: import table (20-byte IMAGE_IMPORT_DESCRIPTORs, Name RVA at +12).
    $impRva = [BitConverter]::ToUInt32($b, $dirBase + 8)
    if ($impRva -ne 0) {
        $off = & $toOffset $impRva
        while ($off -ge 0 -and ($off + 20) -le $b.Length) {
            $nameRva = [BitConverter]::ToUInt32($b, $off + 12)
            if ($nameRva -eq 0) { break }
            $no = & $toOffset $nameRva
            if ($no -ge 0) { $names.Add((& $readName $no)) }
            $off += 20
        }
    }
    # Directory 13: delay-load imports (32-byte descriptors, DllName RVA at +4).
    $dlRva = [BitConverter]::ToUInt32($b, $dirBase + 13 * 8)
    if ($dlRva -ne 0) {
        $off = & $toOffset $dlRva
        while ($off -ge 0 -and ($off + 32) -le $b.Length) {
            $nameRva = [BitConverter]::ToUInt32($b, $off + 4)
            if ($nameRva -eq 0) { break }
            $no = & $toOffset $nameRva
            if ($no -ge 0) { $names.Add((& $readName $no)) }
            $off += 32
        }
    }
    return , $names.ToArray()
}

# --- Toolchain discovery ------------------------------------------------------------------------
function Find-SwiftRuntimeDir {
    <# The directory holding swiftCore.dll: first on PATH (what `swift build` links against), then the
       default per-user / machine install locations. #>
    foreach ($d in ($env:Path -split ';')) {
        if ($d -and (Test-Path (Join-Path $d 'swiftCore.dll')) -and (Test-Path (Join-Path $d 'Foundation.dll'))) { return (Resolve-Path $d).Path }
    }
    $roots = @()
    if ($env:LOCALAPPDATA) { $roots += Join-Path $env:LOCALAPPDATA 'Programs\Swift\Runtimes' }
    if ($env:ProgramFiles) { $roots += Join-Path $env:ProgramFiles 'Swift\Runtimes' }
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $cands = Get-ChildItem $r -Directory | Sort-Object { try { [version]($_.Name -replace '[^0-9.].*$', '') } catch { [version]'0.0' } } -Descending
        foreach ($c in $cands) {
            $bin = Join-Path $c.FullName 'usr\bin'
            if (Test-Path (Join-Path $bin 'swiftCore.dll')) { return $bin }
        }
    }
    return $null
}

function Find-VisualStudio {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $null }
    $p = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($p) { return ($p | Select-Object -First 1) }
    return $null
}

function Find-MsvcRedistDir([string]$vs) {
    if (-not $vs) { return $null }
    $root = Join-Path $vs 'VC\Redist\MSVC'
    if (-not (Test-Path $root)) { return $null }
    foreach ($v in (Get-ChildItem $root -Directory | Sort-Object Name -Descending)) {
        $crt = Get-ChildItem (Join-Path $v.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($crt) { return $crt.FullName }
    }
    return $null
}

function Find-Dumpbin([string]$vs) {
    if (-not $vs) { return $null }
    $d = Get-ChildItem (Join-Path $vs 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'bin\Hostx64\x64\dumpbin.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    return $d
}

function Test-IsMsvcRuntime([string]$name) {
    return ($name -match '^(vcruntime140(_\d)?|msvcp140(_\w+)?|concrt140|vccorlib140|vcomp140)\.dll$')
}

function Test-IsSystemDll([string]$name) {
    if ($name -match '^(api|ext)-ms-') { return $true }
    $sys = Join-Path $env:SystemRoot 'System32'
    return (Test-Path (Join-Path $sys $name))
}

# --- Build --------------------------------------------------------------------------------------
# swift needs MSVC link.exe on PATH (and SDKROOT): load the VS developer environment if needed.
try { . (Join-Path $PSScriptRoot 'vsdevenv.ps1') } catch { Stop-WithError $_.Exception.Message }
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
    Stop-WithError "swift was not found on PATH. Install the Swift toolchain (scripts\windows\install-prereqs.ps1) and open a new terminal."
}

Push-Location $RepoRoot
try {
    $buildArgs = @('build', '-c', $Configuration, '--product', 'vibeview-engine', '--scratch-path', $ScratchPath)
    if (-not $SkipBuild) {
        Write-Step "swift $($buildArgs -join ' ')"
        & swift @buildArgs
        if ($LASTEXITCODE -ne 0) { Stop-WithError "swift build failed (exit $LASTEXITCODE)" }
    }
    $binDir = (& swift @($buildArgs + '--show-bin-path') | Select-Object -Last 1).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $binDir) { Stop-WithError "could not get the SwiftPM bin path" }
} finally { Pop-Location }

$exe = Join-Path $binDir 'vibeview-engine.exe'
if (-not (Test-Path $exe)) { Stop-WithError "$exe not found (build it first, or drop -SkipBuild)" }

$runtimeDir = Find-SwiftRuntimeDir
if (-not $runtimeDir) { Stop-WithError "Swift runtime DLLs (swiftCore.dll) not found on PATH or under %LOCALAPPDATA%\Programs\Swift\Runtimes." }
Write-Step "Swift runtime: $runtimeDir"

# --- Stage --------------------------------------------------------------------------------------
if (Test-Path $OutDir) { Get-ChildItem $OutDir -Force | Remove-Item -Recurse -Force -Confirm:$false }
else { New-Item -ItemType Directory -Force $OutDir | Out-Null }

Copy-Item $exe $OutDir
# SwiftPM resource bundles of the engine's targets (none today) must sit next to the exe.
Get-ChildItem $binDir -Directory -Filter '*.resources' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '_MolChecks\.resources$' } |
    ForEach-Object { Copy-Item $_.FullName $OutDir -Recurse; Write-Host "    resources: $($_.Name)" }

$searchDirs = @($binDir, $runtimeDir)
$staged = @{}      # dll name (lower) -> source path
$msvc = @{}        # msvc runtime dll names
$unresolved = @{}  # non-system dlls not found anywhere
$queue = New-Object System.Collections.Generic.Queue[string]
$queue.Enqueue($exe)
while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    foreach ($dll in (Get-PEImports $file)) {
        $key = $dll.ToLowerInvariant()
        if ($staged.ContainsKey($key) -or $msvc.ContainsKey($key)) { continue }
        if (Test-IsMsvcRuntime $dll) { $msvc[$key] = $dll; continue }
        $src = $null
        foreach ($d in $searchDirs) { $c = Join-Path $d $dll; if (Test-Path $c) { $src = $c; break } }
        if ($src) { $staged[$key] = $src; $queue.Enqueue($src); continue }
        if (-not (Test-IsSystemDll $dll)) { $unresolved[$key] = "$dll (imported by $(Split-Path $file -Leaf))" }
    }
}

Write-Step "Swift runtime DLLs ($($staged.Count))"
foreach ($k in ($staged.Keys | Sort-Object)) {
    Copy-Item $staged[$k] $OutDir
    Write-Host "    $(Split-Path $staged[$k] -Leaf)"
}

$vs = Find-VisualStudio
if ($msvc.Count -gt 0) {
    Write-Step "MSVC runtime imports: $(($msvc.Values | Sort-Object) -join ', ')"
    if ($NoMsvcRuntime) {
        Write-Host "    not bundled (-NoMsvcRuntime): target machines need the Visual C++ 2015-2022 x64 redistributable" -ForegroundColor Yellow
    } else {
        $redist = Find-MsvcRedistDir $vs
        foreach ($name in ($msvc.Values | Sort-Object)) {
            $src = $null
            if ($redist -and (Test-Path (Join-Path $redist $name))) { $src = Join-Path $redist $name }
            elseif (Test-Path (Join-Path $env:SystemRoot "System32\$name")) { $src = Join-Path $env:SystemRoot "System32\$name" }
            if ($src) { Copy-Item $src $OutDir; Write-Host "    $name  <- $src" }
            else { $unresolved[$name.ToLowerInvariant()] = "$name (MSVC runtime)" }
        }
        # Also follow the MSVC DLLs' own non-system imports (for example msvcp140 -> vcruntime140).
        foreach ($name in @($msvc.Values)) {
            $p = Join-Path $OutDir $name
            if (-not (Test-Path $p)) { continue }
            foreach ($dll in (Get-PEImports $p)) {
                if ((Test-IsMsvcRuntime $dll) -and -not (Test-Path (Join-Path $OutDir $dll))) {
                    $src = $null
                    if ($redist -and (Test-Path (Join-Path $redist $dll))) { $src = Join-Path $redist $dll }
                    elseif (Test-Path (Join-Path $env:SystemRoot "System32\$dll")) { $src = Join-Path $env:SystemRoot "System32\$dll" }
                    if ($src) { Copy-Item $src $OutDir; Write-Host "    $dll  <- $src" }
                }
            }
        }
    }
}
Write-Host "    UCRT (api-ms-win-crt-*, ucrtbase.dll) is part of Windows 10/11 and is not bundled."

if ($unresolved.Count -gt 0) {
    Stop-WithError ("unresolved DLL imports:`n    " + (($unresolved.Values | Sort-Object) -join "`n    "))
}

# Cross-check with dumpbin when Visual Studio is present (informational).
$dumpbin = Find-Dumpbin $vs
if ($dumpbin) {
    $db = & $dumpbin /nologo /dependents (Join-Path $OutDir 'vibeview-engine.exe') | Where-Object { $_ -match '^\s+\S+\.dll\s*$' } | ForEach-Object { $_.Trim() }
    $missing = @($db | Where-Object { -not (Test-Path (Join-Path $OutDir $_)) -and -not (Test-IsSystemDll $_) })
    if ($missing.Count -gt 0) { Stop-WithError "dumpbin lists DLLs that were not staged: $($missing -join ', ')" }
    Write-Host "    dumpbin /dependents agrees ($($db.Count) direct imports)"
}

# --- Verify -------------------------------------------------------------------------------------
if (-not $SkipVerify) {
    Write-Step "Verifying the staged engine without Swift on PATH"
    $staged_exe = Join-Path $OutDir 'vibeview-engine.exe'
    # A missing DLL must fail with exit 0xC0000135 instead of a modal "System Error" box (children
    # inherit the error mode): SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX.
    try {
        Add-Type -Namespace VVStage -Name Native -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint mode);' -ErrorAction Stop
        [void][VVStage.Native]::SetErrorMode(0x8001)
    } catch { Write-Verbose "SetErrorMode unavailable: $_" }
    $savedPath = $env:Path
    try {
        $env:Path = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\Wbem;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
        $ver = & $staged_exe --version
        if ($LASTEXITCODE -ne 0) { Stop-WithError "vibeview-engine.exe --version failed (exit $LASTEXITCODE; 0xC0000135 = -1073741515 means a DLL is missing)" }
        Write-Host "    --version: $ver"
        & $staged_exe --selftest
        if ($LASTEXITCODE -ne 0) { Stop-WithError "vibeview-engine.exe --selftest failed (exit $LASTEXITCODE)" }
        Write-Host "    --selftest: ok"
    } finally { $env:Path = $savedPath }
}

$size = (Get-ChildItem $OutDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
Write-Step ("Staged {0} ({1:N1} MB)" -f $OutDir, $size)
