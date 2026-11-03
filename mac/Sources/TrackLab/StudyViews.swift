import SwiftUI
import TrackLabCore

/// A escada do trecho: uma marca por velocidade, de 5 em 5 % até a meta; as já limpas (até o recorde) em verde, a de
/// agora contornada.
struct SpeedLadder: View {
    let section: StudySection
    let current: Int

    var body: some View {
        let steps = section.ladder(current: current)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                ForEach(steps, id: \.self) { rate in
                    let done = rate <= (section.best ?? 0)
                    let here = abs(rate - current) < SpeedTrainer.step && rate <= current
                    RoundedRectangle(cornerRadius: 2)
                        .fill(done ? Color.green.opacity(0.75) : Color.secondary.opacity(0.18))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(here ? Color.orange : .clear, lineWidth: 1.5))
                        .frame(height: 9)
                        .help("\(rate) %" + (done ? ", limpo" : ""))
                }
            }
            HStack {
                Text("\(steps.first ?? section.startRate) %")
                Spacer()
                Text("meta \(section.goal) %")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityLabel("Escada de velocidade")
        .accessibilityValue("recorde \(section.best ?? 0) %, meta \(section.goal) %")
    }
}

/// Os últimos 7 dias do trecho: cada dia uma coluna, a altura pelas passadas e o verde pelas limpas.
struct SevenDays: View {
    let section: StudySection

    var body: some View {
        let days = section.lastDays(7)
        let top = max(1, days.map(\.passes).max() ?? 1)
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(days, id: \.day) { day in
                VStack(spacing: 2) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.12)).frame(height: 24)
                        RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.45))
                            .frame(height: 24 * Double(day.passes) / Double(top))
                        RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.8))
                            .frame(height: 24 * Double(day.clean) / Double(top))
                    }
                    Text(day.day.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                }
                .help(day.passes == 0 ? "Sem estudo" : "\(day.passes) passada\(day.passes == 1 ? "" : "s"), \(day.clean) limpa\(day.clean == 1 ? "" : "s")"
                      + (day.top.map { ", até \($0) %" } ?? ""))
            }
        }
        .accessibilityLabel("Os últimos 7 dias")
    }
}

/// O espelho da volta: com a guitarra ligada e um loop, cada volta é gravada e ganha a nota no fim; o Limpo conta pelo
/// som. Tocando, só a fila das últimas; parado, primeiro "como foi?", depois os números, os lugares e o tempo.
struct MirrorGroup: View {
    let model: SongModel

    var body: some View {
        let input = InputEngine.shared
        let pass = model.studyPass
        InspectorGroup("A volta", summary: pass.map { "\(Int(($0.score.share * 100).rounded())) % a \($0.rate) %" }
                        ?? (input.running ? "toque com um loop" : "guitarra desligada"), key: "study.mirror") {
            if !input.running {
                Text("Com a guitarra ligada e um loop, cada volta é ouvida: a nota aparece no fim dela, e o Limpo conta sozinho.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Ligar a guitarra") {
                    Task {
                        await input.restoreChain()
                        input.start()
                    }
                }
            } else if pass == nil {
                Text(model.engine.loop == nil ? "Marque um loop (L) e toque: cada volta ganha a nota."
                     : "Toque com o loop: a nota aparece no fim de cada volta.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !model.studyHistory.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(model.studyHistory.enumerated()), id: \.offset) { _, item in
                        VStack(spacing: 1) {
                            Circle().fill(item.clean ? Color.green : item.share >= 0.6 ? Color.orange : Color.red)
                                .frame(width: 9, height: 9)
                            Text("\(Int((item.share * 100).rounded()))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .help("\(Int((item.share * 100).rounded())) % a \(item.rate) %")
                    }
                    Spacer(minLength: 0)
                }
            }
            if let pass, !model.engine.isPlaying {
                if pass.rating == nil {
                    SelfRating(question: "Como foi a última volta?") { model.studyPass?.rating = $0 }
                } else {
                    PassSummary(score: pass.score, rating: pass.rating)
                    PassTroubles(model: model, score: pass.score)
                    TimingHistogram(offsets: pass.score.offsets)
                }
                Button { model.hearStudyPass() } label: {
                    Label("Ouvir a volta", systemImage: "play.circle").frame(maxWidth: .infinity)
                }
                .help("Como ela foi gravada, na velocidade do estudo")
            }
        }
    }
}

/// O braço da guitarra sob a TAB no Estudar: as notas que soam agora cheias, as que vêm no próximo segundo e pouco
/// contornadas (mais fracas quanto mais longe), as que acabaram de soar sumindo; a corda 1 (Mi agudo) em cima, como na
/// TAB.
struct FretboardView: View {
    let model: SongModel
    var height = 112.0
    static let ahead = 1.2
    static let behind = 0.25
    /// Quanto uma nota com let ring segue acesa depois do fim escrito.
    static let ring = 1.5

