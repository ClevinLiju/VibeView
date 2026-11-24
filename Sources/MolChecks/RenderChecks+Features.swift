import Foundation
import AppKit
import SceneKit
import simd
import MolCore
@testable import MolRender

// Round 3 (Lead B): lasso, move selection, hover tooltip/throttle, H-bonds, slab, center-on-atom,
// axes/scale bar, live measurement monitors.
extension Checks {
    static let renderFeatures: [Check] = [
        Check("render.features.lasso.pointInPolygon") { try MainActor.assumeIsolated { try feat_lasso_pointInPolygon() } },
        Check("render.features.lasso.combine") { try MainActor.assumeIsolated { try feat_lasso_combine() } },
        Check("render.features.lasso.renderer") { try MainActor.assumeIsolated { try feat_lasso_renderer() } },
        Check("render.features.move.math") { try MainActor.assumeIsolated { try feat_move_math() } },
        Check("render.features.move.renderer") { try MainActor.assumeIsolated { try feat_move_renderer() } },
        Check("render.features.hbonds") { try MainActor.assumeIsolated { try feat_hbonds() } },
        Check("render.features.slab") { try MainActor.assumeIsolated { try feat_slab() } },
        Check("render.features.centerOnDoubleClick") { try MainActor.assumeIsolated { try feat_centerOnDoubleClick() } },
        Check("render.features.scaleBarAxes") { try MainActor.assumeIsolated { try feat_scaleBarAxes() } },
        Check("render.features.hoverTooltip") { try MainActor.assumeIsolated { try feat_hoverTooltip() } },
        Check("render.features.liveMeasurements") { try MainActor.assumeIsolated { try feat_liveMeasurements() } },
    ]
}

@MainActor fileprivate func feat_lasso_pointInPolygon() throws {
            let sq = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
            try expect(LassoMath.contains(sq, CGPoint(x: 5, y: 5)), "inside square")
            try expect(!LassoMath.contains(sq, CGPoint(x: 15, y: 5)), "outside square")
            try expect(!LassoMath.contains(sq, CGPoint(x: -1, y: -1)), "outside corner")
            // concave "C" shape: the notch is outside
            let c = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 3), CGPoint(x: 3, y: 3),
                     CGPoint(x: 3, y: 7), CGPoint(x: 10, y: 7), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
            try expect(LassoMath.contains(c, CGPoint(x: 1.5, y: 5)), "spine inside")
            try expect(!LassoMath.contains(c, CGPoint(x: 6, y: 5)), "notch outside")
            try expect(LassoMath.contains(c, CGPoint(x: 6, y: 1.5)), "lower arm inside")
            // orientation independent; degenerate polygons select nothing
            try expect(LassoMath.contains(Array(c.reversed()), CGPoint(x: 1.5, y: 5)), "reversed winding")
            try expect(!LassoMath.contains([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)], CGPoint(x: 1, y: 1)), "2-gon")
            let hit = LassoMath.atomsInPolygon(projected: [CGPoint(x: 1, y: 5), nil, CGPoint(x: 6, y: 5), CGPoint(x: 6, y: 9)], polygon: c)
            try expect(hit == [0, 3], "atomsInPolygon \(hit)")
            var pts: [CGPoint] = [CGPoint(x: 0, y: 0)]
            LassoMath.appendSample(&pts, CGPoint(x: 0.5, y: 0.5)); LassoMath.appendSample(&pts, CGPoint(x: 4, y: 0))
            try expect(pts.count == 2, "sample spacing")
        }

@MainActor fileprivate func feat_lasso_combine() throws {
            try expect(SelectionCombine.from(shift: false, command: false, option: false) == .replace, "none")
            try expect(SelectionCombine.from(shift: true, command: false, option: false) == .add, "shift")
            try expect(SelectionCombine.from(shift: false, command: true, option: false) == .subtract, "cmd")
            try expect(SelectionCombine.add.apply([3], to: [1]) == [1, 3], "add")
            try expect(SelectionCombine.subtract.apply([1], to: [1, 2]) == [2], "subtract")
            try expect(SelectionCombine.replace.apply([5], to: [1, 2]) == [5], "replace")
        }

