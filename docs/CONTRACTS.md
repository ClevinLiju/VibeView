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

## Round 3 — Lead D (Analysis + Compute) API (posted early; additive only, existing members unchanged)
All value types / `enum` namespaces / `actor`s, `Sendable`, never touch the main thread.

**Name lookup (MolCompute, `NameLookup.swift`)** — PubChem PUG REST + PubChem autocomplete, optional NCI CACTUS fallback.
- `LookupCandidate: Sendable, Identifiable, Hashable` — `cid: Int`, `title` (PubChem preferred name), `iupacName: String?`, `formula: String?`,
  `molecularWeight: Double?`, `canonicalSMILES: String?`, `synonyms: [String]` (≤ 5), `casNumber: String?` (from synonyms, check digit validated),
  `depictionURL: URL` (`/compound/cid/<cid>/PNG?image_size=...`), `thumbnail: Data?` (PNG, fetched), `matchKind: .exact/.ambiguous/.spellingSuggestion/.cas/.smiles/.cid`,
  `matchedQuery: String` (the string that actually hit, e.g. the autocomplete correction "caffeine" for "cafeine").
- `LookupQueryKind.classify(_ query) -> .cid(Int) / .cas(String) / .smiles(String) / .name(String)`; `CASNumber.isValid(_:)`.
- `NameLookup(timeout: 10, thumbnailSize: 160, useCactusFallback: true, session: .shared)` (an `actor`, caches results per query and per CID):
  `suggest(_ query: String, limit: Int = 8) async -> [LookupCandidate]` (never throws; empty = nothing / offline; `lastError: ComputeError?` tells why),
  `structure(for candidate: LookupCandidate) async throws -> Molecule` (3D SDF, else 2D + embedding, via `PubChemClient`),
  `autocomplete(_ prefix:, limit:) async -> [String]`. Ambiguous names ("xylene") return several CIDs; typos fall back to autocomplete terms.
  Requests are throttled to ≤ 5/s process-wide (`PubChemThrottle.shared`).
  Implemented: `LookupMatchKind` is a String enum; `NameLookup(..., baseURL:)`; `lastError` is `public private(set)`; public parse helpers
  `parseCIDs/parseProperties/parseSynonyms/parseAutocomplete`; `PubChemThrottle(minInterval: 0.2)`. Names that are not PubChem names but are a class
  ("xylene") resolve the simplest autocomplete terms containing the word → o-/m-/p-xylene (`.ambiguous`); otherwise the top autocomplete terms
  are `.spellingSuggestion`; then CACTUS. CAS-shaped strings with a bad check digit are searched as text. Live (2026-11-24): caffeine → 2519 + salts,
  xylene → 7929/7809/7237 + derivatives, 58-08-2 → 2519 (.cas), aspirin → 2244, cafeine → 2519 (PubChem accepts it as a synonym).

**xtb settings + live logs (MolCompute, `XTBSettings.swift`, `RunLog.swift`)**
- `XTBSettings: Codable, Sendable, Equatable` — `method: XTBMethod` (`.gfn0 .gfn1 .gfn2 .gfnff`; `.gfn0` added), `task: XTBTask`, `optLevel: XTBOptLevel`
  (`.crude .sloppy .loose .normal .tight .vtight .extreme`), `maxCycles: Int?` (`--cycles`), `solvationModel: XTBSolvationModel` (`.none .alpb .gbsa`),
  `solvent: String?` (`XTBSolvents.alpb` / `.gbsa` name lists), `charge: Int?`/`uhf: Int?` (nil = from molecule), `electronicTemperature: Double?` (`--etemp`, K),
  `accuracy: Double?` (`--acc`), `threads: Int` (OMP_NUM_THREADS + `-P`), `extraArguments: [String]`, `timeout: TimeInterval?`.
  `arguments(inputFile: "input.xyz", molecule:) -> [String]`, `commandLine(molecule:) -> String` (preview, shell-quoted), `validationErrors() -> [String]` (empty = OK), `environment(base:)`.
