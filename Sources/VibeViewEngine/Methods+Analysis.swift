import Foundation
import MolCore
import MolIO
import MolAnalysis
import MolSIMD

extension Engine {
    // MARK: Geometry

    func analysisMeasure(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let a = try p.ints("atoms")
        let m: Molecule
        if let f = p.optInt("frame"), let fm = d.frame(f) { m = fm } else { m = d.molecule }
        try checkAtoms(a, in: m)
        guard Set(a).count == a.count else { throw RPCError.badRequest("atoms must be distinct") }
        switch a.count {
        case 2: return ["kind": "distance", "value": .number(m.distance(a[0], a[1])), "unit": "Å"]
        case 3: return ["kind": "angle", "value": .number(m.angle(a[0], a[1], a[2])), "unit": "°"]
        case 4: return ["kind": "dihedral", "value": .number(m.dihedral(a[0], a[1], a[2], a[3])), "unit": "°"]
        default: throw RPCError.badRequest("measure needs 2, 3 or 4 atoms")
        }
    }

    func analysisSymmetry(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let tol = p.optDouble("tolerance") ?? 0.1
        let r = Symmetry.detect(d.molecule, tolerance: tol)
        func name(_ e: SymmetryElement) -> String {
            switch e {
            case .identity: return "E"
            case .inversion: return "i"
            case .rotation(_, let n): return n == 0 ? "C∞" : "C\(n)"
            case .reflection: return "σ"
            case .improperRotation(_, let n): return "S\(n)"
            }
        }
        func axis(_ e: SymmetryElement) -> JSON {
            switch e {
            case .rotation(let a, _), .improperRotation(let a, _): return JSONShapes.vec3(a)
            case .reflection(let n): return JSONShapes.vec3(n)
            default: return .null
            }
        }
        return obj([
            "pointGroup": r.schoenflies, "elements": r.elements.map(name), "order": r.order,
            "principalAxis": r.principalAxis.map { JSONShapes.vec3($0) } ?? JSON.null,
            "elementDetails": JSON.array(r.elements.map { obj(["name": name($0), "axis": axis($0)]) }),
            "symmetryNumber": Thermochemistry.rotationalSymmetryNumber(pointGroup: r.schoenflies),
        ])
    }

    // MARK: Orbitals

    func analysisOrbitals(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let diagram: OrbitalLevelDiagram
        if let wf = d.wavefunction {
            diagram = OrbitalLevelDiagram(wavefunction: wf)
        } else if let orbs = d.result?.orbitals, !orbs.isEmpty {
            diagram = OrbitalLevelDiagram(orbitals: orbs)
        } else {
            throw RPCError.notFound("this document has no orbitals")
        }
        let cols: [JSON] = diagram.columns.map { c in
            obj(["spin": c.spin.rawValue, "homoLumoGapEV": c.homoLumoGapEV,
                 "levels": JSON.array(c.levels.map { l in
                     obj(["energy": l.energy, "energyEV": l.energyEV, "orbitalIndices": l.orbitalIndices, "occupation": l.occupation,
                          "isHOMO": l.isHOMO, "isLUMO": l.isLUMO, "label": l.label, "degeneracy": l.degeneracy])
                 })])
        }
        return obj(["columns": JSON.array(cols), "homoLumoGapEV": diagram.homoLumoGapEV,
                    "canDrawSurfaces": d.wavefunction != nil || d.volumes.contains { $0.name.hasPrefix("MO ") }])
    }

    static func quality(_ s: String?) throws -> OrbitalGridQuality {
        guard let s else { return .normal }
        guard let q = OrbitalGridQuality(rawValue: s) else { throw RPCError.badRequest("quality must be draft, normal, high or ultra") }
        return q
    }

