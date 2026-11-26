# VibeView for Windows: engine ↔ front-end protocol (v1)

The Windows app has two processes:

- **`vibeview-engine.exe`**: the Swift executable target `Sources/VibeViewEngine`. It links the portable
  core (MolCore, MolIO, MolBuild, MolAnalysis, MolCompute, MolCommand) and has no UI.
- **The desktop front end**: Electron + three.js, under `windows/`. It spawns the engine and renders everything.

## Transport
- The front end spawns the engine with `vibeview-engine.exe --stdio`. Messages are newline-delimited
  JSON (one UTF-8 JSON object per line, no embedded newlines) on stdin and stdout. stderr is free-form
  diagnostics. The front end writes it to a log and never parses it.
- Requests: `{"id": <int>, "method": "<name>", "params": {...}}`
- Responses: `{"id": <int>, "result": {...}}` or `{"id": <int>, "error": {"code": "<slug>", "message": "<human text>"}}`
- Notifications (engine → front end, no `id`): `{"event": "<name>", "params": {...}}`
- The engine handles requests concurrently. Responses can arrive out of order, so match them by `id`.
  Long work (surfaces, xtb, lookup) must not block other requests.
- `cancel` with `{"id": <request id>}` cancels an in-flight request. That request then answers with error code `cancelled`.
- Error codes: `bad_request`, `not_found`, `parse_error`, `io_error`, `not_installed`, `offline`, `timeout`, `cancelled`, `internal`.
- Numbers are plain JSON numbers. Large float arrays (mesh vertices, normals, grids, spectra) are sent
  as **base64 of little-endian Float32** (indices: little-endian Uint32), with fields named `*B64`.
- Units: Å, Hartree (with eV alongside where useful), cm⁻¹, Debye, degrees.

## Documents
The engine holds documents in memory. Each has a `docId` (string), the current molecule, an undo/redo
stack (`MoleculeDocumentModel`), and, when loaded from a file, the `LoadedMolecularFile`
(result, wavefunction, volumes, companions).

### Shared JSON shapes
```
Molecule  = { "title": str, "charge": int, "multiplicity": int,
              "atoms": [ { "z": int, "symbol": str, "pos": [x,y,z], "charge": num, "label": str|null } ],
              "bonds": [ { "a": int, "b": int, "order": 1|1.5|2|3 } ] }        // 0-based atom indices
DocSummary = { "docId": str, "title": str, "path": str|null, "format": str|null, "program": str|null,
               "formula": str, "atomCount": int, "frameCount": int, "canUndo": bool, "canRedo": bool,
               "hasWavefunction": bool, "volumeNames": [str], "modeCount": int, "orbitalCount": int,
               "excitedStateCount": int, "companions": [ { "fileName": str, "role": str, "used": bool, "note": str } ] }
Mesh      = { "sign": 1|-1, "isovalue": num, "vertexCount": int, "triangleCount": int,
              "positionsB64": str, "normalsB64": str, "indicesB64": str, "colorsB64": str|null }  // colors RGBA float
Spectrum  = { "xLabel": str, "yLabel": str, "xAxisReversed": bool, "xB64": str, "yB64": str,
              "sticks": [ { "x": num, "height": num, "label": str|null, "sourceIndex": int } ] }
```

