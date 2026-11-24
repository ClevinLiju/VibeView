# VibeView: team contracts

VibeView is an open-source, native macOS (Apple Silicon) molecular builder and viewer for quantum
chemistry, built with Swift, SwiftUI and SceneKit through SwiftPM. **Goal (round 2): the best molecular
visualizer on the Mac, not a clone.** It takes GaussView-class functionality as the floor, adds
multi-program support, built-in fast optimization and online import, and gives a polished native experience.

## Clean-room rule (mandatory)
Do NOT inspect, decompile, disassemble, run, or extract resources from any GaussView installation,
binary, or documentation that isn't public. Work only from public, documented file formats, from
general chemistry knowledge, and from established open algorithms. Use original names, icons and
UI wording, and don't use "Gauss" or "GaussView" in identifiers or UI text.

## Module ownership, round 2 (4 leads × 2 workers; edit only your own directories)
| Lead | Module(s) | Directories |
|---|---|---|
| A Data | MolCore + MolIO: chemistry model, all file formats (Gaussian, ORCA, Q-Chem, xtb, XYZ, PDB, MOL/SDF, CML, cube, fchk/molden) | `Sources/MolCore`, `Sources/MolIO` |
| B Visualization | MolRender: SceneKit scene, styles, AO/lighting, picking, labels, surfaces, animation, export | `Sources/MolRender` |
| C App experience | MolBuild + VibeViewApp: builder tools, UI, calc setup for all programs, job runner, command palette, Quick Look, packaging | `Sources/MolBuild`, `Sources/VibeViewApp`, `scripts/`, `Extensions/` |
| D Analysis + Compute | MolAnalysis + MolCompute: orbitals/density/ESP surfaces, spectra, thermochem; xtb runner, PubChem import | `Sources/MolAnalysis`, `Sources/MolCompute` |

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

## Build hygiene (12 agents share this tree)
- Always build with a private scratch path so SwiftPM locks don't collide:
  `swift build --scratch-path .build-<your-agent-name>`. You can also add `--target <YourModule>`.
- Run checks: `swift run --scratch-path .build-<name> vibeview-check <filter>`.
- **Xcode 27.2 is installed.** Prefix every swift command with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in case the user hasn't switched
  xcode-select. SwiftUI `@State`, `#Preview` and the other macros now work.
- Keep using the `vibeview-check` harness (not XCTest), so there's one suite.
- Run the check binary directly (`.build-<name>/debug/vibeview-check [filter]`). There's no
  `timeout` command on this Mac.
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

## Round 2 — Lead D (Analysis + Compute) public API, `Sources/MolAnalysis`, `Sources/MolCompute`
All APIs are value types / `enum` namespaces, `Sendable`, safe to call off the main actor (do heavy work in `Task.detached`).
Units: Å for grids/meshes (MolCore convention), Hartree for energies unless a unit parameter says otherwise.

**Surfaces (MolAnalysis)**
- `MarchingCubes.extract(grid: VolumeGrid, isovalue: Double) -> IsoSurfaceMesh` — welded vertices, gradient normals, CCW outward; handles non-orthogonal axes. `isovalue < 0` extracts the negative lobe (sign = .negative).
- `MarchingCubes.orbitalLobes(grid:, isovalue:) -> [IsoSurfaceMesh]` — `[+|iso|, -|iso|]` (empty meshes kept so indices are stable).
- `MarchingCubes.surfaceArea(_:)`, `.enclosedVolume(_:)`, `.isClosedManifold(_:)` (diagnostics).
- `GridSpec(origin:axes:counts:)` (Å); `GridSpec.automatic(around positions: [Vec3] /*Å*/, padding: 4.0, spacing: 0.25, maxPoints: 2_000_000)`; `.points(...)`.
- `OrbitalEvaluator(basis: AnalysisBasis)` / `OrbitalEvaluator(wavefunction: Wavefunction)`:
  `moGrid(coefficients: [Double], grid: GridSpec) -> VolumeGrid`, `densityGrid(densityMatrix: [Double] /*n×n full*/, grid:)`,
  `values(coefficients:, atBohr: [Vec3]) -> [Double]`, `basisValues(atBohr:)`. Uses Accelerate (vDSP/BLAS) + `DispatchQueue.concurrentPerform`; checks `isCancelled` closure per slab.
