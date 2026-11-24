import SwiftUI
import AppKit
import simd
import MolCore

/// Compact, display-ready tooltip content for a hover target (pure value; build with `make`).
///
/// Atom: title "C3", subtitle "Carbon", rows: charge (when nonzero), bonded neighbors, any measurement
/// values the atom takes part in. Bond: title "C1–O2", subtitle "Double bond", rows: length, plus
/// measurements through both atoms.
public struct HoverTooltip: Sendable, Equatable {
    public struct Row: Sendable, Equatable { public var label: String; public var value: String }
    public var title: String
    public var subtitle: String
    public var rows: [Row]
    /// Element color of the hovered atom (bond: first atom), for the accent dot.
    public var accent: RGBA
    public var isEmpty: Bool { title.isEmpty }
    public static let empty = HoverTooltip(title: "", subtitle: "", rows: [], accent: .clear)

    /// One-line plain-text form ("C3 · Carbon · q −0.412").
    public var plainText: String { ([title, subtitle] + rows.map { "\($0.label) \($0.value)" }).filter { !$0.isEmpty }.joined(separator: " · ") }

    static func fmtCharge(_ q: Double) -> String { String(format: "%+.3f e", q).replacingOccurrences(of: "-", with: "−") }

    public static func make(_ info: HoverInfo, molecule m: Molecule, measurements: [Measurement] = []) -> HoverTooltip {
        func name(_ i: Int) -> String { "\(ElementPalette.symbol(m.atoms[i].atomicNumber))\(i + 1)" }
        func involved(_ atoms: Set<Int>) -> [Row] {
            measurements.compactMap { ms -> Row? in
                let a = ms.atoms
                guard a.allSatisfy({ $0 >= 0 && $0 < m.atoms.count }), !atoms.isDisjoint(with: a) else { return nil }
                let label = a.map(name).joined(separator: "–")
                switch ms {
                case let .distance(i, j): return Row(label: label, value: String(format: "%.3f Å", m.distance(i, j)))
                case let .angle(i, j, k): return Row(label: label, value: String(format: "%.1f°", m.angle(i, j, k)))
                case let .dihedral(i, j, k, l): return Row(label: label, value: String(format: "%.1f°", m.dihedral(i, j, k, l)))
                }
            }
        }
        if let a = info.atom {
            var rows: [Row] = []
            if a.charge != 0 { rows.append(Row(label: "Charge", value: fmtCharge(a.charge))) }
            if let l = a.label, !l.isEmpty { rows.append(Row(label: "Label", value: l)) }
            if !a.neighbors.isEmpty {
                let nb = a.neighbors.prefix(4).map(name).joined(separator: ", ") + (a.neighbors.count > 4 ? " …" : "")
                rows.append(Row(label: "Bonded", value: nb))
            }
            rows += involved([a.index])
            return HoverTooltip(title: name(a.index), subtitle: a.elementName, rows: rows, accent: ElementPalette.color(a.atomicNumber))
        }
        if let b = info.bond {
            let order: String
            switch b.order { case .single: order = "Single"; case .double: order = "Double"; case .triple: order = "Triple"; case .aromatic: order = "Aromatic" }
            var rows = [Row(label: "Length", value: String(format: "%.3f Å", b.length))]
            rows += involved([b.atoms.0, b.atoms.1]).filter { !($0.label == "\(name(b.atoms.0))–\(name(b.atoms.1))" || $0.label == "\(name(b.atoms.1))–\(name(b.atoms.0))") }
            return HoverTooltip(title: "\(name(b.atoms.0))–\(name(b.atoms.1))", subtitle: "\(order) bond", rows: rows,
                                accent: ElementPalette.color(m.atoms[b.atoms.0].atomicNumber))
        }
        return .empty
    }
}

/// Observable hover state for SwiftUI. `MoleculeRenderer.hoverTooltipModel` keeps it current.
@MainActor public final class HoverTooltipModel: ObservableObject {
    @Published public private(set) var tooltip: HoverTooltip = .empty
    /// Pointer location in view coordinates (AppKit, origin bottom-left).
    @Published public private(set) var location: CGPoint = .zero
    @Published public private(set) var visible = false
    /// Delay before a tooltip appears on a new target (s). Moving between targets while visible is instant.
    public var showDelay: TimeInterval = 0.06
    private var pending: DispatchWorkItem?
    public init() {}

    func update(_ t: HoverTooltip, at p: CGPoint?) {
        pending?.cancel(); pending = nil
        guard !t.isEmpty, let p else { visible = false; tooltip = .empty; return }
        // Location only changes with the target, so the bubble doesn't jitter under the pointer.
        if visible || showDelay <= 0 { tooltip = t; location = p; visible = true; return }
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.tooltip = t; self?.location = p; self?.visible = true }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: w)
    }
}

/// Styled hover tooltip bubble. Use `HoverTooltipOverlay(renderer:)` over `MoleculeSceneView`, or this
/// view directly with a `HoverTooltip`.
public struct HoverTooltipView: View {
    public var tooltip: HoverTooltip
    public init(tooltip: HoverTooltip) { self.tooltip = tooltip }
    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: tooltip.accent.nsColor)).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                Text(tooltip.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(tooltip.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !tooltip.rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                    ForEach(Array(tooltip.rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Text(r.value).font(.system(size: 10.5, design: .monospaced))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        .fixedSize()
    }
}

/// Drop-in overlay: `ZStack { MoleculeSceneView(renderer: r); HoverTooltipOverlay(renderer: r) }`.
/// Hit-testing is disabled, so it never steals mouse events from the 3D view.
public struct HoverTooltipOverlay: View {
    @ObservedObject var model: HoverTooltipModel
    public init(renderer: MoleculeRenderer) { model = renderer.hoverTooltipModel }
    public init(model: HoverTooltipModel) { self.model = model }
    public var body: some View {
        GeometryReader { geo in
            if model.visible {
                let p = model.location
                // AppKit (bottom-left) -> SwiftUI (top-left); offset right/below the pointer, flip near edges.
                let x = p.x + 14 > geo.size.width - 180 ? p.x - 14 : p.x + 14
                let y = geo.size.height - p.y + 16
                HoverTooltipView(tooltip: model.tooltip)
                    .alignmentGuide(.leading) { d in x + 14 > geo.size.width - 180 ? d.width - x + 0 : -x }
                    .alignmentGuide(.top) { d in y + d.height > geo.size.height ? -(y - 32 - d.height) : -y }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.08), value: model.visible)
    }
}