## Methods
| Method | Params | Result |
|---|---|---|
| `engine.info` | – | `{ "version": str, "protocol": 1, "platform": str, "formats": { "read": [ {id, name, extensions[]} ], "write": [...] }, "programs": { "xtb": path\|null, "orca": path\|null, "gaussian": path\|null, "qchem": path\|null } }` |
| `doc.new` | `{}` | `DocSummary` |
| `doc.open` | `{ "path": str, "companions": bool=true }` | `DocSummary` |
| `doc.openText` | `{ "text": str, "format": str\|null, "fileName": str\|null }` | `DocSummary` |
| `doc.close` | `{ docId }` | `{}` |
| `doc.save` | `{ docId, "path": str, "format": str\|null }` (null = from extension) | `{ "path": str }` |
| `doc.export` | `{ docId, "format": str }` | `{ "text": str }` |
| `doc.molecule` | `{ docId, "frame": int\|null }` (null = current) | `Molecule` |
| `doc.summary` | `{ docId }` | `DocSummary` |
| `doc.undo` / `doc.redo` | `{ docId }` | `{ "summary": DocSummary, "molecule": Molecule }` |
| `doc.result` | `{ docId }` | `{ "energies": [num], "normalTermination": bool, "dipole": [x,y,z]\|null, "routeSection": str, "info": { "levelOfTheory": str\|null, "rows": [ {label, value} ] }, "thermo": {...}\|null, "charges": { scheme: [num] } }` |
| `doc.frames` | `{ docId }` | `{ "count": int, "energies": [num], "profile": { "coordinates": [num], "relativeKcal": [num] }\|null }` |
| `edit.apply` | `{ docId, "op": EditOp }` | `{ "summary": DocSummary, "molecule": Molecule }` (one undo step) |
| `build.fragments` | – | `{ "fragments": [ { "id": str, "name": str, "category": str, "molecule": Molecule } ] }` |
| `analysis.measure` | `{ docId, "atoms": [int] }` (2, 3 or 4 atoms) | `{ "kind": "distance"\|"angle"\|"dihedral", "value": num }` |
| `analysis.symmetry` | `{ docId, "tolerance": num=0.1 }` | `{ "pointGroup": str, "elements": [str] }` |
| `analysis.orbitals` | `{ docId }` | `{ "columns": [ { "spin": "alpha"\|"beta"\|"restricted", "levels": [ { "energy": num, "energyEV": num, "orbitalIndices": [int], "occupation": num, "isHOMO": bool, "isLUMO": bool } ] } ], "homoLumoGapEV": num\|null }` (0-based orbital indices) |
| `analysis.orbitalSurface` | `{ docId, "orbital": int, "spin": "alpha"\|"beta", "isovalue": num=0.02, "quality": "draft"\|"normal"\|"high"\|"ultra", "smoothing": int=0 }` | `{ "meshes": [Mesh, Mesh], "energy": num, "isOccupied": bool, "isHOMO": bool, "isLUMO": bool }` (cancellable) |
| `analysis.densitySurface` | `{ docId, "kind": "total"\|"spin", "isovalue": num, "quality": str, "esp": bool }` | `{ "meshes": [Mesh] }` (cancellable) |
| `analysis.volumeSurface` | `{ docId, "name": str, "isovalue": num }` | `{ "meshes": [Mesh] }` (cube files) |
| `analysis.modes` | `{ docId }` | `{ "modes": [ { "index": int, "frequency": num, "irIntensity": num, "ramanActivity": num\|null, "symmetry": str\|null, "label": str, "displacements": [[x,y,z]] } ] }` |
| `analysis.spectrum` | `{ docId, "kind": "ir"\|"raman"\|"uvvis"\|"dos", "fwhm": num\|null, "scale": num=1 }` | `Spectrum` |
| `analysis.thermo` | `{ docId, "temperature": num=298.15, "pressure": num=1, "frequencyScale": num=1 }` | thermochemistry table `{ "rows": [ {label, hartree, kcal} ] }` |
| `analysis.secondaryStructure` | `{ docId, "frame": int\|null, "source": "auto"\|"file"\|"computed" = "auto" }` | see "Protein secondary structure" in the change log |
| `build.groups` | `{ "element": int\|null }` | see "Element groups" in the change log |
| `zmatrix.get` / `.edit` / `.parse` / `.apply` / `.addAtom` | see "Z-matrix" in the change log | |
| `doc.exportFormats` / `doc.exportAs` | see "Export" in the change log | |
| `calc.programs` | – | same as `engine.info.programs` |
| `calc.preview` | `{ docId, "spec": CalcSpecJSON }` | `{ "input": str, "errors": [str], "files": [str], "commandLine": str }` |
| `calc.run` | `{ docId, "spec": CalcSpecJSON, "directory": str\|null, "inputText": str\|null }` | `{ "jobId": str, "directory": str }`. Streams `job.log` events. When it finishes, sends `job.finished`. |
| `calc.cancel` | `{ jobId }` | `{}` |
| `xtb.run` | `{ docId, "settings": XTBSettingsJSON }` | `{ "jobId": str, "directory": str }`. Same events. On success the document gets the optimized geometry (one undo step). |
| `lookup.suggest` | `{ "query": str, "limit": int=8, "source": "auto"\|"pubchem"\|"pdb"\|"chembl"\|"drugbank"\|"cactus"\|"scifinder" = "auto" }` | `{ "candidates": [ LookupCandidate ], "source", "resolvedSource", "notice": str\|null, "error": str\|null, "errorCode": str\|null }` (see Lookup below) |
| `lookup.structure` | `{ "id": str }` (or the older `{ "cid": int }`) | `Molecule` |
| `lookup.download` | `{ "id": "pdb:<ID>", "directory": str\|null }` | `{ "path", "fileName", "downloadedFormat": "pdb"\|"cif" }`; open it with `doc.open` |
| `lookup.sources` | – | `[ { "id", "name", "available": bool, "hint" } ]` |
| `command.execute` | `{ docId, "line": str }` | `{ "results": [ { "command": str, "success": bool, "messages": [ {level, text} ] } ], "molecule": Molecule\|null, "view": ViewChange\|null }` |
| `command.complete` | `{ docId, "line": str, "cursor": int }` | `{ "completions": [str], "replaceFrom": int }` |
| `session.save` / `session.load` | `{ "path": str, "docs": [docId]... }` | session JSON (same schema as `.vibeview` on macOS) |

`EditOp` (tagged by `"type"`):
`addAtom {z, pos}`, `deleteAtoms {atoms}`, `setElement {atom, z}`, `addBond {a, b, order}`,
`deleteBond {a, b}`, `setBondOrder {a, b, order}`, `placeFragment {fragmentId, at: atom|null, pos: [x,y,z]|null}`
(the MolBuild placement rules: replace an H, replace a heavy atom in place, or put the fragment in empty space),
`growAtom {from, z}`, `setDistance {atoms:[2], value}`, `setAngle {atoms:[3], value}`, `setDihedral {atoms:[4], value}`,
`moveAtoms {atoms, delta:[x,y,z]}`, `rotateAtoms {atoms, axisPoint, axis, degrees}`, `addHydrogens {}`,
`cleanUp {steps: int=200}` (UFF), `symmetrize {tolerance}`, `setCharge {charge, multiplicity}`, `replaceMolecule {molecule}`.

