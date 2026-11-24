import Foundation
import QuickLookUI
import UniformTypeIdentifiers
import simd
// MolCore + MolIO sources are compiled into this module by scripts/make-app.sh (imports stripped).

/// Finder Quick Look preview for structure files: a shaded 2.5-D drawing plus a property card, as HTML.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let html = (try? QuickLookRenderer.html(for: url)) ?? QuickLookRenderer.errorHTML(url)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 560)) { _ in Data(html.utf8) }
    }
}

enum QuickLookRenderer {
    struct Info { var molecule: Molecule; var kind: String; var details: [(String, String)] }

    static func load(_ url: URL) throws -> Info {
        let text = try String(contentsOf: url, encoding: .utf8)
        let fmt = MoleculeFileFormat.detect(contents: String(text.prefix(4096)), fileName: url.lastPathComponent)
            ?? MoleculeFileFormat.format(forExtension: url.pathExtension)
        var details: [(String, String)] = []
        var m = Molecule()
        switch fmt {
        case .xyz?:
            let f = try XYZFormat.parse(text); m = f.last ?? Molecule()
            if f.count > 1 { details.append(("Frames", "\(f.count)")) }
        case .gaussianInput?:
            if let j = try GaussianInputReader.parse(text).first {
                m = j.molecule
                details.append(("Route", j.route.text))
                if let cm = j.chargeMultiplicities.first { details.append(("Charge / mult.", "\(cm.charge) / \(cm.multiplicity)")) }
            }
        case .gaussianOutput?:
            let log = try GaussianLog.parse(text)
            let r = log.result
            m = r.steps.last ?? log.inputOrientations.last ?? Molecule()
            if !log.firstRoute.isEmpty { details.append(("Route", log.firstRoute)) }
            if let e = r.energies.last { details.append(("Final energy", String(format: "%.6f Eh", e))) }
            if r.steps.count > 1 { details.append(("Geometries", "\(r.steps.count)")) }
            if !r.normalModes.isEmpty {
                let imag = r.normalModes.filter { $0.frequency < 0 }.count
                details.append(("Frequencies", "\(r.normalModes.count) modes" + (imag > 0 ? ", \(imag) imaginary" : "")))
            }
            details.append(("Termination", r.normalTermination ? "Normal" : "Not normal / incomplete"))
        case .mol?, .sdf?:
            let recs = try MDLMolFormat.parse(text); m = recs.first?.molecule ?? Molecule()
            if recs.count > 1 { details.append(("Records", "\(recs.count)")) }
        case .pdb?:
            let p = try PDBFormat.parse(text); m = p.models.first ?? Molecule()
        case .cml?:
            m = try CMLFormat.parse(text).first ?? Molecule()
        case .formattedCheckpoint?:
            let f = try FormattedCheckpoint.parse(text); m = f.molecule
            details.append(("Method", "\(f.method)/\(f.basisName)"))
        case .cube?:
            m = try CubeFile.parse(text).molecule
        case .orcaOutput?, .qchemOutput?:
            let r = fmt == .orcaOutput ? try OrcaOutput.parse(text).result : try QChemOutput.parse(text).result
            m = r.steps.last ?? Molecule()
            details.append(("Program", fmt == .orcaOutput ? "ORCA" : "Q-Chem"))
            if let e = r.energies.last { details.append(("Final energy", String(format: "%.6f Eh", e))) }
            if r.steps.count > 1 { details.append(("Geometries", "\(r.steps.count)")) }
            if !r.normalModes.isEmpty { details.append(("Frequencies", "\(r.normalModes.count) modes")) }
            details.append(("Termination", r.normalTermination ? "Normal" : "Not normal / incomplete"))
        case .orcaInput?:
            let f = try OrcaInputFile.parse(text); m = f.molecule
            details.append(("Keywords", f.keywords.joined(separator: " ")))
        case .qchemInput?:
            m = try QChemInputFile.parse(text).jobs.compactMap(\.molecule).first ?? Molecule()
        case .molden?:
            let f = try MoldenFile.parse(text); m = f.geometries.last ?? f.molecule
        case .orcaHessian?:
            m = try OrcaHessian.parse(text).molecule
        case .xtbOutput?, nil:
            throw CocoaError(.fileReadCorruptFile)
        }
        if m.bonds.isEmpty && m.atoms.count > 1 && m.atoms.count < 5000 { m.perceiveBonds() }
        return Info(molecule: m, kind: fmt?.displayName ?? "Structure", details: details)
    }

    static func html(for url: URL) throws -> String {
        let info = try load(url)
        let m = info.molecule
        let svg = drawing(m, width: 520, height: 520)
        var rows = [("Formula", m.atoms.isEmpty ? "—" : m.formula), ("Atoms", "\(m.atoms.count)"),
                    ("Weight", String(format: "%.3f g/mol", m.molecularWeight))]
        rows += info.details
        let table = rows.map { "<tr><th>\(esc($0.0))</th><td>\(esc($0.1))</td></tr>" }.joined()
        return page(title: url.lastPathComponent, subtitle: info.kind, body: """
        <div class="wrap"><div class="art">\(svg)</div><div class="card"><table>\(table)</table>
        <p class="hint">Open in VibeView to rotate, edit and run calculations.</p></div></div>
        """)
    }

    static func errorHTML(_ url: URL) -> String {
        page(title: url.lastPathComponent, subtitle: "Structure file", body: "<p class=hint>VibeView could not read this file.</p>")
    }