@MainActor fileprivate func feat_lasso_renderer() throws {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
                r.camera.setStandardView(.front)
                r.fitToView(animated: false)
                // a big polygon around the whole view selects every atom; a tiny one far away none
                let all = [CGPoint(x: 1, y: 1), CGPoint(x: 639, y: 1), CGPoint(x: 639, y: 479), CGPoint(x: 1, y: 479)]
                try expect(r.atomsInViewPolygon(all).count == 12, "all atoms")
                // left half: atoms with projected x < 320
                let left = [CGPoint(x: 1, y: 1), CGPoint(x: 315, y: 1), CGPoint(x: 315, y: 479), CGPoint(x: 1, y: 479)]
                let lh = r.atomsInViewPolygon(left)
                try expect(lh.allSatisfy { r.molecule.atoms[$0].position.x < 0 } && lh.count == 6, "left half \(lh.sorted())")
                var reported: Set<Int>?
                r.onLassoSelect = { s, _ in reported = s }
                r.performLassoSelect(left)
                try expect(reported == lh && r.selection == lh, "lasso selects")
                r.performLassoSelect(all, modifiers: [.command])
                try expect(r.selection.isEmpty, "cmd subtracts")
                r.performLassoSelect(left); r.performLassoSelect(all.map { CGPoint(x: $0.x, y: $0.y) }, modifiers: [.shift])
                try expect(r.selection.count == 12, "shift adds")
            }
        }

@MainActor fileprivate func feat_move_math() throws {
            let p = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 2, 0)]
            let t = SelectionMoveMath.translate(p, selection: [1, 2, 7], by: Vec3(0, 0, 1))
            try expect(t[0] == p[0] && t[1] == Vec3(1, 0, 1) && t[2] == Vec3(0, 2, 1), "translate only selected")
            try expect(SelectionMoveMath.centroid(p, selection: [1, 2]) == Vec3(0.5, 1, 0), "centroid")
            let r = SelectionMoveMath.rotate(p, selection: [1, 2], axis: Vec3(0, 0, 1), angle: .pi)
            try expect(r[0] == p[0], "unselected frozen")
            try expect(simd_distance(r[1], Vec3(0, 2, 0)) < 1e-12 && simd_distance(r[2], Vec3(1, 0, 0)) < 1e-12, "180° about centroid")
            try expectClose(simd_distance(r[1], r[2]), simd_distance(p[1], p[2]), tol: 1e-12)
            // view-plane delta and drag rotation axis
            let d = SelectionMoveMath.viewPlaneDelta(dx: 10, dy: -5, right: Vec3(1, 0, 0), up: Vec3(0, 1, 0), worldPerPoint: 0.1)
            try expect(simd_distance(d, Vec3(1, -0.5, 0)) < 1e-12, "delta")
            let rot = SelectionMoveMath.dragRotation(dx: 10, dy: 0, right: Vec3(1, 0, 0), up: Vec3(0, 1, 0))
            try expect(simd_distance(rot.axis, Vec3(0, 1, 0)) < 1e-12 && abs(rot.angle - 0.1) < 1e-12, "horizontal drag spins about up")
            let wpp = SelectionMoveMath.worldPerPoint(depth: 10, verticalFOVDegrees: 90, viewHeight: 200, projection: .perspective, orthographicScale: 1)
            try expectClose(wpp, 0.1, tol: 1e-12)
            try expectClose(SelectionMoveMath.worldPerPoint(depth: 10, verticalFOVDegrees: 90, viewHeight: 200, projection: .orthographic, orthographicScale: 5), 0.05)
        }

@MainActor fileprivate func feat_move_renderer() throws {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                r.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
                r.camera.setStandardView(.front); r.fitToView(animated: false)
                let before = r.molecule.atoms.map(\.position)
                r.performSelectionDrag(dx: 10, dy: 0)
                try expect(r.molecule.atoms.map(\.position) == before, "no selection: nothing moves")
                r.selection = [1]
                var got: ([Vec3], [Vec3])?
                r.onSelectionMoved = { a, b in got = (a, b) }
                r.performSelectionDrag(dx: 20, dy: 0)
                let after = r.molecule.atoms.map(\.position)
                try expect(after[0] == before[0] && after[2] == before[2], "others frozen")
                let delta = after[1] - before[1]
                try expect(simd_dot(delta, r.camera.rightVector) > 0 && abs(simd_dot(delta, r.camera.lookDirection)) < 1e-9, "moved right in view plane")
                // 20 points at the atom depth
                let depth = simd_dot(before[1] - r.camera.eye, r.camera.lookDirection)
                let wpp = SelectionMoveMath.worldPerPoint(depth: depth, verticalFOVDegrees: Double(r.cameraNode.camera!.fieldOfView), viewHeight: 400, projection: .perspective, orthographicScale: 1)
                try expectClose(simd_length(delta), 20 * wpp, tol: 1e-6)
                try expect(got?.0 == before && got?.1 == after, "callback with before/after")
                r.selection = [1, 2]
                let b2 = r.molecule.atoms.map(\.position)
                r.performSelectionDrag(dx: 40, dy: 0, rotate: true)
                let a2 = r.molecule.atoms.map(\.position)
                try expect(a2[0] == b2[0], "O frozen during rotate")
                try expectClose(simd_distance(a2[1], a2[2]), simd_distance(b2[1], b2[2]), tol: 1e-9)
                try expect(simd_distance(a2[1], b2[1]) > 1e-3, "rotated")
            }
        }

