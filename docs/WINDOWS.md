# VibeView on Windows

VibeView started as a macOS app (SwiftUI + SceneKit). On Windows, the chemistry code is the same
Swift code and the user interface is new. This document covers how the port is put together, how to
build it from source, how to run the checks, how packaging works, and what differs from macOS.

## Architecture

```
┌──────────────────────────── VibeView (Electron) ───────────────────────────┐
│  windows/main      main process: windows, menus, file dialogs, engine I/O   │
│  windows/renderer  three.js viewer, sketcher, panels, spectra               │
└──────────────┬──────────────────────────────────────────────────────────────┘
               │ newline-delimited JSON-RPC over stdin/stdout (docs/WINDOWS_PROTOCOL.md)
┌──────────────▼──────────────────────────────────────────────────────────────┐
│  vibeview-engine.exe   (Sources/VibeViewEngine, headless, no UI)           │
│  MolCore · MolIO · MolBuild · MolAnalysis · MolCompute · MolCommand         │
│  MolSIMD  (Apple `simd` on Darwin, pure-Swift vectors/matrices elsewhere)   │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Portable Swift core.** `MolSIMD`, `MolCore`, `MolIO`, `MolBuild`, `MolAnalysis`, `MolCompute` and
  `MolCommand` build on macOS and Windows. `Package.swift` declares `MolRender` (SceneKit/Metal) and
  `MolScopeApp` (SwiftUI/AppKit) only on macOS. On macOS, `swift build` therefore builds everything it
  did before plus `MolSIMD` and `vibeview-engine`.
- **Engine.** `vibeview-engine.exe` links the core and serves the protocol in
  [WINDOWS_PROTOCOL.md](WINDOWS_PROTOCOL.md). Besides `--stdio` (the default) it accepts `--version`,
  `--help`, `--wait-jobs` and `--selftest [--data <TestData dir>]`.
- **Front end.** `windows/` is an Electron + three.js app. electron-builder packages it, with the
  contents of `windows/engine/` copied to `resources\engine\` inside the installed app.
- **Checks.** `molscope-check` runs the same suite on both platforms. On Windows, the render checks
  (`RenderChecks*.swift`) compile to nothing, because they are wrapped in `#if canImport(MolRender)`.

## Prerequisites

| Tool | Why | winget id |
|---|---|---|
| Visual Studio 2022 Build Tools: "Desktop development with C++" workload, MSVC x64 tools, Windows 11 SDK | Swift on Windows uses the MSVC linker, the UCRT and the Windows SDK | `Microsoft.VisualStudio.2022.BuildTools` |
| Swift 6.x for Windows | compiler, SwiftPM, Swift runtime | `Swift.Toolchain` |
| Node.js LTS (18 or later, 22 recommended) | Electron front end, electron-builder | `OpenJS.NodeJS.LTS` |
| Git | checkout | `Git.Git` |

