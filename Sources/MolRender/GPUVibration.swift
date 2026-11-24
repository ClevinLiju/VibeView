import SceneKit
import simd
import MolCore

/// GPU-driven normal-mode animation (round 3).
///
/// While a mode plays, the per-atom/per-bond layers are hidden and replaced by one merged mesh per
/// chunk whose vertices carry the mode's displacement as extra attributes. A geometry shader modifier
/// computes `base + amplitude * sin(omega * (t - t0)) * displacement` on the GPU every frame, so the
/// main thread does no per-frame geometry work and camera rotation stays smooth. The scalar
/// f = amplitude * sin(phase) is a single shader uniform written once per frame from the SceneKit render
/// thread (`VibrationClock`, an SCNSceneRendererDelegate), with the phase computed in Double precision.
///
/// Vertex attributes (all Float):
/// - `position` / `normal`: base pose.
/// - `tangent.xyz`: displacement of this vertex (atom displacement, or the bond-axis interpolation
///   dA + s (dB - dA) at the vertex's axial parameter s); `tangent.w`: tube radius (0 for atoms and lines).
/// - `texcoord0/1/2`: (D0.x, D0.y), (D0.z, dD.x), (dD.y, dD.z) with D0 = base bond vector and
///   dD = dB - dA. For bond vertices the shader rebuilds the ring around the displaced axis, rotating
///   the radial offset from the base direction onto the displaced one (Rodrigues), so bonds stretch AND
///   turn correctly instead of shearing.
enum GPUVibration {
    static let nodeName = "vibration:gpu"
    static let atomChunk = 4096
    static let bondChunk = 8192

    static let geometryModifier = """
    #pragma arguments
    float vibF;
    #pragma body
    float4 vibTg = _geometry.tangent;
    float3 vibP = _geometry.position.xyz;
    if (vibTg.w > 0.0) {
        float2 c0 = _geometry.texcoords[0];
        float2 c1 = _geometry.texcoords[1];
        float2 c2 = _geometry.texcoords[2];
        float3 d0 = float3(c0.x, c0.y, c1.x);
        float3 dd = float3(c1.y, c2.x, c2.y);
        float3 n = _geometry.normal;
        float3 axisPoint = vibP - n * vibTg.w;
        float l0 = length(d0);
        float3 d1 = d0 + vibF * dd;
        float l1 = length(d1);
        float3 rn = n;
        if (l0 > 1e-6 && l1 > 1e-6) {
            float3 a = d0 / l0;
            float3 b = d1 / l1;
            float3 v = cross(a, b);
            float c = dot(a, b);
            if (c > -0.999) { rn = n * c + cross(v, n) + v * (dot(v, n) / (1.0 + c)); }
        }
        vibP = axisPoint + vibF * vibTg.xyz + rn * vibTg.w;
        _geometry.normal = rn;
    } else {
        vibP += vibF * vibTg.xyz;
    }
    _geometry.position.xyz = vibP;
    """

    /// Set the current scalar factor f = amplitude * sin(phase) on every vibration material.
    static func apply(f: Float, to materials: [SCNMaterial]) {
        let v = NSNumber(value: f)
        for m in materials { m.setValue(v, forKey: "vibF") }
    }

    /// Per-vertex buffers being assembled for one chunk.
    struct Buffers {
        var pos: [SIMD3<Float>] = [], nrm: [SIMD3<Float>] = [], tan: [SIMD4<Float>] = []
        var t0: [SIMD2<Float>] = [], t1: [SIMD2<Float>] = [], t2: [SIMD2<Float>] = []
        var col: [SIMD4<Float>] = []
        init(capacity n: Int = 0) {
            pos.reserveCapacity(n); nrm.reserveCapacity(n); tan.reserveCapacity(n)
            t0.reserveCapacity(n); t1.reserveCapacity(n); t2.reserveCapacity(n)
        }
        mutating func add(_ p: SIMD3<Float>, _ n: SIMD3<Float>, disp: SIMD3<Float>, radius: Float, d0: SIMD3<Float>, dd: SIMD3<Float>) {
            pos.append(p); nrm.append(n); tan.append(SIMD4(disp, radius))
            t0.append(SIMD2(d0.x, d0.y)); t1.append(SIMD2(d0.z, dd.x)); t2.append(SIMD2(dd.y, dd.z))
        }
        var count: Int { pos.count }
    }

