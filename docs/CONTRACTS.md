# VibeView: team contracts

VibeView is an open-source, native macOS (Apple Silicon) molecular builder and viewer for
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
| 4 Builder + App | MolBuild (fragments, editing tools, add-H, cleanup force field) and VibeViewApp (SwiftUI shell, calc-setup dialog, job runner) | `Sources/MolBuild`, `Sources/VibeViewApp` |
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

## MolAnalysis public types (Lead 5), in `Sources/MolAnalysis/AnalysisTypes.swift`
```swift
public struct IsoSurfaceMesh: Sendable, Equatable {
    public enum Sign: Int { case positive = 1, negative = -1 }
    public var vertices: [SIMD3<Float>]      // Ångström, same frame as molecule/grid
    public var normals: [SIMD3<Float>]       // unit, outward from the lobe (toward decreasing |value|)
    public var indices: [UInt32]             // 3 per triangle, CCW seen from the normal side
    public var sign: Sign                    // +iso lobe or -iso lobe
    public var isovalue: Double              // signed isovalue used
    public var vertexScalars: [Float]?       // e.g. ESP (Hartree/e) per vertex
    public var vertexColors: [SIMD4<Float>]? // RGBA 0...1 per vertex (ESP color map)
}
// Marching cubes: MarchingCubes.extract(grid: VolumeGrid, isovalue: Double) -> IsoSurfaceMesh
//                 MarchingCubes.orbitalLobes(grid:, isovalue:) -> [IsoSurfaceMesh]  // [+iso, -iso]
public struct SpectrumPoint { public var x, y: Double }
public struct SpectrumStick { public var x, height: Double; public var label: String?; public var sourceIndex: Int }
public struct Spectrum { public var points: [SpectrumPoint]; public var sticks: [SpectrumStick];
                         public var xLabel, yLabel: String; public var xAxisReversed: Bool }
```
Lead 5 also defines `AnalysisShell`/`AnalysisBasis`/`MOCoefficientSet` (centers in Bohr). These are the
analysis-side model. Lead 5 adds an adapter from `MolIO.BasisSet` once it's posted.
**Request to Lead 2:** please make `BasisSet` expose fchk arrays as-is: shell types (0, 1, -1, ±2, ±3, ±4),
primitives per shell, shell-to-atom map (1-based OK), primitive exponents, contraction coefficients,
P(S=P) contraction coefficients, shell coordinates (Bohr), plus alpha/beta MO coefficients
(nMO×nBasis, row = MO), MO energies, and electron counts (alpha, beta).