- `WavefunctionSurfaces` (convenience over `Wavefunction`): `orbitalGrid(_ wf:, mo: Int, spin: .alpha/.beta, grid: GridSpec? = nil)`, `densityGrid(_ wf:, grid:)`, `spinDensityGrid(_ wf:, grid:)`, `densityMatrix(_ wf:, spin:)`.
- `ElectrostaticPotential.evaluate(_ wf: Wavefunction, atAngstrom: [SIMD3<Float>]) -> [Double]` (Hartree/e; exact nuclear + electronic via nuclear-attraction integrals);
  `ElectrostaticPotential.mapOntoDensity(_ wf:, isovalue: 0.0004, grid:) -> IsoSurfaceMesh` (vertexScalars = ESP, vertexColors red(−)…white…blue(+));
  `ESPColorMap.colorize(_ mesh: inout IsoSurfaceMesh, range: ClosedRange<Double>?)`.
- From cube files: `CubeSurfaces.lobes(_ cube: CubeFile, gridIndex: Int = 0, isovalue:)`, `CubeSurfaces.mapped(surface: VolumeGrid, isovalue:, property: VolumeGrid) -> IsoSurfaceMesh` (trilinear sampling, any grid shape), `VolumeGrid.sample(atAngstrom:)`.
- Molden: use MolIO's `MoldenFile.parse(text).wavefunction` (primary; all analysis checks use it). `MoldenWavefunctionReader` is legacy, kept only for a cross-check; don't use it in new code.

**Spectra / thermo / profiles (MolAnalysis)** — all return `Spectrum`
- `SpectrumBuilder.ir(modes: [NormalMode], scale: 1.0, fwhm: 10, shape: .lorentzian, range: 0...4000, pointCount: 2000)`, `.raman(modes:, ..., excitationNM: nil)`,
  `.uvVis(states: [ExcitedState], fwhmEV: 0.3, shape: .gaussian, axis: .wavelengthNM/.energyEV/.wavenumber)` (y = ε, L mol⁻¹ cm⁻¹),
  `.ecd(states:, rotatoryStrengths: [Double] /*1e-40 cgs*/, ...)` (y = Δε), `.nmr(shieldings: [NMRShielding], element: Int, reference: NMRReference, fwhm: 0.02)`.
  `Broadening.lorentzian(x:center:fwhm:)`, `.gaussian(...)`, `NMRReference.tms(...)`, `NMRShielding(atomIndex:element:isotropic:)`.
- `Thermochemistry.compute(ThermoInput, temperature: 298.15, pressure: 1 /*atm*/, frequencyScale: 1, quasiRRHO: QuasiRRHO? = nil) -> ThermoResult`
  (ZPE, E/H/G corrections, S components, Cv; Hartree and cal/mol/K). `ThermoInput(molecule:frequencies:electronicEnergy:symmetryNumber:multiplicity:)`;
  `ThermoInput(log: GaussianLog)`.
- `EnergyProfile` (`points: [EnergyProfile.Point]` with `coordinate`, `energy` Hartree, `geometryIndex`), `.fromScan/.fromIRC/.fromOptimization(GaussianLog)`, `relativeEnergies(unit: EnergyUnit, reference: .first/.min/.index(i))`.