    /// Orthographic view along the smallest principal axis, depth-sorted shaded spheres and bonds.
    static func drawing(_ m: Molecule, width: Double, height: Double) -> String {
        guard !m.atoms.isEmpty else { return "" }
        let c = m.centroid
        var pts = m.atoms.map { $0.position - c }
        // orient: largest spread on x, next on y (principal axes of the coordinate covariance)
        var cov = simd_double3x3()
        for p in pts { cov += simd_double3x3(columns: (p * p.x, p * p.y, p * p.z)) }
        if m.atoms.count > 2 {
            let axes = VecMath.symmetricEigen(cov)   // ascending eigenvalues, columns = vectors
            let ex = axes.vectors.columns.2, ey = axes.vectors.columns.1, ez = simd_cross(ex, ey)
            pts = pts.map { Vec3(simd_dot($0, ex), simd_dot($0, ey), simd_dot($0, ez)) }
        }
        // slight tilt for depth
        let t = 0.35
        pts = pts.map { Vec3($0.x, $0.y * cos(t) - $0.z * sin(t), $0.y * sin(t) + $0.z * cos(t)) }
        let rad = m.atoms.map { $0.atomicNumber == 1 ? 0.22 : 0.18 + 0.12 * min(1.6, Elements.element($0.atomicNumber).covalentRadius) }
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for (i, p) in pts.enumerated() { minX = min(minX, p.x - rad[i]); maxX = max(maxX, p.x + rad[i]); minY = min(minY, p.y - rad[i]); maxY = max(maxY, p.y + rad[i]) }
        let s = min((width - 40) / max(maxX - minX, 1), (height - 40) / max(maxY - minY, 1), 90)
        func X(_ p: Vec3) -> Double { width / 2 + (p.x - (minX + maxX) / 2) * s }
        func Y(_ p: Vec3) -> Double { height / 2 - (p.y - (minY + maxY) / 2) * s }
        var defs = Set<Int>()
        enum Item { case atom(Int), bond(Int) }
        var items: [(z: Double, item: Item)] = []
        for i in pts.indices { items.append((pts[i].z, .atom(i))); defs.insert(m.atoms[i].atomicNumber) }
        for (k, b) in m.bonds.enumerated() where b.a < pts.count && b.b < pts.count { items.append(((pts[b.a].z + pts[b.b].z) / 2 - 0.01, .bond(k))) }
        items.sort { $0.z < $1.z }
        var out = "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 \(Int(width)) \(Int(height))' width='\(Int(width))' height='\(Int(height))'><defs>"
        for z in defs {
            let col = Elements.element(z).color
            func hex(_ v: Double) -> String { String(format: "%02x", Int(max(0, min(1, v)) * 255)) }
            let base = "#" + hex(col.x) + hex(col.y) + hex(col.z)
            let dark = "#" + hex(col.x * 0.45) + hex(col.y * 0.45) + hex(col.z * 0.45)
            out += "<radialGradient id='e\(z)' cx='35%' cy='30%' r='75%'><stop offset='0%' stop-color='#ffffff'/><stop offset='25%' stop-color='\(base)'/><stop offset='100%' stop-color='\(dark)'/></radialGradient>"
        }
        out += "</defs>"
        let bondW = max(2.0, 0.16 * s)
        for it in items {
            switch it.item {
            case .atom(let i):
                out += String(format: "<circle cx='%.1f' cy='%.1f' r='%.1f' fill='url(#e%d)'/>", X(pts[i]), Y(pts[i]), rad[i] * s, m.atoms[i].atomicNumber)
            case .bond(let k):
                let b = m.bonds[k]
                out += String(format: "<line x1='%.1f' y1='%.1f' x2='%.1f' y2='%.1f' stroke='#8a8f99' stroke-width='%.1f' stroke-linecap='round'/>",
                              X(pts[b.a]), Y(pts[b.a]), X(pts[b.b]), Y(pts[b.b]), bondW)
            }
        }
        return out + "</svg>"
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func page(title: String, subtitle: String, body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><style>
        :root { color-scheme: light dark; --bg:#f5f6f8; --fg:#1d1f23; --muted:#6b7079; --card:#ffffff; --line:#e3e5e9; }
        @media (prefers-color-scheme: dark) { :root { --bg:#1c1d21; --fg:#ececef; --muted:#9a9ea7; --card:#26282d; --line:#34363c; } }
        body { margin:0; background:var(--bg); color:var(--fg); font:13px -apple-system, system-ui, sans-serif; }
        header { padding:16px 22px 6px; } h1 { font-size:17px; margin:0; font-weight:600; } .sub { color:var(--muted); }
        .wrap { display:flex; gap:18px; padding:10px 22px 22px; align-items:flex-start; }
        .art { flex:0 0 auto; background:var(--card); border-radius:14px; border:1px solid var(--line); }
        .card { flex:1; background:var(--card); border-radius:14px; border:1px solid var(--line); padding:14px 16px; }
        th { text-align:left; color:var(--muted); font-weight:500; padding:4px 14px 4px 0; vertical-align:top; white-space:nowrap; }
        td { padding:4px 0; font-variant-numeric: tabular-nums; word-break: break-word; }
        .hint { color:var(--muted); font-size:12px; margin-top:14px; }
        </style></head><body><header><h1>\(esc(title))</h1><div class="sub">\(esc(subtitle)) · VibeView</div></header>\(body)</body></html>
        """
    }
}