### MolIO `BasisSet` / `Wavefunction` (Lead 2 → Lead 5), `Sources/MolIO/BasisSet.swift`
Atomic units throughout: centers in Bohr, exponents in Bohr^-2. Contraction coefficients multiply
NORMALIZED primitives, so the evaluator applies N(alpha, l). In-shell function order:
`BasisSet.cartesianOrder(l)` (d: XX YY ZZ XY XZ YZ; f: XXX YYY ZZZ XYY XXY XXZ XZZ YZZ YYZ XYZ) or
`BasisSet.pureOrder(l)` (m = 0, +1, -1, +2, -2, ...). An SP shell gives 4 functions: s, px, py, pz.
```swift
public struct BasisSet { public var shells: [Shell]; var functionCount: Int; var shellOffsets: [Int]
  public struct Shell { atomIndex: Int; center: Vec3 /*Bohr*/; angularMomentum: Int; isSP: Bool; isPure: Bool
                        exponents: [Double]; coefficients: [Double]; spCoefficients: [Double]?
                        var fchkShellType: Int; var functionCount: Int }
  static func cartesianOrder(_ l: Int) -> [(Int, Int, Int)]; static func pureOrder(_ l: Int) -> [Int] }
public struct MOCoefficients { energies: [Double] /*Hartree*/; coefficients: [Double] /*row-major [mo][mu]*/
                               basisCount: Int; occupiedCount: Int; var orbitalCount: Int; func orbital(_ mo: Int) -> ArraySlice<Double> }
public struct Wavefunction { basis: BasisSet; alpha: MOCoefficients; beta: MOCoefficients?
                             totalDensity: [Double]?; spinDensity: [Double]? /*lower-triangular packed*/
                             atomicNumbers: [Int]; nuclearPositions: [Vec3] /*Bohr*/; betaElectronCount: Int?; var isUnrestricted; var homoIndex: Int? }
```
Flat fchk-style views (per Lead 5's request): `BasisSet.shellTypes`, `primitivesPerShell`, `shellToAtomMap` (1-based),
`primitiveExponents`, `contractionCoefficients`, `spContractionCoefficients`, `shellCoordinates` (Bohr);
`Wavefunction.alphaElectrons` / `betaElectrons`. `Wavefunction.betaElectronCount` is stored as read from the file, so the counts are correct for ROHF too.
You get a `Wavefunction` from `try FormattedCheckpoint.read(url:)` via `.wavefunction`.

## MolRender public API (Lead 3), in `Sources/MolRender`
Import `MolRender`. Everything below is `@MainActor` unless it is a value type or a pure `enum` helper.
- `MoleculeRenderer` (class, `RenderTypes.swift`/`MoleculeRenderer.swift`). Keep one per document window (store it in a model object, not in a SwiftUI view struct).
  - `init(molecule: Molecule = .init(), options: RenderOptions = .init())`
  - `setMolecule(_:fitCamera:)` rebuilds the scene; `updatePositions(_ [Vec3])` is the fast path when only coordinates change.
  - `options: RenderOptions` (assign a modified copy; only changed layers are rebuilt).
  - `selection: Set<Int>` (atom indices), `hovered: PickTarget` (read-only), `autoSelect: Bool = true` (built-in: click selects, shift adds, cmd toggles, double-click selects the fragment, click on empty space clears, shift-drag rubber-band adds).
  - Callbacks: `onPick: (PickEvent) -> Void` (`target: PickTarget` = `.atom(i)` / `.bond(i)` / `.none`, `modifiers: NSEvent.ModifierFlags`, `clickCount`, `location`), `onHover: (PickTarget) -> Void`, `onSelectionChange: (Set<Int>) -> Void`, `onBoxSelect: (Set<Int>, NSEvent.ModifierFlags) -> Void`.
  - `pick(at: CGPoint) -> PickTarget`, `fitToView(animated:)`, `boundingSphere()`.
  - `camera: CameraController`: `orbit(dx:dy:)`, `pan(dx:dy:viewSize:)`, `zoom(by:)`, `roll(radians:)`, `fit(center:radius:animated:)`, `setStandardView(_ StandardView, animated:)` (`.front .back .left .right .top .bottom .alongX .alongY .alongZ`), `projection`, `target`, `distance`, `onChange`.
  - Isosurfaces: `setIsosurface(Isosurface)`, `removeIsosurface(id:)`, `removeAllIsosurfaces()`. `Isosurface(id:meshes: [IsoSurfaceMesh])` (Lead 5's mesh type, used as is) with `positiveColor`, `negativeColor`, `opacity`, `mode: SurfaceDisplayMode` (`.solid/.mesh/.points`), `visible`.
  - Vibrations: `vibration: VibrationAnimator` (`play(NormalMode)`, `stop()`, `amplitude`, `cyclesPerSecond`), `showDisplacementArrows(_ NormalMode?, scale:color:)`.
  - Trajectories (opt/scan/IRC steps): `trajectory: TrajectoryPlayer` (`load([Molecule])`, `show(frame:)`, `play()`, `pause()`, `framesPerSecond`, `loops`, `onFrameChange`).
  - Export: `renderImage(ImageExportOptions) -> CGImage`, `exportImage(to:options:)`. `ImageExportOptions` has `widthPoints`, `heightPoints`, `dpi`, `transparentBackground`, `format: .png/.tiff`. Animation export (GIF/movie) is in `AnimationExporter.swift`.
- `MoleculeSceneView(renderer:)`, a SwiftUI `NSViewRepresentable` that hosts `renderer.view` (`MoleculeSCNView`). Input: drag to orbit, option-drag or right-drag to pan, shift-drag for rubber-band selection, mouse wheel or pinch to zoom, two-finger scroll to orbit (shift+scroll pans), two-finger rotate to roll. Keys: F fits the view, 1/3/7 give the front/right/top views (ctrl gives the opposite), O toggles orthographic.
- `RenderOptions` (Codable value): `style` (`.ballAndStick/.tube/.wireframe/.spaceFilling`), `colorScheme` (`.element`, `.charge(range:)` red-white-blue, `.uniform(RGBA)`), `atomScale`, `bondRadius`, `tubeRadius`, `wireWidth`, `splitBondColors`, `bondColor`, `showBondOrders`, `dashedBonds: Set<AtomPair>`, `showHydrogens`, `geometryQuality`, `labelMode` (`.none/.element/.index/.elementIndex/.charge/.custom`), `labelSize`, `measurements: [Measurement]` (`.distance/.angle/.dihedral`, `value(in:)`), `unitCell: UnitCell?`, `showUnitCell`, `theme` (`.light/.dark/.black/.white`), `backgroundColor`, `transparentBackground`, `material` (`.matte/.glossy/.metallic/.flat`), `depthCueing`, `ambientOcclusion`, `projection`, `selectionColor`, `hoverColor`.
- Helpers: `RGBA`, `ColorMap.charge(_:range:)`, `ElementPalette` (delegates to MolCore `Elements`), `RenderMetrics.atomRadius/bondRadius/atomColors`, `UnitCell(a:b:c:alpha:beta:gamma:)`.

## Build hygiene (55 agents share this tree)
- Always build with a private scratch path so SwiftPM locks don't collide:
  `swift build --scratch-path .build-<your-agent-name>`. You can also add `--target <YourModule>`.
- Run checks: `swift run --scratch-path .build-<name> vibeview-check <filter>`.
- No XCTest or Swift Testing, because they're unavailable on this machine.
- SwiftUI macro plugins are missing with Command Line Tools: do NOT use `@State`, `#Preview` or `@Entry` (error "plugin for module 'SwiftUIMacros' not found"). `@StateObject`, `@ObservedObject`, `@Binding`, `@Environment`, `@AppStorage`, `@FocusState`, `@FocusedValue` and `@Observable` work. Hold view state in a small `ObservableObject` via `@StateObject`. (Lead 4)
- **Do not run git commit, stash, reset or checkout.** The coordinator commits.
- Don't add third-party package dependencies. Use Apple frameworks only: Foundation, simd,
  SceneKit, SwiftUI, AppKit, Charts and Accelerate.
- Keep every module compiling at all times. Before you finish, run a full `swift build`
  with your scratch path.

## Change log
- Lead 5: `Harness.swift` `allChecks` was `[Check]`, which can't hold the per-team `[Check]` arrays its comment asks for. It's now `([ Checks.x, ... ] as [[Check]]).flatMap { $0 }`. Register one array per line, e.g. `Checks.core,`.
- Lead 1, MolCore API v1 (additive only; existing shared types unchanged). Invariant: `atoms[i].id == i`, editing ops renumber ids. Angles in degrees, lengths in Å.
  - `Vector.swift`: `degToRad`, `radToDeg`, `VecMath.distance/angle/dihedral/rotate(_:about:axis:degrees:)/rotationMatrix/perpendicular/symmetricEigen`.
  - `Topology.swift`: `Molecule.adjacency()`, `neighbors(of:)`, `bondIndex`, `bond(between:and:)`, `areBonded`, `degree(of:)`, `bondOrderSum(of:)`, `positions` (get/set), `renumberAtomIDs()`, `normalizeBonds()`, `distance(i,j)`, `angle(i,j,k)`, `dihedral(i,j,k,l)`.
  - `Elements.swift`: `Element` (atomicNumber, symbol, name, mass, covalentRadius, vdwRadius, color [Jmol], cpkColor, valences, electronegativity, defaultValence), `Elements.all` (index = Z, 0 = dummy "X"), `Elements.element(_:)`, `element(symbol:)`, `atomicNumber(symbol:)`, `symbol(_:)`, `Atom.element`, `Atom.symbol`.
  - `SpatialHash.swift`: `NeighborGrid(positions:cellSize:)`, `.neighbors(of:within:)`, `.pairs(within:)`.
  - `BondPerception.swift`: `Molecule.perceiveBonds(tolerance:keepExistingOrders:)`, `perceivedBonds(tolerance:)`.
  - `Rings.swift`: `Molecule.smallestSetOfSmallestRings()`, `ringAtomMask()`, `isRingBond(_:_:)`.
  - `Formula.swift`: `Molecule.formula` (Hill), `molecularWeight`, `elementCounts`, `monoisotopicMass`.
  - `BondOrders.swift`: `Molecule.perceiveBondOrders()`, `formalCharges()`, `aromaticRings()`, `kekulize()`.
  - `Geometry.swift`: `Geometry.*` (centroid, centerOfMass, inertiaTensor, principalAxes, rmsd, kabsch), `Molecule.centroid`, `centerOfMass`, `inertiaTensor()`, `principalAxes()`, `translated(by:)`, `transformed(rotation:translation:)`, `rmsd(to:)`, `aligned(onto:)`.
  - `Editing.swift`: `Molecule.addAtom`, `removeAtoms(_:) -> [Int?]` (old to new map), `addBond`, `removeBond`, `setBondOrder`, `fragments()`, `fragment(containing:)`, `setDistance/setAngle/setDihedral(..., moving:)`, `atomsOnSide(of:from:)`.
  - `ZMatrix.swift`: `ZMatrix`, `ZMatrixRow`, `ZValue`, `ZMatrix.parse(_:)`, `cartesian()`, `molecule()`, `ZMatrix(molecule:)`, `formatted()`.
  - `PointGroup.swift`: `PointGroupResult`, `SymmetryElement`, `Symmetry.detect(_:tolerance:)`, `Symmetry.symmetrize(_:tolerance:)`, `Symmetry.standardOrientation(_:)`.
  - `Selection.swift` / `DocumentModel.swift`: `AtomSelection`, `MoleculeDocumentModel` (value type with undo/redo).
  - `SMILES.swift`: `Molecule.smiles()`, `Molecule(smiles:)`.
  Final signatures are documented in the doc comments of each file. A later entry will note any deviations.