    static func src<T>(_ v: [T], _ sem: SCNGeometrySource.Semantic, comps: Int, channel: Int = 0) -> SCNGeometrySource {
        let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: sem, vectorCount: v.count, usesFloatComponents: true,
                                 componentsPerVector: comps, bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<T>.stride)
    }

    static func geometry(_ b: Buffers, elements: [SCNGeometryElement], withColors: Bool) -> SCNGeometry {
        var sources = [src(b.pos, .vertex, comps: 3), src(b.nrm, .normal, comps: 3), src(b.tan, .tangent, comps: 4),
                       src(b.t0, .texcoord, comps: 2), src(b.t1, .texcoord, comps: 2), src(b.t2, .texcoord, comps: 2)]
        if withColors { sources.append(src(b.col, .color, comps: 4)) }
        return SCNGeometry(sources: sources, elements: elements)
    }

    /// Material copy carrying the shader modifier (the shared library materials are left untouched).
    static func vibMaterial(_ base: SCNMaterial) -> SCNMaterial {
        let m = base.copy() as! SCNMaterial
        m.shaderModifiers = [.geometry: geometryModifier]
        return m
    }

    /// Build the vibrating layer for `molecule` (base pose) and `mode`. Returns the node and its materials.
    static func build(molecule: Molecule, mode: NormalMode, options: RenderOptions, colors: [RGBA],
                      materials lib: MaterialLibrary) -> (SCNNode, [SCNMaterial]) {
        let root = SCNNode(); root.name = nodeName
        var mats: [SCNMaterial] = []
        var matCache: [RGBA: SCNMaterial] = [:]
        func mat(_ c: RGBA) -> SCNMaterial {
            if let m = matCache[c] { return m }
            let m = vibMaterial(lib.material(for: c)); matCache[c] = m; mats.append(m); return m
        }
        let disp = mode.displacements.map { SIMD3<Float>($0) }

        // Atoms
        let idx = AtomLayerBuilder.displayedAtoms(molecule: molecule, options: options)
        if !idx.isEmpty {
            let lon = idx.count > AtomLayerBuilder.mergeThreshold
                ? SceneQuality.mergedSphereSegments(quality: options.geometryQuality, atomCount: idx.count)
                : SceneQuality.sphereSegments(quality: options.geometryQuality, atomCount: idx.count)
            let tpl = MergedGeometry.unitSphere(lon: lon, lat: max(4, lon * 2 / 3))
            var start = 0, k = 0
            while start < idx.count {
                let end = min(idx.count, start + atomChunk)
                var b = Buffers(capacity: (end - start) * tpl.positions.count); var groups = MergedGeometry.Groups()
                for i in idx[start..<end] {
                    let a = molecule.atoms[i]
                    let c = SIMD3<Float>(a.position), r = Float(AtomLayerBuilder.radius(of: a, options: options))
                    let base = UInt32(b.count)
                    let d = i < disp.count ? disp[i] : .zero
                    for t in tpl.positions { b.add(c + t * r, t, disp: d, radius: 0, d0: .zero, dd: .zero) }
                    let color = i < colors.count ? colors[i] : ElementPalette.color(a.atomicNumber)
                    let g = groups.index(for: color)
                    for t in tpl.indices { groups.indices[g].append(t + base) }
                }
                let geo = geometry(b, elements: groups.indices.map(MergedGeometry.element), withColors: false)
                geo.materials = groups.order.map(mat)
                let n = SCNNode(geometry: geo); n.name = "vibration:atoms:\(k)"
                root.addChildNode(n)
                start = end; k += 1
            }
        }

        // Bonds
        let segs = BondGeometry.renderSegments(molecule: molecule, options: options, colors: colors)
        func axial(_ p: Vec3, _ s: BondSegment) -> (disp: SIMD3<Float>, d0: SIMD3<Float>, dd: SIMD3<Float>) {
            let bond = molecule.bonds[s.bondIndex]
            let pa = molecule.atoms[bond.a].position, pb = molecule.atoms[bond.b].position
            let D = pb - pa
            let L2 = simd_length_squared(D)
            let t = L2 > 1e-12 ? max(0, min(1, simd_dot(p - pa, D) / L2)) : 0
            let da = bond.a < disp.count ? disp[bond.a] : .zero, db = bond.b < disp.count ? disp[bond.b] : .zero
            return (da + Float(t) * (db - da), SIMD3<Float>(D), db - da)
        }
        if !segs.isEmpty && options.style == .wireframe {
            var b = Buffers()
            var ix: [UInt32] = []
            for s in segs {
                let c = SIMD4<Float>(Float(s.color.r), Float(s.color.g), Float(s.color.b), Float(s.color.a))
                for p in [s.start, s.end] {
                    let ax = axial(p, s)
                    ix.append(UInt32(b.count))
                    b.add(SIMD3<Float>(p), SIMD3(0, 0, 1), disp: ax.disp, radius: 0, d0: .zero, dd: .zero)
                    b.col.append(c)
                }
            }
            let el = SCNGeometryElement(data: ix.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .line,
                                        primitiveCount: segs.count, bytesPerIndex: 4)
            let geo = geometry(b, elements: [el], withColors: true)
            let m = vibMaterial(lib.lineMaterial()); mats.append(m)
            geo.materials = [m]
            let n = SCNNode(geometry: geo); n.name = "vibration:bonds:wire"
            root.addChildNode(n)
        } else if !segs.isEmpty {
            let radial = molecule.atoms.count > AtomLayerBuilder.mergeThreshold
                ? SceneQuality.mergedCylinderSegments(quality: options.geometryQuality, segmentCount: segs.count)
                : SceneQuality.cylinderSegments(quality: options.geometryQuality, segmentCount: segs.count)
            let ring: [SIMD2<Float>] = (0..<radial).map { k in let a = 2 * Float.pi * Float(k) / Float(radial); return SIMD2(cos(a), sin(a)) }
            var start = 0, k = 0
            while start < segs.count {
                let end = min(segs.count, start + bondChunk)
                var b = Buffers(capacity: (end - start) * 2 * radial); var groups = MergedGeometry.Groups()
                for s in segs[start..<end] {
                    let a = SIMD3<Float>(s.start), e = SIMD3<Float>(s.end)
                    let d = e - a, len = simd_length(d)
                    let y = len > 1e-9 ? d / len : SIMD3<Float>(0, 1, 0)
                    let helper: SIMD3<Float> = abs(y.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
                    let u = simd_normalize(simd_cross(helper, y)), v = simd_cross(y, u)
                    let r = Float(s.radius)
                    let axA = axial(s.start, s), axB = axial(s.end, s)
                    let base = UInt32(b.count)
                    for q in ring { let dir = u * q.x + v * q.y; b.add(a + dir * r, dir, disp: axA.disp, radius: r, d0: axA.d0, dd: axA.dd) }
                    for q in ring { let dir = u * q.x + v * q.y; b.add(e + dir * r, dir, disp: axB.disp, radius: r, d0: axB.d0, dd: axB.dd) }
                    let g = groups.index(for: s.color)
                    for j in 0..<radial {
                        let b0 = base + UInt32(j), b1 = base + UInt32((j + 1) % radial)
                        let t0 = b0 + UInt32(radial), t1 = b1 + UInt32(radial)
                        groups.indices[g].append(b0); groups.indices[g].append(b1); groups.indices[g].append(t0)
                        groups.indices[g].append(b1); groups.indices[g].append(t1); groups.indices[g].append(t0)
                    }
                }
                let geo = geometry(b, elements: groups.indices.map(MergedGeometry.element), withColors: false)
                geo.materials = groups.order.map(mat)
                let n = SCNNode(geometry: geo); n.name = "vibration:bonds:\(k)"
                root.addChildNode(n)
                start = end; k += 1
            }
        }
        return (root, mats)
    }

    /// CPU reference of what the shader does to one bond-ring vertex (used by checks).
    static func displacedRingVertex(position p: SIMD3<Float>, normal n: SIMD3<Float>, disp: SIMD3<Float>, radius r: Float,
                                    d0: SIMD3<Float>, dd: SIMD3<Float>, f: Float) -> SIMD3<Float> {
        guard r > 0 else { return p + f * disp }
        let axisPoint = p - n * r
        let l0 = simd_length(d0), d1 = d0 + f * dd, l1 = simd_length(d1)
        var rn = n
        if l0 > 1e-6, l1 > 1e-6 {
            let a = d0 / l0, b = d1 / l1, v = simd_cross(a, b), c = simd_dot(a, b)
            if c > -0.999 { rn = n * c + simd_cross(v, n) + v * (simd_dot(v, n) / (1 + c)) }
        }
        return axisPoint + f * disp + rn * r
    }
}

