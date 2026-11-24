import SwiftUI
import Charts
import MolCore

struct TrajectoryView: View {
    @ObservedObject var editor: EditorModel
    let result: CalculationResult

    @State private var playing = false
    @State private var loop = true
    @State private var speed = 4.0   // frames per second

    private var count: Int { max(result.steps.count, result.energies.count) }
    private var hasFrames: Bool { !result.steps.isEmpty }
    private var current: Int { min(max(editor.frameIndex ?? (count - 1), 0), max(count - 1, 0)) }
    private var minE: Double { result.energies.min() ?? 0 }

    private struct Pt: Identifiable { var i: Int; var rel: Double; var id: Int { i } }
    private var points: [Pt] {
        result.energies.enumerated().map { Pt(i: $0.offset, rel: ($0.element - minE) * SpectrumMath.hartreeToKcal) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if hasFrames { transport }
            chart
            footer
        }
        .padding(10)
        .task(id: "\(playing)-\(speed)") { await runPlayback() }
        .onChange(of: playing) { _, p in editor.isPlayingFrames = p }
        .onDisappear { playing = false; editor.isPlayingFrames = false }
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button { go(0) } label: { Image(systemName: "backward.end.fill") }.help("First frame")
            Button { go(current - 1) } label: { Image(systemName: "backward.frame.fill") }.help("Previous frame")
            Button { if !playing, current >= count - 1 { go(0) }; playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 16)
            }.help(playing ? "Pause" : "Play")
            Button { go(current + 1) } label: { Image(systemName: "forward.frame.fill") }.help("Next frame")
            Button { go(count - 1) } label: { Image(systemName: "forward.end.fill") }.help("Last frame")
            Slider(value: Binding(get: { Double(current) }, set: { go(Int($0.rounded())) }),
                   in: 0...Double(max(count - 1, 1)), step: 1)
            Text("\(current + 1) / \(count)").monospacedDigit().font(.caption).foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
            Toggle(isOn: $loop) { Image(systemName: "repeat") }.toggleStyle(.button).help("Loop")
            Menu {
                ForEach([1.0, 2.0, 4.0, 8.0, 16.0], id: \.self) { s in
                    Button { speed = s } label: { Text("\(Int(s)) frames/s") }
                }
            } label: { Image(systemName: "speedometer") }
                .menuStyle(.borderlessButton).fixedSize().help("Playback speed")
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private var chart: some View {
        if result.energies.count > 1 {
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value("Step", p.i), y: .value("ΔE", p.rel))
                        .foregroundStyle(Color.accentColor.opacity(0.7))
                    PointMark(x: .value("Step", p.i), y: .value("ΔE", p.rel))
                        .symbolSize(p.i == current ? 0 : 22).foregroundStyle(Color.accentColor)
                }
                if let cur = points.first(where: { $0.i == current }) {
                    RuleMark(x: .value("Step", cur.i)).foregroundStyle(.secondary.opacity(0.6))
                    PointMark(x: .value("Step", cur.i), y: .value("ΔE", cur.rel))
                        .symbolSize(70).foregroundStyle(Color.orange)
                }
            }
            .chartXAxisLabel("Step")
            .chartYAxisLabel("Relative energy (kcal/mol)")
            .chartXScale(domain: 0...max(count - 1, 1))
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            guard let plot = proxy.plotFrame else { return }
                            let x = v.location.x - geo[plot].origin.x
                            if let s: Double = proxy.value(atX: x) { go(Int(s.rounded())) }
                        })
                }
            }
            .frame(minHeight: 90)
        } else {
            Spacer()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if current < result.energies.count {
                let e = result.energies[current]
                Text(String(format: "E = %.8f Ha", e)).monospacedDigit()
                Text(String(format: "ΔE = %.3f kcal/mol", (e - minE) * SpectrumMath.hartreeToKcal))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            TerminationBadge(normal: result.normalTermination)
            Spacer()
            if hasFrames {
                Button("Use This Geometry") {
                    if result.steps.indices.contains(current) {
                        editor.replaceMolecule(result.steps[current], actionName: "Use Result Geometry")
                        editor.frameIndex = nil
                    }
                }
                .controlSize(.small)
            }
        }
        .font(.caption)
    }

    private func go(_ i: Int) {
        guard hasFrames else { return }
        editor.frameIndex = min(max(i, 0), count - 1)
    }

    private func runPlayback() async {
        guard playing else { return }
        let delay = UInt64(1_000_000_000 / max(speed, 0.5))
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { break }
            let next = current + 1
            if next >= count {
                if loop { go(0) } else { playing = false; break }
            } else { go(next) }
        }
    }
}