@MainActor fileprivate func feat_hbonds() throws {
            // water dimer: donor O0-H1 ... O3 acceptor, linear-ish
            var atoms = [Atom(id: 0, atomicNumber: 8, position: Vec3(0, 0, 0)), Atom(id: 1, atomicNumber: 1, position: Vec3(0.96, 0, 0)),
                         Atom(id: 2, atomicNumber: 1, position: Vec3(-0.24, 0.93, 0))]
            atoms += [Atom(id: 3, atomicNumber: 8, position: Vec3(2.9, 0, 0)), Atom(id: 4, atomicNumber: 1, position: Vec3(3.2, 0.9, 0)),
                      Atom(id: 5, atomicNumber: 1, position: Vec3(3.2, -0.9, 0))]
            let m = Molecule(atoms: atoms, bonds: [Bond(0, 1), Bond(0, 2), Bond(3, 4), Bond(3, 5)], title: "dimer")
            let hb = HydrogenBonds.find(in: m)
            try expect(hb.count == 1, "one H-bond: \(hb)")
            try expect(hb[0].donor == 0 && hb[0].hydrogen == 1 && hb[0].acceptor == 3, "D-H...A")
            try expectClose(hb[0].distance, 1.94, tol: 1e-9)
            try expect(hb[0].angle > 170, "angle")
            try expect(HydrogenBonds.find(in: m, maxDistance: 1.8).isEmpty, "distance cutoff")
            // bend the donor H off-line: angle criterion rejects
            var bent = m; bent.atoms[1].position = Vec3(0.5, 0.82, 0)
            try expect(HydrogenBonds.find(in: bent, maxDistance: 3.0, minAngle: 150).isEmpty, "angle cutoff")
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: m)
                try expect(r.root.childNode(withName: FeatureNodeName.hbonds, recursively: false)?.childNodes.isEmpty ?? true, "off by default")
                var o = r.options; o.showHydrogenBonds = true; r.options = o
                let n = r.root.childNode(withName: FeatureNodeName.hbonds, recursively: false)
                try expect((n?.childNodes.count ?? 0) >= 3, "dashed pieces drawn")
                o.showHydrogenBonds = false; r.options = o
                try expect(r.root.childNode(withName: FeatureNodeName.hbonds, recursively: false)?.childNodes.isEmpty ?? true, "toggled off")
                try expect(r.hydrogenBonds().count == 1, "renderer API")
            }
        }

@MainActor fileprivate func feat_slab() throws {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.fitToView(animated: false)
                let cam = r.cameraNode.camera!
                let n0 = cam.zNear, f0 = cam.zFar
                var o = r.options; o.slabNear = 1.0; o.slabFar = 2.0; r.options = o
                try expectClose(cam.zNear, r.camera.distance - 1.0, tol: 1e-6)
                try expectClose(cam.zFar, r.camera.distance + 2.0, tol: 1e-6)
                r.camera.zoom(by: 1.5)
                try expectClose(cam.zNear, r.camera.distance - 1.0, tol: 1e-6)   // follows the camera
                o.slabNear = nil; o.slabFar = nil; r.options = o
                try expect(cam.zNear == n0 && cam.zFar == f0, "restored defaults")
                // round-trip through Codable
                var p = RenderOptions(); p.slabNear = 0.5; p.showAxes = true; p.showHydrogenBonds = true; p.aromaticStyle = .circle
                let back = try JSONDecoder().decode(RenderOptions.self, from: JSONEncoder().encode(p))
                try expect(back == p, "codable round-trip")
            }
        }

@MainActor fileprivate func feat_centerOnDoubleClick() throws {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                r.view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
                r.camera.setStandardView(.front); r.fitToView(animated: false)
                let p = r.view.projectPoint(featVec(r.molecule.atoms[7].position))
                r.performClick(at: CGPoint(x: p.x, y: p.y), clickCount: 2)
                for _ in 0..<40 { r.camera.advanceAnimation(by: 0.02) }
                try expect(simd_distance(r.camera.target, r.molecule.atoms[7].position) < 1e-6, "target on atom \(r.camera.target)")
                r.centerOnDoubleClick = false
                r.centerOn(atom: 0, animated: false)
                try expect(simd_distance(r.camera.target, r.molecule.atoms[0].position) < 1e-9, "centerOn")
            }
        }