`scripts\windows\install-prereqs.ps1` installs all four. It skips anything already installed, and
`-DryRun` prints the winget commands without running them:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\install-prereqs.ps1 -DryRun
powershell -ExecutionPolicy Bypass -File scripts\windows\install-prereqs.ps1
```

Open a **new** terminal afterwards so PATH includes `swift`, `node` and `npm`.

Before cloning, consider enabling long paths (`git config --global core.longpaths true`) and using a
short clone path such as `C:\src\VibeView`, because deep SwiftPM build directories can hit the 260-character limit.

### Line endings

`.gitattributes` fixes line endings independently of `core.autocrlf`:

- Text files are checked out with LF (`* text=auto eol=lf`, plus explicit rules for `*.swift`, `*.md`,
  `*.sh`, `*.yml`, `*.js`, `*.json`, `*.html`, `*.css` and `*.plist`). `*.ps1` is CRLF, and images
  are binary.
- `Sources/MolChecks/TestData/**` is `-text`, so fixtures are byte-for-byte identical to the macOS
  checkout. Several checks compare exact bytes or line counts.

If you cloned before `.gitattributes` existed and had `core.autocrlf=true`, your working copy still has
CRLF files. Git doesn't rewrite them by itself. Commit or stash your work first, because this
discards uncommitted changes:

```powershell
git rm -r --cached -q .
git reset --hard
```

## Building from source

All in one step (prerequisite check, engine, `npm ci`, `npm run dist`):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\build.ps1
# -> windows\dist\VibeView-Setup-<version>.exe  (and VibeView-<version>-x64.zip)
```

Options: `-Version 1.2.3` stamps a version (a leading `v` is dropped; the default comes from
`windows\package.json`, not from the repository's `VERSION` file),
`-SkipEngine` reuses `windows\engine\`, `-SkipNpmInstall` skips `npm ci`, and `-Configuration debug`
builds a debug engine.

Step by step:

```powershell
swift build                                   # whole portable package (debug)
swift run molscope-check                      # self-checks (pass a filter: swift run molscope-check io.)
swift run vibeview-engine --selftest
scripts\windows\stage-engine.ps1              # release engine + DLLs -> windows\engine\
cd windows; npm ci; npm run dist              # installer -> windows\dist\
```

For front-end development, run `npm run dev` in `windows\`. It runs Electron against the first engine
it finds: `%VIBEVIEW_ENGINE%`, then `windows\engine\vibeview-engine.exe`, then the newest
`vibeview-engine.exe` under `.build*\{debug,release}`. Without any engine it falls back to the mock
engine, and `npm run dev:mock` always uses the mock. `npm run smoke` opens a sample output in a hidden
window and writes `windows\dist\smoke.png`. See `windows\README.md` for the full list.

## Running the checks

```powershell
swift build --product molscope-check
swift run molscope-check            # all checks; the last line is "<passed>/<ran> checks passed"
swift run molscope-check compute.   # only names containing "compute."
```

Areas, by name prefix: `core.`, `io.`, `command.`, `analysis.`, `compute.` and `build.`. There are no
`render.` checks on Windows. Checks that need external programs (`compute.xtb.live`, ...) or the
network (PubChem) print `SKIP` when the program or network is unavailable.

On macOS the compute checks run `/bin/echo`, `/bin/sh`, `/bin/sleep` and so on. Windows has no `/bin`,
so the check binary runs itself as those tools (`molscope-check.exe --tool echo hello`, see
`Sources/MolChecks/CheckTools.swift`). The expected output is identical on both platforms.

## Packaging

`scripts\windows\stage-engine.ps1 [-Configuration release|debug] [-ScratchPath .build-win] [-OutDir <dir>]
[-SkipBuild] [-SkipVerify] [-NoMsvcRuntime]`:

1. Runs `swift build -c <Configuration> --product vibeview-engine` with its own scratch path, so it
   doesn't disturb your `.build`. `-SkipBuild` reuses the existing build.
2. Copies `vibeview-engine.exe` to `windows\engine\` (or `-OutDir`).
3. Reads the PE import tables (regular and delay-load) of the exe, and recursively of every DLL it
   finds in the Swift runtime directory (`%LOCALAPPDATA%\Programs\Swift\Runtimes\<version>\usr\bin`,
   or whichever directory on PATH holds `swiftCore.dll`). It copies that closure, which is typically
   `swiftCore`, `swiftCRT`, `swiftWinSDK`, `swift_Concurrency`, `swift_StringProcessing`,
   `swift_RegexParser`, `swiftDispatch`, `dispatch`, `BlocksRuntime`, `Foundation`,
   `FoundationEssentials`, `FoundationInternationalization` and `_FoundationICU`, plus
   `FoundationNetworking` because PubChem lookup uses URLSession. The parser is built into the
   script, so no extra tools are required. When Visual Studio is present, `dumpbin /dependents`
   cross-checks the result.
4. **MSVC runtime.** The Swift runtime imports `vcruntime140.dll`, `vcruntime140_1.dll` and
   `msvcp140.dll`. The script copies them app-locally from the Visual Studio redist folder
   (`VC\Redist\MSVC\<ver>\x64\Microsoft.VC143.CRT`), which Microsoft's redistribution terms allow.
   It falls back to System32 if that folder is missing. With `-NoMsvcRuntime` they are not bundled,
   and users then need the "Visual C++ 2015-2022 Redistributable (x64)". The UCRT
   (`ucrtbase.dll`, `api-ms-win-crt-*`) is part of Windows 10 and 11 and is never bundled.
5. Unless `-SkipVerify` is given, runs `--version` and `--selftest` from the staged folder with PATH reduced to
   `C:\Windows\System32` and related directories, so a missing DLL fails the script (exit
   `-1073741515` = `0xC0000135`) instead of failing on a user's machine.

electron-builder then produces:

- `VibeView-Setup-<version>.exe`: an NSIS installer that installs per user, needs no administrator
  rights, lets you choose the install directory, and creates Start menu and desktop shortcuts and
  file associations.
- `VibeView-<version>-x64.zip`: a portable build.

Neither is code-signed yet, so SmartScreen warns on the first run.

### CI

The `windows` job in `.github/workflows/build.yml` runs on `windows-latest`, next to the macOS `build`
job. It installs the swift.org toolchain with `compnerd/gha-setup-swift`. Every action is pinned by
commit SHA, and the Swift version comes from `SWIFT_VERSION` (currently 6.4.3, the same as local
builds). The job then loads the MSVC environment with `scripts\windows\vsdevenv.ps1 -ExportGitHubEnv`
and runs `swift build`, `swift run molscope-check`, the engine `--selftest`, `stage-engine.ps1`, Node
setup and `build.ps1 -SkipEngine`. It uploads the installer and zip as the `VibeView-windows` artifact.

On `v*` tags, the tag without its `v` becomes the installer version, and the job attaches
`VibeView-Setup-<version>.exe` to the GitHub release. The zip is only in the artifact. Whichever job
finishes first creates the release, and the other adds its file to it.

## Swift-on-Windows pitfalls (read before writing async or recursive code)

- **SIMD values and async code.** Swift 6.4.3 on Windows x64 miscompiles async code that moves inline
  SIMD vectors (`Vec3` = `SIMD3<Double>`, and structs that contain one, such as `GridSpec` and
  `VolumeGrid`). The process crashes with "Access violation at 0xffffffffffffffff", usually inside
  "partial apply for closure #N". Two patterns crash:
  - an async closure (`Task.detached`, `Task {}`, `withTaskCancellationHandler`) that **captures** such a
    value by value. Capture an `AsyncCapture` box (`Sources/MolSIMD/AsyncCapture.swift`) instead;
  - an async function that takes such a value as a **parameter**. Take `@autoclosure () -> T` and evaluate
    it first, as `OrbitalEvaluator.evaluateAsync` does, or pass a box or the scalars.

  Returning such values from async functions works. The macOS behaviour of these patterns is unchanged.
- **Small stacks.** The main thread has a 1 MB stack (8 MB on macOS) and debug frames are large, so deep
  recursion over atoms overflows. Walk long chains iteratively, as `SMILES.write` does.

## Known limitations compared with macOS

- **No Quick Look.** Explorer has no thumbnail or preview handler for structure files yet. File
  associations open them in VibeView.
- **Rendering** is three.js (WebGL) instead of SceneKit. Image and movie export and the GPU vibration
  path are implemented differently, and the macOS render checks don't apply.
- **No macOS conveniences.** There is no Reveal in Finder (Show in Explorer is used instead), no Open in
  Console, and no `.app` bundle or DMG.
- **Shell commands.** Job command lines shown in the UI use Windows quoting. Calculation jobs are
  started directly, not through `/bin/sh`.

### External programs on Windows

VibeView finds programs on `PATH`, in conda environments (`%USERPROFILE%\miniforge3`, `miniconda3`,
`anaconda3`, ...), and in the program's usual install directory. Viewing and building need none of them.

- **xtb**: from conda-forge: `conda install -c conda-forge xtb` in a Miniforge or Miniconda prompt.
  conda-forge provides Windows builds. Alternatively, download the Windows zip from the xtb GitHub
  releases and put `xtb.exe` on PATH. Set `XTBPATH` if xtb can't find its parameter files.
- **ORCA**: download the Windows build from the ORCA forum (registration required) and install
  **Microsoft MPI** (MS-MPI, both `msmpisetup.exe` and the SDK are fine) for parallel runs (`%pal`).
  ORCA must be started with its full path for parallel jobs. Put the ORCA directory on PATH, or point
  VibeView at `orca.exe`.
- **Gaussian**: Gaussian 16W (G16W) is commercial and installed separately. VibeView looks for
  `g16.exe` (and `formchk.exe`) on PATH and in the default G16W directory, and needs `GAUSS_EXEDIR`
  and `GAUSS_SCRDIR` set as in the G16W documentation.
- **Q-Chem** has no native Windows build. Use WSL or a remote machine, then open the outputs in VibeView.
