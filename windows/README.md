# VibeView for Windows: front end

The Windows desktop app is an Electron + three.js front end. All chemistry (file parsing, editing and undo,
orbitals and surfaces, spectra, xtb/ORCA jobs, PubChem lookup, the command console) runs in the headless
Swift engine `vibeview-engine.exe` (`Sources/VibeViewEngine`). The two talk newline-delimited JSON over
stdio; the contract is [`docs/WINDOWS_PROTOCOL.md`](../docs/WINDOWS_PROTOCOL.md).

## Requirements

- Node.js LTS (20 or 22) with npm. Newer npm releases (11.x) run dependency install scripts only when they are
  approved; `package.json` approves `electron` and `esbuild` in `allowScripts`. Don't run `npm ci` while a dev
  Electron from `node_modules` is open (`build.ps1` refuses), because the half-deleted folder breaks both.
- For the real engine: the Swift toolchain for Windows (see `docs/WINDOWS.md`). Without it the app falls
  back to a small mock engine (`dev/mock-engine.js`) so the UI can still be developed.

## Commands (run inside `windows/`)

| Command | What it does |
|---|---|
| `npm install` | Installs Electron, three.js, esbuild and electron-builder (exact versions are pinned). |
| `npm run build` | Bundles `renderer/src` into `renderer/dist/bundle.js` and creates `build/icon.ico` if it is missing. |
| `npm run dev` | Build, then start the app with the menu's reload/DevTools items. |
| `npm run dev:mock` | Same, but always with the mock engine. |
| `npm run smoke` | Headless check: opens `water_optfreq.out`, renders, writes `dist/smoke.png` and `dist/smoke-viewport.png`, exits. |
| `npm run icon` | Redraws the app icon (`build/icon.ico`, `build/icon.png`). |
| `npm run dist` | Builds the NSIS installer and the portable zip in `dist/`. Run `scripts/windows/stage-engine.ps1` first so `windows/engine/` holds the engine and its Swift runtime DLLs. |

## Finding the engine

`main/engine.js` looks, in order, at:

1. `VIBEVIEW_ENGINE` (full path to an exe)
2. `resources/engine/vibeview-engine.exe` in a packaged app
3. `windows/engine/vibeview-engine.exe`
4. the newest `vibeview-engine.exe` in any `..\.build*` scratch folder: `{debug,release}\`, the
   `x86_64-unknown-windows-msvc\{debug,release}\` subfolder, or `out\Products\{Debug,Release}-windows-x86_64\`
   (the swift-build layout of SwiftPM 6.x)
5. in development only: `dev/mock-engine.js` (the status bar then shows "Mock engine")

`--mock-engine` or `VIBEVIEW_MOCK_ENGINE=1` forces the mock. Engine stderr goes to
`%APPDATA%\VibeView\logs\engine-*.log` (Help > Open Logs Folder). If the engine crashes it is restarted
(up to 5 times) and open documents are restored from disk or from the last molecule the front end holds.

## Command-line flags

- `VibeView.exe file.xyz other.out`: open files (a second launch hands them to the running window).
- `--smoke-test <file> --screenshot <out.png> [--size 1400x900]`: hidden window, open the file through the
  engine, render, write a screenshot of the window (`out.png`) and of the viewport at 1200×900
  (`out-viewport.png`), print a one-line summary and exit (code 0 on success). `VIBEVIEW_SMOKE_TAB=orbitals`
  (or `vibrations`, `trajectory`, …) selects a results tab first; `VIBEVIEW_SMOKE_ORBITAL=HOMO` also computes
  that orbital surface. `VIBEVIEW_SMOKE_EXPORT=all` (or a list of `struct`, `image`, `csv`, `gif`, `webm`) runs File >
  Export on every open document: each structure format (all frames where the format allows) is written next to the
  screenshot and re-opened in the engine, plus PNG/JPEG, the CSV tables and animated GIFs of the trajectory and of a
  vibrational mode (800×600, 12 fps). Several files can follow `--smoke-test`.
- `--dev`: adds Reload/DevTools to the View menu.

## Layout

```
main/            Electron main process
  main.js        window, single-instance lock, IPC, dialogs, recent files, smoke test
  engine.js      spawns the engine, matches responses by id, timeouts, cancel, restart, stderr log
  menu.js        File / Edit / View / Build / Calculate / Help menus
  preload.js     the narrow window.vibeview bridge (contextIsolation on, nodeIntegration off, sandbox on)
renderer/
  index.html, styles.css
  src/main.js        entry point and the smoke test
  src/app.js         documents, edits (all via edit.apply), tools, selection, picking, jobs
  src/viewport.js    three.js scene: instanced spheres/cylinders, bond orders, picking, labels,
                     measurements, isosurfaces, vibrations, arrows, PNG export, SAO
  src/shell.js       toolbar, document tabs, status bar, splitters, drag and drop
  src/sidebar.js     element tiles, periodic table, fragment library thumbnails, recent files
  src/inspector.js   style, labels, colours, theme, molecule info, measurements
  src/results.js     Summary, Orbitals, Vibrations + IR/Raman, UV-Vis, Trajectory tabs
  src/chart.js       canvas spectra, profiles and orbital level diagrams (no chart library)
  src/export.js      File > Export: structure formats (doc.exportAs), PNG/JPEG, GIF/WebM/MP4 animations, CSV tables
  src/gif.js         GIF89a encoder: median-cut palette, optional dithering, LZW, changed-rectangle frames
  src/console.js     console with history and Tab completion (command.complete)
  src/palette.js     Ctrl+K command palette (fuzzy search)
  src/dialogs.js     name lookup, calculation setup, xtb settings, image export, job log, about
  src/elements*.js   element table (Jmol colours, covalent and vdW radii) from MolCore
dev/mock-engine.js   protocol subset for UI work without the Swift build
build/make-icon.js   draws the original app icon
scripts/build.js     esbuild bundling
```

## Mouse and keyboard

- Left drag rotates (Alt: roll), right or middle drag pans, Ctrl+right drag or the wheel zooms.
- Select tool: click, Shift-click adds, Ctrl-click toggles, double-click selects a fragment, Shift-drag on empty
  space draws a selection box. Dragging selected atoms moves them, Alt-drag rotates them (one undo step).
- Place tool: click empty space to add the current element or fragment, click an atom to change it, Ctrl-click
  to grow a bonded atom; typing an element symbol (C, N, Cl…) picks it.
- Link tool: click two atoms to bond them (1/2/3 set the order), click a bond to cycle its order, Ctrl-click to
  delete it. Gauge tool: 2, 3 or 4 atoms; edit the value in the inspector to move the structure.
- F1 lists all shortcuts.

## Packaging notes

`package.json` holds the electron-builder config: `appId` `io.github.vibeview.windows`, per-user NSIS
installer with desktop and Start-menu shortcuts, a portable zip, file associations for
`.xyz .pdb .mol .sdf .cml .gjf .com .log .out .fchk .cube .molden .vibeview`, and `engine/**` copied to
`resources/engine/`.

electron-builder needs `winCodeSign-2.6.0` (rcedit). Its archive contains macOS symlinks that 7-Zip can't create
without Developer Mode or administrator rights, so `scripts\windows\build.ps1` pre-extracts it into
`%LOCALAPPDATA%\electron-builder\Cache\winCodeSign\` and skips only those symlink errors. If you run `npm run dist`
directly on a normal account, run `build.ps1 -SkipEngine -SkipNpmInstall` once first.