@MainActor fileprivate func feat_scaleBarAxes() throws {
            let a = ScaleBarMath.niceLength(worldPerPoint: 0.05, targetPoints: 100)   // want 5 Å
            try expectClose(a.angstrom, 5); try expectClose(a.points, 100)
            let b = ScaleBarMath.niceLength(worldPerPoint: 0.031, targetPoints: 100)  // want 3.1 -> 2 or 5
            try expect([2.0, 5.0].contains(b.angstrom), "nice \(b)")
            try expect(ScaleBarMath.label(0.5) == "0.5 Å" && ScaleBarMath.label(10) == "10 Å", "labels")
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.benzene)
                var o = r.options; o.showAxes = true; o.showScaleBar = true; r.options = o
                let names = r.view.layer?.sublayers?.compactMap(\.name) ?? []
                try expect(names.contains("vibeview.axes") && names.contains("vibeview.scalebar"), "overlays \(names)")
                o.showAxes = false; o.showScaleBar = false; r.options = o
                let names2 = r.view.layer?.sublayers?.compactMap(\.name) ?? []
                try expect(!names2.contains("vibeview.axes") && !names2.contains("vibeview.scalebar"), "removed")
            }
        }

@MainActor fileprivate func feat_hoverTooltip() throws {
            try MainActor.assumeIsolated {
                var m = RenderFixtures.water; m.bonds[0].order = .single
                let ti = HoverTooltip.make(HoverInfo.make(.atom(0), molecule: m), molecule: m, measurements: [.angle(1, 0, 2)])
                try expect(ti.title == "O1" && ti.subtitle == "Oxygen", "title \(ti.title) \(ti.subtitle)")
                try expect(ti.rows.contains { $0.label == "Charge" && $0.value == "−0.800 e" }, "charge \(ti.rows)")
                try expect(ti.rows.contains { $0.label == "H2–O1–H3" && $0.value.hasSuffix("°") }, "angle row")
                let tb = HoverTooltip.make(HoverInfo.make(.bond(0), molecule: m), molecule: m)
                try expect(tb.title == "O1–H2" && tb.subtitle == "Single bond", "bond title")
                try expect(tb.rows.first?.label == "Length" && tb.rows.first?.value.hasSuffix(" Å") == true, "length")
                try expect(HoverTooltip.make(HoverInfo.make(.none, molecule: m), molecule: m).isEmpty, "empty")
                // the model shows without delay when already visible, and hides on .none
                let model = HoverTooltipModel(); model.showDelay = 0
                model.update(ti, at: CGPoint(x: 5, y: 5))
                try expect(model.visible && model.tooltip == ti, "visible")
                model.update(.empty, at: nil)
                try expect(!model.visible, "hidden")
                // renderer pushes hover into the model; hover pick is cached per revision
                let r = MoleculeRenderer(molecule: m)
                r.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
                r.camera.setStandardView(.front); r.fitToView(animated: false)
                r.hoverTooltipModel.showDelay = 0
                let p = r.view.projectPoint(featVec(m.atoms[0].position))
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                r.picking.hover(at: CGPoint(x: p.x, y: p.y), throttled: true)
                try expect(r.hovered == .atom(0), "hovered")
                try expect(r.hoverTooltipModel.visible && r.hoverTooltipModel.tooltip.title == "O1", "model updated")
                // rapid second hover inside the throttle window is coalesced, then applied
                r.picking.hover(at: CGPoint(x: 2, y: 2), throttled: true)
                try expect(r.hovered == .atom(0), "coalesced inside the throttle window")
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                try expect(r.hovered == .none, "trailing hover applied")
                r.performHover(at: nil)
                try expect(!r.hoverTooltipModel.visible, "hidden on exit")
            }
        }

@MainActor fileprivate func feat_liveMeasurements() throws {
            try MainActor.assumeIsolated {
                let r = MoleculeRenderer(molecule: RenderFixtures.water)
                var o = r.options; o.measurements = [.distance(0, 1), .angle(1, 0, 2)]; r.options = o
                var seen: [[Double]] = []
                r.onMeasurementValues = { seen.append($0) }
                let v0 = r.measurementValues()
                try expectClose(v0[0], RenderFixtures.water.distance(0, 1), tol: 1e-12)
                var p = r.molecule.atoms.map(\.position); p[1] += Vec3(0.2, 0, 0)
                r.updatePositions(p)          // trajectory-style update
                try expect(seen.last.map { abs($0[0] - simd_distance(p[0], p[1])) < 1e-12 } == true, "monitor updated")
                // vibration (GPU): overlays follow, monitor fires repeatedly
                r.updatePositions(RenderFixtures.water.atoms.map(\.position))
                seen.removeAll()
                r.vibration.play(NormalMode(frequency: 1, irIntensity: 0, displacements: [Vec3(0, 0.1, 0), Vec3(0.3, 0, 0), Vec3(-0.3, 0, 0)]))
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                r.vibration.stop()
                try expect(seen.count >= 3, "live values during vibration (\(seen.count))")
                try expect(Set(seen.map { ($0[0] * 1e6).rounded() }).count >= 2, "values change")
            }
        }

fileprivate func featVec(_ v: Vec3) -> SCNVector3 { SCNVector3(x: CGFloat(v.x), y: CGFloat(v.y), z: CGFloat(v.z)) }
