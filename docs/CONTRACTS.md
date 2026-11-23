# MolScope: team contracts

MolScope is an open-source, native macOS (Apple Silicon) molecular builder and viewer for
Gaussian-style quantum chemistry workflows. It is built with Swift, SwiftUI and SceneKit through
SwiftPM, with Command Line Tools only (no Xcode).

## Clean-room rule (mandatory)
Do NOT inspect, decompile, disassemble, run, or extract resources from any GaussView installation,
binary, or documentation that isn't public. Work only from public, documented file formats (the
Gaussian input-format docs on gaussian.com, cube/fchk format descriptions, XYZ/PDB/MOL specs), from
general chemistry knowledge, and from established open algorithms. Use original names, icons and
UI wording, and don't use "Gauss" or "GaussView" in identifiers or UI text.

## Module ownership (edit only your own directory)
| Lead | Module(s) | Directory |
|---|---|---|
| 1 Core | MolCore: element table, molecule ops, bond perception, geometry math, selection, undo | `Sources/MolCore` |
| 2 I/O | MolIO: .gjf/.com read+write, .log/.out parse, .fchk, .cube, XYZ, PDB, MOL/SDF, CML | `Sources/MolIO` |
| 3 Render | MolRender: SceneKit scenes, styles, picking, labels, isosurface meshes, vibration animation | `Sources/MolRender` |
| 4 Builder + App | MolBuild (fragments, editing tools, add-H, cleanup force field) and MolScopeApp (SwiftUI shell, calc-setup dialog, job runner) | `Sources/MolBuild`, `Sources/MolScopeApp` |
| 5 Analysis | MolAnalysis: spectra broadening (IR/Raman/UV-Vis), MO/density evaluation on grids from fchk basis sets, marching cubes, energy plots, thermochem | `Sources/MolAnalysis` |

Each team puts checks in `Sources/MolChecks/<Team>Checks.swift` and test files under
`Sources/MolChecks/TestData/<team>/`. To register checks, add exactly one line to `allChecks` in
`Sources/MolChecks/Harness.swift`. That one line is the only shared-file edit allowed.

## Shared types (in MolCore, owned by Lead 1)
`Atom`, `Bond`, `BondOrder`, `Molecule`, `CalculationResult`, `NormalMode`, `OrbitalInfo`,
`ExcitedState` and `VolumeGrid` in `Sources/MolCore/*.swift`. You can add **extensions** in your own
module. To change a stored property or signature, ask Lead 1, who records it under "Change log"
below. Lead 1 makes additive changes only and never breaks existing members.

Types shared by teams other than Core: MolIO exposes `BasisSet` (from fchk), which MolAnalysis
consumes. Lead 2 defines it in `Sources/MolIO/BasisSet.swift` and posts the signature here.

## Build hygiene (55 agents share this tree)
- Always build with a private scratch path so SwiftPM locks don't collide:
  `swift build --scratch-path .build-<your-agent-name>`. You can also add `--target <YourModule>`.
- Run checks: `swift run --scratch-path .build-<name> molscope-check <filter>`.
- No XCTest or Swift Testing, because they're unavailable on this machine.
- **Do not run git commit, stash, reset or checkout.** The coordinator commits.
- Don't add third-party package dependencies. Use Apple frameworks only: Foundation, simd,
  SceneKit, SwiftUI, AppKit, Charts and Accelerate.
- Keep every module compiling at all times. Before you finish, run a full `swift build`
  with your scratch path.

## Change log
- (empty)
