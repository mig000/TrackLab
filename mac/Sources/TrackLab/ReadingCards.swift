import SwiftUI
import TrackLabCore

/// As leituras da nota escolhida em cartões desenhados: à esquerda a TAB (a casa, a seta do bend, a volta tracejada,
/// o vibrato), à direita a forma da leitura (faixa âmbar) sobre os pontos do som, e embaixo quão perto do som ela fica.
/// Um clique (ou ⌥1–⌥4) escolhe; o alto-falante ouve a leitura sintetizada. Com várias notas escolhidas, os cartões
/// são o trecho em outras posições do braço. "Corrigir pelo som" (⇧F) corrige a pista inteira, ou o loop.
struct ReadingCards: View {
    let model: SongModel

    private static let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Leituras").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { model.correctBySound() } label: {
                    HStack(spacing: 3) { Text("Corrigir pelo som"); KeyHint("⇧F") }
                }
                .help("⇧F: escreve o que o som faz onde ele discorda da TAB com segurança (a altura, o bend, o vibrato), "
                      + "na pista inteira ou só no loop; ⌘Z desfaz")
            }
            if let positions = model.selectedPositions() {
                LazyVGrid(columns: Self.columns, spacing: 6) {
                    ForEach(positions) { card in
                        PositionTile(card: card)
                            .onTapGesture { model.choosePosition(card.id) }
                            .help(card.current ? "O trecho como está" : "O trecho nesta posição do braço")
                    }
                }
            } else if let sheet = model.selectedReadings() {
                LazyVGrid(columns: Self.columns, spacing: 6) {
                    ForEach(sheet.cards) { card in
                        ReadingTile(card: card, sheet: sheet, hear: { model.hearReading(card.id) })
                            .onTapGesture { model.chooseReading(card.id) }
                            .help(help(card))
                    }
                }
            } else {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            let corrected = model.correctedCount(track: model.scoreTrack)
            if corrected > 0 {
                Text("\(corrected) nota\(corrected == 1 ? "" : "s") corrigida\(corrected == 1 ? "" : "s") pelo som, "
                     + "marcadas na Lente")
                    .font(.caption)
                    .foregroundStyle(ReadingTile.teal)
            }
        }
    }

    private var placeholder: String {
        guard model.tabSelection != nil else { return "Escolha uma nota para ver as leituras do som." }
        return model.lensVisible ? "Sem medida do som nesta nota (acorde, ou a curva ainda não chegou)."
            : "As leituras vêm da Lente: mostre-a (⌥⌘2) para medir o som."
    }

    private func help(_ card: SongModel.ReadingCard) -> String {
        let percent = Int((card.closeness * 100).rounded())
        let key = card.id < 4 ? " (⌥\(card.id + 1))" : ""
        return card.current ? "\(card.reading.name): é o que está escrito · \(percent) % perto do som"
            : "\(card.reading.name)\(key) · \(percent) % perto do som"
    }
}

/// Um cartão de leitura: a TAB à esquerda, a forma sobre o som à direita, o nome e quão perto do som.
struct ReadingTile: View {
    let card: SongModel.ReadingCard
    let sheet: SongModel.ReadingSheet
    let hear: () -> Void