/// Render-thread clock for the GPU vibration: once per frame (SceneKit's update phase, render thread)
/// it writes `vibF = amplitude * sin(omega * (now - t0))` to the vibration materials. Thread-safe.
final class VibrationClock: NSObject, SCNSceneRendererDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var materials: [SCNMaterial] = []
    private var amplitude = 0.0, omega = 0.0, t0 = 0.0
    private var heldPhase: Double? = nil
    /// Frames the delegate has driven (diagnostics/checks).
    private(set) var frameCount = 0

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func configure(materials: [SCNMaterial], amplitude: Double, cyclesPerSecond: Double, phase: Double, held: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.materials = materials
        self.amplitude = amplitude
        omega = 2 * .pi * cyclesPerSecond
        t0 = Self.now() - (omega > 0 ? phase / omega : 0)
        heldPhase = held ? phase : nil
        GPUVibration.apply(f: Float(amplitude * sin(phase)), to: materials)
    }

    /// Current phase (radians) on the shared clock.
    func phase(at t: Double = VibrationClock.now()) -> Double {
        lock.lock(); defer { lock.unlock() }
        return heldPhase ?? omega * (t - t0)
    }
    var currentAmplitude: Double { lock.lock(); defer { lock.unlock() }; return amplitude }

    func clear() { lock.lock(); materials = []; heldPhase = nil; lock.unlock() }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        let mats = materials, ph = heldPhase ?? omega * (Self.now() - t0), a = amplitude
        if !mats.isEmpty { frameCount += 1 }
        lock.unlock()
        if !mats.isEmpty { GPUVibration.apply(f: Float(a * sin(ph)), to: mats) }
    }
}