    /// Quantas casas o braço mostra: até a mais alta da pista, ao menos 15.
    static func frets(_ model: SongModel) -> Int {
        let notes = model.scoreNotes.indices.contains(model.scoreTrack) ? model.scoreNotes[model.scoreTrack] : []
        return min(24, max(15, (notes.map(\.fret).max() ?? 12) + 1))
    }

    /// A altura de um braço de verdade na largura `width`: as cordas a pouco mais de um terço da largura de uma casa.
    static func naturalHeight(width: Double, model: SongModel) -> Double {
        let fretWidth = max(1, width - 44) / Double(frets(model))
        return min(max(fretWidth * 0.36, 16), 34) * 5 + 30
    }

    var body: some View {
        let notes = model.scoreNotes.indices.contains(model.scoreTrack) ? model.scoreNotes[model.scoreTrack] : []
        let strings = max(6, notes.map(\.string).max() ?? 6)
        let frets = Self.frets(model)
        TimelineView(.animation(paused: !model.engine.isPlaying)) { context in
            let host = CACurrentMediaTime() + context.date.timeIntervalSinceNow
            let now = model.engine.songTime(atHost: host)
            Canvas { canvas, size in
                draw(&canvas, size: size, now: now, notes: notes, strings: strings, frets: frets)
            }
        }
        .frame(height: height)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("O braço com as notas que tocam")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Double, notes: [ScoreNote], strings: Int,
                      frets: Int) {
        let left = 34.0
        let right = 10.0
        let top = 12.0
        let bottom = 18.0
        let width = size.width - left - right
        let gap = (size.height - top - bottom) / Double(max(1, strings - 1))
        let fretWidth = width / Double(frets)
        func y(_ string: Int) -> Double { top + Double(string - 1) * gap }
        func x(_ fret: Int) -> Double { fret == 0 ? left - 14 : left + (Double(fret) - 0.5) * fretWidth }
        // As marcas do braço e os trastes.
        for fret in [3, 5, 7, 9, 15, 17, 19, 21] where fret <= frets {
            let center = CGPoint(x: x(fret), y: size.height / 2 - bottom / 2 + top / 2)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                         with: .color(.secondary.opacity(0.18)))
        }
        for fret in [12, 24] where fret <= frets {
            for dy in [-gap, gap] {
                let center = CGPoint(x: x(fret), y: size.height / 2 - bottom / 2 + top / 2 + dy)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
                             with: .color(.secondary.opacity(0.18)))
            }
        }
        var wires = Path()
        for fret in 1...frets {
            wires.addRect(CGRect(x: left + Double(fret) * fretWidth, y: top - 2, width: 1, height: gap * Double(strings - 1) + 4))
        }
        context.fill(wires, with: .color(.secondary.opacity(0.35)))
        context.fill(Path(CGRect(x: left - 2, y: top - 3, width: 3, height: gap * Double(strings - 1) + 6)),
                     with: .color(.primary.opacity(0.7)))
        for string in 1...strings {
            context.fill(Path(CGRect(x: left - 22, y: y(string) - 0.5, width: width + 22, height: 0.6 + Double(string) * 0.18)),
                         with: .color(.secondary.opacity(0.6)))
        }
        for fret in [3, 5, 7, 9, 12, 15, 17, 19, 21, 24] where fret <= frets {
            context.draw(Text("\(fret)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                         at: CGPoint(x: x(fret), y: size.height - 8))
        }
        // As notas perto de agora, pela ordem do tempo (as de longe primeiro, as que soam por cima).
        guard !notes.isEmpty, !model.grid.isEmpty else { return }
        let grid = model.grid
        let firstTick = grid.tick(at: now - Self.behind) - 4 * TempoGrid.ticksPerQuarter * 2
        let lastTick = grid.tick(at: now + Self.ahead)
        var low = 0
        var high = notes.count
        while low < high {
            let middle = (low + high) / 2
            if notes[middle].tick < firstTick { low = middle + 1 } else { high = middle }
        }
        let amber = Color(red: 0.95, green: 0.62, blue: 0.16)
        let blue = Color(red: 0.3, green: 0.55, blue: 0.95)
        // Uma casa fracionária (o slide no meio do caminho) no x do braço; a corda solta fica antes da pestana.
        func xf(_ fret: Double) -> Double {
            fret >= 0.5 ? left + (fret - 0.5) * fretWidth : left - 14 + max(0, fret) * 28
        }
        // O bend empurra a corda pelo braço: as três de cima para o lado das graves, as outras para o das agudas; um
        // tom leva a corda até a vizinha.
        func push(_ string: Int) -> Double { string <= strings / 2 ? 1 : -1 }
        let perSemitone = gap * 0.5
        var marks: [(order: Double, draw: (inout GraphicsContext) -> Void)] = []
        var nextOnset: Double?
        // A nota de onde esta sai num ligado (hammer-on ou pull-off): a anterior da mesma corda que acaba onde ela começa,
        // sem slide (o slide já anda pela corda).
        func legatoFrom(_ index: Int) -> ScoreNote? {
            let note = notes[index]
            guard note.approached, note.slideIn == 0 else { return nil }
            var k = index - 1
            while k >= 0, notes[k].tick > note.tick - 8 * TempoGrid.ticksPerQuarter {
                let other = notes[k]
                if other.string == note.string, abs(other.tick + other.duration - note.tick) <= 1 {
                    return other.slidesOut || other.fret == note.fret ? nil : other
                }
                k -= 1
            }
            return nil
        }
        // O vibrato para o braço: na casa, a corda vai e volta para o lado do bend; dobrada, solta um pouco e volta ao
        // alto (é o que a mão faz). Maior que o do som, para se ver ao lado do bend.
        func vibratoShift(_ note: ScoreNote, bent: Bool, elapsed: Double) -> Double {
            guard note.vibrato > 0 else { return 0 }
            let swing = (note.vibrato > 1 ? 0.9 : 0.6) * 0.5 * (1 - cos(2 * .pi * 5.5 * elapsed))
            return bent ? -swing : swing
        }
        let pink = Color(red: 0.88, green: 0.36, blue: 0.72)
        let bottomY = y(strings)
        // A posição da mão: as casas das notas de agora (de 0,6 s atrás a 0,4 s adiante) sombreadas; se as dos próximos
        // 2 s pedem outra posição, ela tracejada, com uma seta da de agora até ela e a casa.
        do {
            let soonTick = grid.tick(at: now + 0.4)
            let pastTick = grid.tick(at: now - 0.6)
            let farTick = grid.tick(at: now + 2.5)
            var current: [Int] = []
            var coming: [(fret: Int, start: Double)] = []
            for note in notes[low...] {
                guard note.tick <= farTick else { break }
                guard !note.dead else { continue }
                if note.tick < soonTick, note.tick + note.duration > pastTick { current.append(note.fret) }
                else if note.tick >= soonTick { coming.append((note.fret, grid.seconds(at: note.tick))) }
            }
            func box(_ span: ClosedRange<Int>) -> CGRect {
                let x0 = left + Double(span.lowerBound - 1) * fretWidth
                return CGRect(x: x0, y: top - 6, width: Double(span.count) * fretWidth, height: bottomY - top + 12)
            }
            if let here = HandPosition.span(current) {
                let rect = box(here)
                context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(amber.opacity(0.09)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(amber.opacity(0.35)), lineWidth: 1)
                // A próxima posição: as notas que vêm até a primeira que sai desta, e as seguintes até 2,5 s.
                if let first = coming.firstIndex(where: { !(here.contains($0.fret) || $0.fret == 0) }),
                   let next = HandPosition.span(coming[first...].prefix(8).map(\.fret)), HandPosition.shifts(from: here, to: next) {
                    let lead = coming[first].start - now
                    let strength = max(0.25, min(1, 1.4 - lead / 2))
                    let target = box(next)
                    context.stroke(Path(roundedRect: target, cornerRadius: 6), with: .color(blue.opacity(0.7 * strength)),
                                   style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    let from = CGPoint(x: rect.midX, y: top - 8)
                    let to = CGPoint(x: target.midX + (target.midX > rect.midX ? -6 : 6), y: top - 8)
                    Self.arrow(&context, from: from, to: to, color: blue.opacity(strength), dashed: false)
                    context.draw(Text("\(next.lowerBound)ª").font(.system(size: 9, weight: .bold)).foregroundStyle(blue.opacity(strength)),
                                 at: CGPoint(x: target.midX, y: top - 8), anchor: target.midX > rect.midX ? .leading : .trailing)
                }
            }
        }
        // Os acordes: as notas que atacam juntas, ligadas por uma linha, e a pestana onde duas ou mais dividem a casa
        // mais baixa (`chords[tique]`: a corda, a casa, se soa).
        var chords: [Double: [(string: Int, fret: Int, sounding: Bool, strength: Double)]] = [:]
        // O formato da nota: losango no harmônico, bolinha no resto.
        func dot(_ rect: CGRect, _ note: ScoreNote) -> Path {
            guard note.harmonic else { return Path(ellipseIn: rect) }
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY - 1))
            path.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY + 1))
            path.addLine(to: CGPoint(x: rect.minX - 1, y: rect.midY))
            path.closeSubpath()
            return path
        }
        // O que vai escrito na nota: a casa, X na morta, entre parênteses na fantasma.
        func caption(_ note: ScoreNote, fret: Int, radius: Double) -> Text {
            let text = note.dead ? "X" : note.ghost ? "(\(fret))" : "\(fret)"
            return Text(text).font(.system(size: radius * (note.ghost ? 0.9 : 1.15), weight: .bold).monospacedDigit())
        }
        // As marcas em volta: PM embaixo, T (tapping) em cima à esquerda, o harmônico ("H.A." no artificial) e o dedo
        // num selo embaixo à direita.
        func extras(_ context: inout GraphicsContext, _ note: ScoreNote, center: CGPoint, radius: Double, color: Color) {
            if note.palmMute {
                context.draw(Text("PM").font(.system(size: 8, weight: .heavy)).foregroundStyle(color),
                             at: CGPoint(x: center.x, y: center.y + radius + 6))
            }
            if note.tapped {
                context.draw(Text("T").font(.system(size: 9, weight: .heavy)).foregroundStyle(pink),
                             at: CGPoint(x: center.x - radius - 2, y: center.y - radius - 2))
            }
            if note.harmonic, !note.naturalHarmonic {
                context.draw(Text("H.A.").font(.system(size: 8, weight: .bold)).foregroundStyle(color),
                             at: CGPoint(x: center.x, y: center.y - radius - 7))
            }
            if let finger = note.finger {
                let badge = CGRect(x: center.x + radius * 0.45, y: center.y + radius * 0.35, width: 11, height: 11)
                context.fill(Path(ellipseIn: badge), with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(Path(ellipseIn: badge), with: .color(color), lineWidth: 1)
                context.draw(Text(finger == 0 ? "T" : "\(finger)").font(.system(size: 8, weight: .bold)).foregroundStyle(color),
                             at: CGPoint(x: badge.midX, y: badge.midY))
            }
        }
        // Uma nota com let ring segue soando depois do fim escrito, até outra nota da mesma corda ou 1,5 s.
        func rings(_ index: Int, until tick: Double) -> Bool {
            let note = notes[index]
            guard note.letRing else { return false }
            var k = index + 1
            while k < notes.count, notes[k].tick <= tick {
                if notes[k].string == note.string, notes[k].tick >= note.tick + note.duration - 1 { return false }
                k += 1
            }
            return true
        }
        let nowTick = grid.tick(at: now)
        for index in low..<notes.count {
            let note = notes[index]
            guard note.tick <= lastTick else { break }
            let start = grid.seconds(at: note.tick)
            let end = grid.seconds(at: note.tick + note.duration)
            if start > now, nextOnset == nil || start < nextOnset! { nextOnset = start }
            let ringing = end <= now && now - end < Self.ring && rings(index, until: nowTick)
            guard end > now - Self.behind || ringing, start < now + Self.ahead else { continue }
            let length = max(1e-3, end - start)
            let rowY = y(note.string)
            let radius = min(15, max(8, gap * 0.4))
            let topBend = Int((note.bend.map(\.value).max() ?? 0).rounded())
            let direction = push(note.string)
            if start <= now, end > now {
                // Soando: a bolinha anda pela corda no slide e sai dela no bend e no vibrato, como a mão.
                let elapsed = now - start
                let slide = note.slideOffset(elapsed: elapsed, length: length)
                let lifted = note.bendOffset(fraction: elapsed / length)
                let bend = lifted + vibratoShift(note, bent: lifted >= 0.2, elapsed: elapsed)
                // O trinado: a bolinha salta entre as duas casas.
                let trillFret = note.trill.map { Double(note.fret + $0 - note.pitch) }
                let trillOn = trillFret != nil && Int(elapsed * 15) % 2 == 1
                let fret = (trillOn ? trillFret! : Double(note.fret)) + slide
                let legato = legatoFrom(index)
                let center = CGPoint(x: xf(fret), y: rowY + direction * bend * perSemitone)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                let shown = max(0, Int(fret.rounded()))
                let label = caption(note, fret: shown, radius: radius)
                // A cor: âmbar; rosa no tapping; cinza na morta; mais apagada no palm mute e na fantasma.
                let fill = note.dead ? Color.gray : note.tapped ? pink : amber.opacity(note.ghost ? 0.5 : note.palmMute ? 0.75 : 1)
                chords[note.tick, default: []].append((note.string, note.fret, true, 1))
                marks.append((3, { context in
                    // O ligado que acabou de soar: um arco da casa de antes até esta, com H ou P, apagando em 0,4 s.
                    if let legato, elapsed < 0.4 {
                        Self.legatoArc(&context, from: xf(Double(legato.fret)), to: xf(Double(note.fret)), y: rowY - radius,
                                       hammer: note.pitch > legato.pitch, color: amber.opacity(1 - elapsed / 0.4), lift: radius)
                    }
                    // O trinado: a outra casa contornada, ligada por um traço, e "tr".
                    if let trillFret {
                        let other = CGPoint(x: xf(trillFret), y: rowY)
                        let ring = CGRect(x: other.x - radius, y: other.y - radius, width: radius * 2, height: radius * 2)
                        context.stroke(Path(ellipseIn: ring), with: .color(amber.opacity(0.8)), lineWidth: 1.5)
                        context.draw(Text("tr").font(.system(size: 10, weight: .bold).italic()).foregroundStyle(amber),
                                     at: CGPoint(x: (xf(Double(note.fret)) + other.x) / 2, y: rowY - radius - 6))
                    }
                    // O rastro do slide desde a casa de onde a nota saiu.
                    let from = note.slideIn != 0 && elapsed < 0.4 ? Double(note.fret) + note.slideIn
                        : slide != 0 ? Double(note.fret) : nil
                    if let from {
                        var trail = Path()
                        trail.move(to: CGPoint(x: xf(from), y: rowY))
                        trail.addLine(to: CGPoint(x: center.x, y: rowY))
                        context.stroke(trail, with: .linearGradient(Gradient(colors: [amber.opacity(0), amber.opacity(0.8)]),
                                                                    startPoint: CGPoint(x: xf(from), y: rowY),
                                                                    endPoint: CGPoint(x: center.x, y: rowY)),
                                       style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    }
                    // A corda dobrada: da casa de trás até a ponte, passando pelo dedo.
                    if abs(center.y - rowY) > 0.5 {
                        var string = Path()
                        string.move(to: CGPoint(x: center.x - fretWidth * 2.2, y: rowY))
                        string.addQuadCurve(to: CGPoint(x: center.x + fretWidth * 2.2, y: rowY),
                                            control: CGPoint(x: center.x, y: rowY + (center.y - rowY) * 2))
                        context.stroke(string, with: .color(amber.opacity(0.85)), lineWidth: 1.6)
                    }
                    // O vibrato: um halo que pulsa com ele.
                    if note.vibrato > 0 {
                        let pulse = 0.5 + 0.5 * sin(2 * .pi * 5.5 * elapsed)
                        let halo = rect.insetBy(dx: -3 - 3 * pulse, dy: -3 - 3 * pulse)
                        context.stroke(Path(ellipseIn: halo), with: .color(amber.opacity(0.25 + 0.35 * pulse)), lineWidth: 1.5)
                    }
                    context.fill(dot(rect, note), with: .color(fill))
                    // Quanto falta da nota: um anel que se fecha até o fim dela.
                    let remaining = 1 - elapsed / length
                    if length >= 0.25 {
                        var arc = Path()
                        arc.addArc(center: center, radius: radius + 2.5, startAngle: .degrees(-90),
                                   endAngle: .degrees(-90 + 360 * remaining), clockwise: false)
                        context.stroke(arc, with: .color(fill.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                    context.draw(label.foregroundStyle(.black), at: center)
                    extras(&context, note, center: center, radius: radius, color: Color.primary.opacity(0.8))
                    // Quanto o bend chega: o alto escrito, ao lado, enquanto a corda está fora do lugar.
                    if topBend > 0, lifted >= 0.2 {
                        let text = Text("↑" + BendForm.name(topBend) + (note.vibrato > 0 ? " ∿" : "")).font(.system(size: 10, weight: .bold))
                        context.draw(text.foregroundStyle(amber), at: CGPoint(x: center.x + radius + 3, y: center.y), anchor: .leading)
                    }
                }))
            } else if end <= now {
                // Acabou: apaga em 0,25 s; com let ring, segue acesa e apagando devagar com um anel em volta.
                let fade = ringing ? max(0, 1 - (now - end) / Self.ring) : max(0, 1 - (now - end) / Self.behind)
                let fret = Double(note.fret) + note.slideOut
                let center = CGPoint(x: xf(fret), y: rowY)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                let label = caption(note, fret: note.fret, radius: radius)
                marks.append((ringing ? 2.5 : 0, { context in
                    context.fill(dot(rect, note), with: .color(amber.opacity((ringing ? 0.6 : 0.35) * fade)))
                    if ringing {
                        context.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(amber.opacity(0.5 * fade)),
                                       style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        context.draw(label.foregroundStyle(Color.black.opacity(0.7 * fade)), at: center)
                    }
                }))
            } else {
                let center = CGPoint(x: xf(Double(note.fret)), y: rowY)
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                let label = caption(note, fret: note.fret, radius: radius)
                let lead = start - now
                let strength = max(0.15, 1 - lead / Self.ahead)
                let soon = nextOnset.map { abs(start - $0) < 0.02 } ?? false
                chords[note.tick, default: []].append((note.string, note.fret, false, strength))
                marks.append((soon ? 2 : 1 - lead, { context in
                    let tint = (soon ? blue : note.tapped ? pink : Color.secondary).opacity(strength)
                    if let legato = legatoFrom(index) {
                        Self.legatoArc(&context, from: xf(Double(legato.fret)), to: center.x, y: rowY - radius,
                                       hammer: note.pitch > legato.pitch, color: tint, lift: radius)
                    }
                    if let trill = note.trill {
                        let otherX: Double = xf(Double(note.fret + trill - note.pitch))
                        let other = CGPoint(x: otherX, y: rowY)
                        let middle: Double = (center.x + otherX) / 2
                        let small = radius * 0.7
                        context.stroke(Path(ellipseIn: CGRect(x: other.x - small, y: other.y - small, width: small * 2, height: small * 2)),
                                       with: .color(tint), style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                        context.draw(Text("tr").font(.system(size: 9, weight: .bold).italic()).foregroundStyle(tint),
                                     at: CGPoint(x: middle, y: rowY - radius - 5))
                    }
                    // O que vem: o slide como uma seta pela corda, o bend como uma seta para o lado e o vibrato numa onda.
                    if note.slideIn != 0 {
                        let from = CGPoint(x: xf(Double(note.fret) + note.slideIn), y: rowY)
                        Self.arrow(&context, from: from, to: CGPoint(x: center.x - (note.slideIn < 0 ? radius : -radius), y: rowY),
                                   color: tint, dashed: true)
                    }
                    if note.slideOut != 0 {
                        let to = CGPoint(x: xf(Double(note.fret) + note.slideOut), y: rowY)
                        Self.arrow(&context, from: CGPoint(x: center.x + (note.slideOut > 0 ? radius : -radius), y: rowY), to: to,
                                   color: tint, dashed: true)
                    }
                    if topBend > 0 {
                        let reach = max(radius + 6, Double(topBend) / 2 * perSemitone + radius)
                        let tip = CGPoint(x: center.x, y: rowY + direction * reach)
                        Self.arrow(&context, from: CGPoint(x: center.x, y: rowY + direction * radius), to: tip, color: tint, dashed: false)
                        context.draw(Text(BendForm.name(topBend)).font(.system(size: 9, weight: .bold)).foregroundStyle(tint),
                                     at: CGPoint(x: tip.x + 4, y: tip.y), anchor: .leading)
                    }
                    if note.vibrato > 0 {
                        // Na ponta da seta do bend, se ele dobra (o vibrato é lá em cima); senão, em cima da bolinha.
                        var wave = Path()
                        let y0 = topBend > 0 ? rowY + direction * (max(radius + 6, Double(topBend) / 2 * perSemitone + radius) + 8)
                            : rowY - direction * (radius + 4)
                        let amplitude = note.vibrato > 1 ? 3.0 : 2.0
                        for k in 0...16 {
                            let u = Double(k) / 16
                            let point = CGPoint(x: center.x - radius + u * radius * 2, y: y0 + sin(u * 4 * .pi) * amplitude)
                            if k == 0 { wave.move(to: point) } else { wave.addLine(to: point) }
                        }
                        context.stroke(wave, with: .color(tint), lineWidth: 1.2)
                    }
                    context.fill(dot(rect, note), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.9 * strength)))
                    context.stroke(dot(rect, note), with: .color(tint),
                                   style: StrokeStyle(lineWidth: soon ? 2 : 1.2, dash: note.ghost ? [2, 2] : []))
                    context.draw(label.foregroundStyle(tint), at: center)
                    extras(&context, note, center: center, radius: radius, color: tint)
                }))
            }
        }
        // Os acordes (três notas ou mais juntas, ou duas na mesma casa): a linha que as liga e a pestana, atrás das bolinhas.
        for (tick, group) in chords where group.count >= 2 {
            let sorted = group.sorted { $0.string < $1.string }
            let fretted = sorted.filter { $0.fret > 0 }
            let lowest = fretted.map(\.fret).min()
            let barre = lowest.map { fret in fretted.filter { $0.fret == fret } } ?? []
            guard sorted.count >= 3 || barre.count >= 2 else { continue }
            let sounding = sorted.contains { $0.sounding }
            let strength = sorted.map(\.strength).max() ?? 1
            let color = sounding ? amber : (nextOnset.map { abs(grid.seconds(at: tick) - $0) < 0.02 } ?? false ? blue : Color.secondary)
            let radius = min(15, max(8, gap * 0.4))
            marks.append((sounding ? 2.9 : 0.5, { context in
                if sorted.count >= 3 {
                    var line = Path()
                    for (k, item) in sorted.enumerated() {
                        let point = CGPoint(x: xf(Double(item.fret)), y: y(item.string))
                        if k == 0 { line.move(to: point) } else { line.addLine(to: point) }
                    }
                    context.stroke(line, with: .color(color.opacity(0.5 * strength)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
                if barre.count >= 2, let fret = lowest, let first = barre.first?.string, let last = barre.last?.string {
                    let bar = CGRect(x: xf(Double(fret)) - radius * 0.55, y: y(first) - radius * 0.9,
                                     width: radius * 1.1, height: y(last) - y(first) + radius * 1.8)
                    context.fill(Path(roundedRect: bar, cornerRadius: radius * 0.55),
                                 with: .color(color.opacity((sounding ? 0.45 : 0.25) * strength)))
                }
            }))
        }
        for mark in marks.sorted(by: { $0.order < $1.order }) { mark.draw(&context) }
    }

    /// O ligado: um arco sobre a corda entre as duas casas, com H (hammer-on, para cima) ou P (pull-off, para baixo).
    private static func legatoArc(_ context: inout GraphicsContext, from: Double, to: Double, y: Double, hammer: Bool,
                                  color: Color, lift: Double) {
        guard abs(to - from) > 2 else { return }
        var arc = Path()
        arc.move(to: CGPoint(x: from, y: y))
        arc.addQuadCurve(to: CGPoint(x: to, y: y), control: CGPoint(x: (from + to) / 2, y: y - lift))
        context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        context.draw(Text(hammer ? "H" : "P").font(.system(size: 9, weight: .heavy)).foregroundStyle(color),
                     at: CGPoint(x: (from + to) / 2, y: y - lift / 2 - 6))
    }

    /// Uma seta fina (o slide que vem pela corda, o bend para o lado).
    private static func arrow(_ context: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color, dashed: Bool) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = hypot(dx, dy)
        guard length > 3 else { return }
        var line = Path()
        line.move(to: from)
        line.addLine(to: to)
        context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: dashed ? [3, 2] : []))
        let ux = dx / length
        let uy = dy / length
        var head = Path()
        head.move(to: to)
        head.addLine(to: CGPoint(x: to.x - ux * 5 - uy * 3, y: to.y - uy * 5 + ux * 3))
        head.addLine(to: CGPoint(x: to.x - ux * 5 + uy * 3, y: to.y - uy * 5 - ux * 3))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }
}
