import SwiftUI
import TrackLabCore

/// A Fita: a onda da música passando sob uma agulha parada a 40 % da largura, como a partitura em cima (com um loop
/// que cabe na tela, a onda para e a agulha anda). O original
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

    static func clampSpan(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 10, spans.lowerBound), spans.upperBound)
    }
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
        // Um loop que cabe na tela para a Fita e só a agulha anda (a TAB faz a mesma conta).
        let start = LoopView.windowStart(now: now, loop: model.engine.loop, span: span, playheadAt: Self.playheadAt)
            ?? now - span * Self.playheadAt
        // No espectro, a imagem vai numa camada da GPU por baixo (só a transformação muda a cada quadro) e o Canvas,
        // transparente, desenha por cima a grade, as notas e o teclado; `drawingGroup` rasteriza o Canvas no Metal.
        let pitches = model.fitaMode == .spectrum ? pitchWindow(gridStart: start) : nil
        return ZStack(alignment: .topLeading) {
            if let pitches {
                SpectrumLayerView(image: model.spectrumImage, start: start - model.soundShift, span: span,
                                  pitches: pitches, spectrum: model.spectrum)
                    .padding(.top, Self.waveStrip)
            }
            Canvas { context, size in
                draw(in: &context, size: size, start: start, now: now, pitches: pitches)
            }
            .drawingGroup()
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
                // Um clique na Fita devolve as teclas ao transporte (tira o foco da busca, por exemplo).
                if let window = NSApp.keyWindow, window.firstResponder is NSText { window.makeFirstResponder(nil) }
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

    private func draw(in context: inout GraphicsContext, size: CGSize, start: Double, now: Double,
                      pitches: ClosedRange<Double>?) {
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

        // Batidas e compassos; no Ajuste as batidas aparecem mais, porque são para pegar. No espectro, só na faixa
        // da onda: embaixo ele desenha os seus.
        let gridBottom = model.fitaMode == .spectrum ? Self.waveStrip : height
        var beatLines = Path()
        for beat in model.grid.beats where beat >= start && beat <= end {
            beatLines.addRect(CGRect(x: x(beat), y: 14, width: 1, height: max(0, gridBottom - 14)))
        }
        context.fill(beatLines, with: .color(.secondary.opacity(model.adjusting ? 0.4 : 0.18)))
        let bars = model.grid.bars
        var barLines = Path()
        for (index, bar) in bars.enumerated() where bar >= start && bar <= end {
            barLines.addRect(CGRect(x: x(bar), y: 0, width: 1, height: gridBottom))
            if index < bars.count - 1 {
                context.draw(Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: x(bar) + 4, y: 2), anchor: .topLeading)
            }
        }
        context.fill(barLines, with: .color(.secondary.opacity(0.55)))

        // O espectro (com as notas da TAB por cima) no lugar das ondas.
        if model.fitaMode == .spectrum {
            drawSpectrum(in: &context, size: size, start: soundStart, gridStart: start, pitches: pitches)
        }
        // As ondas: o original atrás, a guitarra na frente.
        let step = 2.0
        if model.fitaMode == .wave, let peaks = model.sourcePeaks {
            context.fill(wave(peaks, start: soundStart, width: width, step: step, middle: middle, half: half),
                         with: .color(.secondary.opacity(0.35)))
        }
        if model.fitaMode == .wave, let peaks = model.guitarPeaks {
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

    /// O espectro do trecho visível, como a Lente do TabLab: em cima, uma faixa estreita com a onda; embaixo, o que vai
    /// sobre a imagem (ela fica na camada da GPU, `SpectrumLayerView`). A janela de alturas acompanha as notas do trecho (das duas
    /// pistas, com folga, ao menos uma oitava e meia) e desliza tocando; com Z, fica em volta da nota que toca. Por
    /// cima: as linhas dos compassos e das batidas; as notas (a pista em âmbar, a segunda em azul) como faixas que
    /// seguem a escrita (o bend sobe, o vibrato ondula), com a casa; dentro de cada faixa, pontilhada, a altura que o
    /// som tem de verdade (o motor mede); e o teclado à esquerda.
    private func drawSpectrum(in context: inout GraphicsContext, size: CGSize, start: Double, gridStart: Double,
                              pitches: ClosedRange<Double>?) {
        let width = size.width
        let strip = Self.waveStrip
        let height = size.height - strip
        _ = model.pitchCurvesVersion   // uma curva nova redesenha a Fita

        // A onda, estreita, em cima.
        let step = 2.0
        if let peaks = model.sourcePeaks {
            context.fill(wave(peaks, start: start, width: width, step: step, middle: strip / 2, half: strip * 0.45),
                         with: .color(.secondary.opacity(0.35)))
        }
        if let peaks = model.guitarPeaks {
            context.fill(wave(peaks, start: start, width: width, step: step, middle: strip / 2, half: strip * 0.45),
                         with: .color(.orange.opacity(0.85)))
        }
        context.translateBy(x: 0, y: strip)
        defer { context.translateBy(x: 0, y: -strip) }

        // A imagem está na camada de baixo (`SpectrumLayerView`); aqui só o que vai por cima.
        guard model.spectrum != nil, model.spectrumImage != nil, let pitches else {
            context.draw(Text(model.spectrumMessage ?? "Calculando o espectro…").font(.caption).foregroundStyle(.secondary),
                         at: CGPoint(x: width / 2, y: height / 2))
            return
        }
        let main = model.scoreNotes.indices.contains(model.scoreTrack) ? model.scoreNotes[model.scoreTrack] : []
        let second = model.scoreSecond.flatMap { model.scoreNotes.indices.contains($0) ? model.scoreNotes[$0] : nil } ?? []
        let lowPitch = pitches.lowerBound
        let highPitch = pitches.upperBound
        func y(_ pitch: Double) -> Double { height - (pitch - lowPitch) / (highPitch - lowPitch) * height }

        // Batidas e compassos por cima do espectro: a TAB se confere com eles.
        func gx(_ t: Double) -> Double { (t - gridStart) / span * width }
        var beatLines = Path()
        for beat in model.grid.beats where beat >= gridStart && beat <= gridStart + span {
            beatLines.addRect(CGRect(x: gx(beat), y: 0, width: 1, height: height))
        }
        context.fill(beatLines, with: .color(.white.opacity(0.07)))
        var barLines = Path()
        for bar in model.grid.bars where bar >= gridStart && bar <= gridStart + span {
            barLines.addRect(CGRect(x: gx(bar), y: 0, width: 1, height: height))
        }
        context.fill(barLines, with: .color(.white.opacity(0.3)))

        // As notas: faixas que seguem a escrita (a largura da Lente: 72 % do semitom), a casa, e a curva do som. Cada
        // pista num caminho só para as faixas e outro para os pontos (centenas de pontos a cada quadro, um por um,
        // custavam caro).
        let semitone = height / (highPitch - lowPitch)
        let half = max(3, min(8, semitone * 0.36))
        func bands(_ notes: [ScoreNote], track: Int, color: Color) {
            var visible: [ScoreNote] = []
            var shapes = Path()
            var dots = Path()
            var labels: [(fret: Int, at: CGPoint)] = []
            for note in notes {
                let s0 = model.grid.seconds(at: note.tick)
                guard s0 < gridStart + span else { continue }
                let s1 = model.grid.seconds(at: note.tick + note.duration)
                guard s1 > gridStart else { continue }
                visible.append(note)
                let x0 = gx(s0)
                let x1 = max(gx(s1) - 1, x0 + 3)
                let steps = max(2, Int(((x1 - x0) / 3).rounded(.up)))
                let centers = (0...steps).map { i -> CGPoint in
                    let f = Double(i) / Double(steps)
                    let offset = note.shape(fraction: f, elapsed: f * (s1 - s0))
                    return CGPoint(x: x0 + (x1 - x0) * f, y: y(Double(note.pitch) + offset))
                }
                shapes.move(to: CGPoint(x: centers[0].x, y: centers[0].y - half))
                for point in centers.dropFirst() { shapes.addLine(to: CGPoint(x: point.x, y: point.y - half)) }
                for point in centers.reversed() { shapes.addLine(to: CGPoint(x: point.x, y: point.y + half)) }
                shapes.closeSubpath()
                // A altura do som, pontilhada dentro da faixa.
                if let curve = model.pitchCurves[model.curveKey(note, track: track)] {
                    for (k, value) in curve.values.enumerated() {
                        guard let value else { continue }
                        let t = curve.from + Double(k) * curve.hop
                        dots.addEllipse(in: CGRect(x: gx(t) - 1.1, y: y(value) - 1.1, width: 2.2, height: 2.2))
                    }
                }
                if x1 - x0 > 16, half * 2 >= 9 { labels.append((note.fret, CGPoint(x: x0 + 3, y: centers[0].y - half - 1))) }
            }
            context.fill(shapes, with: .color(color.opacity(0.22)))
            context.stroke(shapes, with: .color(color), lineWidth: 1.2)
            context.fill(dots, with: .color(.white.opacity(0.9)))
            // Uma casa resolvida serve para todas as notas com ela.
            var resolved: [Int: GraphicsContext.ResolvedText] = [:]
            let font = Font.system(size: min(11, half * 2 - 1)).weight(.semibold).monospacedDigit()
            for label in labels {
                let text = resolved[label.fret] ?? context.resolve(Text("\(label.fret)").font(font).foregroundStyle(color))
                resolved[label.fret] = text
                context.draw(text, at: label.at, anchor: .bottomLeading)
            }
            if !visible.isEmpty { model.askCurves(visible, track: track) }
        }
        if let index = model.scoreSecond { bands(second, track: index, color: .cyan) }
        bands(main, track: model.scoreTrack, color: .orange)

        // O teclado à esquerda (o da Lente): as teclas brancas e pretas de cada semitom, os Dós e os Mis com nome.
        let gutter = Self.keyboardWidth
        context.fill(Path(CGRect(x: 0, y: 0, width: gutter, height: height)), with: .color(Color(red: 0.06, green: 0.07, blue: 0.09)))
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        var whiteKeys = Path()
        var blackKeys = Path()
        var rules = Path()
        var keyNames: [(String, Bool, CGPoint)] = []
        for pitch in Int(lowPitch.rounded(.up))...Int(highPitch.rounded(.down)) {
            let y0 = y(Double(pitch) + 0.5)
            let y1 = y(Double(pitch) - 0.5)
            let pc = ((pitch % 12) + 12) % 12
            let black = [1, 3, 6, 8, 10].contains(pc)
            let key = CGRect(x: black ? 16 : 4, y: y0 + 0.5, width: black ? gutter - 20 : gutter - 8, height: max(0, y1 - y0 - 1))
            if black { blackKeys.addRect(key) } else { whiteKeys.addRect(key) }
            if pc == 0 || pc == 4 || semitone >= 16 {
                keyNames.append(("\(names[pc])\(pitch / 12 - 1)", pc == 0, CGPoint(x: 6, y: (y0 + y1) / 2)))
                rules.addRect(CGRect(x: gutter, y: y1.rounded(), width: width - gutter, height: 1))
            }
        }
        context.fill(whiteKeys, with: .color(Color(red: 0.13, green: 0.15, blue: 0.19)))
        context.fill(blackKeys, with: .color(Color(red: 0.04, green: 0.05, blue: 0.07)))
        context.fill(rules, with: .color(.white.opacity(0.04)))
        for (name, isC, at) in keyNames {
            context.draw(Text(name).font(.system(size: 9).monospacedDigit())
                .foregroundStyle(isC ? Color(white: 0.65) : Color(white: 0.45)), at: at, anchor: .leading)
        }
    }

    /// A janela de alturas do espectro neste quadro: as notas do trecho (das duas pistas) ou, com Z, a nota que toca;
    /// desliza tocando. Nil sem espectro.
    private func pitchWindow(gridStart: Double) -> ClosedRange<Double>? {
        guard let spectrum = model.spectrum else { return nil }
        let main = model.scoreNotes.indices.contains(model.scoreTrack) ? model.scoreNotes[model.scoreTrack] : []
        let second = model.scoreSecond.flatMap { model.scoreNotes.indices.contains($0) ? model.scoreNotes[$0] : nil } ?? []
        let limits = spectrum.low...spectrum.pitch(row: Double(spectrum.rows - 1))
        let target = model.pitchZoom
            ? Self.zoomTarget(main, grid: model.grid, at: model.engine.currentTime, limits: limits)
            : Self.pitchTarget(main + second, grid: model.grid, from: gridStart - span * 0.5, to: gridStart + span * 1.5,
                               limits: limits)
        return model.pitchWindow.update(target: target, easing: model.engine.isPlaying)
    }

    /// A faixa da onda em cima do espectro.
    static let waveStrip = 30.0

    /// Z: a janela em volta da nota que toca (ou da mais perto): 2 semitons abaixo e 6 acima, para caber o bend.
    static func zoomTarget(_ notes: [ScoreNote], grid: TempoGrid, at seconds: Double,
                           limits: ClosedRange<Double>) -> ClosedRange<Double>? {
        let nearest = notes.min { a, b in
            func distance(_ n: ScoreNote) -> Double {
                let s0 = grid.seconds(at: n.tick)
                let s1 = grid.seconds(at: n.tick + n.duration)
                return seconds < s0 ? s0 - seconds : seconds > s1 ? seconds - s1 : 0
            }
            return distance(a) < distance(b)
        }
        guard let note = nearest else { return nil }
        let low = max(limits.lowerBound, Double(note.pitch) - 2)
        return low...min(limits.upperBound, low + 8)
    }

    static let keyboardWidth = 34.0

    /// A janela de alturas que as notas do trecho pedem: da mais grave à mais aguda com 2 semitons de folga, ao menos
    /// 18 semitons (centrada nelas), dentro do espectro; sem notas no trecho, nil (fica a de antes).
    static func pitchTarget(_ notes: [ScoreNote], grid: TempoGrid, from: Double, to: Double,
                            limits: ClosedRange<Double>) -> ClosedRange<Double>? {
        let pitches = notes.filter { note in
            let s0 = grid.seconds(at: note.tick)
            return s0 <= to && grid.seconds(at: note.tick + note.duration) >= from
        }.map { Double($0.pitch) }
        guard let low = pitches.min(), let high = pitches.max() else { return nil }
        var a = low - 2
        var b = high + 2
        if b - a < 18 {
            let middle = (a + b) / 2
            a = middle - 9
            b = middle + 9
        }
        a = max(limits.lowerBound, a)
        b = min(limits.upperBound, max(b, a + 18))
        return a...b
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
