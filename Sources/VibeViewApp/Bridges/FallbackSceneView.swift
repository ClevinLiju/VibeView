import SwiftUI
import SceneKit
import AppKit
import MolCore

enum ViewportPick {
    case atom(Int)
    case bond(Int, Int)
    case empty(Vec3)
}

struct ViewportStyle: Equatable {
    var renderStyle: String = "ballAndStick"
    var backgroundHex: String = "#1E1F24"
    var showLabels: Bool = false
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
    var isDark: Bool { let c = usingColorSpace(.sRGB) ?? self; return (0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent) < 0.5 }
}

/// Self-contained SceneKit ball-and-stick viewer used until the MolRender viewer is swapped in.
struct FallbackSceneView: NSViewRepresentable {
    var molecule: Molecule
    var selection: Set<Int>
    var selectedBond: Bond?
    var measurePicks: [Int]
    var modeDisplacements: [Vec3]?
    var amplitude: Double
    var style: ViewportStyle
    var onPick: (ViewportPick, NSEvent.ModifierFlags) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = context.coordinator.scene
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling4X
        v.pointOfView = context.coordinator.cameraNode
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        v.addGestureRecognizer(click)
        context.coordinator.view = v
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        context.coordinator.update(self, view: v)
    }

    @MainActor
    final class Coordinator: NSObject {
        let scene = SCNScene()
        let cameraNode = SCNNode()
        let root = SCNNode()
        weak var view: SCNView?
        var parent: FallbackSceneView?
        var lastMol: Molecule?
        var lastSel: Set<Int> = []
        var lastBond: Bond?
        var lastPicks: [Int] = []
        var lastStyle: ViewportStyle?
        var atomNodes: [SCNNode] = []
        var bondNodes: [(Bond, SCNNode)] = []
        var disp: [Vec3]?
        var amp = 0.5
        var timer: Timer?
        var t0 = CACurrentMediaTime()
        var framed = false
        static var materialCache: [String: SCNMaterial] = [:]

        override init() {
            super.init()
            let cam = SCNCamera()
            cam.zNear = 0.1; cam.zFar = 500; cam.fieldOfView = 40
            cameraNode.camera = cam
            cameraNode.position = SCNVector3(0, 0, 10)
            let light = SCNLight(); light.type = .omni; light.intensity = 900
            let ln = SCNNode(); ln.light = light; ln.position = SCNVector3(3, 5, 6)
            cameraNode.addChildNode(ln)
            scene.rootNode.addChildNode(cameraNode)
            let amb = SCNLight(); amb.type = .ambient; amb.intensity = 450
            let an = SCNNode(); an.light = amb
            scene.rootNode.addChildNode(an)
            scene.rootNode.addChildNode(root)
        }

        func material(_ z: Int) -> SCNMaterial {
            let key = "z\(z)"
            if let m = Self.materialCache[key] { return m }
            let c = ElementInfo.rgb(z)
            let m = SCNMaterial()
            m.diffuse.contents = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
            m.specular.contents = NSColor(white: 0.6, alpha: 1)
            m.shininess = 0.4
            m.lightingModel = .blinn
            Self.materialCache[key] = m
            return m
        }

        func update(_ p: FallbackSceneView, view v: SCNView) {
            parent = p
            amp = p.amplitude
            if lastStyle != p.style {
                v.backgroundColor = NSColor(hex: p.style.backgroundHex)
            }
            let needRebuild = lastMol != p.molecule || lastStyle != p.style
            let needHighlight = needRebuild || lastSel != p.selection || lastBond != p.selectedBond || lastPicks != p.measurePicks
            if needRebuild { rebuild(p) }
            if needHighlight { highlight(p) }
            lastMol = p.molecule; lastStyle = p.style; lastSel = p.selection; lastBond = p.selectedBond; lastPicks = p.measurePicks
            disp = p.modeDisplacements
            if let d = disp, d.count == p.molecule.atoms.count, timer == nil {
                t0 = CACurrentMediaTime()
                timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                }
            } else if disp == nil, timer != nil {
                timer?.invalidate(); timer = nil
                if let m = lastMol { positions(m.atoms.map(\.position)) }
            }
        }

        var radii: (atom: (Int) -> Double, bond: Double) {
            switch parent?.style.renderStyle ?? "ballAndStick" {
            case "spaceFill": return ({ ElementInfo.vdwRadius($0) * 0.95 }, 0.0)
            case "sticks": return ({ _ in 0.12 }, 0.12)
            case "wireframe": return ({ _ in 0.05 }, 0.03)
            default: return ({ max(0.2, ElementInfo.covalentRadius($0) * 0.5) }, 0.1)
            }
        }

        func rebuild(_ p: FallbackSceneView) {
            root.childNodes.forEach { $0.removeFromParentNode() }
            atomNodes = []; bondNodes = []
            let m = p.molecule
            let (rad, br) = radii
            for (i, a) in m.atoms.enumerated() {
                let s = SCNSphere(radius: rad(a.atomicNumber))
                s.segmentCount = 24
                s.firstMaterial = material(a.atomicNumber)
                let n = SCNNode(geometry: s)
                n.name = "atom:\(i)"
                n.simdPosition = SIMD3<Float>(Float(a.position.x), Float(a.position.y), Float(a.position.z))
                root.addChildNode(n)
                atomNodes.append(n)
                if p.style.showLabels {
                    let t = SCNText(string: "\(ElementInfo.symbol(a.atomicNumber))\(i + 1)", extrusionDepth: 0.1)
                    t.font = NSFont.systemFont(ofSize: 1)
                    t.flatness = 0.1
                    t.firstMaterial?.diffuse.contents = NSColor(hex: p.style.backgroundHex).isDark ? NSColor.white : NSColor.black
                    let tn = SCNNode(geometry: t)
                    tn.scale = SCNVector3(0.22, 0.22, 0.22)
                    tn.position = SCNVector3(rad(a.atomicNumber), rad(a.atomicNumber), 0)
                    let bc = SCNBillboardConstraint(); bc.freeAxes = .all
                    tn.constraints = [bc]
                    n.addChildNode(tn)
                }
            }
            if br > 0 {
                for b in m.bonds where b.a < m.atoms.count && b.b < m.atoms.count {
                    let c = SCNNode()
                    c.name = "bond:\(b.a)-\(b.b)"
                    let offsets: [Float]
                    let r = br * (b.order == .triple ? 0.55 : (b.order == .double || b.order == .aromatic) ? 0.65 : 1.0)
                    switch b.order {
                    case .single: offsets = [0]
                    case .double, .aromatic: offsets = [-Float(br) * 1.1, Float(br) * 1.1]
                    case .triple: offsets = [-Float(br) * 1.7, 0, Float(br) * 1.7]
                    }
                    for o in offsets {
                        let cyl = SCNCylinder(radius: r, height: 1)
                        cyl.radialSegmentCount = 12
                        let mat = SCNMaterial(); mat.diffuse.contents = NSColor(white: b.order == .aromatic ? 0.65 : 0.72, alpha: 1)
                        cyl.firstMaterial = mat
                        let cn = SCNNode(geometry: cyl)
                        cn.position = SCNVector3(o, 0, 0)
                        c.addChildNode(cn)
                    }
                    root.addChildNode(c)
                    bondNodes.append((b, c))
                }
            }
            positions(m.atoms.map(\.position))
            if !framed, !m.atoms.isEmpty { frame(m); framed = true }
            if m.atoms.isEmpty { framed = false }
        }

        func positions(_ pos: [Vec3]) {
            guard pos.count == atomNodes.count else { return }
            for (i, n) in atomNodes.enumerated() {
                n.simdPosition = SIMD3<Float>(Float(pos[i].x), Float(pos[i].y), Float(pos[i].z))
            }
            for (b, n) in bondNodes {
                let p1 = pos[b.a], p2 = pos[b.b]
                let d = p2 - p1
                let len = simd_length(d)
                guard len > 1e-6 else { continue }
                n.simdPosition = SIMD3<Float>(Float((p1.x + p2.x) / 2), Float((p1.y + p2.y) / 2), Float((p1.z + p2.z) / 2))
                let dir = SIMD3<Float>(Float(d.x / len), Float(d.y / len), Float(d.z / len))
                n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir)
                n.simdScale = SIMD3<Float>(1, Float(len), 1)
            }
        }

        func tick() {
            guard let d = disp, let m = lastMol, d.count == m.atoms.count else { return }
            let s = sin((CACurrentMediaTime() - t0) * 2 * .pi * 1.2) * amp
            positions(zip(m.atoms, d).map { $0.position + $1 * s })
        }

        func frame(_ m: Molecule) {
            let bb = m.boundingBox()
            let c = (bb.min + bb.max) / 2
            let r = max(simd_length(bb.max - bb.min) / 2, 1.0)
            let dist = Float(r * 2.6 + 2)
            cameraNode.simdPosition = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z) + dist)
            cameraNode.simdOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            view?.defaultCameraController.target = SCNVector3(c.x, c.y, c.z)
        }

        func highlight(_ p: FallbackSceneView) {
            for n in atomNodes { n.childNodes.filter { $0.name == "halo" }.forEach { $0.removeFromParentNode() } }
            for (_, n) in bondNodes { n.childNodes.filter { $0.name == "halo" }.forEach { $0.removeFromParentNode() } }
            func halo(_ color: NSColor, _ n: SCNNode) {
                guard let s = n.geometry as? SCNSphere else { return }
                let g = SCNSphere(radius: s.radius * 1.35)
                let mat = SCNMaterial(); mat.diffuse.contents = color.withAlphaComponent(0.35)
                mat.emission.contents = color.withAlphaComponent(0.5)
                mat.isDoubleSided = false
                mat.writesToDepthBuffer = false
                g.firstMaterial = mat
                let h = SCNNode(geometry: g); h.name = "halo"
                n.addChildNode(h)
            }
            for i in p.selection where atomNodes.indices.contains(i) { halo(.systemYellow, atomNodes[i]) }
            for i in p.measurePicks where atomNodes.indices.contains(i) { halo(.systemCyan, atomNodes[i]) }
            if let sb = p.selectedBond, let (_, n) = bondNodes.first(where: { $0.0.a == sb.a && $0.0.b == sb.b }) {
                let cyl = SCNCylinder(radius: 0.22, height: 1)
                let mat = SCNMaterial(); mat.diffuse.contents = NSColor.systemYellow.withAlphaComponent(0.4)
                mat.emission.contents = NSColor.systemYellow.withAlphaComponent(0.4)
                mat.writesToDepthBuffer = false
                cyl.firstMaterial = mat
                let h = SCNNode(geometry: cyl); h.name = "halo"
                n.addChildNode(h)
            }
        }

        @objc func clicked(_ g: NSClickGestureRecognizer) {
            guard let v = view, let p = parent else { return }
            let loc = g.location(in: v)
            let mods = NSApp.currentEvent?.modifierFlags ?? []
            let hits = v.hitTest(loc, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true])
            for h in hits {
                var n: SCNNode? = h.node
                while let node = n {
                    if let name = node.name {
                        if name.hasPrefix("atom:"), let i = Int(name.dropFirst(5)) { p.onPick(.atom(i), mods); return }
                        if name.hasPrefix("bond:") {
                            let parts = name.dropFirst(5).split(separator: "-").compactMap { Int($0) }
                            if parts.count == 2 { p.onPick(.bond(parts[0], parts[1]), mods); return }
                        }
                    }
                    n = node.parent
                }
            }
            let c = p.molecule.atoms.isEmpty ? Vec3.zero : p.molecule.centroid
            let proj = v.projectPoint(SCNVector3(c.x, c.y, c.z))
            let w = v.unprojectPoint(SCNVector3(loc.x, loc.y, proj.z))
            p.onPick(.empty(Vec3(Double(w.x), Double(w.y), Double(w.z))), mods)
        }
    }
}