    func analysisOrbitalSurface(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let orbital = try p.int("orbital")
        let spinName = p.optString("spin") ?? "alpha"
        guard spinName == "alpha" || spinName == "beta" else { throw RPCError.badRequest("spin must be alpha or beta") }
        let iso = abs(p.optDouble("isovalue") ?? 0.02)
        guard iso > 0 else { throw RPCError.badRequest("isovalue must be non-zero") }
        let quality = try Engine.quality(p.optString("quality"))
        let smoothing = max(0, min(p.optInt("smoothing") ?? 0, 50))
        guard let service = d.surfaces else {
            // Fall back to an orbital cube ("MO n", 1-based) when there is no wavefunction.
            if let k = d.volumes.firstIndex(where: { $0.name == "MO \(orbital + 1)" }) {
                let meshes = try await Offload.run(AsyncCapture((d, k, iso))) { input, _ -> [IsoSurfaceMesh]? in
                    let (d, k, iso) = input.value
                    return MarchingCubes.orbitalLobes(grid: d.volumes[k].grid, isovalue: iso)
                }
                let info = d.result?.orbitals.first { $0.index == orbital + 1 && $0.spin != .beta }
                return obj(["meshes": JSON.array(meshes.map(JSONShapes.mesh)), "energy": info?.energy ?? 0,
                            "isOccupied": info?.occupied ?? false, "isHOMO": false, "isLUMO": false, "source": "cube"])
            }
            throw RPCError.notFound("no wavefunction: open a .fchk or Molden file (or an orbital cube) to draw orbital surfaces")
        }
        let req = OrbitalSurfaceRequest(orbital: orbital, spin: spinName == "beta" ? .beta : .alpha, isovalue: iso,
                                        quality: quality, smoothing: smoothing,
                                        maxTriangles: p.optInt("maxTriangles") ?? 400_000)
        let r = try await service.surfaces(req)
        try Task.checkCancellation()
        return obj([
            "meshes": JSON.array(r.meshes.map(JSONShapes.mesh)), "energy": r.energy, "energyEV": r.energy * PhysConst.hartreeToEV,
            "isOccupied": r.isOccupied, "isHOMO": r.isHOMO, "isLUMO": r.isLUMO, "occupation": r.occupation,
            "timings": JSON.object(r.timings.mapValues { .number($0) }), "gridPoints": r.grid.pointCount, "source": "wavefunction",
        ])
    }

    func analysisDensitySurface(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        guard let wf = d.wavefunction else { throw RPCError.notFound("no wavefunction: open a .fchk or Molden file to draw densities") }
        let kind = p.optString("kind") ?? "total"
        guard kind == "total" || kind == "spin" else { throw RPCError.badRequest("kind must be total or spin") }
        let iso = abs(p.optDouble("isovalue") ?? (kind == "spin" ? 0.002 : 0.0004))
        guard iso > 0 else { throw RPCError.badRequest("isovalue must be non-zero") }
        let quality = try Engine.quality(p.optString("quality"))
        let esp = p.bool("esp", default: false)
        var espRange: ClosedRange<Double>? = nil
        if let lo = p.optDouble("espMin"), let hi = p.optDouble("espMax"), lo < hi { espRange = lo...hi }
        // All grid work runs in one detached task. GridSpec / VolumeGrid hold SIMD3<Double> inline, so they are
        // created and consumed inside the task and never cross an async boundary (Windows codegen bug, see
        // MolSIMD/AsyncCapture.swift). Only arrays of meshes come back.
        let meshes = try await Offload.run(AsyncCapture((wf, kind, iso, quality, esp, espRange))) { input, cancelled -> [IsoSurfaceMesh]? in
            let (wf, kind, iso, quality, esp, espRange) = input.value
            let grid = GridSpec.adaptive(wf, quality: quality)
            // Occupied orbitals with weights (alpha +1, beta +1 or −1 for spin density).
            let nA = min(wf.alphaElectrons, wf.alpha.orbitalCount)
            let bset = wf.beta ?? wf.alpha
            let nB = min(wf.betaElectrons, bset.orbitalCount)
            var orbs: [[Double]] = (0..<nA).map { Array(wf.alpha.orbital($0)) }
            var w = [Double](repeating: 1, count: orbs.count)
            orbs += (0..<nB).map { Array(bset.orbital($0)) }
            w += [Double](repeating: kind == "spin" ? -1 : 1, count: nB)
            guard let rho = OrbitalEvaluator(wavefunction: wf).evaluate(.orbitalDensity(orbitals: orbs, weights: w), on: grid,
                                                                        isCancelled: cancelled), !cancelled() else { return nil }
            if kind == "spin" { return MarchingCubes.orbitalLobes(grid: rho, isovalue: iso) }
            var mesh = MarchingCubes.extract(grid: rho, isovalue: iso)
            if esp, !mesh.vertices.isEmpty, !cancelled() {
                let values = ElectrostaticPotential(wavefunction: wf).evaluate(atAngstrom: mesh.vertices)
                mesh.vertexScalars = values.map(Float.init)
                ESPColorMap.colorize(&mesh, range: espRange)
            }
            return [mesh]
        }
        return ["meshes": .array(meshes.map(JSONShapes.mesh))]
    }

