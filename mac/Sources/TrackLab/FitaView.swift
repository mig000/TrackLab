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
    /// A camada da Lente (o espectro com as notas) ou a da Onda; com `strip`, a Lente leva a faixa estreita da onda em
    /// cima (quando a camada da Onda está escondida).
    var lens = false
    var strip = true
    @Local private var drag: (from: Double, to: Double)?
    /// Onde o arrasto começou, em tempo da música: a Fita anda enquanto se arrasta tocando.
    @Local private var origin: Double?
    /// No Ajuste: a batida que está sendo arrastada e para onde vai.
    @Local private var held: (point: TempoPoint, to: Double)?
    /// No espectro: a nota pega na faixa e quantos semitons ela já andou.
    @Local private var grabbed: (note: ScoreNote, track: Int, semitones: Int, steps: Int)?
    /// No espectro, com ⌥: o retângulo da seleção (o tempo e as alturas) enquanto se arrasta.
    @Local private var marquee: (from: (seconds: Double, pitch: Double), to: (seconds: Double, pitch: Double))?
    @Environment(\.colorScheme) private var scheme

    /// A aparência clara (papel) vale para a Onda e para a Lente. De 1/11 a 3/11 a Lente foi sempre escura (o espectro
    /// em tinta cinza sobre o claro tinha pouco contraste com as faixas âmbar); com a Tinta, o som das notas acende em
    /// âmbar sobre o violeta, e ela segue a aparência.
    private var paper: Bool { scheme == .light }
    /// A cor das linhas e marcas por cima do espectro: branca no escuro, preta no papel.
    private var ink: Color { paper ? .black : .white }

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
                tape(size: geometry.size, now: model.engine.songTime(atHost: host))
            }
        }
        // A Onda no papel tem o fundo da página (branco), no escuro o de baixo da página; a Lente, o dela.
        .background(lens ? SpectrumPalette.ground(paper: paper)
                    : paper ? Color(red: 0.98, green: 0.973, blue: 0.953) : Color(nsColor: .underPageBackgroundColor))
        .onChange(of: scheme, initial: true) { if lens { model.paper = paper } }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // O canto da Lente: a afinação da gravação, as corrigidas, as suspeitas (o selo abre o filtro) e o Z.
        .overlay(alignment: .topTrailing) { if lens { LensBadges(model: model) } }
    }

    private func tape(size: CGSize, now: Double) -> some View {
        let width = size.width
        // Um loop que cabe na tela para a Fita e só a agulha anda; fora dele, a agulha fica onde o último clique a
        // deixou (`playheadAt`, 0,4 de início). A TAB faz a mesma conta.
        let start = model.viewStart(now: now)
        // No espectro, a imagem vai numa camada da GPU por baixo (só a transformação muda a cada quadro) e o Canvas,
        // transparente, desenha por cima a grade, as notas e o teclado; `drawingGroup` rasteriza o Canvas no Metal.
        let pitches = lens ? pitchWindow(gridStart: start) : nil
        return ZStack(alignment: .topLeading) {
            if let pitches {
                // As notas estão na afinação da gravação descontada: o espectro desce o mesmo tanto.
                SpectrumLayerView(image: model.spectrumImage, warm: model.spectrumWarm, glow: model.lensGlow(),
                                  start: start - model.soundShift, span: span,
                                  pitches: (pitches.lowerBound + model.tuning)...(pitches.upperBound + model.tuning),
                                  spectrum: model.spectrum)
                    .padding(.top, stripHeight)
                    .opacity(model.lensSpectrum ? 1 : 0)
            }
            Canvas { context, size in
                draw(in: &context, size: size, start: start, now: now, pitches: pitches)
            }
            .drawingGroup()
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(size: size, start: start))
        // O botão direito: numa faixa da Lente, o menu da nota; fora dela (e na Onda), o menu do compasso.
        .background(RightClickCatcher { point, view in
            if let hit = noteAt(point, size: size, start: start) {
                model.contextMenu(forTrack: hit.track, tick: hit.note.tick, string: hit.note.string, at: point, in: view)
                return true
            }
            let t = time(at: point.x, width: width, start: start)
            guard let bar = model.grid.bar(at: t) else { return false }
            model.showBarMenu(index: bar - 1, signature: nil, section: nil, at: point, in: view)
            return true
        })
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

    /// O cabeçote vai para o clique: a música até ali e a agulha naquele ponto da largura (a Fita fica parada).
    private func seek(at x: Double, width: Double, start: Double) {
        model.seek(to: time(at: x, width: width, start: start), at: x / max(width, 1))
    }

    private func dragGesture(size: CGSize, start: Double) -> some Gesture {
        let width = size.width
        // O tempo e a altura de um ponto da Lente (a altura como a Lente mostra, com a afinação da gravação descontada).
        func place(_ point: CGPoint) -> (seconds: Double, pitch: Double) {
            let window = model.pitchWindow.range
            let height = max(1, size.height - stripHeight)
            return (time(at: point.x, width: width, start: start),
                    window.lowerBound + (size.height - point.y) / height * (window.upperBound - window.lowerBound))
        }
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                if marquee != nil {
                    marquee?.to = place(value.location)
                    return
                }
                if origin == nil {
                    let at = time(at: value.startLocation.x, width: width, start: start)
                    origin = at
                    if lens, !model.adjusting, model.spectrum != nil,
                       NSEvent.modifierFlags.contains(.option) || model.selectingRegion, value.startLocation.y > stripHeight {
                        // ⌥ + arrastar na Lente (ou o arrasto depois do ⌥⌘R): o retângulo da seleção, que o motor
                        // reconhece de novo.
                        marquee = (place(value.startLocation), place(value.location))
                        return
                    }
                    if model.adjusting, let point = model.grid.beat(near: at, within: Self.grab / max(width, 1) * span) {
                        held = (point, point.seconds)
                    } else if !model.adjusting, let hit = noteAt(value.startLocation, size: size, start: start) {
                        grabbed = (hit.note, hit.track, 0, 0)
                    }
                }
                if let grabbed {
                    // Para cima ou para baixo, de semitom em semitom; para os lados, de semicolcheia em semicolcheia
                    // (o eixo em que o mouse andou mais). A faixa acompanha.
                    let window = model.pitchWindow.range
                    let semitone = (size.height - stripHeight) / (window.upperBound - window.lowerBound)
                    if abs(value.translation.width) > abs(value.translation.height) {
                        let step = model.grid.seconds(at: grabbed.note.tick + Double(model.gridTicks))
                            - model.grid.seconds(at: grabbed.note.tick)
                        let seconds = value.translation.width / max(width, 1) * span
                        self.grabbed?.steps = Int((seconds / max(0.01, step)).rounded())
                        self.grabbed?.semitones = 0
                    } else {
                        self.grabbed?.semitones = Int((-value.translation.height / max(1, semitone)).rounded())
                        self.grabbed?.steps = 0
                    }
                    return
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
                    grabbed = nil
                    marquee = nil
                }
                if let marquee {
                    model.selectingRegion = false
                    let a = marquee.from
                    let b = place(value.location)
                    if abs(value.translation.width) > 3, abs(value.translation.height) > 3 {
                        model.recognize(from: min(a.seconds, b.seconds), to: max(a.seconds, b.seconds),
                                        low: min(a.pitch, b.pitch), high: max(a.pitch, b.pitch))
                    }
                    return
                }
                // Um clique na Fita devolve as teclas ao transporte (tira o foco da busca, por exemplo).
                if let window = NSApp.keyWindow, window.firstResponder is NSText { window.makeFirstResponder(nil) }
                if let grabbed {
                    // Clique numa faixa: escolhe a nota (e liga a edição); arrastada, muda a altura e encaixa no som.
                    if grabbed.steps != 0 {
                        model.shiftNote(grabbed.note, track: grabbed.track, steps: grabbed.steps)
                    } else if grabbed.semitones == 0 {
                        if hypot(value.translation.width, value.translation.height) <= 3 {
                            model.selectNote(grabbed.note, track: grabbed.track)
                            seek(at: value.location.x, width: width, start: start)
                            // A nota clicada soa (o som gravado dela, sozinho).
                            model.hearNote(grabbed.note, track: grabbed.track, synth: false)
                        }
                    } else {
                        model.dragPitch(grabbed.note, track: grabbed.track, semitones: grabbed.semitones,
                                        onlyPitch: NSEvent.modifierFlags.contains(.option))
                    }
                    return
                }
                if let held {
                    // Um clique numa batida também leva o cabeçote até ali: a Fita não anda (a agulha vai para o
                    // lugar do clique), e o duplo clique acerta a mesma batida.
                    if abs(value.translation.width) > 3 {
                        // O alcance pelas teclas seguradas ao soltar: ⌥ só esta, ⇧ tudo à direita, ⌥⇧ a música toda.
                        model.moveBeat(tick: held.point.tick, to: held.to, reach: DragReach.current())
                    } else {
                        seek(at: value.location.x, width: width, start: start)
                    }
                    return
                }
                if abs(value.translation.width) <= 3 {
                    // Fora de uma nota, na Lente: a escolha sai (a edição continua ligada).
                    if lens, model.tabSelection != nil { model.tabEdit("clear") }
                    seek(at: value.location.x, width: width, start: start)
                    return
                }
                guard let drag else { return }
                if let range = LoopRegion.snapped(drag.from, drag.to, grid: model.grid, duration: model.engine.duration) {
                    model.setLoop(range, seekToStart: true)
                }
            }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, start: Double, now: Double,
                      pitches: ClosedRange<Double>?) {
        let width = size.width
        let height = size.height
        // Os números dos compassos ficam nos 14 pontos de cima; a onda ocupa o resto, de borda a borda.
        let middle = (height + 14) / 2
        let half = (height - 14) / 2 - 2
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
        let gridBottom = lens ? stripHeight : height
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
                context.draw(CanvasLabel.image("\(index + 1)", size: 10, monospaced: true, color: .secondaryLabelColor,
                                               dark: !paper),
                             at: CGPoint(x: x(bar) + 4, y: 2), anchor: .topLeading)
            }
        }
        context.fill(barLines, with: .color(.secondary.opacity(0.55)))

        // O nome de cada parte embaixo, no começo dela (a que já começou antes fica presa na borda esquerda).
        if !lens, !model.adjusting {
            for part in model.songParts() where part.to > start && part.from < end {
                let x0 = max(x(part.from), 0) + 4
                guard x(part.to) - x0 > 44 else { continue }
                context.draw(CanvasLabel.image(part.name, size: 10, weight: .semibold,
                                               color: NSColor(srgbRed: part.color.0, green: part.color.1,
                                                              blue: part.color.2, alpha: 1), dark: !paper),
                             at: CGPoint(x: x0, y: height - 3), anchor: .bottomLeading)
            }
        }

        // O espectro (com as notas da TAB por cima) no lugar das ondas.
        if lens {
            drawSpectrum(in: &context, size: size, start: soundStart, gridStart: start, pitches: pitches)
        }
        // No Ajuste, no lugar das ondas: a batida (a força dos ataques da bateria), o detector e o pente.
        if !lens, model.adjusting {
            drawBeatView(in: &context, size: size, start: start, soundStart: soundStart)
        }
        // As ondas: o original atrás, a guitarra na frente.
        let step = 2.0
        if !lens, !model.adjusting, let peaks = model.sourcePeaks {
            fillSource(wave(peaks, start: soundStart, width: width, step: step, middle: middle, half: half),
                       in: &context, start: start, width: width, height: height)
        }
        if !lens, !model.adjusting, let peaks = model.guitarPeaks {
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
            context.draw(CanvasLabel.image("\(delta > 0 ? "+" : "")\(delta) ms · \(DragReach.current().label)", size: 10,
                                           monospaced: true, color: .systemOrange, dark: !paper),
                         at: CGPoint(x: x(held.to) + 6, y: 12), anchor: .leading)
        }

        // A agulha.
        let needle = x(now)
        var line = Path()
        line.move(to: CGPoint(x: needle, y: 0))
        line.addLine(to: CGPoint(x: needle, y: height))
        context.stroke(line, with: .color(.accentColor), lineWidth: 2)
    }

    /// No Ajuste, no lugar das ondas (o tempo, sem as notas): embaixo, a força dos ataques da faixa de ritmo (a
    /// bateria, o baixo ou o original) e, tracejadas, as batidas que o detector achou nela; em cima, o pente (os
    /// ataques escritos da pista, sem as notas, ligados aos ouvidos na faixa dela; em vermelho os de 25 ms para cima);
    /// e entre as batidas do mapa, o intervalo em ms, em vermelho quando foge 5 % dos vizinhos (um ponto fora do lugar).
    private func drawBeatView(in context: inout GraphicsContext, size: CGSize, start: Double, soundStart: Double) {
        let width = Double(size.width)
        let height = Double(size.height)
        func x(_ t: Double) -> Double { (t - start) / span * width }
        func sx(_ t: Double) -> Double { (t - soundStart) / span * width }
        let end = start + span
        // O pente com uma parte da altura (as linhas ligando o escrito ao ouvido ficam legíveis na tela grande), a força
        // dos ataques com outra (até 200 pt) e, embaixo, a onda com o resto (2/11: o Miguel queria ver o som também).
        let combTop = 18.0
        let combBottom = combTop + min(max(height * 0.3, 46), 220)
        let tick = min(max((combBottom - combTop) * 0.28, 13), 30)
        let top = combBottom + 22
        let below = height - 4 - top
        let base = top + min(max(below * 0.4, 50), 200, max(0, below))
        drawAdjustWave(in: &context, width: width, top: base + 12, bottom: height - 4, start: start, soundStart: soundStart)
        let blue = Color(red: 0.25, green: 0.5, blue: 0.95)
        let red = Color(red: 0.9, green: 0.22, blue: 0.17)

        // A força dos ataques, como uma onda só de um lado.
        if let beats = model.heardBeats, base > top {
            var area = Path()
            area.move(to: CGPoint(x: 0, y: base))
            var px = 0.0
            while px <= width {
                let perPixel: Double = span / max(width, 1)
                let t0: Double = soundStart + px * perPixel
                let peak = beats.peak(from: t0, to: t0 + 2 * perPixel)
                area.addLine(to: CGPoint(x: px, y: base - peak * (base - top)))
                px += 2
            }
            area.addLine(to: CGPoint(x: width, y: base))
            area.closeSubpath()
            context.fill(area, with: .color(.secondary.opacity(0.32)))
            var ghosts = Path()
            for beat in beats.beats where beat >= soundStart - 0.1 && beat <= soundStart + span + 0.1 {
                ghosts.move(to: CGPoint(x: sx(beat), y: top - 6))
                ghosts.addLine(to: CGPoint(x: sx(beat), y: base))
            }
            context.stroke(ghosts, with: .color(.secondary.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            context.draw(CanvasLabel.image("\(Self.stemName(beats.stem)) · tracejado: o detector", size: 9, weight: .semibold,
                                           color: .secondaryLabelColor, dark: !paper),
                         at: CGPoint(x: width - 6, y: base - 4), anchor: .bottomTrailing)
        } else if base > top {
            context.draw(Text("Ouvindo as batidas…").font(.caption).foregroundStyle(.secondary),
                         at: CGPoint(x: width / 2, y: (top + base) / 2))
        }

        // O pente: os ataques escritos em cima, os ouvidos embaixo, e a ligação entre eles.
        let written = model.writtenAttacks.filter { $0 >= start - 0.2 && $0 <= end + 0.2 }
        let heard = model.heardAttacks.filter { $0 >= soundStart - 0.2 && $0 <= soundStart + span + 0.2 }
        var writtenTicks = Path()
        for t in written { writtenTicks.addRect(CGRect(x: x(t) - 1, y: combTop, width: 2, height: tick)) }
        context.fill(writtenTicks, with: .color(.primary))
        var heardTicks = Path()
        for t in heard { heardTicks.addRect(CGRect(x: sx(t) - 1, y: combBottom - tick, width: 2, height: tick)) }
        context.fill(heardTicks, with: .color(blue))
        var good = Path()
        var off = Path()
        let shift = soundStart - start
        for pair in Comb.pairs(written: written, heard: heard.map { $0 - shift }) {
            var line = Path()
            line.move(to: CGPoint(x: x(pair.written), y: combTop + tick))
            line.addLine(to: CGPoint(x: x(pair.heard), y: combBottom - tick))
            if abs(pair.offset) >= AdjustReview.threshold {
                off.addPath(line)
                if span <= 8 {
                    let ms = Int((pair.offset * 1000).rounded())
                    context.draw(CanvasLabel.image("\(ms > 0 ? "+" : "−")\(abs(ms))", size: 9, monospaced: true,
                                                   color: .systemRed, dark: !paper),
                                 at: CGPoint(x: (x(pair.written) + x(pair.heard)) / 2 + 3, y: (combTop + combBottom) / 2),
                                 anchor: .leading)
                }
            } else {
                good.addPath(line)
            }
        }
        context.stroke(good, with: .color(.green.opacity(0.85)), lineWidth: 1.2)
        context.stroke(off, with: .color(red), lineWidth: 1.8)
        context.draw(CanvasLabel.image("escrito", size: 9, weight: .semibold, color: .secondaryLabelColor, dark: !paper),
                     at: CGPoint(x: 6, y: combTop - 1), anchor: .bottomLeading)
        context.draw(CanvasLabel.image("ouvido", size: 9, weight: .semibold, color: .systemBlue, dark: !paper),
                     at: CGPoint(x: 6, y: combBottom + 1), anchor: .topLeading)

        // O intervalo entre as batidas do mapa, em ms.
        let beats = model.grid.beats
        guard beats.count >= 2 else { return }
        var first = 0
        while first < beats.count - 1, beats[first + 1] < start { first += 1 }
        var index = first
        while index < beats.count - 1, beats[index] <= end {
            let gap: Double = beats[index + 1] - beats[index]
            let pixels: Double = x(beats[index + 1]) - x(beats[index])
            if pixels > 34 {
                var around: [Double] = []
                for k in max(0, index - 3)...min(beats.count - 2, index + 3) where k != index {
                    around.append(beats[k + 1] - beats[k])
                }
                around.sort()
                let typical: Double = around.isEmpty ? gap : around[around.count / 2]
                let odd: Bool = typical > 0 && abs(gap - typical) / typical > 0.05
                context.draw(CanvasLabel.image("\(Int((gap * 1000).rounded()))", size: 9, weight: odd ? .bold : .regular,
                                               monospaced: true, color: odd ? .systemRed : .tertiaryLabelColor, dark: !paper),
                             at: CGPoint(x: (x(beats[index]) + x(beats[index + 1])) / 2, y: combBottom + 14), anchor: .center)
            }
            index += 1
        }
    }

    /// A onda embaixo do Ajuste, como a Fita dos outros modos: a banda inteira (o original, nas cores das partes) atrás
    /// e a guitarra em âmbar na frente, no tempo do som, com as batidas do mapa por cima (as linhas da Fita). A bateria
    /// já está na força dos ataques, logo acima (2/11: o Miguel achou a banda inteira mais útil que a bateria de novo).
    private func drawAdjustWave(in context: inout GraphicsContext, width: Double, top: Double, bottom: Double,
                                start: Double, soundStart: Double) {
        guard bottom - top >= 40 else { return }
        let middle = (top + bottom) / 2
        let half = (bottom - top) / 2 - 2
        if let peaks = model.sourcePeaks {
            fillSource(wave(peaks, start: soundStart, width: width, step: 2, middle: middle, half: half),
                       in: &context, start: start, width: width, height: bottom)
        }
        if let peaks = model.guitarPeaks {
            context.fill(wave(peaks, start: soundStart, width: width, step: 2, middle: middle, half: half),
                         with: .color(.orange.opacity(0.85)))
        }
        context.draw(CanvasLabel.image(model.guitarPeaks != nil ? "a banda · a guitarra em âmbar" : "a banda", size: 9,
                                       weight: .semibold, color: .secondaryLabelColor, dark: !paper),
                     at: CGPoint(x: 6, y: top + 2), anchor: .topLeading)
    }

    static func stemName(_ stem: String) -> String {
        switch stem {
        case Stem.drums.rawValue: "a bateria"
        case Stem.bass.rawValue: "o baixo"
        default: "a música toda"
        }
    }

    /// O espectro do trecho visível, como a Lente do TabLab: em cima, uma faixa estreita com a onda; embaixo, o que vai
    /// sobre a imagem (ela fica na camada da GPU, `SpectrumLayerView`). A janela de alturas acompanha as notas do trecho
    /// (das duas pistas, com folga, ao menos uma oitava e meia) e desliza tocando; com Z, fica em volta da nota que toca.
    /// Por cima: as linhas dos compassos e das batidas; as notas (a pista em âmbar, a segunda em azul) como faixas que
    /// seguem o som (`SoundNote.offset`: o vibrato e o bend da curva; sem ela, a escrita), com o traço do ataque e os
    /// pontos laranja da altura que soa; a nota escolhida brilha (de perto, a curva dela é uma linha). Um clique numa
    /// faixa escolhe a nota na TAB; arrastar para cima ou para baixo muda a altura e, ao soltar, encaixa no som (⌥: só
    /// a altura). E o teclado à esquerda.
    private func drawSpectrum(in context: inout GraphicsContext, size: CGSize, start: Double, gridStart: Double,
                              pitches: ClosedRange<Double>?) {
        let width = size.width
        let strip = stripHeight
        let height = size.height - strip
        _ = model.pitchCurvesVersion   // uma curva nova redesenha a Fita

        // A onda, estreita, em cima.
        let step = 2.0
        if let peaks = model.sourcePeaks {
            fillSource(wave(peaks, start: start, width: width, step: step, middle: strip / 2, half: strip * 0.45),
                       in: &context, start: gridStart, width: width, height: strip)
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
        let lowPitch = pitches.lowerBound
        let highPitch = pitches.upperBound
        func y(_ pitch: Double) -> Double { height - (pitch - lowPitch) / (highPitch - lowPitch) * height }

        // Batidas e compassos por cima do espectro: a TAB se confere com eles.
        func gx(_ t: Double) -> Double { (t - gridStart) / span * width }
        var beatLines = Path()
        for beat in model.grid.beats where beat >= gridStart && beat <= gridStart + span {
            beatLines.addRect(CGRect(x: gx(beat), y: 0, width: 1, height: height))
        }
        context.fill(beatLines, with: .color(ink.opacity(paper ? 0.1 : 0.06)))
        var barLines = Path()
        for bar in model.grid.bars where bar >= gridStart && bar <= gridStart + span {
            barLines.addRect(CGRect(x: gx(bar), y: 0, width: 1, height: height))
        }
        context.fill(barLines, with: .color(ink.opacity(paper ? 0.35 : 0.22)))

        // As notas. Com o espectro (a Tinta, 3/11): o som da nota já acende em âmbar na imagem, e por cima vai só a
        // escrita, um contorno com a casa num selo na ponta (e a curva da nota escolhida). Sem o espectro, como na Lente
        // do TabLab: faixas que seguem o som (o vibrato e o bend copiados da curva quando ela os tem; senão a escrita),
        // com o traço do ataque na ponta e, por cima, os pontos da altura que soa. Cada pista num caminho só para as
        // faixas e outro para os pontos (centenas de pontos a cada quadro, um por um, custavam caro). Sem as barras,
        // nada disso (só o espectro), mas as curvas continuam pedidas.
        let semitone = height / (highPitch - lowPitch)
        let thick = Self.bandWidth(semitone: semitone)
        let tinta = model.lensSpectrum
        let barsShown = model.lensBars
        let bandHalf = tinta ? max(thick / 2, min(semitone * 0.42, 12)) : thick / 2
        let selection = model.tabSelection
        // As notas suspeitas dos tipos ligados no filtro (uma vez por quadro, não por nota).
        let flagged = model.suspectNotes(track: model.scoreTrack)
        // A nota escolhida, para o destaque desenhado depois de todas as pistas (`spotlight`).
        var spot: Spot?
        func bands(_ notes: [ScoreNote], track: Int, rgb: (Double, Double, Double)) {
            let color = Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255)
            var visible: [ScoreNote] = []
            var shapes = Path()
            var attacks = Path()
            var dots = Path()
            var suspect = Path()
            var corrected = Path()
            var timing = Path()
            var chosen: (shape: Path, line: Path?)?
            // Os selos da casa (na Tinta, só a pista principal): onde, a casa, suspeita.
            var heads: [(x: Double, y: Double, fret: Int, suspect: Bool)] = []
            for note in notes {
                let s0 = model.grid.seconds(at: note.tick)
                guard s0 < gridStart + span else { continue }
                let s1 = model.grid.seconds(at: note.tick + note.duration)
                guard s1 > gridStart else { continue }
                visible.append(note)
                guard barsShown else { continue }
                let sound = model.soundNotes[model.curveKey(note, track: track)]
                let isChosen = selection?.matches(note, track: track) == true
                let lift = grabbed.map { $0.track == track && $0.note == note ? Double($0.semitones) : 0 } ?? 0
                let x0 = gx(s0)
                let x1 = max(gx(s1), x0 + 3)
                let teeth = sound?.fit?.trill != nil
                let steps = max(2, Int(((x1 - x0) / (teeth ? 1 : 3)).rounded(.up)))
                let centers = (0...steps).map { i -> CGPoint in
                    let x = x0 + (x1 - x0) * Double(i) / Double(steps)
                    // Na Tinta, o contorno é a escrita: o som é a âmbar do espectro, e onde um foge do outro a TAB
                    // discorda.
                    let offset = Self.offset(note, sound: tinta ? nil : sound, at: gridStart + x / width * span, start: s0, end: s1)
                    return CGPoint(x: x, y: y(Double(note.pitch) + lift + offset))
                }
                var band = Path()
                band.move(to: CGPoint(x: centers[0].x, y: centers[0].y - bandHalf))
                for point in centers.dropFirst() { band.addLine(to: CGPoint(x: point.x, y: point.y - bandHalf)) }
                for point in centers.reversed() { band.addLine(to: CGPoint(x: point.x, y: point.y + bandHalf)) }
                band.closeSubpath()
                if lift != 0 {
                    // Onde estava: o contorno tracejado, apagado; o rótulo com a altura nova.
                    context.stroke(band.offsetBy(dx: 0, dy: lift * semitone), with: .color(color.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    context.draw(Text(SongModel.pitchName(note.pitch + Int(lift))).font(.caption.weight(.semibold))
                        .foregroundStyle(color), at: CGPoint(x: x1 + 6, y: centers[0].y), anchor: .leading)
                }
                // Arrastada para os lados: para onde vai, tracejada, e quantas semicolcheias.
                let slide = grabbed.map { $0.track == track && $0.note == note ? $0.steps : 0 } ?? 0
                if slide != 0 {
                    let step = model.grid.seconds(at: note.tick + Double(model.gridTicks)) - s0
                    let dx = Double(slide) * step / span * width
                    context.stroke(band.offsetBy(dx: dx, dy: 0), with: .color(color),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    context.draw(Text("\(slide > 0 ? "+" : "−")\(abs(slide)) × \(SongModel.grids.first { $0.ticks == model.gridTicks }?.name ?? "")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color), at: CGPoint(x: x1 + dx + 6, y: centers[0].y), anchor: .leading)
                }
                // Corrigida pelo som (o corretor): contorno verde tracejado.
                if track == model.scoreTrack, model.isCorrected(note, track: track) {
                    corrected.addPath(band)
                }
                // Suspeita (o som discorda da escrita): contorno vermelho e um ponto sobre o ataque.
                if sound != nil, track == model.scoreTrack, flagged.contains(note) {
                    suspect.addPath(band)
                    // Na Tinta, o selo da casa já fica vermelho.
                    if !tinta {
                        suspect.addEllipse(in: CGRect(x: x0 - 3, y: Double(centers[0].y) - thick / 2 - 9, width: 6, height: 6))
                    }
                }
                // Onde a nota soa de fato, quando passa de 30 ms da escrita: um traço branco no ataque medido, ligado
                // ao começo escrito (o mapa de tempo está fora ali; o Ajuste acerta).
                if let attack = sound?.curve.attack, abs(attack - s0) >= 0.03 {
                    let x = gx(attack)
                    let top = Double(centers[0].y) - thick / 2 - 3
                    timing.addRect(CGRect(x: x - 0.75, y: top, width: 1.5, height: thick + 6))
                    timing.addRect(CGRect(x: min(x, x0), y: Double(centers[0].y) - 0.5, width: abs(x - x0), height: 1))
                }
                // O ataque: um traço mais forte na ponta; na Tinta, a casa num selo em cima da ponta (a pista principal).
                if !tinta {
                    attacks.addRect(CGRect(x: x0.rounded() - 1, y: Double(centers[0].y) - thick / 2 - 2, width: 2.5, height: thick + 4))
                } else if track == model.scoreTrack {
                    heads.append((x0, Double(centers[0].y) - bandHalf, note.fret, sound != nil && flagged.contains(note)))
                }
                // De perto, a curva da nota escolhida é uma linha (dá para ver onde o bend chega); senão, pontos a
                // cada 3,5 px.
                var line: Path?
                if let sound {
                    let curve = sound.curve
                    if isChosen, semitone >= 20 || tinta {
                        var path = Path()
                        var open = false
                        for (k, value) in curve.values.enumerated() {
                            guard let value else {
                                open = false
                                continue
                            }
                            let point = CGPoint(x: gx(curve.from + Double(k) * curve.hop), y: y(value))
                            if open { path.addLine(to: point) } else { path.move(to: point) }
                            open = true
                        }
                        line = path
                    } else {
                        let r = isChosen ? 1.6 : 1.1
                        var lastX = -Double.infinity
                        // Na Tinta, os pontos só na escolhida (o som das outras já está na âmbar).
                        for (k, value) in curve.values.enumerated() where isChosen || !tinta {
                            guard let value else { continue }
                            let x = gx(curve.from + Double(k) * curve.hop)
                            guard x - lastX >= 3.5 else { continue }
                            lastX = x
                            let dot = CGRect(x: x - r, y: y(value) - r, width: 2 * r, height: 2 * r)
                            if isChosen { line = (line ?? Path()); line?.addEllipse(in: dot) } else { dots.addEllipse(in: dot) }
                        }
                    }
                }
                if isChosen || lift != 0 { chosen = (band, line) } else { shapes.addPath(band) }
                if isChosen, lift == 0, slide == 0 {
                    spot = Spot(shape: band, line: line, color: color, note: note, start: s0, end: s1,
                                fret: track == model.scoreTrack && tinta && semitone >= 9)
                }
            }
            if tinta {
                // Só o contorno da escrita: na pista principal, um marrom no papel (o âmbar é do som).
                let edge = track == model.scoreTrack && paper ? Color(red: 0.48, green: 0.35, blue: 0.12) : color
                context.fill(shapes, with: .color(color.opacity(0.05)))
                context.stroke(shapes, with: .color(edge.opacity(paper ? 0.5 : 0.6)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            } else {
                // Faixas cheias e um contorno fino: a nota se lê pela cor, sem a moldura grossa.
                context.fill(shapes, with: .color(color.opacity(paper ? 0.2 : 0.3)))
                context.stroke(shapes, with: .color(color.opacity(paper ? 0.85 : 0.7)), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
            }
            if let chosen, !tinta {
                var glow = context
                glow.addFilter(.shadow(color: color.opacity(0.55), radius: 5))
                glow.fill(chosen.shape, with: .color(color.opacity(0.3)))
                glow.stroke(chosen.shape, with: .color(color), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }
            context.fill(attacks, with: .color(color))
            context.fill(timing, with: .color(ink.opacity(0.75)))
            context.stroke(corrected, with: .color(ReadingTile.teal.opacity(0.95)),
                           style: StrokeStyle(lineWidth: 1.6, lineJoin: .round, dash: [4, 2]))
            let red = Color(red: 1, green: 0.36, blue: 0.36)
            context.stroke(suspect, with: .color(red), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            // A altura que soa: no escuro, um branco quente, que se lê sobre o âmbar da faixa e sobre o espectro (o
            // laranja de antes sumia dentro da faixa).
            let orange = paper ? Color(red: 0.86, green: 0.36, blue: 0.08) : Color(red: 1, green: 0.95, blue: 0.86)
            context.fill(dots, with: .color(orange.opacity(paper ? 0.55 : 0.8)))
            if let line = chosen?.line, !tinta {
                if semitone >= 20 {
                    context.stroke(line, with: .color(orange.opacity(0.95)), lineWidth: 1.8)
                } else {
                    context.fill(line, with: .color(orange.opacity(0.95)))
                }
            }
            // Os selos da casa: índigo no papel, lilás no escuro, vermelho na suspeita; só com espaço para eles.
            if semitone >= 9 {
                let fill = paper ? Color(red: 0.16, green: 0.14, blue: 0.31).opacity(0.8) : Color(red: 0.36, green: 0.31, blue: 0.62)
                for head in heads {
                    let wide = head.fret >= 10 ? 16.0 : 11.0
                    let rect = CGRect(x: head.x - 1, y: head.y - 13, width: wide, height: 11.5)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3),
                                 with: .color(head.suspect ? Color(red: 0.85, green: 0.23, blue: 0.34) : fill))
                    context.draw(CanvasLabel.image("\(head.fret)", size: 8.5, weight: .bold, monospaced: true, color: .white, dark: true),
                                 at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
                }
            }
            if !visible.isEmpty { model.askCurves(visible, track: track) }
        }
        // As outras pistas, cada uma na sua cor (a primeira em azul, como a segunda da Lente), embaixo da principal.
        for (order, index) in model.shownTracks.dropFirst().enumerated() where model.scoreNotes.indices.contains(index) {
            bands(model.scoreNotes[index], track: index, rgb: Self.otherColors[order % Self.otherColors.count])
        }
        // A principal em âmbar (mais escuro no papel, para ler sobre o claro).
        bands(main, track: model.scoreTrack, rgb: paper ? (196, 118, 10) : (245, 181, 68))
        if let spot { spotlight(spot, in: &context, width: width, height: height, semitone: semitone, gx: gx, y: y) }
        // A seleção no espectro: o retângulo que se arrasta (⌥) e o trecho reconhecido, com as notas achadas tracejadas em
        // verde, como ficariam (o cartão "Reconhecido" na coluna as escreve).
        let teal = ReadingTile.teal
        if let marquee {
            let rect = CGRect(x: gx(min(marquee.from.seconds, marquee.to.seconds)), y: y(max(marquee.from.pitch, marquee.to.pitch)),
                              width: abs(gx(marquee.to.seconds) - gx(marquee.from.seconds)),
                              height: abs(y(marquee.to.pitch) - y(marquee.from.pitch)))
            context.fill(Path(rect), with: .color(teal.opacity(0.1)))
            context.stroke(Path(rect), with: .color(teal), style: StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
        }
        if let region = model.regionReading, region.track == model.scoreTrack {
            let rect = CGRect(x: gx(region.seconds.lowerBound), y: y(region.pitches.upperBound + 0.5),
                              width: gx(region.seconds.upperBound) - gx(region.seconds.lowerBound),
                              height: y(region.pitches.lowerBound - 0.5) - y(region.pitches.upperBound + 0.5))
            context.stroke(Path(rect), with: .color(teal.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
            var found = Path()
            for note in region.shapes {
                let s0 = model.grid.seconds(at: note.tick)
                let s1 = model.grid.seconds(at: note.tick + note.duration)
                guard s1 > gridStart, s0 < gridStart + span else { continue }
                let x0 = gx(s0)
                let x1 = max(gx(s1), x0 + 3)
                let steps = max(2, Int(((x1 - x0) / 3).rounded(.up)))
                let centers = (0...steps).map { i -> CGPoint in
                    let x = x0 + (x1 - x0) * Double(i) / Double(steps)
                    let t = gridStart + x / width * span
                    return CGPoint(x: x, y: y(Double(note.pitch) + Self.offset(note, sound: nil, at: t, start: s0, end: s1)))
                }
                var band = Path()
                band.move(to: CGPoint(x: centers[0].x, y: centers[0].y - thick / 2))
                for point in centers.dropFirst() { band.addLine(to: CGPoint(x: point.x, y: point.y - thick / 2)) }
                for point in centers.reversed() { band.addLine(to: CGPoint(x: point.x, y: point.y + thick / 2)) }
                band.closeSubpath()
                found.addPath(band)
                context.draw(Text("\(note.fret)").font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(teal),
                             at: CGPoint(x: x0 + 2, y: Double(centers[0].y) - thick / 2 - 2), anchor: .bottomLeading)
            }
            context.fill(found, with: .color(teal.opacity(0.18)))
            context.stroke(found, with: .color(teal), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round, dash: [4, 2]))
        }
        // O som forte sem nota escrita (suspeita): um contorno vermelho na altura dele, do ataque a 120 ms depois.
        var unwritten = Path()
        for sound in model.unwrittenSounds(track: model.scoreTrack) where barsShown {
            let x = gx(sound.seconds)
            guard x > -20, x < width + 20, Double(sound.pitch) >= lowPitch - 1, Double(sound.pitch) <= highPitch + 1 else { continue }
            let rect = CGRect(x: x, y: y(Double(sound.pitch)) - thick / 2, width: max(8, 0.12 / span * width), height: thick)
            unwritten.addRoundedRect(in: rect, cornerSize: CGSize(width: thick / 3, height: thick / 3))
        }
        context.stroke(unwritten, with: .color(Color(red: 1, green: 0.36, blue: 0.36)), lineWidth: 1.6)
        // No Ajuste, no alto de cada compasso: quanto os ataques chegam depois (+) ou antes (−) do mapa, de 25 ms para
        // cima (A leva o 1 até eles).
        if model.adjusting {
            let offsets = model.barOffsets()
            for (index, offset) in offsets where abs(offset) >= 0.025 && model.grid.bars.indices.contains(index) {
                let x = gx(model.grid.bars[index])
                guard x > -40, x < width else { continue }
                let ms = Int((offset * 1000).rounded())
                context.draw(CanvasLabel.image("\(ms > 0 ? "+" : "−")\(abs(ms)) ms", size: 10, weight: .semibold,
                                               monospaced: true, color: NSColor(srgbRed: 0.45, green: 0.85, blue: 1, alpha: 1),
                                               dark: !paper),
                             at: CGPoint(x: x + 4, y: 4), anchor: .topLeading)
            }
        }

        // A nota ao vivo (a guitarra na entrada): o rastro dos últimos segundos e um ponto na ponta.
        let trail = model.studio.trail
        if InputEngine.shared.running, trail.count > 1 {
            let red = Color(red: 0.95, green: 0.25, blue: 0.2)
            var line = Path()
            var previous: (time: Double, pitch: Double)?
            for point in trail where point.pitch >= lowPitch - 1 && point.pitch <= highPitch + 1 {
                let spot = CGPoint(x: gx(point.time), y: y(point.pitch))
                if let previous, point.time - previous.time < 0.12, abs(point.pitch - previous.pitch) < 1.5 {
                    line.addLine(to: spot)
                } else {
                    line.move(to: spot)
                }
                previous = point
            }
            context.stroke(line, with: .color(red.opacity(0.85)), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            if let last = trail.last, abs(model.engine.currentTime - last.time) < 0.25, last.pitch >= lowPitch, last.pitch <= highPitch {
                let dot = CGRect(x: gx(last.time) - 5, y: y(last.pitch) - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: dot), with: .color(red))
                context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
            }
        }

        // O teclado à esquerda (o da Lente): as teclas brancas e pretas de cada semitom, os Dós e os Mis com nome.
        let gutter = Self.keyboardWidth
        context.fill(Path(CGRect(x: 0, y: 0, width: gutter, height: height)),
                     with: .color(paper ? Color(red: 0.93, green: 0.93, blue: 0.95) : Color(red: 0.06, green: 0.07, blue: 0.09)))
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
        context.fill(whiteKeys, with: .color(paper ? Color(white: 1) : Color(red: 0.13, green: 0.15, blue: 0.19)))
        context.fill(blackKeys, with: .color(paper ? Color(red: 0.72, green: 0.71, blue: 0.78) : Color(red: 0.04, green: 0.05, blue: 0.07)))
        context.fill(rules, with: .color(ink.opacity(0.04)))
        for (name, isC, at) in keyNames {
            context.draw(CanvasLabel.image(name, size: 9, monospaced: true,
                                           color: NSColor(white: paper ? (isC ? 0.25 : 0.45) : (isC ? 0.65 : 0.45), alpha: 1),
                                           dark: !paper), at: at, anchor: .leading)
        }
        // A tecla da nota escolhida acesa, com o nome.
        if let spot, Double(spot.note.pitch) > lowPitch, Double(spot.note.pitch) < highPitch {
            let y0 = y(Double(spot.note.pitch) + 0.5)
            let y1 = y(Double(spot.note.pitch) - 0.5)
            let key = CGRect(x: 2, y: y0 + 0.5, width: gutter - 4, height: max(2, y1 - y0 - 1))
            context.fill(Path(roundedRect: key, cornerRadius: 2), with: .color(spot.color))
            if semitone >= 9 {
                context.draw(CanvasLabel.image(SongModel.pitchName(spot.note.pitch).replacingOccurrences(of: " ", with: ""),
                                               size: 8.5, weight: .bold, color: .white, dark: true),
                             at: CGPoint(x: key.midX, y: key.midY), anchor: .center)
            }
        }
    }

    /// A nota escolhida na Lente (3/11): o resto do espectro e das notas fica sob um véu da cor do fundo, com uma janela
    /// em volta dela; a escrita em contorno forte, a curva do som numa linha, uma guia até o teclado, a duração numa
    /// régua embaixo e um cartão com o nome, a casa e o que o som fez. Ouvindo a nota (o clique), a parte já tocada
    /// acende e uma linha corre por ela.
    private struct Spot {
        let shape: Path
        let line: Path?
        let color: Color
        let note: ScoreNote
        let start: Double
        let end: Double
        /// Se o selo da casa está em cima da ponta (a janela abre para ele).
        let fret: Bool
    }

    private func spotlight(_ spot: Spot, in context: inout GraphicsContext, width: Double, height: Double, semitone: Double,
                           gx: (Double) -> Double, y: (Double) -> Double) {
        let ground = SpectrumPalette.ground(paper: paper)
        let ink = paper ? Color(red: 0.16, green: 0.14, blue: 0.31) : Color.white
        let gutter = Self.keyboardWidth
        let bounds = spot.shape.boundingRect
        var hole = bounds.insetBy(dx: -10, dy: -max(7, semitone * 0.5))
        if spot.fret {
            hole.origin.y -= 14
            hole.size.height += 14
        }
        // O véu em dois degraus, para a borda da janela não ser seca.
        let area = CGRect(x: gutter, y: 0, width: width - gutter, height: height)
        for (grow, alpha) in [(12.0, paper ? 0.3 : 0.28), (0.0, paper ? 0.28 : 0.24)] {
            let window = hole.insetBy(dx: -grow, dy: -grow)
            var veil = Path(area)
            veil.addPath(Path(roundedRect: window, cornerRadius: min(window.height / 2, 10 + grow)))
            context.fill(veil, with: .color(ground.opacity(alpha)), style: FillStyle(eoFill: true))
        }
        // A guia da altura escrita até o teclado.
        let pitchY = y(Double(spot.note.pitch))
        if hole.minX > gutter + 4 {
            var guide = Path()
            guide.move(to: CGPoint(x: gutter, y: pitchY))
            guide.addLine(to: CGPoint(x: hole.minX - 2, y: pitchY))
            context.stroke(guide, with: .color(spot.color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }
        // Ouvindo: a parte já tocada acende, e uma linha corre por ela.
        let engine = model.engine
        if engine.auditionActive, engine.currentTime > spot.start, engine.currentTime < spot.end + 0.05 {
            let x = min(gx(engine.currentTime), bounds.maxX)
            var played = context
            played.clip(to: Path(CGRect(x: bounds.minX - 2, y: hole.minY, width: x - bounds.minX + 2, height: hole.height)))
            played.fill(spot.shape, with: .color(spot.color.opacity(0.45)))
            context.fill(Path(CGRect(x: x - 0.75, y: hole.minY + 4, width: 1.5, height: hole.height - 8)), with: .color(ink.opacity(0.8)))
        } else {
            context.fill(spot.shape, with: .color(spot.color.opacity(paper ? 0.14 : 0.18)))
        }
        // A escrita, forte.
        var glow = context
        glow.addFilter(.shadow(color: spot.color.opacity(0.6), radius: 4))
        glow.stroke(spot.shape, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        // A curva do som: uma linha com borda clara, que se lê sobre o âmbar e o violeta.
        if let line = spot.line, model.lensSpectrum {
            let curve = paper ? Color(red: 0.86, green: 0.36, blue: 0.08) : Color(red: 1, green: 0.95, blue: 0.86)
            context.stroke(line, with: .color(paper ? .white : Color.black.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 3.8, lineCap: .round, lineJoin: .round))
            context.stroke(line, with: .color(curve), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        // A régua da duração embaixo.
        let rule = hole.maxY - 4
        var ruler = Path()
        ruler.move(to: CGPoint(x: bounds.minX, y: rule - 3))
        ruler.addLine(to: CGPoint(x: bounds.minX, y: rule))
        ruler.addLine(to: CGPoint(x: bounds.maxX, y: rule))
        ruler.addLine(to: CGPoint(x: bounds.maxX, y: rule - 3))
        context.stroke(ruler, with: .color(ink.opacity(0.45)), lineWidth: 1)
        // O cartão: em cima da janela, ou embaixo se não cabe.
        let note = spot.note
        let title = "\(SongModel.pitchName(note.pitch)) · casa \(note.fret) · corda \(note.string)"
            + String(format: " · %.2f s", spot.end - spot.start).replacingOccurrences(of: ".", with: ",")
        let first = context.resolve(CanvasLabel.image(title, size: 11, weight: .semibold, color: paper ? NSColor(white: 0.12, alpha: 1)
                                                      : NSColor(white: 0.95, alpha: 1), dark: !paper))
        let summary = model.soundSummary
        let second = summary.map {
            context.resolve(CanvasLabel.image($0, size: 10, color: paper ? NSColor(white: 0.38, alpha: 1) : NSColor(white: 0.7, alpha: 1),
                                              dark: !paper))
        }
        let cardWidth = max(first.size.width, second?.size.width ?? 0) + 16
        let cardHeight = first.size.height + (second.map { $0.size.height + 2 } ?? 0) + 10
        let above = hole.minY - cardHeight - 6 >= 2
        let card = CGRect(x: min(max(gutter + 4, hole.minX), width - cardWidth - 4),
                          y: above ? hole.minY - cardHeight - 6 : min(hole.maxY + 6, height - cardHeight - 2),
                          width: cardWidth, height: cardHeight)
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(paper ? 0.18 : 0.5), radius: 6, y: 2))
        shadowed.fill(Path(roundedRect: card, cornerRadius: 7),
                      with: .color(paper ? Color(white: 1) : Color(red: 0.13, green: 0.13, blue: 0.18)))
        context.fill(Path(roundedRect: CGRect(x: card.minX, y: card.minY, width: 3, height: card.height), cornerRadius: 1.5),
                     with: .color(spot.color))
        context.draw(first, at: CGPoint(x: card.minX + 9, y: card.minY + 5), anchor: .topLeading)
        if let second {
            context.draw(second, at: CGPoint(x: card.minX + 9, y: card.minY + 7 + first.size.height), anchor: .topLeading)
        }
    }

    /// A janela de alturas do espectro neste quadro: as notas do trecho (das duas pistas) ou, com Z, a nota que toca;
    /// desliza tocando. Nil sem espectro.
    private func pitchWindow(gridStart: Double) -> ClosedRange<Double>? {
        guard let spectrum = model.spectrum else { return nil }
        let main = model.scoreNotes.indices.contains(model.scoreTrack) ? model.scoreNotes[model.scoreTrack] : []
        let others = model.shownTracks.dropFirst().flatMap { model.scoreNotes.indices.contains($0) ? model.scoreNotes[$0] : [] }
        let limits = spectrum.low...spectrum.pitch(row: Double(spectrum.rows - 1))
        let target = model.pitchZoom
            ? Self.zoomTarget(main, grid: model.grid, at: model.engine.currentTime, limits: limits)
            : Self.pitchTarget(main + others, grid: model.grid, from: gridStart - span * 0.5, to: gridStart + span * 1.5,
                               limits: limits)
        return model.pitchWindow.update(target: target, easing: model.engine.isPlaying)
    }

    /// A faixa da onda em cima do espectro.
    static let waveStrip = 30.0
    /// As cores das outras pistas na Lente, pela ordem em que foram escolhidas (a principal é âmbar).
    static let otherColors: [(Double, Double, Double)] = [(91, 155, 255), (110, 205, 140), (190, 130, 255),
                                                          (255, 120, 170), (90, 210, 210)]
    /// A faixa da onda em cima da Lente; sem ela (a Onda à vista noutra camada), zero.
    private var stripHeight: Double { lens && strip ? Self.waveStrip : 0 }

    /// A largura da faixa de uma nota (a da Lente: 72 % do semitom, de 5 a 14 px).
    static func bandWidth(semitone: Double) -> Double { max(5, min(14, semitone * 0.72)) }

    /// Quantos semitons acima da escrita a faixa passa em `t`: pelo som, se a curva chegou; senão pela escrita; mais o
    /// slide escrito, na entrada e na saída (antes a faixa ficava reta e o slide não aparecia).
    static func offset(_ note: ScoreNote, sound: SoundNote?, at t: Double, start: Double, end: Double) -> Double {
        let length = max(1e-3, end - start)
        let slide = note.slideOffset(elapsed: t - start, length: length)
        if let sound { return sound.offset(note, at: t, start: start, end: end) + slide }
        return note.shape(fraction: (t - start) / length, elapsed: t - start) + slide
    }

    /// A nota sob o ponteiro no espectro (a pista principal antes da segunda): a faixa dela passa a até 3 px.
    private func noteAt(_ point: CGPoint, size: CGSize, start: Double) -> (note: ScoreNote, track: Int)? {
        guard lens, model.spectrum != nil, point.y > stripHeight,
              point.x > Self.keyboardWidth else { return nil }
        let height = size.height - stripHeight
        let window = model.pitchWindow.range
        let semitone = height / (window.upperBound - window.lowerBound)
        let reach = Self.bandWidth(semitone: semitone) / 2 + 3
        let t = start + point.x / max(size.width, 1) * span
        let slack = 2 / max(Double(size.width), 1) * span
        for track in model.shownTracks where model.scoreNotes.indices.contains(track) {
            for note in model.scoreNotes[track] {
                let s0 = model.grid.seconds(at: note.tick)
                let s1 = model.grid.seconds(at: note.tick + note.duration)
                guard t >= s0 - slack, t <= s1 + slack else { continue }
                let sound = model.soundNotes[model.curveKey(note, track: track)]
                let pitch = Double(note.pitch) + Self.offset(note, sound: sound, at: min(max(t, s0), s1), start: s0, end: s1)
                let y = stripHeight + height - (pitch - window.lowerBound) * semitone
                if abs(point.y - y) <= reach { return (note, track) }
            }
        }
        return nil
    }

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
    /// A silhueta da banda (o original) na cor de cada parte da música (as seções do Guitar Pro: todas as Verse de uma
    /// cor, os Chorus de outra); cinza antes da primeira parte, depois da última e numa música sem seções.
    private func fillSource(_ path: Path, in context: inout GraphicsContext, start: Double, width: Double, height: Double) {
        let gray = Color.secondary.opacity(0.35)
        let parts = model.songParts()
        guard !parts.isEmpty else {
            context.fill(path, with: .color(gray))
            return
        }
        func x(_ t: Double) -> Double { (t - start) / span * width }
        func paint(_ x0: Double, _ x1: Double, _ color: Color) {
            guard x1 > x0 else { return }
            var clipped = context
            clipped.clip(to: Path(CGRect(x: x0, y: 0, width: x1 - x0, height: height)))
            clipped.fill(path, with: .color(color))
        }
        paint(-1, min(width + 1, x(parts[0].from)), gray)
        for part in parts {
            paint(max(-1, x(part.from)), min(width + 1, x(part.to)),
                  Color(red: part.color.0, green: part.color.1, blue: part.color.2).opacity(0.5))
        }
        paint(max(-1, x(parts[parts.count - 1].to)), width + 1, gray)
    }

    private func wave(_ peaks: Peaks, start: Double, width: Double, step: Double, middle: Double, half: Double) -> Path {
        let dt = step / max(width, 1) * span
        var top: [CGPoint] = []
        var k = (start / dt).rounded(.down) - 1
        while true {
            let a = k * dt
            let x = (a - start) / span * width
            let amplitude = a < 0 ? 0 : Peaks.display(peaks.amplitude(from: a, to: a + dt), loudest: model.waveLoudest)
            top.append(CGPoint(x: x, y: middle - amplitude * half))
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

/// Os selos no canto da Lente: a afinação da gravação (de 5 cents para cima), as notas corrigidas pelo som, as
/// suspeitas (um clique abre o filtro por tipo e a navegação) e o Z (a janela de alturas em volta da nota que toca).
struct LensBadges: View {
    let model: SongModel
    @Local private var filtering = false

    var body: some View {
        let cents = Int((model.tuning * 100).rounded())
        let fixed = model.correctedCount(track: model.scoreTrack)
        let suspects = model.suspects(track: model.scoreTrack).count
        HStack(spacing: 4) {
            if model.measuring {
                ProgressView().controlSize(.mini)
            }
            if abs(cents) >= 5 {
                badge("gravação \(cents > 0 ? "+" : "−")\(abs(cents)) cents", color: .secondary)
                    .help("A afinação da gravação, descontada em tudo o que está na tela; o Tom (Lá 440) a desconta no som")
            }
            if fixed > 0 {
                badge("\(fixed) corrigida\(fixed == 1 ? "" : "s")", color: ReadingTile.teal)
                    .help("Notas que o corretor mudou pelo som, marcadas na Lente")
            }
            Button { filtering.toggle() } label: {
                badge(suspects > 0 ? "\(suspects) suspeita\(suspects == 1 ? "" : "s")" : "sem suspeitas",
                      color: suspects > 0 ? Color(red: 0.86, green: 0.25, blue: 0.25) : .secondary)
            }
            .buttonStyle(.plain)
            .help("Onde o som discorda da TAB; Tab e ⇧Tab vão de uma a outra; o clique abre o filtro por tipo")
            .popover(isPresented: $filtering, arrowEdge: .bottom) {
                SuspectFilter(model: model).padding(12).frame(width: 260).controlSize(.small)
            }
            // O que a Lente mostra: as barras das notas e o espectro (uma das duas fica ligada).
            Toggle("Barras", isOn: Binding(get: { model.lensBars }, set: { model.lensBars = $0 }))
                .toggleStyle(.button)
                .controlSize(.mini)
                .help("As notas da TAB por cima do espectro (⌥⌘B); desligadas, só o som, com as notas acesas em âmbar")
            Toggle("Espectro", isOn: Binding(get: { model.lensSpectrum }, set: { model.lensSpectrum = $0 }))
                .toggleStyle(.button)
                .controlSize(.mini)
                .help("O espectro da faixa (⌥⌘S); desligado, as notas viram faixas que seguem o som, com os pontos da altura")
            Toggle(isOn: Binding(get: { model.pitchZoom }, set: { model.pitchZoom = $0 })) {
                Image(systemName: "arrow.up.and.down.square")
            }
            .toggleStyle(.button)
            .controlSize(.mini)
            .keyboardShortcut("z", modifiers: [])
            .help("Z: amplia a altura em volta da nota que toca (para conferir um bend); Z de novo volta")
            .accessibilityLabel("Ampliar a altura")
        }
        .padding(.top, 6)
        .padding(.trailing, 8)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }
}