    static let amber = Color(red: 0.94, green: 0.62, blue: 0.15)
    static let orange = Color(red: 1, green: 138 / 255, blue: 61 / 255)
    static let teal = Color(red: 0.11, green: 0.62, blue: 0.46)

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Canvas { context, size in draw(context, size) }
                .frame(height: 46)
            HStack(spacing: 4) {
                if card.id < 4 { KeyHint("⌥\(card.id + 1)") }
                Text(card.reading.name).font(.caption2.weight(card.current ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 2)
                Button(action: hear) { Image(systemName: "speaker.wave.2").font(.caption2) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Ouvir esta leitura sintetizada")
            }
            HStack(spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule().fill(Self.teal).frame(width: geometry.size.width * card.closeness)
                    }
                }
                .frame(height: 3)
                Text("\(Int((card.closeness * 100).rounded())) %").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(card.current ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: card.current ? 2 : 0.5))
        .contentShape(Rectangle())
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let reading = card.reading
        let ink = Color.secondary
        // A TAB, à esquerda: três linhas de corda, a casa na do meio e os sinais.
        let tabWidth = size.width * 0.42
        let mid = size.height * 0.62
        let gap = 7.0
        var lines = Path()
        for k in -1...1 {
            lines.move(to: CGPoint(x: 0, y: mid + Double(k) * gap))
            lines.addLine(to: CGPoint(x: tabWidth, y: mid + Double(k) * gap))
        }
        context.stroke(lines, with: .color(ink.opacity(0.5)), lineWidth: 0.5)
        let fret = sheet.fret + reading.pitch - sheet.pitch
        let label = reading.trill.map { "\(fret)(\(sheet.fret + $0 - sheet.pitch))" } ?? "\(fret)"
        let numberX = 9.0
        context.fill(Path(CGRect(x: numberX - 6, y: mid - 5, width: Double(label.count) * 6.5 + 2, height: 10)),
                     with: .color(Color(nsColor: .controlBackgroundColor)))
        context.draw(Text(label).font(.system(size: 10, weight: .semibold).monospacedDigit()),
                     at: CGPoint(x: numberX - 4, y: mid), anchor: .leading)
        let after = numberX - 4 + Double(label.count) * 6.5 + 2
        if reading.trill != nil {
            context.draw(Text("tr").font(.system(size: 9, weight: .semibold).italic()), at: CGPoint(x: numberX, y: mid - 15))
        }
        if reading.vibrato {
            var wave = Path()
            let y0 = mid - 15.0
            wave.move(to: CGPoint(x: after, y: y0))
            for i in 1...16 {
                let x = after + Double(i) * 1.6
                wave.addLine(to: CGPoint(x: x, y: y0 + sin(Double(i) * .pi / 2.5) * 2))
            }
            context.stroke(wave, with: .color(ink), lineWidth: 1)
        }
        if let form = reading.form {
            let top = 4.0
            let start = CGPoint(x: after, y: mid)
            let height = form.kind.usesTop ? form.top : form.pre
            var arrow = Path()
            let tip = CGPoint(x: after + 12, y: top + 9)
            if form.kind == .prebend || form.kind == .prebendRelease || form.kind == .prebendBend {
                arrow.move(to: CGPoint(x: after + 2, y: mid))
                arrow.addLine(to: CGPoint(x: after + 2, y: top + 9))
            } else {
                arrow.move(to: start)
                arrow.addQuadCurve(to: tip, control: CGPoint(x: tip.x, y: mid))
            }
            let head = form.kind == .prebend || form.kind == .prebendRelease || form.kind == .prebendBend
                ? CGPoint(x: after + 2, y: top + 9) : tip
            arrow.move(to: CGPoint(x: head.x - 3, y: head.y + 4))
            arrow.addLine(to: head)
            arrow.addLine(to: CGPoint(x: head.x + 3, y: head.y + 4))
            context.stroke(arrow, with: .color(Self.amber), lineWidth: 1.3)
            context.draw(Text(BendForm.name(height)).font(.system(size: 9, weight: .semibold)),
                         at: CGPoint(x: head.x, y: top + 2))
            if form.kind.usesEnd {
                var back = Path()
                back.move(to: CGPoint(x: head.x + 3, y: top + 9))
                back.addQuadCurve(to: CGPoint(x: head.x + 12, y: mid - 4), control: CGPoint(x: head.x + 12, y: top + 9))
                context.stroke(back, with: .color(Self.amber), style: StrokeStyle(lineWidth: 1.3, dash: [2.5, 2]))
                if form.end > 0 {
                    context.draw(Text(BendForm.name(form.end)).font(.system(size: 8)),
                                 at: CGPoint(x: head.x + 16, y: mid - 9))
                }
            }
        }
        // A forma sobre o som, à direita: semitons acima da altura escrita.
        let x0 = tabWidth + 6
        let width = size.width - x0
        var shape: [Double] = []
        for i in 0...40 {
            let f = Double(i) / 40
            var value = Double(reading.pitch - sheet.pitch) + reading.offset(at: f)
            if let high = reading.trill { value = i % 4 < 2 ? value : Double(high - sheet.pitch) }
            if reading.vibrato { value += 0.12 * (1 - cos(f * 2 * .pi * 5)) }
            shape.append(value)
        }
        let values = shape + sheet.sound.map(\.semitones)
        let low = min(-0.5, (values.min() ?? 0) - 0.3)
        let high = max(1.5, (values.max() ?? 0) + 0.3)
        func y(_ semitones: Double) -> Double { size.height - 2 - (semitones - low) / (high - low) * (size.height - 4) }
        var base = Path()
        base.move(to: CGPoint(x: x0, y: y(0)))
        base.addLine(to: CGPoint(x: size.width, y: y(0)))
        context.stroke(base, with: .color(ink.opacity(0.4)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 2]))
        var band = Path()
        for (i, value) in shape.enumerated() {
            let point = CGPoint(x: x0 + width * Double(i) / 40, y: y(value))
            if i == 0 { band.move(to: point) } else { band.addLine(to: point) }
        }
        context.stroke(band, with: .color(Self.amber.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        var dots = Path()
        for point in sheet.sound {
            let x: Double = x0 + width * point.fraction
            let top: Double = y(point.semitones)
            dots.addEllipse(in: CGRect(x: x - 1, y: top - 1, width: 2, height: 2))
        }
        context.fill(dots, with: .color(Self.orange))
    }
}