    func analysisVolumeSurface(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let name = try p.string("name")
        guard let k = d.volumes.firstIndex(where: { $0.name == name }) else {
            throw RPCError.notFound("no volume '\(name)' (have: \(d.volumes.map { $0.name }.joined(separator: ", ")))")
        }
        let iso = p.optDouble("isovalue") ?? 0.02
        guard iso != 0 else { throw RPCError.badRequest("isovalue must be non-zero") }
        let signedParam = p.optBool("signed")
        // The VolumeGrid is read inside the worker (it holds SIMD values inline; see Offload).
        let r = try await Offload.run(AsyncCapture((d, k, iso, signedParam))) { input, _ -> ([IsoSurfaceMesh], Double, Double, [Int])? in
            let (d, k, iso, signedParam) = input.value
            let g = d.volumes[k].grid
            let lo = g.values.min() ?? 0, hi = g.values.max() ?? 0
            // Signed data (orbitals, spin densities): both lobes. Positive-only data (densities): one surface.
            let signed = signedParam ?? (Double(lo) < -abs(iso))
            let meshes = signed ? MarchingCubes.orbitalLobes(grid: g, isovalue: abs(iso)) : [MarchingCubes.extract(grid: g, isovalue: iso)]
            return (meshes, Double(lo), Double(hi), g.counts)
        }
        return obj(["meshes": JSON.array(r.0.map(JSONShapes.mesh)), "min": r.1, "max": r.2, "counts": r.3])
    }

    // MARK: Vibrations, spectra, thermochemistry

    func analysisModes(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let modes = d.result?.normalModes ?? []
        guard !modes.isEmpty else { return ["modes": []] }
        let geom = d.resultGeometry
        let usable = modes.allSatisfy { $0.displacements.count == geom.atoms.count }
        let labels = usable ? VibrationalModeAnalysis.labels(for: modes, molecule: geom) : modes.map { _ in "" }
        let out: [JSON] = modes.enumerated().map { k, m in
            obj(["index": k, "frequency": m.frequency, "irIntensity": m.irIntensity, "ramanActivity": m.ramanActivity,
                 "symmetry": m.symmetry, "label": labels.indices.contains(k) ? labels[k] : "",
                 "isImaginary": m.frequency < 0, "reducedMass": m.reducedMass, "forceConstant": m.forceConstant,
                 "displacements": JSON.array(m.displacements.map { JSONShapes.vec3($0) })])
        }
        return ["modes": .array(out), "geometry": JSONShapes.molecule(geom)]
    }