- `RunLogEvent: Sendable` — `.started(runDirectory: URL, commandLine: String)`, `.stdout(String)`, `.stderr(String)`, `.file(name: String, line: String)` (tailed output files), `.finished(exitCode: Int32)`. Events are whole lines.
- `XTBRunner.run(_ molecule, settings: XTBSettings, runDirectory: URL? = nil, onEvent: (@Sendable (RunLogEvent) -> Void)? = nil) async throws -> XTBResult`
  and `XTBRunner.stream(_ molecule, settings:, runDirectory:) -> XTBRunHandle` with `events: AsyncStream<RunLogEvent>`, `runDirectory: URL`, `result: Task<XTBResult, Error>`, `cancel()`.
  `XTBResult` gains `converged: Bool?` (false when the cycle limit was hit, parsed from "FAILED TO CONVERGE"/"not converged"), `optimizationCycles: Int?`, `commandLine: String`.
  The run directory is kept when the caller passes `runDirectory` (or `keepFiles = true`); `workingDirectory` is the path to show/open.
  Implemented: `XTBRunHandle = RunHandle<XTBResult>` / `ProgramRunHandle = RunHandle<ProcessOutput>` (`events`, `runDirectory: URL?`, `result: Task`, `value` (async throws), `cancel()`).
  `stream(...)` always keeps its run directory (temp `vibeview-xtb-<uuid>` when none is passed); `run(...)` without `runDirectory` deletes its temp dir.
  stdout is saved as `xtb.out`; `xtbopt.log` is tailed for optimizations. A non-converged optimization does NOT throw: it returns `converged == false`
  (plus `exitCode`). Invalid settings throw `ComputeError.parse("invalid xtb settings: ...")`. `XTBMethod` gains `.gfn0`, `title`, `id`, Codable; `XTBTask` is Codable.
  Helper: `shellQuoted(_ args:)`. `RunLogEvent.line` gives the text of a line event.
- `ProgramRunner.runLogged(executable:arguments:workingDirectory:environment:stdin:timeout:throwOnFailure:tailFiles: [String] = [], stdoutFile: String? = nil, onEvent:)`
  — same guarantees as `run` (no main thread, cancellation kills the child, timeout), line-buffered events, tails the named files in `workingDirectory` while running
  (ORCA `job.out`, Gaussian `job.log`), optionally tees stdout to `stdoutFile`. `ProgramRunner.stream(...) -> ProgramRunHandle` (`events`, `result`, `cancel()`).

**Orbital quality (MolAnalysis, `OrbitalSurfaces.swift`, `MeshProcessing.swift`)**
- `OrbitalGridQuality: String, Codable, CaseIterable` — `.draft` (0.25 Å), `.normal` (0.15 Å), `.high` (0.10 Å), `.ultra` (0.07 Å); `spacing`, `maxPoints`.
- `GridSpec.adaptive(_ wf: Wavefunction, quality:, threshold: 1e-4)` — box from basis-function extents (most diffuse primitive per atom where |φ| < threshold), not a fixed padding.
- `OrbitalSurfaceRequest: Hashable, Sendable` — `orbital: Int` (0-based), `spin: WavefunctionSurfaces.Spin`, `isovalue: Double = 0.02`, `quality: OrbitalGridQuality = .normal`,
  `smoothing: Int = 0` (Taubin iterations), `maxTriangles: Int? = 400_000` (decimate above).
- `OrbitalSurfaceResult` — `meshes: [IsoSurfaceMesh]` (`[+lobe, −lobe]`), `isOccupied: Bool`, `isHOMO`, `isLUMO`, `energy: Double` (Hartree), `occupation: Double`, `grid: GridSpec`, `timings`.
- `OrbitalSurfaceService` (actor; LRU cache of evaluated grids keyed by (wavefunction id, orbital, spin, quality)):
  `init(wavefunction:, cacheLimit: 8)`, `surfaces(_ request) async throws -> OrbitalSurfaceResult`, `grid(orbital:spin:quality:) async throws -> VolumeGrid`, `clearCache()`.
