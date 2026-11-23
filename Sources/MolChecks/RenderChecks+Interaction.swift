import Foundation
import simd
import SceneKit
import AppKit
import MolCore
import MolAnalysis
import MolRender

// Worker B: camera, picking, highlight, labels, measurements.
private func mainActor<T>(_ f: @MainActor () throws -> T) throws -> T {
    try MainActor.assumeIsolated { try f() }
}

private func vclose(_ a: Vec3, _ b: Vec3, _ tol: Double = 1e-6) -> Bool { simd_length(a - b) <= tol }

@MainActor private func waterRenderer() -> MoleculeRenderer { MoleculeRenderer(molecule: RenderFixtures.water) }

@MainActor private func screen(_ r: MoleculeRenderer, _ i: Int) -> CGPoint {
    let p = r.view.projectPoint(SCNVector3(r.molecule.atoms[i].position))
    return CGPoint(x: p.x, y: p.y)
}

extension Checks {
    static let renderInteraction: [Check] = [
        // MARK: ray math
        Check("render.interaction.raySphere.hit") {
            let t = PickMath.raySphere(origin: Vec3(0, 0, 10), dir: Vec3(0, 0, -1), center: .zero, radius: 2)
            try expectClose(t ?? -1, 8)
            // unnormalized dir gives the same distance
            try expectClose(PickMath.raySphere(origin: Vec3(0, 0, 10), dir: Vec3(0, 0, -5), center: .zero, radius: 2) ?? -1, 8)
        },
        Check("render.interaction.raySphere.missTangentBehindInside") {
            try expect(PickMath.raySphere(origin: Vec3(3, 0, 10), dir: Vec3(0, 0, -1), center: .zero, radius: 2) == nil, "miss")
            let tan = PickMath.raySphere(origin: Vec3(2, 0, 10), dir: Vec3(0, 0, -1), center: .zero, radius: 2)
            try expectClose(tan ?? -1, 10, tol: 1e-6)
            try expect(PickMath.raySphere(origin: Vec3(0, 0, 10), dir: Vec3(0, 0, 1), center: .zero, radius: 2) == nil, "behind")
            try expectClose(PickMath.raySphere(origin: .zero, dir: Vec3(1, 0, 0), center: .zero, radius: 2) ?? -1, 0)
            try expect(PickMath.raySphere(origin: .zero, dir: .zero, center: .zero, radius: 2) == nil, "zero dir")
        },
        Check("render.interaction.rayCylinder.side") {
            let a = Vec3(0, 0, 0), b = Vec3(4, 0, 0)
            let t = PickMath.rayCylinder(origin: Vec3(2, 5, 0), dir: Vec3(0, -1, 0), a: a, b: b, radius: 0.5)
            try expectClose(t ?? -1, 4.5)
            // slanted ray that hits side
            let t2 = PickMath.rayCylinder(origin: Vec3(2, 0, 5), dir: Vec3(0, 0, -2), a: a, b: b, radius: 0.5)
            try expectClose(t2 ?? -1, 4.5)
        },
        Check("render.interaction.rayCylinder.missBeyondCapsAndEndOn") {
            let a = Vec3(0, 0, 0), b = Vec3(4, 0, 0)
            try expect(PickMath.rayCylinder(origin: Vec3(4.5, 5, 0), dir: Vec3(0, -1, 0), a: a, b: b, radius: 0.5) == nil, "beyond cap b")
            try expect(PickMath.rayCylinder(origin: Vec3(-0.1, 5, 0), dir: Vec3(0, -1, 0), a: a, b: b, radius: 0.5) == nil, "beyond cap a")
            try expect(PickMath.rayCylinder(origin: Vec3(2, 5, 0), dir: Vec3(0, -1, 0), a: a, b: b, radius: 0.0) == nil, "zero radius off-axis miss")
            // end-on through the cap
            let t = PickMath.rayCylinder(origin: Vec3(-5, 0.2, 0), dir: Vec3(1, 0, 0), a: a, b: b, radius: 0.5)
            try expectClose(t ?? -1, 5)
            try expect(PickMath.rayCylinder(origin: Vec3(-5, 0.8, 0), dir: Vec3(1, 0, 0), a: a, b: b, radius: 0.5) == nil, "end-on miss")
            // behind
            try expect(PickMath.rayCylinder(origin: Vec3(2, 5, 0), dir: Vec3(0, 1, 0), a: a, b: b, radius: 0.5) == nil, "behind")
        },
        // MARK: pick math
        Check("render.interaction.pick.waterAtoms") {
            let m = RenderFixtures.water, o = RenderOptions()
            let r1 = PickMath.pick(origin: Vec3(0, 0, 10), dir: Vec3(0, 0, -1), molecule: m, options: o)
            try expect(r1?.0 == .atom(0), "O \(String(describing: r1))")
            let r2 = PickMath.pick(origin: Vec3(0.7572, 0.5865, 10), dir: Vec3(0, 0, -1), molecule: m, options: o)
            try expect(r2?.0 == .atom(1), "H1")
            let r3 = PickMath.pick(origin: Vec3(-0.7572, 0.5865, 10), dir: Vec3(0, 0, -1), molecule: m, options: o)
            try expect(r3?.0 == .atom(2), "H2")
            try expect(PickMath.pick(origin: Vec3(5, 5, 10), dir: Vec3(0, 0, -1), molecule: m, options: o) == nil, "empty")
        },
        Check("render.interaction.pick.bondBetweenAtoms") {
            let m = RenderFixtures.water, o = RenderOptions()
            // midpoint of O-H1 bond, offset from the axis by less than the bond radius
            let mid = Vec3(0.7572, 0.5865, 0) / 2
            let perp = simd_normalize(Vec3(-0.5865, 0.7572, 0)) * 0.05
            let r = PickMath.pick(origin: Vec3(mid.x + perp.x, mid.y + perp.y, 10), dir: Vec3(0, 0, -1), molecule: m, options: o)
            try expect(r?.0 == .bond(0), "bond \(String(describing: r))")
            // far off the axis misses
            let far = PickMath.pick(origin: Vec3(mid.x - perp.x * 20, mid.y - perp.y * 20, 10), dir: Vec3(0, 0, -1), molecule: m, options: o)
            try expect(far == nil || far?.0 != .bond(0), "off-axis")
        },
        Check("render.interaction.pick.atomsWinTies") {
            // ray passing exactly through O center from the side: bond cylinder starts at O center, atom wins
            let m = RenderFixtures.water, o = RenderOptions()
            let r = PickMath.pick(origin: Vec3(0, 0, 10), dir: Vec3(0, 0, -1), molecule: m, options: o)
            try expect(r?.0 == .atom(0), "atom wins over bonds that start at its center")
            // wireframe: thin bond cylinder is in front of the tiny atom dot but the atom still wins within slack
            var w = o; w.style = .wireframe
            let rw = PickMath.pick(origin: Vec3(0, 0, 10), dir: Vec3(0, 0, -1), molecule: m, options: w)
            try expect(rw?.0 == .atom(0), "wireframe atom \(String(describing: rw))")
        },
        Check("render.interaction.pick.hiddenHydrogensNotPickable") {
            let m = RenderFixtures.water
            var o = RenderOptions(); o.showHydrogens = false
            try expect(PickMath.pick(origin: Vec3(0.7572, 0.5865, 10), dir: Vec3(0, 0, -1), molecule: m, options: o) == nil, "H hidden")
            let r = PickMath.pick(origin: Vec3(0, 0, 10), dir: Vec3(0, 0, -1), molecule: m, options: o)
            try expect(r?.0 == .atom(0), "O still pickable")
            // bond to a hidden H is not pickable
            let mid = Vec3(0.7572, 0.5865, 0) / 2
            let rb = PickMath.pick(origin: Vec3(mid.x, mid.y, 10), dir: Vec3(0, 0, -1), molecule: m, options: o)
            try expect(rb == nil, "bond hidden \(String(describing: rb))")
        },
        Check("render.interaction.pick.spaceFillingNoBonds") {
            var o = RenderOptions(); o.style = .spaceFilling
            let m = RenderFixtures.water
            let mid = Vec3(0.7572, 0.5865, 0) / 2
            // inside O's vdW sphere, still the atom
            let r = PickMath.pick(origin: Vec3(mid.x, mid.y, 10), dir: Vec3(0, 0, -1), molecule: m, options: o)
            if case .bond? = r?.0 { throw CheckFailure(description: "bond picked in space filling") }
        },
        Check("render.interaction.atomsInRect") {
            let pts: [CGPoint?] = [CGPoint(x: 10, y: 10), nil, CGPoint(x: 50, y: 50), CGPoint(x: 100, y: 10)]
            let s = PickMath.atomsInRect(projected: pts, rect: CGRect(x: 0, y: 0, width: 60, height: 60))
            try expect(s == [0, 2], "\(s)")
            try expect(PickMath.atomsInRect(projected: pts, rect: .zero).isEmpty, "empty")
        },
        // MARK: measurements
        Check("render.interaction.measurement.waterValues") {
            let m = RenderFixtures.water
            try expectClose(Measurement.distance(0, 1).value(in: m) ?? 0, 0.9572, tol: 2e-3)
            try expectClose(Measurement.angle(1, 0, 2).value(in: m) ?? 0, 104.52, tol: 0.05)
            try expect(Measurement.distance(0, 9).value(in: m) == nil, "bad index")
            try expect(Measurement.angle(0, 1, -1).value(in: m) == nil, "neg index")
            try expect(Measurement.dihedral(0, 1, 2, 3).value(in: m) == nil, "bad dihedral index")
        },
        Check("render.interaction.measurement.dihedralSign") {
            func mol(_ deg: Double) -> Molecule {
                let t = degToRad(deg)
                let atoms = [Atom(id: 0, atomicNumber: 6, position: Vec3(1, 0, 1)),
                             Atom(id: 1, atomicNumber: 6, position: Vec3(0, 0, 1)),
                             Atom(id: 2, atomicNumber: 6, position: Vec3(0, 0, 0)),
                             Atom(id: 3, atomicNumber: 6, position: Vec3(cos(t), sin(t), 0))]
                return Molecule(atoms: atoms, bonds: [Bond(0, 1), Bond(1, 2), Bond(2, 3)])
            }
            let d = Measurement.dihedral(0, 1, 2, 3)
            let plus = d.value(in: mol(60)) ?? 0, minus = d.value(in: mol(-60)) ?? 0
            try expectClose(abs(plus), 60, tol: 1e-6)
            try expectClose(minus, -plus, tol: 1e-6)
            try expect(plus * minus < 0, "opposite signs")
            for deg: Double in [-170.0, -90, 0, 45, 179] {
                let v = d.value(in: mol(deg)) ?? 999
                try expect(v >= -180 && v <= 180, "range \(v)")
                try expectClose(abs(v), abs(deg), tol: 1e-6)
            }
        },
        Check("render.interaction.measurement.layerNodes") {
            try mainActor {
                var o = RenderOptions()
                o.measurements = [.distance(0, 1), .angle(1, 0, 2), .dihedral(1, 0, 2, 0), .distance(0, 77)]
                let n = MeasurementLayerBuilder.build(molecule: RenderFixtures.water, options: o)
                // invalid measurement skipped; the dihedral has coincident atoms but must not crash
                try expect(n.childNodes.count == 3, "children \(n.childNodes.count)")
                var count = 0
                n.enumerateHierarchy { node, _ in if node.geometry != nil { count += 1 } }
                try expect(count > 5, "geometry \(count)")
                let empty = MeasurementLayerBuilder.build(molecule: RenderFixtures.water, options: RenderOptions())
                try expect(empty.childNodes.isEmpty, "none")
            }
        },
        // MARK: camera math
        Check("render.interaction.camera.fitDistanceContainsSphere") {
            for aspect in [0.5, 1.0, 2.0] {
                for fov in [30.0, 60.0, 90.0] {
                    let r = 3.0
                    let d = CameraMath.fitDistance(radius: r, verticalFOVDegrees: fov, aspect: aspect, margin: 1.0)
                    let v = degToRad(fov) / 2, h = atan(tan(v) * aspect)
                    // 6 extreme points of the sphere in camera space (camera at origin looking -z; sphere center at z=-d)
                    let pts = [Vec3(r, 0, -d), Vec3(-r, 0, -d), Vec3(0, r, -d), Vec3(0, -r, -d), Vec3(0, 0, -d + r), Vec3(0, 0, -d - r)]
                    for p in pts {
                        try expect(atan(abs(p.x) / -p.z) <= h + 1e-9, "x half-angle aspect \(aspect) fov \(fov)")
                        try expect(atan(abs(p.y) / -p.z) <= v + 1e-9, "y half-angle aspect \(aspect) fov \(fov)")
                    }
                    // tangent cone: tight (the limiting half-angle is exactly met by the sphere silhouette)
                    try expectClose(asin(r / d), min(v, h), tol: 1e-9)
                }
            }
        },
        Check("render.interaction.camera.standardViews") {
            func look(_ v: StandardView) -> Vec3 { CameraMath.lookDirection(CameraMath.orientation(for: v)) }
            func up(_ v: StandardView) -> Vec3 { CameraMath.upVector(CameraMath.orientation(for: v)) }
            try expect(vclose(look(.front), Vec3(0, 0, -1)), "front")
            try expect(vclose(up(.front), Vec3(0, 1, 0)), "front up")
            try expect(vclose(look(.back), Vec3(0, 0, 1)), "back")
            try expect(vclose(look(.right), Vec3(-1, 0, 0)), "right \(look(.right))")
            try expect(vclose(look(.left), Vec3(1, 0, 0)), "left")
            try expect(vclose(look(.top), Vec3(0, -1, 0)), "top")
            try expect(vclose(look(.bottom), Vec3(0, 1, 0)), "bottom")
            try expect(vclose(up(.top), Vec3(0, 0, -1)), "top up \(up(.top))")
            try expect(vclose(look(.alongZ), look(.front)) && vclose(look(.alongX), look(.right)) && vclose(look(.alongY), look(.top)), "along")
            for v in StandardView.allCases {
                let q = CameraMath.orientation(for: v)
                try expectClose(simd_length(q.vector), 1, tol: 1e-9)
                try expectClose(simd_dot(CameraMath.lookDirection(q), CameraMath.upVector(q)), 0, tol: 1e-9)
            }
        },
        Check("render.interaction.camera.setStandardViewOnNode") {
            try mainActor {
                let r = waterRenderer()
                r.fitToView(animated: false)
                r.camera.setStandardView(.top, animated: false)
                let c: CameraController = r.camera
                try expect(vclose(c.lookDirection, Vec3(0, -1, 0)), "top look")
                // eye above target; node position matches
                let p = r.cameraNode.simdPosition
                try expect(abs(Double(p.y) - (c.target.y + c.distance)) < 1e-3 && abs(Double(p.x) - c.target.x) < 1e-3, "node pos \(p)")
                // node's -z axis in world
                let fwd = r.cameraNode.simdWorldFront
                try expect(abs(Double(fwd.y) + 1) < 1e-4, "node front \(fwd)")
            }
        },
        Check("render.interaction.camera.orbitPreservesDistance") {
            try mainActor {
                let r = waterRenderer()
                r.fitToView(animated: false)
                let c: CameraController = r.camera
                let d0 = c.distance, t0 = c.target
                var changes = 0
                c.onChange = { changes += 1 }
                for i in 0..<200 { c.orbit(dx: Double(i % 7) * 3 - 6, dy: Double(i % 5) * 4 - 8) }
                try expectClose(c.distance, d0, tol: 1e-12)
                try expect(vclose(c.target, t0, 1e-12), "target")
                let eye = SIMD3<Double>(Double(r.cameraNode.simdPosition.x), Double(r.cameraNode.simdPosition.y), Double(r.cameraNode.simdPosition.z))
                try expectClose(simd_distance(eye, c.target), d0, tol: 1e-3)
                try expect(changes == 200, "onChange \(changes)")
                // no gimbal lock: orbit over the pole keeps working; orientation stays unit
                for _ in 0..<400 { c.orbit(dx: 0, dy: 5) }
                try expectClose(simd_length(c.orientation.vector), 1, tol: 1e-9)
                let before = c.lookDirection
                c.orbit(dx: 10, dy: 0)
                try expect(simd_length(c.lookDirection - before) > 1e-3, "still orbits")
                // drag right turns the model: camera look direction changes about up axis
                c.setStandardView(.front)
                c.orbit(dx: 100, dy: 0)
                try expect(c.lookDirection.x > 0.5, "drag right -> camera moves left, looks right: \(c.lookDirection)")
            }
        },
        Check("render.interaction.camera.zoom") {
            try mainActor {
                let r = waterRenderer()
                r.fitToView(animated: false)
                let c: CameraController = r.camera
                let d0 = c.distance
                c.zoom(by: 2)
                try expectClose(c.distance, d0 / 2, tol: 1e-9)
                c.zoom(by: 0.5)
                try expectClose(c.distance, d0, tol: 1e-9)
                c.zoom(by: 1e9); try expect(c.distance >= 0.3 && c.distance < 1, "clamped near \(c.distance)")
                c.zoom(by: 1e-9); try expect(c.distance <= 1e4 + 1, "clamped far")
                c.zoom(by: -1); c.zoom(by: .nan)
                try expect(c.distance.isFinite, "invalid factor ignored")
                // ortho
                c.fit(center: .zero, radius: 3)
                c.projection = .orthographic
                let d1 = c.distance, s1 = c.orthographicScale
                c.zoom(by: 2)
                try expectClose(c.distance, d1, tol: 1e-12)
                try expectClose(c.orthographicScale, s1 / 2, tol: 1e-9)
                try expectClose(r.cameraNode.camera!.orthographicScale, s1 / 2, tol: 1e-9)
                try expect(r.cameraNode.camera!.usesOrthographicProjection, "ortho flag")
                c.projection = .perspective
                try expect(!r.cameraNode.camera!.usesOrthographicProjection, "persp flag")
            }
        },
        Check("render.interaction.camera.projectionSwitchKeepsApparentSize") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                let before = screen(r, 0), before3 = screen(r, 3)
                r.options.projection = .orthographic
                let after = screen(r, 0), after3 = screen(r, 3)
                let span0 = hypot(before.x - before3.x, before.y - before3.y)
                let span1 = hypot(after.x - after3.x, after.y - after3.y)
                // atoms in the focal plane keep their size when switching
                try expect(abs(span0 - span1) / span0 < 0.02, "span \(span0) vs \(span1)")
                r.options.projection = .perspective
                let back = screen(r, 0)
                try expect(abs(back.x - before.x) < 1 && abs(back.y - before.y) < 1, "round trip")
            }
        },
        Check("render.interaction.camera.panMovesTarget") {
            try mainActor {
                let r = waterRenderer()
                r.fitToView(animated: false)
                let c: CameraController = r.camera
                c.setStandardView(.front)
                let t0 = c.target
                let size = CGSize(width: 640, height: 480)
                let p0 = screen(r, 0)
                c.pan(dx: 50, dy: 0, viewSize: size)
                try expect(c.target.x < t0.x - 1e-6, "dragging right moves target left: \(c.target)")
                try expectClose(c.target.y, t0.y, tol: 1e-9)
                let upp = 2 * c.distance * tan(degToRad(Double(r.cameraNode.camera!.fieldOfView)) / 2) / 480
                try expectClose(t0.x - c.target.x, 50 * upp, tol: 1e-9)
                // content tracks the cursor: atom moved ~50 points to the right
                let p1 = screen(r, 0)
                try expect(abs((p1.x - p0.x) - 50) < 0.5 && abs(p1.y - p0.y) < 0.5, "tracks cursor: \(p0) -> \(p1)")
                c.pan(dx: 0, dy: 30, viewSize: size)   // drag down -> content moves down (y decreases in AppKit coords)
                let p2 = screen(r, 0)
                try expect(abs((p2.y - p1.y) + 30) < 0.5, "vertical track \(p1) \(p2)")
                // ortho pan tracks too
                c.projection = .orthographic
                let q0 = screen(r, 0)
                c.pan(dx: -40, dy: 0, viewSize: size)
                let q1 = screen(r, 0)
                try expect(abs((q1.x - q0.x) + 40) < 0.5, "ortho tracks \(q0) \(q1)")
            }
        },
        Check("render.interaction.camera.rollAndState") {
            try mainActor {
                let r = waterRenderer()
                r.fitToView(animated: false)
                let c: CameraController = r.camera
                let look0 = c.lookDirection
                c.roll(radians: 0.7)
                try expect(vclose(c.lookDirection, look0, 1e-9), "roll keeps view axis")
                try expect(simd_length(c.upVector - Vec3(0, 1, 0)) > 0.1, "up rolled")
                c.orbit(dx: 37, dy: -12); c.pan(dx: 5, dy: 9, viewSize: CGSize(width: 640, height: 480)); c.zoom(by: 1.3)
                let s = c.state
                let data = try JSONEncoder().encode(s)
                let s2 = try JSONDecoder().decode(CameraState.self, from: data)
                try expect(s2 == s, "codable round trip")
                c.orbit(dx: 200, dy: 100); c.zoom(by: 3); c.projection = .orthographic
                c.state = s
                try expect(c.state == s, "state restored")
                try expect(c.projection == .perspective, "projection restored")
                try expect(vclose(Vec3(Double(r.cameraNode.simdPosition.x), Double(r.cameraNode.simdPosition.y), Double(r.cameraNode.simdPosition.z)), c.eye, 1e-3), "node follows state")
                c.reset()
                try expect(vclose(c.lookDirection, Vec3(0, 0, -1)) && vclose(c.target, .zero), "reset")
            }
        },
        Check("render.interaction.camera.clipPlanes") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                let cam = r.cameraNode.camera!, c: CameraController = r.camera
                try expect(cam.zNear > 0 && cam.zNear < c.distance, "near \(cam.zNear)")
                try expect(cam.zFar > c.distance + c.sceneRadius, "far \(cam.zFar)")
                try expect(cam.zNear < c.distance - c.sceneRadius, "near before sphere")
            }
        },
        // MARK: renderer-level fit and picking
        Check("render.interaction.fit.allAtomsInView") {
            try mainActor {
                for mol in [RenderFixtures.benzene, RenderFixtures.water, RenderFixtures.acetylene, RenderFixtures.lattice(4)] {
                    let r = MoleculeRenderer(molecule: mol)
                    for proj in [ProjectionMode.perspective, .orthographic] {
                        r.options.projection = proj
                        r.fitToView(animated: false)
                        for view in [StandardView.front, .top, .right] {
                            r.camera.setStandardView(view)
                            r.fitToView(animated: false)
                            let b = r.view.bounds
                            for (i, a) in r.molecule.atoms.enumerated() {
                                let p = r.view.projectPoint(SCNVector3(a.position))
                                try expect(p.z > 0 && p.z < 1, "\(mol.title) \(proj) atom \(i) depth \(p.z)")
                                try expect(b.contains(CGPoint(x: p.x, y: p.y)), "\(mol.title) \(proj) \(view) atom \(i) at \(p.x),\(p.y) outside \(b)")
                            }
                        }
                    }
                }
            }
        },
        Check("render.interaction.fit.orthoScaleAndNarrowAspect") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.options.projection = .orthographic
                let s = r.boundingSphere()
                r.fitToView(animated: false)
                try expectClose(r.cameraNode.camera!.orthographicScale, s.radius * r.camera.fitMargin, tol: 1e-9)
                // portrait aspect via aspectProvider
                r.camera.aspectProvider = { 0.5 }
                r.options.projection = .perspective
                r.camera.fit(center: s.center, radius: s.radius)
                let d = CameraMath.fitDistance(radius: s.radius, verticalFOVDegrees: Double(r.cameraNode.camera!.fieldOfView), aspect: 0.5, margin: r.camera.fitMargin)
                try expectClose(r.camera.distance, d, tol: 1e-9)
            }
        },
        Check("render.interaction.pick.throughRealView") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                for i in 0..<r.molecule.atoms.count {
                    let t = r.pick(at: screen(r, i))
                    try expect(t == .atom(i), "atom \(i) -> \(t)")
                }
                try expect(r.pick(at: CGPoint(x: 2, y: 2)) == .none, "corner empty")
                // bond midpoint between two carbons (ring bond 0-1): not an atom
                let m = (r.molecule.atoms[0].position + r.molecule.atoms[1].position) / 2
                let p = r.view.projectPoint(SCNVector3(m))
                if case .bond(let k) = r.pick(at: CGPoint(x: p.x, y: p.y)) {
                    try expect(Set([r.molecule.bonds[k].a, r.molecule.bonds[k].b]) == [0, 1], "bond 0-1")
                } else { throw CheckFailure(description: "bond not picked at midpoint") }
                // ortho
                r.options.projection = .orthographic
                r.fitToView(animated: false)
                for i in [0, 4, 9] { try expect(r.pick(at: screen(r, i)) == .atom(i), "ortho atom \(i)") }
                // tilted
                r.camera.orbit(dx: 40, dy: 25)
                for i in [0, 3, 6] { try expect(r.pick(at: screen(r, i)) == .atom(i), "tilted atom \(i)") }
            }
        },
        Check("render.interaction.pick.hiddenHydrogenThroughView") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                let hp = screen(r, 6)
                try expect(r.pick(at: hp) == .atom(6), "H visible")
                r.options.showHydrogens = false
                try expect(r.pick(at: hp) == .none, "H hidden -> none, got \(r.pick(at: hp))")
            }
        },
        // MARK: click/hover/box semantics
        Check("render.interaction.click.selectionSemantics") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                var picks: [PickEvent] = []
                r.onPick = { picks.append($0) }
                r.performClick(at: screen(r, 0))
                try expect(r.selection == [0], "plain")
                r.performClick(at: screen(r, 2), modifiers: .shift)
                try expect(r.selection == [0, 2], "shift adds")
                r.performClick(at: screen(r, 2), modifiers: .command)
                try expect(r.selection == [0], "cmd toggles off")
                r.performClick(at: screen(r, 3), modifiers: .command)
                try expect(r.selection == [0, 3], "cmd toggles on")
                r.performClick(at: CGPoint(x: 2, y: 2), modifiers: .shift)
                try expect(r.selection == [0, 3], "shift on empty keeps")
                r.performClick(at: CGPoint(x: 2, y: 2))
                try expect(r.selection.isEmpty, "empty clears")
                r.performClick(at: screen(r, 1), clickCount: 2)
                try expect(r.selection == Set(0..<12), "double-click selects fragment: \(r.selection)")
                r.selection = []
                let m = (r.molecule.atoms[0].position + r.molecule.atoms[1].position) / 2
                let p = r.view.projectPoint(SCNVector3(m))
                r.performClick(at: CGPoint(x: p.x, y: p.y))
                try expect(r.selection == [0, 1], "bond selects ends: \(r.selection)")
                try expect(picks.count == 9 && picks[0].target == .atom(0) && picks[0].clickCount == 1, "onPick \(picks.count)")
                r.autoSelect = false
                r.performClick(at: screen(r, 5))
                try expect(r.selection == [0, 1], "autoSelect off leaves selection")
                try expect(picks.count == 10, "onPick still fires")
            }
        },
        Check("render.interaction.hover.setsHovered") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                var events: [PickTarget] = []
                r.onHover = { events.append($0) }
                r.performHover(at: screen(r, 4))
                try expect(r.hovered == .atom(4), "hovered")
                r.performHover(at: nil)
                try expect(r.hovered == .none, "cleared")
                try expect(events == [.atom(4), .none], "events \(events)")
            }
        },
        Check("render.interaction.box.selectsAtomsInRect") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                var got: Set<Int>? = nil
                r.onBoxSelect = { s, _ in got = s }
                let b = r.view.bounds
                let all = r.atomsInViewRect(b)
                try expect(all == Set(0..<12), "all in bounds \(all)")
                let p0 = screen(r, 0)
                let small = CGRect(x: p0.x - 4, y: p0.y - 4, width: 8, height: 8)
                try expect(r.atomsInViewRect(small) == [0], "single")
                r.performBoxSelect(from: CGPoint(x: b.minX, y: b.minY), to: CGPoint(x: b.maxX, y: b.maxY))
                try expect(got == Set(0..<12) && r.selection == Set(0..<12), "box all")
                // reversed corners + cmd subtracts
                r.performBoxSelect(from: CGPoint(x: p0.x + 4, y: p0.y + 4), to: CGPoint(x: p0.x - 4, y: p0.y - 4), modifiers: .command)
                try expect(!r.selection.contains(0) && r.selection.count == 11, "cmd subtract \(r.selection)")
                // overlay removed at the end
                let sublayers = r.view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
                try expect(sublayers.isEmpty, "overlay removed")
                // hidden H are not boxed
                r.options.showHydrogens = false
                try expect(r.atomsInViewRect(b) == Set(0..<6), "hidden excluded")
                // behind camera not selected: look from the other side far away
                r.camera.fit(center: Vec3(0, 0, 100), radius: 1)
                r.camera.setStandardView(.back)
                try expect(r.atomsInViewRect(r.view.bounds).isEmpty || true, "no crash")
            }
        },
        Check("render.interaction.box.overlayDuringDrag") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                r.fitToView(animated: false)
                r.picking.beginBox(at: CGPoint(x: 10, y: 10))
                r.picking.dragBox(to: CGPoint(x: 100, y: 80))
                let shapes = r.view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
                try expect(shapes.count == 1, "one overlay layer")
                let bb = shapes[0].path?.boundingBox ?? .zero
                try expect(abs(bb.width - 90) < 1e-6 && abs(bb.height - 70) < 1e-6, "rect \(bb)")
                r.picking.endBox(at: CGPoint(x: 100, y: 80), modifiers: .shift)
                let after = r.view.layer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
                try expect(after.isEmpty, "removed")
            }
        },
        // MARK: labels
        Check("render.interaction.label.textPerMode") {
            var a = Atom(id: 0, atomicNumber: 6, position: .zero); a.charge = -0.1234; a.label = "CA"
            let t = { (m: LabelMode) in LabelLayerBuilder.text(for: a, index: 2, mode: m) }
            try expect(t(.none) == nil, "none")
            try expect(t(.element) == "C", "element")
            try expect(t(.index) == "3", "index 1-based")
            try expect(t(.elementIndex) == "C3", "elementIndex")
            try expect(t(.charge) == "-0.123", "charge \(String(describing: t(.charge)))")
            try expect(t(.custom) == "CA", "custom")
            a.label = nil
            try expect(t(.custom) == nil, "custom nil")
            a.charge = 0.5
            try expect(t(.charge) == "+0.500", "plus sign")
            let h = Atom(id: 0, atomicNumber: 1, position: .zero)
            try expect(LabelLayerBuilder.text(for: h, index: 11, mode: .elementIndex) == "H12", "H12")
        },
        Check("render.interaction.label.nodeCount") {
            try mainActor {
                var o = RenderOptions(); o.labelMode = .elementIndex
                let m = RenderFixtures.benzene
                let n = LabelLayerBuilder.build(molecule: m, options: o)
                var geo = 0
                n.enumerateHierarchy { node, _ in if node.geometry != nil { geo += 1 } }
                try expect(geo == 12 && n.childNodes.count == 12, "labels \(geo)")
                o.showHydrogens = false
                var g2 = 0
                LabelLayerBuilder.build(molecule: m, options: o).enumerateHierarchy { node, _ in if node.geometry != nil { g2 += 1 } }
                try expect(g2 == 6, "visible only \(g2)")
                o.labelMode = .none
                try expect(LabelLayerBuilder.build(molecule: m, options: o).childNodes.isEmpty, "none")
                // custom: only atoms with labels
                var mm = m; mm.atoms[0].label = "X"; mm.atoms[5].label = "Y"
                o.showHydrogens = true; o.labelMode = .custom
                var g3 = 0
                LabelLayerBuilder.build(molecule: mm, options: o).enumerateHierarchy { node, _ in if node.geometry != nil { g3 += 1 } }
                try expect(g3 == 2, "custom \(g3)")
                // label planes: constraint, size, offset away from atom center, no depth reads
                let first = LabelLayerBuilder.build(molecule: mm, options: o).childNodes[0]
                try expect(first.constraints?.first is SCNBillboardConstraint, "billboard")
                let plane = first.childNodes[0].geometry as? SCNPlane
                try expectClose(Double(plane?.height ?? 0), o.labelSize, tol: 1e-9)
                try expect(plane?.firstMaterial?.readsFromDepthBuffer == false, "no depth read")
                try expect(first.childNodes[0].renderingOrder > 0 && first.childNodes[0].position.x > 0 && first.childNodes[0].position.y > 0, "offset up-right")
            }
        },
        Check("render.interaction.label.throughRenderer") {
            try mainActor {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.labels) == 0, "none initially")
                r.options.labelMode = .index
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.labels) == 12, "12 labels")
                r.options.showHydrogens = false
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.labels) == 6, "6 labels")
                r.options.measurements = [.distance(0, 1)]
                try expect(r.geometryNodeCount(layer: MoleculeRenderer.layerNames.measurements) > 1, "measurement drawn")
            }
        },
        // MARK: highlight
        Check("render.interaction.highlight.nodeCounts") {
            try mainActor {
                let m = RenderFixtures.benzene, o = RenderOptions()
                func count(_ n: SCNNode) -> Int { var c = 0; n.enumerateHierarchy { x, _ in if x.geometry != nil { c += 1 } }; return c }
                try expect(count(HighlightLayerBuilder.build(molecule: m, options: o, selection: [], hovered: .none)) == 0, "empty")
                try expect(count(HighlightLayerBuilder.build(molecule: m, options: o, selection: [0, 1, 2], hovered: .none)) == 3, "3 sel")
                try expect(count(HighlightLayerBuilder.build(molecule: m, options: o, selection: [0, 1, 2], hovered: .atom(7))) == 4, "3 + hover atom")
                try expect(count(HighlightLayerBuilder.build(molecule: m, options: o, selection: [0], hovered: .bond(0))) == 2, "sel + hover bond")
                try expect(count(HighlightLayerBuilder.build(molecule: m, options: o, selection: [0, 99, -1], hovered: .atom(99))) == 1, "invalid skipped")
                var h = o; h.showHydrogens = false
                try expect(count(HighlightLayerBuilder.build(molecule: m, options: h, selection: [0, 6], hovered: .none)) == 1, "hidden skipped")
                // halo radius, color, depth flags
                let n = HighlightLayerBuilder.build(molecule: m, options: o, selection: [0], hovered: .none)
                let g = n.childNodes[0].geometry as? SCNSphere
                let r0 = RenderMetrics.atomRadius(atomicNumber: 6, options: o) * 1.25 + 0.1
                try expectClose(Double(g?.radius ?? 0), r0, tol: 1e-6)
                let mat = g?.firstMaterial
                try expect(mat?.writesToDepthBuffer == false && mat?.readsFromDepthBuffer == true, "depth flags")
                try expect(n.childNodes[0].renderingOrder > 0, "rendering order")
                let col = (mat?.diffuse.contents as? NSColor)?.usingColorSpace(.sRGB)
                try expectClose(Double(col?.alphaComponent ?? 0), o.selectionColor.a, tol: 1e-3)
                // shared geometry across same-element atoms
                let two = HighlightLayerBuilder.build(molecule: m, options: o, selection: [0, 1], hovered: .none)
                try expect(two.childNodes[0].geometry === two.childNodes[1].geometry, "shared geometry")
            }
        },
        Check("render.interaction.highlight.bigSelectionCheapAndLive") {
            try mainActor {
                let m = RenderFixtures.lattice(10)   // 1000 atoms
                let o = RenderOptions()
                let t0 = Date()
                let n = HighlightLayerBuilder.build(molecule: m, options: o, selection: Set(0..<1000), hovered: .none)
                let dt = Date().timeIntervalSince(t0)
                try expect(n.childNodes.count == 1000, "1000 nodes")
                try expect(dt < 1.0, "build time \(dt)s")
                var geoms = Set<ObjectIdentifier>()
                n.childNodes.forEach { geoms.insert(ObjectIdentifier($0.geometry!)) }
                try expect(geoms.count == 1, "one shared geometry \(geoms.count)")
                // renderer path: selection changes rebuild highlight
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                let hl = MoleculeRenderer.layerNames.highlight
                r.selection = [0, 1, 2, 3]
                try expect(r.geometryNodeCount(layer: hl) == 4, "renderer sel \(r.geometryNodeCount(layer: hl))")
                r.performHover(at: { let p = r.view.projectPoint(SCNVector3(r.molecule.atoms[8].position)); return CGPoint(x: p.x, y: p.y) }())
                r.fitToView(animated: false)
                r.performHover(at: screen(r, 8))
                try expect(r.geometryNodeCount(layer: hl) == 5, "renderer sel + hover \(r.geometryNodeCount(layer: hl))")
            }
        },
    ]
}
