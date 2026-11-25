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
| `calc.programs` | – | same as `engine.info.programs` |
| `calc.preview` | `{ docId, "spec": CalcSpecJSON }` | `{ "input": str, "errors": [str], "files": [str], "commandLine": str }` |
| `calc.run` | `{ docId, "spec": CalcSpecJSON, "directory": str\|null }` | `{ "jobId": str, "directory": str }`. Streams `job.log` events. When it finishes, sends `job.finished`. |
| `calc.cancel` | `{ jobId }` | `{}` |
| `xtb.run` | `{ docId, "settings": XTBSettingsJSON }` | `{ "jobId": str, "directory": str }`. Same events. On success the document gets the optimized geometry (one undo step). |
| `lookup.suggest` | `{ "query": str, "limit": int=8 }` | `{ "candidates": [ { "cid", "title", "iupacName", "formula", "molecularWeight", "canonicalSMILES", "synonyms", "casNumber", "matchKind", "thumbnailB64": str\|null } ], "error": str\|null }` |
| `lookup.structure` | `{ "cid": int }` | `Molecule` |
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

## Versioning
`engine.info.protocol` is bumped on breaking changes. Additive fields are allowed at any time, and
the front end must ignore unknown fields.