**MolCompute**
- `ComputeError`: `.notInstalled(program: String, searched: [String])`, `.offline`, `.timeout`, `.notFound(String)`, `.httpStatus(Int)`, `.processFailed(code: Int32, stderr: String)`, `.parse(String)`, `.cancelled`. `LocalizedError` with clear messages.
- `ProgramRunner.run(executable: URL, arguments:, workingDirectory:, environment:, stdin:) async throws -> ProcessOutput` — cancellable (task cancel terminates the child). Shared runner usable by Lead C for ORCA/Gaussian.
- `ProgramLocator.find(_ name: String, extraDirectories:) -> URL?` (PATH, ~/miniconda3/envs/*/bin, ~/miniconda3/bin, /opt/homebrew/bin, /usr/local/bin).
- `XTBRunner(executable: URL? = nil)`; `XTBRunner.locate() -> URL?`; `run(_ molecule: Molecule, task: .singlePoint/.optimize/.hessian, method: .gfn2, solvent: String? = nil, threads:) async throws -> XTBResult`
  (`energy` Hartree, `molecule` optimized, `frequencies`, `gradientNorm`, `homoLumoGap` eV, `log`). Throws `.notInstalled` when xtb is absent.
- `PubChemClient(timeout: 15)`: `fetch(name:)`, `fetch(cid:)`, `fetch(smiles:) async throws -> PubChemCompound` (`cid`, `molecule`, `title`, `is3D` — false when a 2D record was embedded locally with MolBuild's UFF cleanup).

Change log (Lead D): Package.swift — `MolCompute` now also depends on `MolBuild` (for 2D→3D embedding of PubChem records).
**Request to Lead A (Molden reader):** please convert Molden contraction coefficients to the BasisSet convention (coefficients of NORMALIZED primitives; ORCA's orca_2mkl files carry coefficients that already include N(α,l)), and reorder Cartesian g (Molden order xxxx yyyy zzzz xxxy xxxz yyyx yyyz zzzx zzzy xxyy xxzz yyzz xxyz yyxz zzxy) into `cartesianOrder(4)`. ORCA molden pure f/g functions with |m| ≥ 3 have flipped signs vs. the standard real solid harmonics.
- Lead B (Render), round 2 — MolRender API, additive only (no existing member removed or renamed):
  - `RenderOptions`: new `ambientOcclusionIntensity` (1.6), `ambientOcclusionRadius` (1.4 Å), `shadows` (true, soft key-light shadows), `outline` (false), `outlineWidth` (1.2 pt), `outlineColor: RGBA?` (nil = auto), `resolvedOutlineColor`, `depthOfField` (false), `depthOfFieldFStop` (2.8). **Default change:** `ambientOcclusion` is now `true`. Decoding is lenient (missing keys keep defaults), so persisted options from older builds still load.
  - `RenderLook` (`.studio .whitePaper .darkStage .illustration`), `RenderOptions(look:)`, `mutating apply(_ look:)` (changes only look fields: theme/background/material/AO/shadows/outline/DoF/fog).
  - `MaterialPreset` gains `.satin` and `.ceramic` (switches over it must handle them). All presets except `.flat` are now physically based; `MaterialLibrary.pbrParameters(_:)`.
  - `ImageExportOptions`: `supersampling` (2; render at N× then downsample, on top of 4× MSAA), `look: RenderLook?` (export-only style override), `static pixels(width:height:dpi:)`, `static uhd4K` (3840×2160, transparent), `static publication` (4200×3000 @600 dpi, white paper). Export framing now keeps everything visible in the view when the export aspect is narrower than the view.
  - Hover: `MoleculeRenderer.onHoverInfo: ((HoverInfo) -> Void)?` with `HoverInfo` (`target`, `atom: AtomDetail?` (index, symbol, elementName, position, charge, label, neighbors, summary), `bond: BondDetail?` (atoms, order, length, summary), `location`, `text` tooltip string); `HoverInfo.make(_:molecule:location:)`.
  - `CameraController`: `animate(to:duration:)`, `setState(_:animated:)`, `isAnimating`, `inertiaEnabled`, `isInertiaActive`, `startInertia(orbitVelocity:)`, `startPanInertia(velocity:viewSize:)`, `stopInertia()`, `cancelMotion()`, `advanceAnimation(by:)`. `fit`/`setStandardView` with `animated: true` now interpolate (slerp + log-distance, ease-in-out); `animated: false` stays synchronous. View: drag release keeps inertia, pinch = exp zoom, smart-magnify fits, F/1/3/7 animate.
  - `TrajectoryPlayer`: `interpolates` (true; smooth 60 Hz playback between frames of equal topology), `playhead`, `show(position:)`, `advance(by:)`. `show(frame:)`/`advance()` unchanged.
  - Big structures: above `AtomLayerBuilder.mergeThreshold` displayed atoms, atoms/bonds are drawn as merged per-color meshes (few nodes); picking is analytic and unaffected. `geometryNodeCount(layer:)` therefore reports mesh chunks, not atoms, for big molecules.
- Lead D, final API notes (round 2): implemented as posted above, with these specifics:
  - Grid evaluation: `OrbitalEvaluator.evaluate(_ field: .orbital(c) | .orbitalDensity(orbitals:weights:) | .densityMatrix(P), on: GridSpec, isCancelled:) -> VolumeGrid?` (nil = cancelled); `evaluateAsync(_:on:) async throws` honours Task cancellation.
  - `WavefunctionSurfaces.densityGrid(_ wf, kind: .total/.spin/.alpha/.beta, grid:)`, `defaultGrid(_ wf, padding:spacing:maxPoints:)`, `espMappedDensity(_ wf, isovalue:grid:colorRange:)`, `atomPositions(_ wf)` (Å). Density grids are e/Bohr³.
  - `ElectrostaticPotential(wavefunction:)` / `(basis:densityMatrix:nuclearCharges:nuclearPositions:)`, `.evaluate(atBohr:)`, `.evaluate(atAngstrom: [SIMD3<Float>])`.
  - `CubeSurfaces.lobes(_:gridIndex:isovalue:)`, `.surface(_:gridIndex:isovalue:)`, `.mapped(surface:isovalue:property:colorRange:)`.
  - Spectra/thermo/profile and MolCompute signatures as posted; extras: `Thermochemistry.rotationalSymmetryNumber(pointGroup:)`, `ThermoResult.tsTerm`, `PubChemClient.parseSDF/embed2D`, `ProgramRunner.runStreaming(..., onOutput:)`, `XTBRunner.parse*` helpers. Types are `XTBTask` / `XTBMethod`.
  - Cartesian d/f/g use per-component normalization (fchk convention). MolIO's `MoldenFile` and the local `MoldenWavefunctionReader` are cross-checked to give identical orbitals.
  - Round 2 additions (Lead D2): `MolecularQuadrature(wavefunction:radialPoints:thetaPoints:)` / `(nuclei:atomicNumbers:...)` (Becke atom-centred grid, Bohr; `points`, `weights`, `owner`, `integrate(_:)`, `integratePerAtom(_:)`). `OrbitalEvaluator.evaluate(_ field:, atBohr: [Vec3]) -> [Double]` (any `Field` at arbitrary points). `WavefunctionSurfaces.electronCount(_ wf, kind:)`, `.beckePopulations(_ wf, kind:)`, `.beckeCharges(_ wf)`. Use these for integrals: uniform cube grids under-count core density (water STO-3G 9.94 of 10 e at 0.08 Å).
  - `ThermoInput(orca: OrcaOutput)` (final geometry, vibrational frequencies, electronic energy). `Thermochemistry.calPerMolKToHartreePerK` is now public. Pass `quasiRRHO: QuasiRRHO()` to match ORCA's default entropy.
  - `ProgramRunner` never touches the main thread: it uses `terminationHandler` and background pipe readers, not `waitUntilExit`. Check helper: `computeRunAsync(timeout: 30)` in ComputeChecks.swift spins the main run loop and turns a hang into a FAIL.
  - MolCompute: `XTBRunner.searchDirectories: [String]?` (nil = default search; set = only those dirs, no PATH/`VIBEVIEW_XTB`), `XTBRunner.locate(searchDirectories:)`. An explicit `executable` that isn't executable throws `.notInstalled`. Override the default search with the `VIBEVIEW_XTB` env var. Typical UI flow: `try await XTBRunner().run(mol, task: .optimize)` in a `Task`, and cancel the Task to kill xtb.

## Round 2 — Lead A (Data) public API, `Sources/MolIO` (additive only)
All value types / `enum` namespaces, `Sendable`, no process launching. Units: Å, Hartree, cm⁻¹, Debye unless noted.
Every parser throws `MolIOError` (never traps) on malformed or truncated input; a cut log parses as far as its tables are complete.

**Program-neutral jobs (for Lead C)** — `CalcSpec.swift`, `CalcJob.swift`
- `CalcSpec(program: QCProgram /*.gaussian .orca .qchem .xtb*/, task: CalcTask, method:, basis:, molecule:, title:)` with
  `dispersion: DispersionCorrection?` (`.d3zero .d3bj .d4`), `solvation: Solvation?` (`SolvationModel` `.pcm .cpcm .smd` / xtb `.alpb .gbsa`, solvent name),
  `unrestricted: Bool?`, `excitedStates: ExcitedStatesSpec?` (`roots`, `triplets`, `tammDancoff`), `scan: ScanCoordinate?` (2/3/4 atoms, 0-based),
  `frozenAtoms` (0-based), `computeFrequenciesAfterTS`, `tightOptimization`, `nprocs`, `memoryMB` (total), `extraKeywords`, `extraInput`, `checkpointName`.
  `CalcTask`: `.energy .optimize .frequencies .optimizeAndFrequencies .transitionState .scan .irc .gradient`. `validationErrors() -> [String]` (empty = OK; show these in the UI).
- `CalcInputWriter.write(_ spec) throws -> String` (input text only). Per program: `GaussianJob(spec:)`, `OrcaInput.write(_:)`
  (! line, %pal/%maxcore per core, %tddft, CPCM(solvent) or %cpcm SMD, %geom Scan/Constraints, OptTS with `Calc_Hess true`), `QChemInput.write(_:)`
  (multi-job "@@@" for opt+freq, $rem, $opt FIXED, $scan, $pcm/$solvent or $smx), `XTBInput.arguments(for:)` / `XTBInput.xcontrol(for:)`.
- `CalcJobPlanner.plan(_ spec, baseName: "job") throws -> CalcJobPlan`: `files: [CalcJobFile]` (input first, plus xtb `xcontrol.inp`), `executableName`
  ("orca" / "qchem" / "g16" / "xtb"; ORCA with nprocs > 1 must be launched by absolute path), `arguments`, `environment` (xtb OMP threads),
  `captureStdout` (ORCA, xtb: save stdout as `outputFileName`), `outputFileName`, `companionFileNames`, `write(to: URL)`. Refuses invalid specs and unsafe base names.
- `CalcJobResults.collect(_ plan, directory: URL) throws -> LoadedMolecularFile`: parses the log and merges companion files
  (ORCA `.hess` modes, `.molden.input` wavefunction; Gaussian `.fchk`; xtb `xtbopt.xyz`/`xtbopt.log` frames, `g98.out` modes). Works on running/failed jobs too.

**Loading any file** — `FileLoader.swift`, `MoleculeFileFormat.swift`
- `MolecularFileLoader.load(url:)` / `load(text:format:fileName:) -> LoadedMolecularFile` (`format`, `molecules` (frames, last = show), `result: CalculationResult?`,
  `wavefunction: Wavefunction?`, `volumes`, `sdfProperties`, `program: QCProgram?`). `MolecularFileLoader.write(_:format:)`, `writableFormats`.
- `MoleculeFileFormat.detect(url:)` / `detect(contents:fileName:)`: content is sniffed first, so ORCA / Q-Chem / xtb / Gaussian logs named `.out`, `.log`, `.txt`
  or without extension are told apart by their banners. Cases: `.gaussianInput .gaussianOutput .formattedCheckpoint .cube .xyz .pdb .mol .sdf .cml
  .orcaInput .orcaOutput .orcaHessian .qchemInput .qchemOutput .xtbOutput .molden`; `isCalculationOutput`, `canWrite`, `fileExtensions`.

**Program outputs** (each has `parse(_ text)` / `read(url:)` and a `result: CalculationResult` with `extras` (program, version, finalEnergy, charges by scheme, thermochemistry, HOMO–LUMO gap, convergence))
- ORCA: `OrcaOutput` (steps/energies, convergence cycles, all/vibrational modes + IR/Raman, orbitals (last block = final geometry), Mulliken/Loewdin/Hirshfeld charges and spins,
  TD-DFT/TDA states incl. ORCA 6 global numbering with triplets, scans, thermochemistry, dipole, gradient), `OrcaHessian` (.hess), `OrcaEngrad` (.engrad), `OrcaInputFile` (reader).
- Q-Chem: `QChemOutput` (per-job geometries, SCF energies, opt convergence, modes, orbitals α/β, Mulliken, dipole, TD-DFT, thermo), `QChemInputFile` (reader).
- xtb: `XTBOutput` (stdout), `XTBGradientFile`, `XTBChargesFile`, `XTBTrajectory` (xtbopt.log/xtbscan.log), `XTBG98Frequencies` (g98.out).

**Molden → orbital surfaces (Lead D's request, done)** — `MoldenFormat.swift`
- `MoldenFile.parse(_ text, normalizeContractions: true, primitiveConvention: .unnormalizedPrimitives, applyOrcaSignConvention: true)` / `read(url:)` → `.wavefunction: Wavefunction?`
  in the `BasisSet` convention above (Bohr, coefficients of normalized primitives, Cartesian/pure order as `BasisSet`, Cartesian g reordered, SP shells), plus `orbitals`,
  `normalModes`, `geometries`. Default renormalizes every contracted shell: measured on real ORCA 6.1.1 `orca_2mkl` files, the contracted d shells are not unit-normalized as
  written, and with renormalization C·S·Cᵀ = I to 1e-4 (checked). The ORCA |m| ≥ 3 pure f/g sign flip is implemented from documentation only (no real f/g fixture yet).
  `MoldenWriter.write(...)` round-trips. Lead D can replace `MoldenWavefunctionReader` with `try MoldenFile.parse(text).wavefunction`.

## Coordinator: calculation info (round 2)
- MolCore: `CalculationInfo` (method, methodFamily, exchange/correlation functional, exactExchange, reference,
  basisSet, auxiliaryBasis, dispersion, solvationModel/solvent/dielectric, approximations, jobTypes, keywords,
  charge, multiplicity, electrons, basisFunctions, integrationGrid, cores, memoryPerCoreMB, wallTimeSeconds),
  plus the derived `levelOfTheory` and `solvationLabel`. Stored as `CalculationExtras.info` (optional, additive).
- MolIO: `OrcaOutput.info` is filled by `OrcaRunInfo.swift` from the input echo, the "utilizes ..." banners and SCF
  SETTINGS, and copied to `result.extras.info`. Checks: `io.orca.info.*`. Other parsers (Gaussian, Q-Chem, xtb)
  may fill the same struct.
- App: `CalculationInfoCard` (viewport, top-left, shown automatically, toggled with View ▸ Calculation Info) and
  setup rows at the top of the Summary tab, both built from `CalculationInfoRows`.

## Round 3 ownership (4 leads × 2 workers). The app is now called **VibeView**.
| Lead | Owns |
|---|---|
| A Data + Commands | `Sources/MolCore`, `Sources/MolIO`, `Sources/MolCommand` (new: command-line language: parser, registry, executor protocol) |
| B Visualization | `Sources/MolRender` |
| C App | `Sources/MolBuild`, `Sources/VibeViewApp`, `scripts/`, `Extensions/`, `README.md`, `docs/INSTALL.md` |
| D Analysis + Compute | `Sources/MolAnalysis`, `Sources/MolCompute` |
Module and directory names keep their Mol* prefix internally; only the user-facing product, bundle and executable are renamed.
Feature ideas may come from general knowledge of GaussView, Avogadro 2, ChimeraX and VMD, but
**never copy their code, icons, wording or layouts** (clean-room rule).
