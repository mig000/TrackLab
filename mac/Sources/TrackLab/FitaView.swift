import SwiftUI
import TrackLabCore

/// A Fita: a onda da música passando sob uma agulha parada a 40 % da largura, como a partitura em cima. O original
/// em cinza e a guitarra separada em âmbar por cima; compassos e batidas do mapa de tempo; o loop sombreado.
/// Clique leva a música até ali; arrastar marca um loop preso nas batidas.
struct FitaView: View {
    let model: SongModel
    /// Segundos visíveis na largura.
    @Binding var span: Double
    @Local private var drag: (from: Double, to: Double)?
    /// Onde o arrasto começou, em tempo da música: a Fita anda enquanto se arrasta tocando.
    @Local private var origin: Double?

    static let playheadAt = 0.4
    static let spans: ClosedRange<Double> = 3...40

    var body: some View {
        let engine = model.engine
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !engine.isPlaying)) { _ in
            GeometryReader { geometry in
                let now = engine.currentTime
                let start = now - span * Self.playheadAt
                Canvas { context, size in
                    draw(in: &context, size: size, start: start, now: now)
                }
                .contentShape(Rectangle())
                .gesture(loopGesture(width: geometry.size.width, start: start))
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func time(at x: Double, width: Double, start: Double) -> Double {
        start + x / max(width, 1) * span
    }

    private func loopGesture(width: Double, start: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let a = origin ?? time(at: value.startLocation.x, width: width, start: start)
                origin = a
                let b = time(at: value.location.x, width: width, start: start)
                if abs(value.translation.width) > 3 { drag = (a, b) }
            }
            .onEnded { value in
                defer {
                    drag = nil
                    origin = nil
                }
                if abs(value.translation.width) <= 3 {
                    model.engine.seek(to: max(0, time(at: value.location.x, width: width, start: start)))
                    return
                }
                guard let drag else { return }
                if let range = LoopRegion.snapped(drag.from, drag.to, grid: model.grid, duration: model.engine.duration) {
                    model.setLoop(range)
                    if !model.engine.isPlaying { model.engine.seek(to: range.lowerBound) }
                }
            }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, start: Double, now: Double) {
        let width = size.width
        let height = size.height
        let middle = height * 0.56
        let half = height * 0.40
        func x(_ t: Double) -> Double { (t - start) / span * width }
        let end = start + span

        // O loop (e o que está sendo arrastado).
        let loops = [model.engine.loop, drag.map { min($0.from, $0.to)...max($0.from, $0.to) }].compactMap { $0 }
        for range in loops where range.upperBound > start && range.lowerBound < end {
            let rect = CGRect(x: x(range.lowerBound), y: 0, width: x(range.upperBound) - x(range.lowerBound), height: height)
            context.fill(Path(rect), with: .color(.orange.opacity(0.13)))
            context.stroke(Path(rect), with: .color(.orange.opacity(0.55)), lineWidth: 1)
        }

        // Batidas e compassos.
        for beat in model.grid.beats where beat >= start && beat <= end {
            var line = Path()
            line.move(to: CGPoint(x: x(beat), y: 14))
            line.addLine(to: CGPoint(x: x(beat), y: height))
            context.stroke(line, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
        }
        let bars = model.grid.bars
        for (index, bar) in bars.enumerated() where bar >= start && bar <= end {
            var line = Path()
            line.move(to: CGPoint(x: x(bar), y: 0))
            line.addLine(to: CGPoint(x: x(bar), y: height))
            context.stroke(line, with: .color(.secondary.opacity(0.55)), lineWidth: 1)
            if index < bars.count - 1 {
                context.draw(Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x(bar) + 4, y: 2), anchor: .topLeading)
            }
        }

        // As ondas: o original atrás, a guitarra na frente.
        let step = 2.0
        if let peaks = model.sourcePeaks {
            context.fill(wave(peaks, start: start, width: width, step: step, middle: middle, half: half),
                         with: .color(.secondary.opacity(0.35)))
        }
        if let peaks = model.guitarPeaks {
            context.fill(wave(peaks, start: start, width: width, step: step, middle: middle, half: half),
                         with: .color(.orange.opacity(0.85)))
        }

        // A agulha.
        let needle = x(now)
        var line = Path()
        line.move(to: CGPoint(x: needle, y: 0))
        line.addLine(to: CGPoint(x: needle, y: height))
        context.stroke(line, with: .color(.accentColor), lineWidth: 2)
    }

    /// A silhueta espelhada da onda, um ponto a cada `step` pixels.
    private func wave(_ peaks: Peaks, start: Double, width: Double, step: Double, middle: Double, half: Double) -> Path {
        var top: [CGPoint] = []
        var x = 0.0
        while x <= width {
            let a = start + x / width * span
            let b = start + (x + step) / width * span
            let amplitude = a < 0 ? 0 : Double(peaks.amplitude(from: a, to: b))
            top.append(CGPoint(x: x, y: middle - min(1, amplitude) * half))
            x += step
        }
        var path = Path()
        guard let first = top.first else { return path }
        path.move(to: first)
        for point in top.dropFirst() { path.addLine(to: point) }
        for point in top.reversed() { path.addLine(to: CGPoint(x: point.x, y: 2 * middle - point.y)) }
        path.closeSubpath()
        return path
    }
}
