import SwiftUI
import TrackLabCore

/// A Fita: a onda da música passando sob uma agulha parada a 40 % da largura, como a partitura em cima. O original
/// em cinza e a guitarra separada em âmbar por cima; compassos e batidas do mapa de tempo; as âncoras em laranja; o
/// loop sombreado. Clique leva a música até ali; arrastar marca um loop preso nas batidas. No Ajuste, arrastar uma
/// batida a leva até onde ela soa (vira âncora) e o duplo clique prende ou solta.
struct FitaView: View {
    let model: SongModel
    /// Segundos visíveis na largura.
    @Binding var span: Double
    @Local private var drag: (from: Double, to: Double)?
    /// Onde o arrasto começou, em tempo da música: a Fita anda enquanto se arrasta tocando.
    @Local private var origin: Double?
    /// No Ajuste: a batida que está sendo arrastada e para onde vai.
    @Local private var held: (point: TempoPoint, to: Double)?

    static let playheadAt = 0.4
    static let spans: ClosedRange<Double> = 3...40
    /// No Ajuste, um arrasto que começa a até tantos pixels de uma batida a pega.
    static let grab = 6.0

    var body: some View {
        // O relógio é lido direto na TimelineView e entra no Canvas: dentro de um GeometryReader a Fita não era
        // redesenhada a cada quadro e ficava parada enquanto a música tocava. O tempo é o do quadro (`context.date`),
        // não o da hora em que a view é avaliada: os passos saem iguais.
        GeometryReader { geometry in
            TimelineView(.animation(paused: !model.engine.isPlaying)) { context in
                let host = CACurrentMediaTime() + context.date.timeIntervalSinceNow
                tape(width: geometry.size.width, now: model.engine.songTime(atHost: host))
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func tape(width: Double, now: Double) -> some View {
        let start = now - span * Self.playheadAt
        return Canvas { context, size in
            draw(in: &context, size: size, start: start, now: now)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(width: width, start: start))
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            guard model.adjusting,
                  let point = model.grid.beat(near: time(at: value.location.x, width: width, start: start),
                                              within: Self.grab / max(width, 1) * span) else { return }
            model.toggleAnchor(point)
        })
    }

    private func time(at x: Double, width: Double, start: Double) -> Double {
        start + x / max(width, 1) * span
    }

    private func dragGesture(width: Double, start: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if origin == nil {
                    let at = time(at: value.startLocation.x, width: width, start: start)
                    origin = at
                    if model.adjusting, let point = model.grid.beat(near: at, within: Self.grab / max(width, 1) * span) {
                        held = (point, point.seconds)
                    }
                }
                if let held {
                    // Pelo deslocamento do mouse, não pela posição: tocando, a Fita anda por baixo.
                    self.held = (held.point, held.point.seconds + value.translation.width / max(width, 1) * span)
                    return
                }
                let b = time(at: value.location.x, width: width, start: start)
                if abs(value.translation.width) > 3, let origin { drag = (origin, b) }
            }
            .onEnded { value in
                defer {
                    drag = nil
                    origin = nil
                    held = nil
                }
                if let held {
                    // Um clique numa batida não leva a música até ela: a Fita andaria e o duplo clique erraria.
                    if abs(value.translation.width) > 3 { model.moveBeat(tick: held.point.tick, to: held.to) }
                    return
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
        // No ⇧ + arrastar só a onda (o som) desliza com o mouse; a grade, as âncoras e a agulha ficam paradas.
        let soundStart = start - model.soundShift

        // O loop (e o que está sendo arrastado).
        let loops = [model.engine.loop, drag.map { min($0.from, $0.to)...max($0.from, $0.to) }].compactMap { $0 }
        for range in loops where range.upperBound > start && range.lowerBound < end {
            let rect = CGRect(x: x(range.lowerBound), y: 0, width: x(range.upperBound) - x(range.lowerBound), height: height)
            context.fill(Path(rect), with: .color(.orange.opacity(0.13)))
            context.stroke(Path(rect), with: .color(.orange.opacity(0.55)), lineWidth: 1)
        }

        // Batidas e compassos; no Ajuste as batidas aparecem mais, porque são para pegar.
        for beat in model.grid.beats where beat >= start && beat <= end {
            var line = Path()
            line.move(to: CGPoint(x: x(beat), y: 14))
            line.addLine(to: CGPoint(x: x(beat), y: height))
            context.stroke(line, with: .color(.secondary.opacity(model.adjusting ? 0.4 : 0.18)), lineWidth: 1)
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
            context.fill(wave(peaks, start: soundStart, width: width, step: step, middle: middle, half: half),
                         with: .color(.secondary.opacity(0.35)))
        }
        if let peaks = model.guitarPeaks {
            context.fill(wave(peaks, start: soundStart, width: width, step: step, middle: middle, half: half),
                         with: .color(.orange.opacity(0.85)))
        }

        // Os compassos conferidos: uma faixa verde no alto.
        for (index, bar) in bars.enumerated() where index + 1 < bars.count && model.checkedBars.contains(index + 1) {
            let next = bars[index + 1]
            guard next > start && bar < end else { continue }
            context.fill(Path(CGRect(x: x(bar), y: 0, width: x(next) - x(bar), height: 4)), with: .color(.green.opacity(0.8)))
        }

        // As âncoras: uma linha laranja com um triângulo no alto.
        for point in model.grid.points where point.isAnchor && point.seconds >= start && point.seconds <= end {
            anchorMark(in: &context, x: x(point.seconds), height: height, color: .orange)
        }

        // Os toques do Bater junto em curso: marcas laranja embaixo.
        for tap in model.taps where tap >= start && tap <= end {
            var mark = Path()
            mark.move(to: CGPoint(x: x(tap), y: height - 18))
            mark.addLine(to: CGPoint(x: x(tap), y: height))
            context.stroke(mark, with: .color(.orange), lineWidth: 2)
        }

        // A batida sendo arrastada: de onde saiu, apagada; para onde vai, com a diferença em milissegundos.
        if let held {
            var from = Path()
            from.move(to: CGPoint(x: x(held.point.seconds), y: 14))
            from.addLine(to: CGPoint(x: x(held.point.seconds), y: height))
            context.stroke(from, with: .color(.orange.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            anchorMark(in: &context, x: x(held.to), height: height, color: .orange)
            let delta = Int(((held.to - held.point.seconds) * 1000).rounded())
            context.draw(Text("\(delta > 0 ? "+" : "")\(delta) ms").font(.caption.monospacedDigit()).foregroundStyle(.orange),
                         at: CGPoint(x: x(held.to) + 6, y: 12), anchor: .leading)
        }

        // A agulha.
        let needle = x(now)
        var line = Path()
        line.move(to: CGPoint(x: needle, y: 0))
        line.addLine(to: CGPoint(x: needle, y: height))
        context.stroke(line, with: .color(.accentColor), lineWidth: 2)
    }

    private func anchorMark(in context: inout GraphicsContext, x: Double, height: Double, color: Color) {
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: height))
        context.stroke(line, with: .color(color), lineWidth: 1.5)
        var head = Path()
        head.move(to: CGPoint(x: x - 5, y: 0))
        head.addLine(to: CGPoint(x: x + 5, y: 0))
        head.addLine(to: CGPoint(x: x, y: 8))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    /// A silhueta espelhada da onda, um ponto a cada `step` pixels. Os pontos ficam presos em instantes da música
    /// (múltiplos de um passo de tempo), não em pixels da tela: tocando, a silhueta só desliza; amostrada nos pixels,
    /// cada quadro pegava trechos um pouco diferentes do áudio e a onda tremia.
    private func wave(_ peaks: Peaks, start: Double, width: Double, step: Double, middle: Double, half: Double) -> Path {
        let dt = step / max(width, 1) * span
        var top: [CGPoint] = []
        var k = (start / dt).rounded(.down) - 1
        while true {
            let a = k * dt
            let x = (a - start) / span * width
            let amplitude = a < 0 ? 0 : Double(peaks.amplitude(from: a, to: a + dt))
            top.append(CGPoint(x: x, y: middle - min(1, amplitude) * half))
            if x > width { break }
            k += 1
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