/// Um cartão de posição: o braço com as notas do trecho (as cordas na horizontal, a mais aguda em cima).
struct PositionTile: View {
    let card: SongModel.PositionCard

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Canvas { context, size in draw(context, size) }
                .frame(height: 44)
            Text(card.current ? "Como está" : name).font(.caption2.weight(card.current ? .semibold : .regular)).lineLimit(1)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(card.current ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: card.current ? 2 : 0.5))
        .contentShape(Rectangle())
    }

    private var name: String {
        card.frets.lowerBound == card.frets.upperBound ? "Casa \(card.frets.lowerBound)"
            : "Casas \(card.frets.lowerBound)–\(card.frets.upperBound)"
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let first = max(0, card.frets.lowerBound - 1)
        let last = max(first + 4, card.frets.upperBound + 1)
        let count = Double(last - first)
        let step = size.width / count
        let rows = max(1, card.strings - 1)
        func y(_ string: Int) -> Double { 3 + Double(string - 1) / Double(rows) * (size.height - 6) }
        var lines = Path()
        for string in 1...card.strings {
            lines.move(to: CGPoint(x: 0, y: y(string)))
            lines.addLine(to: CGPoint(x: size.width, y: y(string)))
        }
        for k in 0...Int(count) {
            let x = Double(k) * step
            lines.move(to: CGPoint(x: x, y: y(1)))
            lines.addLine(to: CGPoint(x: x, y: y(card.strings)))
        }
        context.stroke(lines, with: .color(Color.secondary.opacity(0.5)), lineWidth: 0.5)
        if first == 0 {
            context.fill(Path(CGRect(x: 0, y: y(1), width: 2, height: y(card.strings) - y(1))), with: .color(.secondary))
        }
        var dots = Path()
        for dot in card.dots {
            let x = dot.fret == 0 ? 3 : (Double(dot.fret - first) - 0.5) * step
            dots.addEllipse(in: CGRect(x: x - 3, y: y(dot.string) - 3, width: 6, height: 6))
        }
        context.fill(dots, with: .color(ReadingTile.teal))
    }
}