- `MeshProcessing.weld(_:tolerance:)`, `.taubinSmooth(_:iterations:lambda:mu:)`, `.decimate(_:targetTriangles:)` (vertex clustering), `.recomputeNormals(_:)`,
  `.analyticNormals(_ mesh, evaluator:, coefficients:)` (normals from basis-function gradients).
  Implemented: `OrbitalEvaluator.evaluateOrbitalFast(_:on:isCancelled:)` (single-MO path, folded coefficients, line clipping; used by the service),
  `OrbitalEvaluator.valuesAndGradients(coefficients:atBohr:) -> (values, gradients /*per Bohr*/)`, `MeshProcessing.roughness(_:)`, `OrbitalSurfaceError.orbitalOutOfRange`.
  Cache key is (orbital, spin, quality) per service instance (one service per wavefunction). `timings` keys "grid"/"mesh"/"post" (s). Decimation runs
  before smoothing; marching-cubes normals are kept unless smoothing/decimation ran (call `analyticNormals` explicitly if wanted). `occupation` is 2 (restricted) or 1.
  Fix: `OrbitalEvaluator.evaluateAsync` cancellation now reaches the parallel workers (it used `Task.isCancelled` on non-task threads).

**Analysis models (MolAnalysis, `OrbitalLevels.swift`, `VibrationalAnalysis.swift`)**
- `OrbitalLevelDiagram(wavefunction:)` / `(orbitals: [OrbitalInfo])` — `columns: [Column]` (alpha, and beta for unrestricted), each `levels: [Level]`
  (`energy` Hartree, `energyEV`, `orbitalIndices` (degenerate group, tolerance 1e-3 Eh), `occupation`, `isHOMO`, `isLUMO`, `degeneracy`); `homoLumoGapEV`, `energyRange(window:)`.
- `DensityOfStates.compute(energies: [Double] /*Eh*/, occupations:, fwhmEV: 0.3, shape: .gaussian, rangeEV:, pointCount:) -> Spectrum` (x eV, y states/eV; `sticks` = levels), plus occupied-only partial curve.
- `VibrationalModeAnalysis.analyze(mode: NormalMode, molecule:) -> ModeCharacter` — `label` (e.g. "C=O stretch", "H–C–H bend", "C–H stretch (sym)"),
  `contributions: [InternalContribution]` (coordinate kind .stretch/.bend/.torsion/.outOfPlane, atoms, signed amplitude, percent), `groups`, `dominant`. `labels(for modes:, molecule:) -> [String]`.
  Implemented: percent is an approximate PED (k·s² with typical diagonal force constants). Bonds/orders are perceived when the molecule has none or only single bonds.
  Labels on ORCA h2co: 1192 "C out-of-plane bend", 1265 "O–C–H bend", 1529 "H–C–H bend", 1862 "C=O stretch", 2864 "C–H stretch (sym)", 2923 "C–H stretch (asym)".
  Mixed modes read "mixed: A + B" (top group < 45 %); imaginary modes get " (imaginary)".
- NTO / difference density: only if the data provide transition amplitudes (current Molden/ORCA parsers do not), so they are not part of round 3.

## Round 3 — Lead A (Data + Commands) public API (additive only)
**Kekulé display (MolCore, `BondOrders.swift`) — for Lead B**
- `Molecule.kekuleDisplayOrders() -> [BondOrder]`: parallel to `bonds`; every `.aromatic` bond becomes `.single`/`.double`
  in one alternating Kekulé structure; other bonds unchanged; the molecule is NOT mutated. Best effort (never fails):
  a pyrrole-type N without its H is treated as the donor, else a maximum partial assignment. Deterministic.
- `Molecule.kekuleDisplayMolecule() -> Molecule` (copy with those orders). `kekulize()` unchanged (strict, returns false when impossible).

