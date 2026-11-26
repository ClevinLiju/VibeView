import SwiftUI
import MolCore
import MolAnalysis

/// Orbital energy-level diagram (Orbitals tab): one column per spin set (restricted, or alpha + beta), degenerate
/// levels drawn side by side, occupied levels solid with electrons, virtual levels dashed, HOMO/LUMO labelled and
/// the gap annotated. Click a level to show its orbital; the shown orbital is highlighted. Opens zoomed on the
/// frontier region; pinch or the +/− buttons zoom, drag pans, "Frontier" / "All" reset the window.
struct OrbitalLevelDiagramView: View {
    let diagram: OrbitalLevelDiagram
    /// 1-based orbital index shown in the viewport.
    let selected: Int?
    /// Spin column the selection belongs to (UHF), nil = any.
    let selectedSpin: OrbitalLevelDiagram.Column.Spin?
    /// (1-based orbital index, column spin).
    var onPick: (Int, OrbitalLevelDiagram.Column.Spin) -> Void

    @State private var window: ClosedRange<Double>? = nil
    @State private var dragStart: ClosedRange<Double>? = nil
    @State private var pinchStart: ClosedRange<Double>? = nil
    @State private var hover: CGPoint? = nil

    private let left: CGFloat = 40, top: CGFloat = 10, bottom: CGFloat = 18

    /// HOMO-centred window: 2.2 gaps below HOMO to 2.2 gaps above LUMO.
    static func frontierWindow(_ d: OrbitalLevelDiagram) -> ClosedRange<Double> {
        let h = d.columns.compactMap { $0.homo?.energyEV }.max(), l = d.columns.compactMap { $0.lumo?.energyEV }.min()
        if let h, let l {
            let gap = max(1, l - h)
            return (h - gap * 2.2)...(l + gap * 2.2)
        }
        return fullWindow(d)
    }
    static func fullWindow(_ d: OrbitalLevelDiagram) -> ClosedRange<Double> {
        let e = d.columns.flatMap { $0.levels.map(\.energyEV) }
        guard let lo = e.min(), let hi = e.max() else { return -10...5 }
        let pad = max(0.5, (hi - lo) * 0.03)
        return (lo - pad)...(hi + pad)
    }

    private var win: ClosedRange<Double> { window ?? Self.frontierWindow(diagram) }

    struct Hit { var rect: CGRect; var orbital: Int; var spin: OrbitalLevelDiagram.Column.Spin; var level: OrbitalLevelDiagram.Level }