`ViewChange` (sent back by console commands that change display state the engine can't apply itself):
`{ "style": "ball"|"stick"|"spacefill"|"wire"|null, "labels": str|null, "fit": bool, "view": "x"|"y"|"z"|null, "orbital": {...}|null, "background": [r,g,b,a]|null }`.

`CalcSpecJSON` mirrors `MolIO.CalcSpec`:
`{ program, task, method, basis, title, dispersion, solvation: {model, solvent}|null, unrestricted, excitedStates: {roots, triplets, tammDancoff}|null, scan, frozenAtoms, tightOptimization, nprocs, memoryMB, extraKeywords, extraInput }`.
`XTBSettingsJSON` is the Codable encoding of `MolCompute.XTBSettings` (enum raw values as strings).

## Events
- `job.log` `{ jobId, "stream": "stdout"|"stderr"|"file", "file": str|null, "line": str }`
- `job.finished` `{ jobId, "exitCode": int, "ok": bool, "error": str|null, "docId": str|null, "summary": DocSummary|null }`.
  A finished `calc.run` loads its results with `CalcJobResults.collect` into a **new** document and returns its summary.
- `engine.log` `{ "level": str, "text": str }`
- `doc.wavefunction`: a background formchk conversion finished (see "Gaussian checkpoints" in the change log).

## Versioning
`engine.info.protocol` is bumped on breaking changes. Additive fields are allowed at any time, and
the front end must ignore unknown fields.

## Change log
Engine implementation notes (agent "engine", `Sources/VibeViewEngine`). Protocol stays at **1**. Everything below
is either a clarification of something the table leaves open, or an additive field/method.

**Transport and errors**
- A line that is not valid JSON gets `{"id": null, "error": {"code": "parse_error", …}}`. A request without an integer
  `id` gets `id: null` (or the id as sent) and `bad_request`. An unknown method gets `bad_request`.
- `cancel {id}` answers immediately with `{"cancelled": bool}` (false when that request had already finished). The
  cancelled request then answers with error `cancelled`. Any request finishing after its cancel answers `cancelled`, even
  when the work completed.
- At end of stdin the engine waits for in-flight requests to answer, cancels running jobs (kills xtb/ORCA), then exits 0.
  `--wait-jobs` makes it wait for the jobs instead (useful when piping a script in). Other flags: `--version`, `--help`,
  `--selftest [--data <Sources/MolChecks/TestData>]` (prints `PASS`/`FAIL` lines and exits 0 or 1).
- **Ordering.** Requests on one document that read or change its editable state (`doc.close`, `doc.save`, `doc.export`,
  `doc.molecule`, `doc.summary`, `doc.undo`, `doc.redo`, `doc.setSelection`, `edit.apply`, `command.execute`) run one at a
  time in the order they arrived, so the front end can send edits back to back without awaiting each one. Other methods
  (surfaces, spectra, lookup, …) and other documents are not held up by them.
- `job.started`, `job.log` and `job.finished` for a job are never sent before the response that returned its `jobId`
  (`calc.run`, `xtb.run`, or `command.execute` with `xtb opt`).
- Cancelling a long `edit.apply` (e.g. `cleanUp` of a large molecule), `command.execute` or surface request answers
  `cancelled` at once. The abandoned computation may finish in the background, but its result is discarded and nothing is
  committed to the document.
- Set `VIBEVIEW_ENGINE_VERBOSE=1` for a per-request trace on stderr.
- JSON objects are written with sorted keys; integers that are whole numbers are printed without a decimal point.

**Additional methods** (additive)
- `engine.ping` → `{"pong": true}`.
- `engine.info` also returns `pid` (the engine's process id).
- `doc.list` → `{"docs": [DocSummary]}`.
- `doc.setSelection {docId, atoms}` → `{"selection": [int]}` (the console's `sel` refers to it).
- `calc.setProgramPath {program: "xtb"|"orca"|"gaussian"|"qchem"|"formchk", path: str|null}` → same as `calc.programs`. It's kept in
  memory for the engine's lifetime, so the front end re-sends saved settings after spawning. Lookup order is: this path, then the
  `VIBEVIEW_XTB`/`VIBEVIEW_ORCA`/`VIBEVIEW_GAUSSIAN`/`VIBEVIEW_QCHEM` env vars, then MolCompute's search (PATH, conda), then on
  Windows `*.exe|bat|cmd` in PATH, `C:\orca*`, `%ProgramFiles%\orca*`, `%LOCALAPPDATA%\Programs\…` and conda `Library\bin`.
- `jobs.list` → `{"jobs": [{jobId, kind: "calc"|"xtb"|"formchk", docId, directory, status, commandLine}]}`.
- Event `job.started {jobId, directory, commandLine}` is sent when the process has launched (before the first `job.log`).

**Documents**
- `doc.new` also accepts an optional `molecule` (Molecule) and `title`.
- DocSummary extra fields: `bondCount`, `undoName`, `redoName`, `isDirty`, `charge`, `multiplicity`, `isUnrestricted`,
  `hasResult`, `levelOfTheory`, `selection`. Each companion also has `path`. `frameCount` is at least 1. `orbitalCount`
  is the number of alpha (or restricted) MOs in the wavefunction, or else in the parsed orbital table.
- `doc.open` detects the format from the contents first. If that reader fails, it retries with the format the file
  extension names (an ORCA `.inp` whose first line is a `# comment` otherwise looks like a Gaussian route).
- `format` values are `MoleculeFileFormat` raw values (`xyz`, `pdb`, `mol`, `sdf`, `cml`, `gaussianInput`, `orcaInput`, `qchemInput`, …).
  `doc.save`/`doc.export`/`doc.openText` accept either a raw value or a file extension. Only the formats in `engine.info.formats.write` can be saved.
  Saving a structure format makes it the document's path; saving from a calculation output keeps the output as the path.
- The current molecule carries bond orders. Formats that state them (PDB, MOL/SDF, CML, Gaussian input) keep the
  file's orders. For the others (XYZ, calculation outputs, Molden, fchk, cube, …) orders are perceived on load, also when
  the parser already supplied single-bond connectivity (up to 2000 atoms).
- `doc.molecule {frame}`: frames are 0-based. A single-structure document accepts `frame: 0`. Frames come with bonds
  (perceived when the file has none) but without perceived bond orders. The current molecule is the one with orders.
- `doc.result` extras: `dipoleMagnitude`, `spinDensities`, `program`, `programVersion`, `finalEnergy`, `homoLumoGapEV`,
  `optimizationConverged`, `messages`, `hasResult`, and `excitedStates: [{index, energyEV, wavelengthNM, oscillatorStrength,
  multiplicity, symmetry}]`. `charges` and `spinDensities` use one spelling per scheme (`Mulliken`, `Loewdin`, `Hirshfeld`, `CHELPG`, `NPA`, `ESP`, `CM5`, `xtb`; others as the parser names them). `thermo` is the program's printed thermochemistry (`ThermochemistrySummary` field names,
  Hartree), or null. For thermochemistry recomputed at another T/p, use `analysis.thermo`.
- `doc.frames.profile` is relative to the first point (kcal/mol), with `coordinates` = step index and `xLabel`.

**Editing** (`edit.apply`)
- `addAtom {z, pos, addHydrogens: bool = true}`: by default it behaves like a Sketch click in empty space (a free atom
  filled with hydrogens, `Builder.placeElement`). Pass `addHydrogens: false` for a bare atom.
- Extra ops: `placeElement {z, at: atom|null, pos}` (the same click rules as `placeFragment`, for an element),
  `setPositions {positions: [[x,y,z]] per atom}` (commits a drag as one undo step), `removeHydrogens {atoms?}`,
  `setTitle {title}`. `addHydrogens` accepts optional `atoms`, `cleanUp` optional `frozen`, `setElement`/`setBondOrder`
  optional `adjustHydrogens` (default true), and `replaceMolecule` optional `perceiveBonds` and `name` (undo label).
- `rotateAtoms.axisPoint` defaults to the centroid of `atoms`. `setDistance`/`setAngle`/`setDihedral` move whichever side is
  smaller (MolBuild `…MovingSmaller`).
- Bond `order` accepts 1, 1.5, 2, 3 or "single"/"aromatic"/"double"/"triple".
- An out-of-range atom index or an invalid valence gives `bad_request` with a readable message, and an unknown
  `fragmentId` gives `not_found`. `bad_request` is also the answer for `deleteBond`/`setBondOrder` on atoms that aren't bonded and
  `setDistance`/`setAngle`/`setDihedral` with repeated atoms.
- `build.fragments` also returns `categories: [{id, title}]` and, per fragment, `categoryTitle`, `anchor`, `leaving`.
- **Element groups** (GaussView-style picker after choosing an element; MolBuild `GroupLibrary`, `Sources/MolBuild/Groups.swift`,
  engine side `Methods+Groups.swift`). `build.groups {element?: int}` → `{groups: [{id, name, label, element, kind:
  "atom"|"group", hybridization: "sp"|"sp2"|"sp3"|null, bondOrder: 1|2|3, anchor, leaving, molecule}]}`. Ids are
  `<Symbol>.<key>` (`C.sp2`, `C.methyl`, `N.dimethylamino`, `O.carbonyl`, …); `molecule` is the template with all
  hydrogens (what an empty-space click places), `anchor` the attachment atom and `leaving` its hydrogen that marks the
  open valence. Edit op `placeGroup {groupId, at: atom|null, pos: [x,y,z]|null}` (unknown id → `not_found`): empty space →
  the template; a hydrogen → replaced by the group (bond length from covalent radii, torsion chosen to avoid clashes);
  a heavy atom with a free valence → a functional group is bonded to it; any other heavy atom → replaced in place
  (an atom template keeps its hybridization's hydrogen count and geometry). `bondOrder` 2/3 groups (`=O`, `=CH₂`, `=NH`,
  `=S`, `≡N`, `≡CH`) take further hydrogens off the host, re-place the host's remaining hydrogens in sp²/sp geometry and
  keep the planes coplanar; a host without spare hydrogens (e.g. an aromatic C) gives `bad_request`. sp²/sp atom
  templates leave valences open, and when bonded to a host with a free valence the bond order is raised (C sp² on an H of
  a C sp² → ethylene, planar). Undo label: "Place <group name>".

**Analysis**
- `analysis.measure` accepts an optional `frame` and returns `unit`.
- `analysis.symmetry` extras: `order`, `principalAxis`, `elementDetails: [{name, axis}]`, `symmetryNumber`. Element names
  are `E`, `i`, `Cn` (`C∞`), `σ`, `Sn`: generators, not every operation.
- `analysis.orbitals` levels also carry `label` ("HOMO", "LUMO+1", …) and `degeneracy`. Each column carries
  `homoLumoGapEV`, and the result carries `canDrawSurfaces`.
- `analysis.orbitalSurface`: `spin` defaults to "alpha". `isovalue` is taken as |iso|. Mesh 0 is the + lobe and mesh 1
  is the − lobe, and either can be empty (`vertexCount` 0). There's an optional `maxTriangles` (400000). Extras: `energyEV`,
  `occupation`, `timings`, `gridPoints`, `source: "wavefunction"|"cube"`. Without a wavefunction, an orbital cube named
  `MO <n+1>` is used.
- `analysis.densitySurface`: `isovalue` defaults to 0.0004 (total) / 0.002 (spin), in e/Bohr³. `kind: "spin"` returns two
  meshes `[+, −]`. With `esp: true` the total-density mesh has `colorsB64` (red negative … blue positive) plus
  `scalarsB64` (ESP, Hartree/e, Float32) and `scalarRange`. Optional `espMin`/`espMax` fix the colour range.
- `analysis.volumeSurface`: grids that go below −|iso| (orbitals, spin densities) return two meshes `[+, −]`, and
  positive-only grids return one. Override with `signed: bool`. Extras: `min`, `max`, `counts`. Volume names are the cube
  file's (`cube`, `cube 2`, …) or, for companions, the cube file name.
- Mesh extra fields: `scalarsB64` and `scalarRange` when per-vertex scalars exist.
- `analysis.modes` also returns `geometry` (the Molecule the displacements refer to) and, per mode, `isImaginary`,
  `reducedMass` and `forceConstant`. `label` is MolAnalysis' `VibrationalModeAnalysis` label (e.g. "O–H stretch (sym)").
- `analysis.spectrum`: optional `shape` ("lorentzian"|"gaussian"), `xMin`/`xMax`, `points`, and `excitationNM` (Raman),
  `axis` (uvvis: "wavelengthNM" default | "energyEV" | "wavenumber"). Defaults: IR/Raman fwhm 10 cm⁻¹, 0–4000 cm⁻¹,
  2000 points; UV-vis fwhm 0.3 eV; DOS fwhm 0.3 eV. `scale` multiplies frequencies (IR/Raman). The result adds `pointCount`.
  DOS from a wavefunction adds `occupiedYB64` (occupied-only curve on the same x grid). Missing data gives `not_found`.
- `analysis.thermo` also takes `symmetryNumber` and `quasiRRHO: bool`. It returns rows (Electronic energy, ZPE, thermal
  corrections to E/H/G, E+ZPE, E+thermal, H, G, T·S) plus `entropy`, `heatCapacity` (cal/(mol·K)),
  `rotationalConstantsGHz`, `symmetryNumber`, `isLinear` and `frequenciesUsed`.

**Calculations and jobs**
- CalcSpecJSON: enum fields use the MolIO raw values (`program` gaussian/orca/qchem/xtb; `task` energy/optimize/frequencies/
  optimizeAndFrequencies/transitionState/scan/irc/gradient; `dispersion` d3zero/d3bj/d4 or null/"none"; `solvation.model`
  pcm/cpcm/smd/alpb/gbsa). `scan` is `{atoms, start, end, steps}`. `extraKeywords` may be an array or a space-separated
  string. Also accepted: `charge`, `multiplicity` (override the document's), `checkpointName`, `computeFrequenciesAfterTS`.
- `calc.preview` extras: `fileContents: [{name, contents}]`, `outputFile`, and `executable` (resolved path or null).
  Gaussian also gets `warnings: [str]` (adaptations to the installed build, then input-check messages), `check: [InputIssue]`
  and `gaussian: {name, maxMemoryMB: int|null, hasDef2AndGD3: bool}|null` (the located build, from its PE header: 32-bit
  and link year). `InputIssue = {severity: "error"|"warning", line: int|null (1-based), message, fixable: bool}`.
- Gaussian adaptation (`GaussianInstallProfile.adapt`, applied to the spec by `calc.preview` and `calc.run`): a 32-bit build
  gets `%mem` of at most 1500 MB (G09W stops right after Link 1 with 1700 MB or more, so the output has no atoms); builds
  before G09 rev. D.01 (link year < 2013, e.g. G09W A.02) get `def2-SVP`→`SVP`, `def2-TZVP`→`TZVP`, `def2-QZVP`→`QZVP`
  and no `EmpiricalDispersion` (both are Link 1 syntax errors there). Each change is a `warnings` line.
- The Gaussian command line names the output file: `g09 job.gjf job.log` (or g16). With one argument, Windows G09 passes the
  absolute output path to l1.exe unquoted, so in a folder with a space ("VibeView Jobs") the output went to a file named
  after the first word (`C:\Users\<user>\VibeView`) and job.log held only the header: the "no atoms" error.
- `calc.checkInput {program: "gaussian", text}` → `{issues: [InputIssue], repaired: str|null, fixes: [str], gaussian}`:
  structural check of an edited input (Link 0, route, title, charge/multiplicity, molecule, blank-line terminators,
  Geom=Connectivity section, ModRedundant, `--Link1--` steps, %mem against the build, def2/GD3 on old builds). `repaired`
  is the text with the fixable problems repaired (missing title section, missing blank line after a section or at the end,
  %mem above the limit), null when nothing is fixable. Other programs return no issues.
  When `errors` isn't empty, `input` is "".
- `calc.run`/`xtb.run`: `directory` defaults to `~/VibeView Jobs/<program>-<yyyyMMdd-HHmmss>`. `calc.run` also takes
  `baseName` (default "job") and returns `commandLine`, `inputFile` and `outputFile`. A missing program is answered at once
  with `not_installed`. Invalid specs or settings give `bad_request`. For Gaussian, `calc.run` also returns `warnings`,
  `repairs` (fixes applied to `inputText`, which is otherwise written as given) and `check` (InputIssue list of the file
  written); warnings and repairs are also sent as `job.log` stderr lines starting with "VibeView: ". A failed Gaussian
  job's `job.finished.error` is Gaussian's own reason ("syntax error at 'EmpiricalDispersion=GD3BJ'", "stopped right
  after Link 1", "End of file in ZSymb. (l101.exe)") instead of "no atoms".
- `job.finished` extras: `cancelled`, `directory`. For xtb: `energy`, `gradientNorm`, `homoLumoGapEV`, `converged`, `cycles`
  and `frequencies`, plus `errorCode` on failure. `xtb.run`'s `docId` is the source document, which received the optimized
  coordinates (undo step "xtb Optimization", topology kept). `calc.run`'s `docId` is a new document even when the job failed,
  as long as some output could be read. `ok` = exit code 0 and normal termination.

**Gaussian checkpoints (automatic formchk)**
- A Gaussian `.chk` is converted to `.fchk` with `formchk` so orbitals work without a manual step. formchk is looked up in this
  order: `calc.setProgramPath {program: "formchk", path}`, the `VIBEVIEW_FORMCHK` env var, the `GAUSS_EXEDIR` folders, the folder of
  the Gaussian executable, PATH, then on Windows `C:\G16W`, `C:\G09W` and the same names under `%ProgramFiles%`. `calc.programs`
  and `engine.info.programs` gain a `formchk` key (path or null). When `GAUSS_EXEDIR` is unset, it is set to formchk's folder.
- formchk runs in the checkpoint's folder as `formchk <stem>.chk <temp>.fchk` (10-minute timeout, cancellable). The result
  replaces `<stem>.fchk` next to the `.chk` only when that file is missing or older than the `.chk`. A newer `.fchk` is never
  overwritten, and an up-to-date one is used as it is.
- After a Gaussian `calc.run`, the conversion runs before the results are read (its lines appear in `job.log`), so the new
  document has the wavefunction. `job.finished` adds `fchk` (path or null) and `formchkError` (str or null). A failed or
  missing formchk doesn't fail the job.
- `doc.open` of a Gaussian log whose `.chk` companion has no up-to-date `.fchk` answers at once. The summary then has
  `formchkPending: true`, and the conversion runs in the background (listed by `jobs.list` with `kind: "formchk"`).
  When it ends, the engine sends the event **`doc.wavefunction`**
  `{docId, jobId, chk, ok, fchk: str|null, error: str|null, errorCode?, summary: DocSummary}`. With `ok: true` the document now
  has the wavefunction (`summary.hasWavefunction`). `analysis.orbitals`, orbital and density surfaces and DOS then work, and the
  companions list the `.fchk` as used. With `ok: false` the document is unchanged apart from a note on the `.chk` companion. When
  formchk isn't found, nothing runs and no event is sent: the `.chk` companion keeps its "run formchk" hint, plus a note on how to
  point the engine at formchk. `doc.close` cancels a pending conversion, and a closed document gets no event. The event is never
  sent before the `doc.open` response. The same applies to files opened by the console `open` command and by `session.load`.
- DocSummary extra field: `formchkPending: bool`.

**Lookup**
- `lookup.suggest` candidates also carry `matchedQuery` and `depictionURL`. When nothing is found, `error` explains why
  and `errorCode` holds the protocol code (`offline`, `timeout`, `not_found`, …).
- `lookup.structure {id | cid, title?}` returns a Molecule with bonds and bond orders (perceived if missing). It doesn't create a
  document: use `doc.new {molecule}` or `edit.apply replaceMolecule`. For a PDB id it is the entry's first model (no residue
  information); to open a protein as a document use `lookup.download`, then `doc.open`.
- `LookupCandidate = {id: "<source>:<identifier>", source, sourceName, identifier, cid (0 when not from PubChem), title,
  iupacName, formula, molecularWeight, canonicalSMILES, synonyms, casNumber, matchKind, matchedQuery, depictionURL,
  thumbnailB64, thumbnailMIME ("image/png" PubChem/CACTUS, "image/jpeg" RCSB, "image/svg+xml" ChEMBL), details: [str]
  (e.g. "X-Ray diffraction · 1.50 Å · 327 atoms · released 1981-04-30", organisms), webURL, drugBankID, chemblID,
  sourceNote, isMacromolecule}`. Ids returned by a search stay valid for `lookup.structure`/`lookup.download`;
  `pubchem:<cid>`, `pdb:<ID>` and `chembl:<ID>` also work without a search.
- Sources. `pubchem`: as before. `pdb`: a PDB ID (`1CRN`, `pdb:1crn`, `pdb_00001crn`) or RCSB full-text search
  (search.rcsb.org v2); metadata from the RCSB GraphQL API; thumbnail cdn.rcsb.org `<id>_assembly-1.jpeg`.
  `lookup.download` saves files.rcsb.org `<ID>.pdb`, or `<ID>.cif` when the entry has no PDB-format file, to `directory`
  (default `%LOCALAPPDATA%\VibeView\Downloads`). `chembl`: EBI ChEMBL REST, by CHEMBL ID or name search; structures are
  PubChem's 3D conformer for the record's InChIKey, else the ChEMBL molfile with hydrogens added and embedded in 3D.
  `drugbank`: no free API, so DrugBank IDs and names are resolved through PubChem (PubChem lists DrugBank IDs as synonyms);
  candidates carry a `sourceNote` saying so, and the structure is PubChem's. `cactus`: NCI/CADD Chemical Identifier Resolver
  (one candidate, 3D SD file). `scifinder`: always `errorCode: "unavailable"` with an explanation (no public API; needs an
  institutional CAS subscription; CAS numbers resolve through PubChem). `auto`: PDB ID → pdb (PubChem when no entry
  exists), `CHEMBL\d+` → chembl, `DB\d{5}` → drugbank, everything else → PubChem; names also run an RCSB text search, and
  up to 3 PDB entries follow the PubChem hits (all of them when PubChem has none); CACTUS is tried when PubChem finds
  nothing. CAS-number queries add the SciFinder `notice`. Requests have timeouts (10–20 s, downloads 60–120 s); errors map
  to `offline`, `timeout`, `not_found`.
- **mmCIF.** `.cif`/`.mmcif` files (and text starting with `data_`) are read by `MolIO.MMCIFFormat` into the same model as PDB
  files, so the document `format` is `pdb`: `_atom_site` (auth chain/residue numbers and names, altLoc selection, all
  models), `_struct_conf`/`_struct_sheet_range` (helices and strands for `analysis.secondaryStructure` source "file"),
  `_pdbx_struct_assembly_gen` + `_pdbx_struct_oper_list` (assemblies, operator expressions such as `(1-60)` and
  `(X0)(1-60)`), `_cell`. Chain IDs may have several characters. Small-molecule CIF (fractional coordinates) gives
  `parse_error`. Save on a `.cif` document asks for a new file instead of overwriting it.

**Console**
- `command.execute` result extras: `summary` (DocSummary after the line), `cwd`, `opened: [DocSummary]` (from `open …`, files
  are opened as new documents), `jobs: [jobId]` (from `xtb opt`, which starts an xtb job; options `gfn0|gfn1|gfn2|gfnff`,
  `crude…extreme`, `alpb=<solvent>`, `gbsa=<solvent>`, `chrg=N`, `uhf=N`, `cycles=N`, `threads=N`, `sp`, `hess`). Results may
  include `value: {number, unit} | {text} | {atoms}`. `molecule` is non-null only when the line changed the structure.
- `ViewChange` (null when nothing visual changed): `labels` is "atoms" | "charges" | "none" (off). `orbital` is
  `{index (0-based), number (1-based), spin, label}`. `background` is always null, because no console command sets it. Extra keys:
  `vibration: {mode: int|null (0-based; null = stop), frequency}`, `hydrogens: bool`, `hidden: [{atoms, hidden}]`,
  `colors: [{atoms, rgba}]`, `measurements: [[atoms]]`, `rotate: [{axis, degrees}]` (camera turns), `selection: [int]`,
  `exportImage: {path, width, height}|null` (the front end renders the PNG), `close: bool`.
- `command.complete`: `cursor` and `replaceFrom` are UTF-16 offsets (JavaScript string indices). Also returns `cwd`.

**Sessions**
- `session.save {path, docs?: [docId], views?: {docId: object}}`. `docs` defaults to all open documents, and `views` holds
  each document's front-end view state (opaque to the engine). Returns `{path, session}`. The file keeps the macOS top-level
  keys (`format: "vibeview-session"`, `version: 1`, `appVersion`, `saved`, `molecule`, `sourceFile`, `renderOptions`,
  `monitors`, plus `camera`/`orbitalLook`/`activeOrbitalIndex`/`activeModeIndex`/`orbitalIsovalue`/`frameIndex` when the
  first document's view has them). It adds `documents: [{title, sourceFile, format, molecule, view}]`.
- `session.load {path}` → `{session, docs: [{docId, summary, view}]}`. Each document's `sourceFile` is re-opened when it
  exists. If the saved molecule differs, it's applied as the undo step "Restore Session". Otherwise a document is created
  from the saved molecule. macOS sessions (without `documents`) load as one document whose `view` holds the top-level view keys.

**Export** (agent "export", `Sources/VibeViewEngine/Methods+Export.swift`; additive)
- `doc.exportFormats {docId}` → `{formats: [{id, name, extensions, multiFrame, available, note, volumes?}]}`: the
  `engine.info.formats.write` list plus `molden` (geometry, basis set and MOs when the document has a wavefunction, normal
  modes, and all frames as `[GEOMETRIES]`) and `cube` (`available` only when the document has volumes; `volumes` names them).
  `multiFrame` is true for `xyz`, `sdf`, `pdb` (MODEL records) and `molden`.
- `doc.exportAs {docId, format, frames: "current"|"all"|[int] = "current", atoms: [int]|null, energies: bool = true,
  volume: str|null}` → `{text, format, extension, frameCount, atomCount}`. `current` is the edited document molecule (with
  bond orders); frame indices are 0-based file frames (bonds perceived). Single-structure formats write the last requested
  frame. `atoms` writes only those atoms (bonds between them kept; charge 0 / multiplicity 1 when it's a fragment).
  With `energies`, XYZ title lines and SD data items (`ENERGY_HARTREE`, `FRAME`) carry the frame energies (aligned with the
  last frames when the result lists more energies than geometries). Molden writes the wavefunction and modes only for the
  whole molecule. Ordered per document like `doc.export`. It returns text only; the front end writes it to the path the
  user chose in a Save dialog.

**Calculation catalog, edited input, program paths** (additive)
- `spec.method` and `spec.basis` are written verbatim in the program's spelling (Gaussian route `method/basis`, ORCA `!` line,
  Q-Chem `METHOD`/`BASIS` in `$rem`, the method lower-cased). The front end's catalog (`windows/renderer/src/calc-catalog.js`)
  picks the keyword per program; the engine accepts any keyword. Rules the engine applies:
  - Basis-free methods need no `basis`, and a basis sent with them is dropped: semiempirical (`PM7`, `PM6`, `PM3`, `AM1`,
    `PM3MM`, `RM1`, `MNDO`, `ZINDO`, …), xtb (`GFN*`), every `*-3c` composite (`HF-3c`, `PBEh-3c`, `B97-3c`, `r2SCAN-3c`,
    `wB97X-3c`, …) and Gaussian's composite models (`CBS-QB3`, `CBS-4M`, `CBS-APNO`, `G1`…`G4`, `G3MP2`, `G3B3`, `G4MP2`, `W1U`,
    `W1BD`, `W1RO`). Any other method with an empty basis gives the error "basis set is empty".
  - `dispersion`: Gaussian `d3zero` → `EmpiricalDispersion=GD3`, `d3bj` → `GD3BJ`, `d4` is ignored (no Gaussian keyword);
    ORCA `D3ZERO`/`D3BJ`/`D4`; Q-Chem `DFT_D D3_ZERO`/`D3_BJ`/`D4`. Methods with built-in dispersion (wB97X-D, B97-D3, …)
    should be sent with `dispersion: null`.
  - `unrestricted: true`: Gaussian prefixes `U` (not for names starting with `U`/`RO`, nor for composite models); ORCA adds
    `UKS` for DFT and `UHF` for wavefunction methods (HF, MP2, RI-…, SCS-…, CC…, DLPNO-…, QCISD, CIS, CASSCF, NEVPT), nothing for
    basis-free methods; Q-Chem `UNRESTRICTED true`.
  - `extraKeywords`: Gaussian/ORCA keywords appended to the route / `!` line (e.g. the ORCA `/C` auxiliary basis, `RIJCOSX def2/J`);
    for Q-Chem each entry is one `$rem` line (e.g. `ECP def2-ECP`). The engine adds no SCF/optimisation iteration limits of its
    own; the front end puts those into `extraKeywords`/`extraInput`.
- `calc.run {inputText}`: the input file as the user edited it in the setup dialog. It is written verbatim as the input file
  (a final newline is added) instead of the generated one; everything else (file names, command line, output parsing) still
  comes from `spec`. Blank `inputText` gives `bad_request`. For Gaussian, a `%chk=` line in the edited text decides which
  checkpoint is converted with formchk.
- `calc.preview.commandLine` and `executable` name the program `calc.run` will start (the located or configured executable,
  e.g. `C:\G09W\g09.exe` rather than `g16`). When none is found, the command line uses the default name (`g16`, `orca`, …) and
  `executable` is null.
- Program paths (`calc.programs`, `engine.info.programs`, `calc.preview.executable`, command lines) are native paths: on
  Windows with backslashes and without doubled separators (`C:\G09W\g09.exe`, UNC `\\server\share\…`).
- Gaussian output name: Gaussian on Unix writes `<base>.log`, the Windows builds (G09W/G16W) write `<base>.out`. A finished
  Gaussian job reads whichever exists (the newer one when both do) and tails both while it runs. The result document's
  path/fileName are the file actually read. `calc.run.outputFile` stays the planned `<base>.log`.

**Protein secondary structure** (`Sources/VibeViewEngine/Methods+Structure.swift`; used by the cartoon view)
- `analysis.secondaryStructure {docId, frame?: int, source?: "auto"|"file"|"computed" = "auto"}` (cancellable) →
  `{atomCount, residueCount, residueSource: "file"|"topology", source: "file"|"computed"|"none", ss: str, chain: [str],
  seq: [int], iCode: [str], name: [str], n: [int], ca: [int], c: [int], o: [int], segments: [[start, end]],
  polymerAtoms: [int], waterAtoms: [int], helixCount: int, strandCount: int, chains: [str], atomChain: [int],
  assembly: {id: str, chains: [str], parts: [{chains: [str], operators: [[12 numbers]]}]}|null}`.
- Residues come from the PDB file's ATOM/HETATM records when the document was opened from a `.pdb` file with `doc.open`
  (atoms matched by coordinates, `frame` selects the MODEL). Otherwise (other formats,
  `doc.openText`, or no matching records) the backbone is perceived from the bond graph: N–CA–C(=O) residues linked by C–N
  bonds, chains `A`, `B`, … numbered from 1, `name` "UNK". Fewer than 3 such residues count as no protein (`residueCount` 0,
  `source` "none", empty arrays).
- Per-residue arrays are parallel and in chain order. `n`/`ca`/`c`/`o` are 0-based atom indices (`o` may be -1).
  `segments` are half-open residue ranges `[start, end)` of continuous backbone; a new segment starts at a chain change or
  when C(i)–N(i+1) > 2.0 Å (CA(i)–CA(i+1) > 4.3 Å when a residue lacks its N or C). A residue needs a CA and an N or a C.
  From file records, residues are standard amino acids (also when written as HETATM) plus any residue peptide-linked to a
  neighbour (modified residues such as MSE); a lone non-standard group is a ligand even when it has N/CA/C atom names.
- `ss` has one character per residue: `H` α-helix, `G` 3₁₀-helix, `I` π-helix, `E` strand, `B` isolated bridge, `T` turn,
  `L` loop. With `source: "auto"` the file's HELIX/SHEET records are used when present (`source` "file"; HELIX class 5 → `G`,
  class 3 → `I`, else `H`; SHEET → `E`; all other residues `L`), otherwise a simplified DSSP runs (`source` "computed"; backbone
  H-bond energies, the amide H is placed when the file has none). `"file"` never runs DSSP (`source` "none" and all `L` without
  records), and `"computed"` ignores the records. `helixCount`/`strandCount` count runs of H/G/I and of E within segments.
- `polymerAtoms`: residue atoms plus the hydrogens bonded to them. `waterAtoms`: atoms of HOH/WAT/DOD/H2O/SOL/TIP*/SPC
  residues and their hydrogens. An invalid `source` or an out-of-range `frame` gives `bad_request`.
- `chains`: chain names (residue chains first, then chains met only on other atoms); `atomChain[i]` indexes it, -1 when
  the atom has no record. `assembly`: biological assembly 1 from the file's REMARK 350 (null without one, or when the residues
  are not from the file); operators are row-major 3×4 matrices `[r11 r12 r13 t1 r21 … t3]` in Å applied to the part's chains.
  The front end shows only the assembly's chains in cartoon mode and draws the non-identity operators as copies.

**PDB reading** (`MolIO.PDBFormat`). Only one alternate location per residue is kept (the altLoc label with the highest summed
occupancy, ties to the first label; blank altLoc atoms always kept). A multi-MODEL file opens on model 1, the other models are
frames (the Trajectory tab starts at model 1). Ligands and other non-standard residues get perceived bond orders
(`PDBLigandBondOrders`: geometry-based implicit hydrogens, then valence matching and aromaticity) unless their CONECT
records state multiplicities; standard residues keep their templates.

**Z-matrix** (`Sources/VibeViewEngine/Methods+ZMatrix.swift`, MolCore `ZMatrix`). Rows are 0-based, and `order[row]` is the
document atom index shown in that row. Every edit is one undo step.
- `zmatrix.get {docId, ordering?: "connectivity"|"input" = "connectivity", order?: [int], refs?: [[int|null]], variables?: bool = false}`
  → `ZMatrixJSON` = `{atomCount, ordering, order: [int], refs: [[bondRow, angleRow, dihedralRow]] (null where absent),
  refsUsed: bool, rows: [{row, atom, z, symbol, label, bondRow, bondAtom, bond, bonded: bool, angleRow, angleAtom, angle,
  dihedralRow, dihedralAtom, dihedral}], gaussian: str, gaussianVariables: str, orca: str, charge, multiplicity}`.
  `*Atom` fields are document atom indices, `bond` is in Å, angles in degrees (null where the row has none). `order` is used
  when it is a permutation of all atoms, and `refs` (one entry per row, distinct earlier rows) only together with such an
  `order`. `gaussian` is the bare Gaussian Z-matrix (with `R2`/`A3`/`D4` variables when `variables` is true),
  `gaussianVariables` always the variable form, `orca` a `* int charge mult … *` block. More than 4000 atoms gives `bad_request`.
- `zmatrix.edit {docId, ordering?, order?, refs?, row, field: "bond"|"angle"|"dihedral", value}` or `{…, changes: [{row, field,
  value}]}` → `{summary, molecule, zmatrix: ZMatrixJSON}` (undo "Edit Z-Matrix"). Atoms that don't depend on the edited rows
  keep their positions. `bad_request` for a row out of range, a row without that field (rows 0–2), a distance ≤ 0.01 Å or an
  angle outside (0, 180]. Dihedrals are wrapped to (−180, 180].
- `zmatrix.parse {text}` → `{molecule, rowCount, dummyCount, variables: {name: value}, source, chargeGiven, atomCount}`. It
  accepts a bare Gaussian Z-matrix (`source` "gaussian"; variables section optional, optional leading `charge mult` line, dummy
  atoms `X`), a whole Gaussian input (`gaussianInput`), an ORCA `* int` block or input (`orcaInput`) and bare ORCA internal rows
  (`orcaInternal`). Bonds are perceived. Text that can't be read gives `parse_error`.
- `zmatrix.apply {docId?, text, newDocument?: bool, order?: [int], title?}` → `{summary, molecule, mode: "new"|"positions"|"replace",
  docId, source}`. Without `docId`, or with `newDocument`, a new document is created (`mode` "new"). Otherwise, when `order`
  maps the parsed rows onto the document atoms with the same elements, only positions change (`positions`, undo "Edit
  Z-Matrix"); else the structure is replaced (`replace`, undo "Z-Matrix"). Charge and multiplicity come from the text when it
  states them.
- `zmatrix.addAtom {docId, z, bondAtom?, angleAtom?, dihedralAtom?, bond?, angle?, dihedral?, bondOrder?, addHydrogens?: bool = false,
  dryRun?: bool = false}` → `{defaults: {bondAtom, angleAtom, dihedralAtom, bond, angle, dihedral, hybridization, position},
  position: [x,y,z], atom?: int, summary?, molecule?}`. Reference atoms are document indices. Missing ones default to the last
  selected (or last) atom and its neighbours, the distance to the covalent bond length, the angle to the reference atom's
  hybridization, and the dihedral to the roomiest staggered position. `dryRun` returns only `defaults` and `position`. Undo
  "Add Atom (Z-Matrix)".