**Companion-file autoload (MolIO, `Companions.swift`) — for Lead C**
- `MolecularFileLoader.loadWithCompanions(url:) throws -> (file: LoadedMolecularFile, companions: [CompanionFile])`.
  `load(url:)` is unchanged (no companions). `LoadedMolecularFile.companions: [CompanionFile]` (also filled by `CalcJobResults.collect`).
- `CompanionFile` (`url`, `fileName`, `role: .wavefunction .hessian .gradient .trajectory .geometry .volume .log .binary`,
  `used: Bool`, `note: String` e.g. "6 normal modes", "skipped: modes already present", or the `formchk`/`orca_2mkl` hint for .chk/.gbw).
  Show the `used` ones in the UI ("Also loaded: job.molden.input, job.hess"); show `.binary` notes as a tip.
- `CompanionFiles.baseName(of:)` (multi-dot aware: `job.molden.input`, `job_trj.xyz` → `job`), `candidates(for:)`,
  `merge(into:primaryURL:) -> [CompanionFile]`, `isXTBRunDirectory(_:)`, `maxCubeBytes` (64 MB), `maxCubes` (8).
- Rules: the primary file wins; companions fill gaps only (wavefunction+orbital energies from .molden.input/.molden/.fchk/.fch;
  modes from .hess / xtb g98.out; frames from _trj.xyz / xtbopt.log; gradient from .engrad; cubes `job.cube`, `job_*.cube`, `job.*.cube`;
  a sibling .out/.log fills result data when the primary is an fchk/hess/molden). Atom counts must match or the file is skipped.

**MolCommand (`Sources/MolCommand`, `import MolCommand`) — for Lead C (console wiring)**
Atom numbers in command TEXT are 1-based; every index crossing the Swift API (`selection`, `setHidden`, `setColor`,
`addMeasurement`, `CommandValue.atoms`) is 0-based.
- Wiring: make a document-side class conform to `CommandContext`, then
  `let exec = CommandExecutor(context: ctx)`; `exec.execute(line) -> [CommandResult]` (one per `;`/newline-separated
  command; stops at the first failure; a syntax error gives one failed result "syntax error: … (column N)").
  `CommandResult`: `command`, `success`, `messages: [CommandMessage(level: .info/.warning/.error, text)]`, `value: CommandValue?`
  (`.number(Double, unit:)`, `.text`, `.atoms(Set<Int>)`), `text` (messages joined).
- `CommandContext: AnyObject` — required: `molecule: Molecule { get }`, `selection: Set<Int> { get set }`,
  `currentDirectory: URL { get set }`. Optional (default no-op or throws "… is not supported here"):
  `open(urls:)`, `save(to:format: MoleculeFileFormat?)`, `close()`, `setMolecule(_:actionName:)` (one undoable edit; used by
  bond/unbond/element), `setHydrogensVisible(_:)`, `setHidden(_:hidden:)`, `setStyle(DisplayStyleName)` (.ball .stick
  .spacefill .wire), `setColor(CommandColor, atoms:)` (rgba 0…1), `setLabels(LabelKind?)` (.atoms .charges, nil = off),
  `addMeasurement(atoms:)`, `rotate(axis: Axis, degrees:)`, `fitView()`, `viewAlong(Axis)`, `addHydrogens()`,
  `cleanGeometry()`, `runXTBOptimization(options:)` (synchronous entry; start your own Task), `showOrbital(OrbitalSelector)`
  (`.homo(k)` `.lumo(k)` relative, `.index(n)` 1-based), `showVibration(Int?)` (1-based mode; nil = stop),
  `exportImage(to:width:height:)`, `undo() -> Bool`, `redo() -> Bool`. Throw `CommandError("msg")` to report failures.