    /// Level segments laid out in `size` for the current window.
    func layout(_ size: CGSize) -> [Hit] {
        let w = win
        let plotH = size.height - top - bottom
        func y(_ e: Double) -> CGFloat { top + CGFloat(1 - (e - w.lowerBound) / (w.upperBound - w.lowerBound)) * plotH }
        let cols = diagram.columns
        guard !cols.isEmpty else { return [] }
        let colW = (size.width - left - 8) / CGFloat(cols.count)
        var hits: [Hit] = []
        for (ci, c) in cols.enumerated() {
            let x0 = left + CGFloat(ci) * colW + 12, x1 = x0 + max(20, colW - 84)
            for lv in c.levels where w.contains(lv.energyEV) {
                let n = lv.orbitalIndices.count
                let gapX: CGFloat = 5
                let segW = max(6, (x1 - x0 - CGFloat(n - 1) * gapX) / CGFloat(n))
                for (k, oi) in lv.orbitalIndices.enumerated() {
                    let a = x0 + CGFloat(k) * (segW + gapX)
                    hits.append(Hit(rect: CGRect(x: a, y: y(lv.energyEV) - 4, width: segW, height: 8), orbital: oi + 1, spin: c.spin, level: lv))
                }
            }
        }
        return hits
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Energy levels").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { zoom(0.7) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                Button { zoom(1 / 0.7) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                Button("Frontier") { window = nil }.help("HOMO/LUMO region")
                Button("All") { window = Self.fullWindow(diagram) }.help("Every level")
            }
            .buttonStyle(.borderless).controlSize(.small)
            GeometryReader { geo in
                let hits = layout(geo.size)
                Canvas { ctx, size in draw(&ctx, size: size, hits: hits) }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { v in
                        if let h = hits.first(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(v.location) }) { onPick(h.orbital, h.spin) }
                    })
                    .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { v in
                        let w0 = dragStart ?? win
                        if dragStart == nil { dragStart = w0 }
                        let per = (w0.upperBound - w0.lowerBound) / Double(max(1, geo.size.height - top - bottom))
                        let d = Double(v.translation.height) * per
                        window = (w0.lowerBound + d)...(w0.upperBound + d)
                    }.onEnded { _ in dragStart = nil })
                    .simultaneousGesture(MagnifyGesture().onChanged { v in
                        let w0 = pinchStart ?? win
                        if pinchStart == nil { pinchStart = w0 }
                        let c = (w0.lowerBound + w0.upperBound) / 2, r = (w0.upperBound - w0.lowerBound) / 2 / max(0.05, Double(v.magnification))
                        window = (c - r)...(c + r)
                    }.onEnded { _ in pinchStart = nil })
                    .onContinuousHover { p in if case .active(let q) = p { hover = q } else { hover = nil } }
                    .help(hoverText(hits))
            }
        }
        .onChange(of: diagram) { _, _ in window = nil }
    }

    private func zoom(_ f: Double) {
        let w = win, c = (w.lowerBound + w.upperBound) / 2, r = (w.upperBound - w.lowerBound) / 2 * f
        window = (c - r)...(c + r)
    }

    private func hoverText(_ hits: [Hit]) -> String {
        guard let p = hover, let h = hits.first(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }) else { return "" }
        let lv = h.level
        return String(format: "%@ #%d  %.3f eV (%.5f Eh)  occupation %g", lv.label.isEmpty ? "orbital" : lv.label, h.orbital,
                      lv.energyEV, lv.energy, lv.occupation)
    }

    private func isSelected(_ h: Hit) -> Bool {
        guard let s = selected, h.orbital == s else { return false }
        return selectedSpin == nil || selectedSpin == h.spin || h.spin == .restricted
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, hits: [Hit]) {
        let w = win
        let plotH = size.height - top - bottom
        func y(_ e: Double) -> CGFloat { top + CGFloat(1 - (e - w.lowerBound) / (w.upperBound - w.lowerBound)) * plotH }
        // Axis and grid.
        let span = w.upperBound - w.lowerBound
        let raw = span / 6, p10 = pow(10, floor(log10(raw))), f = raw / p10
        let step = (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * p10
        var e = (w.lowerBound / step).rounded(.up) * step
        while e <= w.upperBound {
            let py = y(e)
            var line = Path(); line.move(to: CGPoint(x: left, y: py)); line.addLine(to: CGPoint(x: size.width, y: py))
            ctx.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 0.5)
            ctx.draw(Text(String(format: step < 1 ? "%.1f" : "%.0f", e)).font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: left - 5, y: py), anchor: .trailing)
            e += step
        }
        ctx.draw(Text("eV").font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: 4, y: top), anchor: .topLeading)
        let cols = diagram.columns
        if cols.count > 1 {
            let colW = (size.width - left - 8) / CGFloat(cols.count)
            for (ci, c) in cols.enumerated() {
                ctx.draw(Text(c.spin == .alpha ? "α" : c.spin == .beta ? "β" : "").font(.caption.weight(.semibold)).foregroundStyle(.secondary),
                         at: CGPoint(x: left + CGFloat(ci) * colW + colW / 2 - 20, y: size.height - 2), anchor: .bottom)
            }
        }
        // Levels.
        for h in hits {
            let lv = h.level, sel = isSelected(h)
            let py = h.rect.midY
            var p = Path(); p.move(to: CGPoint(x: h.rect.minX, y: py)); p.addLine(to: CGPoint(x: h.rect.maxX, y: py))
            let color: Color = sel ? .accentColor : (lv.isOccupied ? .primary : .secondary)
            let style = StrokeStyle(lineWidth: sel ? 3 : 1.6, lineCap: .round, dash: lv.isOccupied || sel ? [] : [4, 2.5])
            ctx.stroke(p, with: .color(color), style: style)
            if lv.isOccupied {
                let electrons = h.spin == .restricted ? Int(lv.occupation.rounded()) : 1
                let mid = h.rect.midX
                for k in 0..<min(2, max(1, electrons)) {
                    let dx: CGFloat = electrons > 1 ? (k == 0 ? -4 : 4) : 0
                    ctx.fill(Path(ellipseIn: CGRect(x: mid + dx - 2, y: py - 7, width: 4, height: 4)), with: .color(.accentColor))
                }
            }
        }
        // HOMO/LUMO labels (once per level) and the gap.
        var labelled = Set<String>()
        for h in hits where (h.level.isHOMO || h.level.isLUMO) {
            let key = "\(h.spin.rawValue)\(h.level.id)"
            guard labelled.insert(key).inserted else { continue }
            let right = hits.filter { $0.spin == h.spin && $0.level.id == h.level.id }.map(\.rect.maxX).max() ?? h.rect.maxX
            ctx.draw(Text(h.level.isHOMO ? "HOMO" : "LUMO").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary),
                     at: CGPoint(x: right + 4, y: h.rect.midY), anchor: .leading)
        }
        let colW = (size.width - left - 8) / CGFloat(max(1, cols.count))
        for (ci, c) in cols.enumerated() {
            guard let hm = c.homo, let lm = c.lumo, let gap = c.homoLumoGapEV else { continue }
            let x = left + CGFloat(ci) * colW + colW - 22
            let y0 = y(hm.energyEV), y1 = y(lm.energyEV)
            guard y0.isFinite, y1.isFinite else { continue }
            let yc0 = min(max(y0, top), top + plotH), yc1 = min(max(y1, top), top + plotH)
            var a = Path(); a.move(to: CGPoint(x: x, y: yc0)); a.addLine(to: CGPoint(x: x, y: yc1))
            for (yy, dir) in [(yc1, CGFloat(1)), (yc0, CGFloat(-1))] {
                a.move(to: CGPoint(x: x - 3, y: yy + 4 * dir)); a.addLine(to: CGPoint(x: x, y: yy)); a.addLine(to: CGPoint(x: x + 3, y: yy + 4 * dir))
            }
            ctx.stroke(a, with: .color(.orange), lineWidth: 1.2)
            ctx.draw(Text(String(format: "%.2f eV", gap)).font(.system(size: 9, weight: .medium)).foregroundStyle(.orange),
                     at: CGPoint(x: x - 4, y: (yc0 + yc1) / 2), anchor: .trailing)
        }
    }
}