    /// The line shape requested by `analysis.spectrum`: `shape` is "gaussian" | "lorentzian" | "voigt" | "pseudoVoigt" |
    /// "sticks"; `fwhm` (Gaussian, Lorentzian, pseudo-Voigt), `gaussianFWHM` + `lorentzianFWHM` (Voigt; each defaults to
    /// fwhm / 2) and `eta` (pseudo-Voigt Lorentzian fraction, default 0.5). Widths are FWHM in the broadening unit.
    private func spectrumProfile(_ p: Params, defaultKind: LineShapeKind, defaultFWHM: Double) throws -> LineShapeProfile {
        var kind = defaultKind
        if let raw = p.optString("shape") {
            switch raw.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "") {
            case "gaussian": kind = .gaussian
            case "lorentzian": kind = .lorentzian
            case "voigt": kind = .voigt
            case "pseudovoigt": kind = .pseudoVoigt
            case "sticks", "sticksonly", "none": kind = .sticks
            default: throw RPCError.badRequest("shape must be gaussian, lorentzian, voigt, pseudoVoigt or sticks")
            }
        }
        let fwhm = p.optDouble("fwhm") ?? defaultFWHM
        let profile = LineShapeProfile(kind: kind, fwhm: fwhm, gaussianFWHM: p.optDouble("gaussianFWHM"),
                                       lorentzianFWHM: p.optDouble("lorentzianFWHM"), eta: p.optDouble("eta") ?? 0.5)
        switch kind {
        case .gaussian, .lorentzian, .pseudoVoigt:
            guard fwhm > 0 else { throw RPCError.badRequest("fwhm must be positive") }
        case .voigt:
            guard profile.gaussianFWHM >= 0, profile.lorentzianFWHM >= 0, profile.gaussianFWHM + profile.lorentzianFWHM > 0
            else { throw RPCError.badRequest("gaussianFWHM and lorentzianFWHM must be non-negative and not both zero") }
            return .voigt(gaussianFWHM: profile.gaussianFWHM, lorentzianFWHM: profile.lorentzianFWHM)
        case .sticks: break
        }
        return profile
    }

    /// Spectrum JSON plus the line shape actually used: `shape`, effective `fwhm` (the Voigt band's own FWHM),
    /// the Voigt / pseudo-Voigt parameters, `normalization` ("height" | "area") and `transmittance` (+ `baseline` 100).
    private func spectrumJSON(_ s: Spectrum, profile: LineShapeProfile, normalization: String, transmittance: Bool = false) -> JSON {
        var j = JSONShapes.spectrum(s)
        if case .object(var o) = j {
            o["shape"] = .string(profile.kind.rawValue)
            o["fwhm"] = .number(profile.effectiveFWHM)
            if profile.kind == .voigt {
                o["gaussianFWHM"] = .number(profile.gaussianFWHM); o["lorentzianFWHM"] = .number(profile.lorentzianFWHM)
            }
            if profile.kind == .pseudoVoigt { o["eta"] = .number(profile.eta) }
            o["normalization"] = .string(normalization)
            o["transmittance"] = .bool(transmittance)
            if transmittance { o["baseline"] = .number(100) }
            j = .object(o)
        }
        return j
    }

    func analysisSpectrum(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        let kind = try p.string("kind")
        let fwhm = p.optDouble("fwhm")
        let scale = p.optDouble("scale") ?? 1
        switch kind {
        case "ir", "raman":
            let modes = d.result?.normalModes ?? []
            guard !modes.isEmpty else { throw RPCError.notFound("this document has no vibrational modes") }
            let lo = p.optDouble("xMin") ?? 0, hi = p.optDouble("xMax") ?? 4000
            guard lo < hi else { throw RPCError.badRequest("xMin must be below xMax") }
            let n = max(2, min(p.optInt("points") ?? 2000, 100_000))
            let profile = try spectrumProfile(p, defaultKind: .lorentzian, defaultFWHM: 10)
            if kind == "ir" {
                let s = SpectrumBuilder.ir(modes: modes, scale: scale, profile: profile, range: lo...hi, pointCount: n)
                // %Transmittance on request (Beer–Lambert, strongest band at `minimumPercent`, default 15 %T).
                if p.optBool("transmittance") == true {
                    let t = TransmittanceScale.transmittance(s, minimumPercent: p.optDouble("minimumPercent") ?? 15)
                    return spectrumJSON(t, profile: profile, normalization: "height", transmittance: true)
                }
                return spectrumJSON(s, profile: profile, normalization: "height")
            }
            guard modes.contains(where: { $0.ramanActivity != nil }) else { throw RPCError.notFound("this document has no Raman activities") }
            return spectrumJSON(SpectrumBuilder.raman(modes: modes, scale: scale, profile: profile, range: lo...hi, pointCount: n,
                                                      excitationNM: p.optDouble("excitationNM")),
                                profile: profile, normalization: "height")
        case "uvvis":
            let states = d.result?.excitedStates ?? []
            guard !states.isEmpty else { throw RPCError.notFound("this document has no excited states") }
            let axis = SpectrumAxis(rawValue: p.optString("axis") ?? "wavelengthNM") ?? .wavelengthNM
            var range: ClosedRange<Double>? = nil
            if let lo = p.optDouble("xMin"), let hi = p.optDouble("xMax"), lo < hi { range = lo...hi }
            let profile = try spectrumProfile(p, defaultKind: .gaussian, defaultFWHM: 0.3)   // widths in eV
            return spectrumJSON(SpectrumBuilder.uvVis(states: states, profile: profile, axis: axis, range: range,
                                                      pointCount: max(2, min(p.optInt("points") ?? 1000, 100_000))),
                                profile: profile, normalization: "area")
        case "dos":
            // The density of states keeps the two-shape broadening (Gaussian or Lorentzian).
            var shape: LineShape? = nil
            if let raw = p.optString("shape") {
                guard let s = LineShape(rawValue: raw.lowercased()) else { throw RPCError.badRequest("dos shape must be gaussian or lorentzian") }
                shape = s
            }
            var range: ClosedRange<Double>? = nil
            if let lo = p.optDouble("xMin"), let hi = p.optDouble("xMax"), lo < hi { range = lo...hi }
            let n = max(2, min(p.optInt("points") ?? 1500, 100_000))
            if let wf = d.wavefunction {
                let r = DensityOfStates.compute(wf, fwhmEV: fwhm ?? 0.3, shape: shape ?? .gaussian, rangeEV: range, pointCount: n)
                var j = JSONShapes.spectrum(r.total)
                if case .object(var o) = j {
                    o["occupiedYB64"] = .string(Binary.float32(r.occupied.points.map(\.y)))
                    j = .object(o)
                }
                return j
            }
            let orbs = d.result?.orbitals ?? []
            guard !orbs.isEmpty else { throw RPCError.notFound("this document has no orbital energies") }
            let restricted = !orbs.contains { $0.spin == .beta }
            return JSONShapes.spectrum(DensityOfStates.compute(energies: orbs.map(\.energy),
                                                               weights: orbs.map { _ in restricted ? 2 : 1 },
                                                               fwhmEV: fwhm ?? 0.3, shape: shape ?? .gaussian, rangeEV: range, pointCount: n))
        default:
            throw RPCError.badRequest("kind must be ir, raman, uvvis or dos")
        }
    }

    func analysisThermo(_ p: Params) async throws -> JSON {
        let d = try await store.get(try p.docId())
        guard let r = d.result, !r.normalModes.isEmpty else { throw RPCError.notFound("thermochemistry needs vibrational frequencies") }
        guard let e = r.extras?.thermochemistry?.electronicEnergy ?? r.extras?.finalEnergy ?? r.energies.last else {
            throw RPCError.notFound("thermochemistry needs an electronic energy")
        }
        let geom = d.resultGeometry
        let T = p.optDouble("temperature") ?? 298.15
        let P = p.optDouble("pressure") ?? 1
        guard T > 0, P > 0 else { throw RPCError.badRequest("temperature and pressure must be positive") }
        let input = ThermoInput(molecule: geom, frequencies: r.normalModes.map(\.frequency), electronicEnergy: e,
                                symmetryNumber: p.optInt("symmetryNumber"), multiplicity: geom.multiplicity)
        let t = Thermochemistry.compute(input, temperature: T, pressure: P, frequencyScale: p.optDouble("frequencyScale") ?? 1,
                                        quasiRRHO: p.bool("quasiRRHO", default: false) ? QuasiRRHO() : nil)
        let k = PhysConst.hartreeToKcalMol
        func row(_ label: String, _ h: Double) -> JSON { obj(["label": label, "hartree": h, "kcal": h * k]) }
        return obj([
            "rows": JSON.array([
                row("Electronic energy", t.electronicEnergy),
                row("Zero-point energy", t.zeroPointEnergy),
                row("Thermal correction to energy", t.thermalEnergyCorrection),
                row("Thermal correction to enthalpy", t.enthalpyCorrection),
                row("Thermal correction to Gibbs free energy", t.gibbsCorrection),
                row("E + ZPE", t.sumZPE),
                row("E + thermal energy", t.sumE),
                row("Enthalpy (H)", t.sumH),
                row("Gibbs free energy (G)", t.sumG),
                row("T·S", t.tsTerm),
            ]),
            "temperature": t.temperature, "pressure": t.pressure,
            "entropy": obj(["total": t.entropy, "translational": t.sTrans, "rotational": t.sRot, "vibrational": t.sVib,
                            "electronic": t.sElec, "unit": "cal/(mol·K)"]),
            "heatCapacity": obj(["total": t.cvTotal, "translational": t.cvTrans, "rotational": t.cvRot, "vibrational": t.cvVib,
                                 "unit": "cal/(mol·K)"]),
            "rotationalConstantsGHz": t.rotationalConstantsGHz, "symmetryNumber": t.symmetryNumber, "isLinear": t.isLinear,
            "frequenciesUsed": t.frequenciesUsed,
        ])
    }
}