- Commands (`CommandRegistry.standard`; unique prefixes and aliases resolve, typos get "Did you mean"):
  `open <path…>` (globs), `save <path> [format]`, `cd [path]`, `pwd`, `ls [path|glob]`, `close`, `select [spec]`,
  `hide|show [hydrogens|spec]`, `style ball|stick|spacefill|wire`, `color <spec> <name|#hex>`, `label on|off [atoms|charges]`,
  `measure distance i j | angle i j k | dihedral i j k l`, `turn x|y|z <deg>`, `view [x|y|z]`, `bond i j [order]`,
  `unbond i j`, `element i Sym`, `addh`, `clean`, `info`, `xtb opt [opts…]`, `orbital homo|lumo|homo-N|lumo+N|N`,
  `vibration N|off`, `export image <path> [w h]`, `undo`, `redo`, `help [command]`.
- Syntax: whitespace words, `'…'`/`"…"` quoting with backslash escapes, `;` or newline separates commands, `#` starts a
  comment (except colour literals like `#ff8800`). Atom spec (`AtomSpec.parse`): `all none sel fragment N within R of X`,
  lists `1-5,8,C,O`, combined with `| & ~` or `or and not`, parentheses.
- Console helpers: `CommandHistory` (`add`, `previous()`, `next()`, `resetCursor()`, `save(to:)`, `load(from:)`, max 500),
  `CommandCompleter.candidates(for: line, cursor:, cwd:, molecule:) -> [String]` (each candidate replaces the word being
  completed: command names, paths for open/cd/ls/save/export, keywords, element symbols, colour names),
  `CommandPaths.resolve/expand/hasWildcard`, `CommandRegistry.allNames`, `.lookup(_:)`, `.register(_:)` for app-specific
  commands (`CommandDefinition(name:aliases:usage:summary:handler:)`).
- Checks: `command.*` (`Sources/MolChecks/CommandChecks.swift`, parser + executor against a mock context).

**CalculationInfo for more programs (MolIO) — for Lead C's info card**
- Gaussian (`GaussianRunInfo.swift`, `GaussianLog.runInfo(text:)`, copied to `result.extras.info`): route → method/family/
  reference (R/U/RO, RKS/UKS), basis, job types, SCRF model/solvent, dispersion (EmpiricalDispersion/GD3/GD3BJ), Link 0
  `%nprocshared`/`%mem`, charge/multiplicity, NBasis, alpha+beta electrons, elapsed time (summed over steps); the program version is in `extras.programVersion`.
- Q-Chem (`QChemRunInfo.swift`) and xtb (`XTBRunInfo.swift`, `XTBOutput.info`) fill the same struct. Checks: `io.gaussian.info.*`,
  `io.qchem.info.*`, `io.xtb.info.*`.

**Protein bond orders (MolIO, `PDBResidueBonds.swift`) — for Leads B/C**
- `MolecularFileLoader.load` now returns PDB models passed through `PDBResidueBondOrders.prepared(_:records:)` when they contain
  standard amino-acid ATOM records: missing bonds are added by distance (stated CONECT bonds/orders kept, as `IOBridge.prepared` does),
  then residue templates set orders: backbone C=O (OXT single), one C=O for Asp/Glu/Asn/Gln, one C=N for Arg, Kekulé rings for
  Phe/Tyr/Trp/His (His tautomer from HD1/HE2), everything else in standard residues single. Ligands/water untouched.
  `PDBFormat.parse` is unchanged. Also `PDBResidueBondOrders.apply(to:records:)`, `doubleBondPairs(residue:atomNames:)`,
  `standardResidues`, `PDBFile.withResidueBondOrders()`. Checks: `io.pdb.residueOrders.*` (fixture `TestData/io/pdb_peptide_orders.pdb`).
  Note for Lead C: the app should NOT run `perceiveBondOrders()` on top of these (it only does so when bonds are empty, so it won't).

Change log (Lead A, round 3):
- Release builds: `swift build -c release` of `vibeview-check` failed because the IO check files used `@testable import MolIO`
  (release modules are built without `-enable-testing`; the error is reported as "unable to resolve Swift module dependency … 'MolIO'").
  Fixed by using plain `import MolIO` in `Sources/MolChecks/IOChecks*.swift`. **Do not use `@testable import` in MolChecks.** Package.swift unchanged.
- Lead A (round 3, replacement): the switch to plain `import MolIO` left `IOChecks+RunInfo.swift` / `IOChecks+RunInfo2.swift`
  calling internal helpers, so the debug build of vibeview-check broke. Now public: `OrcaOutput.runInfo(text:inputLines:keywordLines:)`,
  `OrcaOutput.totalRunTime(_:)`, `QChemOutput.runInfo(lines: [Substring])`, `XTBOutput.runInfo(lines: [String])`; RunInfo2 no longer
  uses `@testable`. Still `@testable import MolRender` (Lead B): `RenderChecks+Features.swift` and `RenderChecks+Vibration.swift`,
  which failed `swift build -c release` of vibeview-check in the same way. **Package.swift (release-build fix, Lead A):** every library
  target now has `swiftSettings: testable` = `.unsafeFlags(["-enable-testing"], .when(configuration: .release))`, so `@testable import`
  resolves in release too; `swift build -c release` of the whole package (VibeView + vibeview-check) succeeds. Prefer plain imports anyway.
  Also public now: `Link0.absorb(_:)`, `GaussianZMatrix.rowPositions()` (used by `IOChecks+GaussianInput.swift`).

## Round 3 — Lead B (Visualization) MolRender API, additive only
Existing members are unchanged. New `RenderOptions` keys decode leniently (old saved options still load).
- **GPU vibration (default):** `VibrationAnimator.play` now builds one merged mesh with per-vertex displacement attributes and animates it in a SceneKit geometry shader. The per-frame scalar `amplitude·sin(phase)` is written on the render thread through `view.delegate` (an internal `SCNSceneRendererDelegate`; **don't set `renderer.view.delegate` yourself while a mode plays**). Bonds stretch and rotate correctly, because the shader rebuilds each tube around the displaced axis. The atom/bond layers are hidden while it plays. `renderer.molecule` keeps the base coordinates unless overlays follow atoms (labels, measurements, selection/hover highlight, H-bonds). In that case a light 60 Hz main-thread timer moves only those overlays. New members: `useGPU` (true; false = round-2 CPU path), `isGPUActive`, `lastFrameWork`. Unchanged: `amplitude`/`cyclesPerSecond` (changing them keeps the phase continuous, no rebuild), `pause`/`resume`, `stop`, `tick(time:)` (poses explicitly and holds the GPU mesh at that phase). Calling `updatePositions` during playback rebases the vibration on the new coordinates. `AnimationExporter.exportVibration` suspends a live vibration and resumes it afterwards.
- **Bond orders / aromatic bonds:** every double bond is now drawn as two equal cylinders at ±d about the atom–atom axis, in the ring plane or a stable neighbor plane. Triple bonds are three equal cylinders at 0 and ±d. The radius and spacing scale with the bond radius, and the outer edge stays below 0.8× the smaller atom radius (checked). Constants: `BondGeometry.doubleHalfFactor` (2.0), `offsetFactor` (2.6), `multiRadiusFactor` (0.5). `RenderOptions.aromaticStyle: AromaticBondStyle` has three cases. `.kekule` is the default and draws aromatic bonds as single/double from MolCore `Molecule.kekuleDisplayOrders()`. `.dashed` draws a symmetric solid and dashed pair. `.circle` draws single lines plus a torus inside each aromatic ring (node `bond:ringcircle:<k>`, ball-and-stick below the merge threshold; `BondGeometry.aromaticRingCircles(molecule:options:)`). Known gap: a linear molecule's triple bond uses a fixed perpendicular, so viewed exactly along it the three lines overlap.
- **Drag tools:** `MoleculeRenderer.dragTool: DragTool` (`.rotate` default, `.boxSelect`, `.lasso`, `.moveSelection`). With `.rotate`, shift-option-drag gives a lasso. Lasso semantics: no modifier replaces, shift adds, command or option subtracts. `onLassoSelect: (Set<Int>, ModifierFlags)`. `.moveSelection`: drag translates the selected atoms in the view plane, option-drag rotates them about their centroid, and an empty selection orbits. **`onSelectionMoved: ([Vec3] before, [Vec3] after)`** fires at mouse-up; the renderer already shows `after`, so the app commits it to the document with undo. Programmatic: `performLassoSelect(_:modifiers:)`, `performSelectionDrag(dx:dy:rotate:)`, `atomsInViewPolygon(_:)`. Pure helpers: `LassoMath`, `SelectionCombine`, `SelectionMoveMath`.
- **Hover:** picks are throttled to 120 Hz (the last point of a burst is always picked) and cached per camera/coordinate revision. Tooltip model `HoverTooltip` (`title` "C3", `subtitle` "Carbon"/"Double bond", `rows` [label, value]: charge, label, bonded neighbors, bond length, and the values of any `options.measurements` the target is part of, `accent`, `plainText`), `HoverTooltip.make(_ HoverInfo, molecule:, measurements:)`. **Drop-in UI:** `ZStack { MoleculeSceneView(renderer: r); HoverTooltipOverlay(renderer: r) }` (it doesn't take hits; appears after `r.hoverTooltipModel.showDelay` = 60 ms and moves instantly between targets) or `HoverTooltipView(tooltip:)` directly. `renderer.hoverTooltipModel: HoverTooltipModel` (ObservableObject: `tooltip`, `location`, `visible`).
- **Overlays/features:** `showHydrogenBonds` (false), `hydrogenBondMaxDistance` (2.5 Å H···A), `hydrogenBondMinAngle` (120°), `hydrogenBondColor`; `HydrogenBonds.find(in:maxDistance:minAngle:) -> [HydrogenBond]` (`donor`, `hydrogen`, `acceptor`, `distance`, `angle`), `renderer.hydrogenBonds()`. Slab: `slabNear`/`slabFar: Double?` (Å in front of/behind the camera target; nil = no clip; follows zoom). `showAxes` (corner xyz triad), `showScaleBar` (Å bar at the target depth); both are live-view CALayer overlays and don't appear in exported images. `centerOnDoubleClick` (true; double-clicking an atom also re-targets the camera), `centerOn(atom:animated:)`. Live measurement monitors: `measurementValues() -> [Double]`, `onMeasurementValues: ([Double]) -> Void` (fires on every overlay rebuild: trajectory frames, vibration overlay updates, edits). `worldPerPointAtTarget()`.
- **Orbitals / isosurfaces:**
  - `SurfaceDisplayMode` is now `.solid, .transparent, .wireframe, .mesh, .points`; `.mesh` is kept as a legacy alias for line rendering. Lead C should add UI entries for `.transparent` and `.wireframe`.
  - `OrbitalColorScheme` (`positive`, `negative`, `.occupied` red/blue, `.virtual` green/yellow, `forOccupation(occupied:)`). Pick it by occupation with `Isosurface(id:meshes:colors:)` or `isosurface.apply(scheme)`. `positiveColor`/`negativeColor` stay user-editable.
  - `Isosurface.smoothingIterations` (4, Taubin smoothing that preserves volume, after welding) and `transparentOpacity` (0.55).
  - **Default change:** `Isosurface.opacity` is now 1.0 (opaque `.solid`). Set it explicitly for a translucent `.solid`, or use `.transparent`.
  - `IsosurfaceSmoothing.weld/taubin/smoothNormals/signedVolume`.
  - Transparent mode draws back faces, then front faces.
  - `fitToView`/`boundingSphere` now include visible isosurfaces, so lobes are no longer clipped.
  - Grid recommendation for Lead D: 0.15–0.18 Å spacing for small molecules (0.15 Å was smooth for H2CO), keeping the `maxPoints` cap.
