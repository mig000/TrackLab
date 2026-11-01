import AppKit
import SwiftUI
import TrackLabCore

/// O diagrama de um acorde no violão: seis cordas, quatro casas, a pestana, os dedos, X e O em cima e a casa inicial ao
/// lado quando o desenho não começa no começo do braço.
struct ChordDiagram: View {
    let shape: ChordShape
    var width = 112.0

    var body: some View {
        Canvas { context, size in draw(&context, size: size) }
            .frame(width: width, height: width * 1.18)
            .accessibilityLabel("Digitação: " + shape.frets.map { $0 < 0 ? "x" : "\($0)" }.joined(separator: " "))
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let strings = shape.frets.count
        guard strings > 1 else { return }
        let base = shape.baseFret
        let left = size.width * 0.2
        let right = size.width * 0.92
        let top = size.height * 0.17
        let bottom = size.height * 0.97
        let step = (right - left) / Double(strings - 1)
        let fretHeight = (bottom - top) / 4
        let ink = Color.primary
        func x(_ string: Int) -> Double { left + Double(string) * step }
        // As cordas e as casas; a pestana do começo do braço mais grossa.
        var grid = Path()
        for string in 0..<strings { grid.addRect(CGRect(x: x(string) - 0.5, y: top, width: 1, height: bottom - top)) }
        for fret in 0...4 { grid.addRect(CGRect(x: left, y: top + Double(fret) * fretHeight - 0.5, width: right - left, height: 1)) }
        context.fill(grid, with: .color(ink.opacity(0.55)))
        if base == 1 {
            context.fill(Path(CGRect(x: left - 0.5, y: top - 3, width: right - left + 1, height: 3.5)), with: .color(ink.opacity(0.85)))
        } else {
            context.draw(Text("\(base)ª").font(.system(size: max(9, size.width * 0.09), weight: .semibold)).foregroundStyle(.secondary),
                         at: CGPoint(x: left - 6, y: top + fretHeight / 2), anchor: .trailing)
        }
        let radius = min(step, fretHeight) * 0.36
        func y(_ fret: Int) -> Double { top + (Double(fret - base) + 0.5) * fretHeight }
        // A pestana: das cordas com essa casa, da primeira à última.
        for barre in shape.barres where barre >= base && barre < base + 4 {
            let on = shape.frets.indices.filter { shape.frets[$0] == barre }
            guard let first = on.first, let last = on.last, last > first else { continue }
            let rect = CGRect(x: x(first) - radius, y: y(barre) - radius, width: x(last) - x(first) + 2 * radius, height: 2 * radius)
            context.fill(Path(roundedRect: rect, cornerRadius: radius), with: .color(ink))
        }
        let markSize = max(8, size.width * 0.085)
        for (string, fret) in shape.frets.enumerated() {
            if fret < 0 {
                context.draw(Text("×").font(.system(size: markSize + 2)).foregroundStyle(.secondary),
                             at: CGPoint(x: x(string), y: top - markSize * 0.95))
            } else if fret == 0 {
                context.stroke(Path(ellipseIn: CGRect(x: x(string) - markSize * 0.38, y: top - markSize * 1.35,
                                                      width: markSize * 0.76, height: markSize * 0.76)),
                               with: .color(.secondary), lineWidth: 1.1)
            } else if fret >= base, fret < base + 4 {
                let center = CGPoint(x: x(string), y: y(fret))
                context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                             with: .color(shape.fromTab ? Color(red: 0.93, green: 0.6, blue: 0.13) : ink))
                let finger = shape.fingers.indices.contains(string) ? shape.fingers[string] : 0
                if finger > 0 {
                    context.draw(Text("\(finger)").font(.system(size: radius * 1.25, weight: .bold))
                                    .foregroundStyle(Color(nsColor: .windowBackgroundColor)), at: center)
                }
            }
        }
    }
}

/// O acorde com as digitações dele: o nome, o diagrama, de onde veio a digitação e a troca entre as outras; o
/// alto-falante toca a forma escolhida.
struct ChordCard: View {
    let model: SongModel
    let chord: ChordSpan
    var width = 112.0
    var label: String? = nil
    @Local private var choice = 0

    var body: some View {
        let shapes = model.chordShapes(for: chord)
        let index = shapes.isEmpty ? 0 : min(choice, shapes.count - 1)
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if let label { Text(label).font(.caption2).foregroundStyle(.secondary) }
                Text(chord.name.isEmpty ? "N.C." : model.shown(chord.name)).font(.system(size: width > 100 ? 17 : 13, weight: .semibold))
                Spacer(minLength: 0)
                if !shapes.isEmpty {
                    Button { model.playShape(shapes[index]) } label: { Image(systemName: "speaker.wave.2") }
                        .buttonStyle(.borderless)
                        .help("Ouvir esta digitação")
                }
            }
            if shapes.isEmpty {
                Text(chord.name.isEmpty ? "Sem acorde" : "Sem digitação para \(chord.name)")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: width, height: width * 1.18)
            } else {
                ChordDiagram(shape: shapes[index], width: width)
                HStack(spacing: 6) {
                    Button { choice = (index + shapes.count - 1) % shapes.count } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).disabled(shapes.count < 2)
                    Text(shapes[index].fromTab ? (width > 100 ? "como na TAB" : "na TAB") : "\(index + 1) de \(shapes.count)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(minWidth: width > 100 ? 60 : 40)
                    Button { choice = (index + 1) % shapes.count } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless).disabled(shapes.count < 2)
                }
                if let shape = model.shapeName(for: chord), shape != chord.name {
                    Text(model.showingShapes ? "soa \(chord.name) · \(model.offsetLabel)" : "forma de \(shape) · \(model.offsetLabel)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: width + 8)
        .onChange(of: chord.from) { choice = 0 }
    }
}

/// No inspetor do Estudar: o acorde que toca (ou o escolhido na barra) e o seguinte, com as digitações.
struct ChordsGroup: View {
    let model: SongModel

    var body: some View {
        InspectorGroup("Acordes", summary: model.chordSpans.isEmpty ? "sem acordes" : nil, key: "acordes") {
            if model.chordSpans.isEmpty {
                Text("A barra de acordes aparece quando a partitura termina de abrir.").font(.caption).foregroundStyle(.secondary)
            } else {
                if let proposal = model.pitchFixProposal() {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(proposal.message, systemImage: "tuningfork").font(.caption).fixedSize(horizontal: false, vertical: true)
                        Button(proposal.action) { model.applyPitchFix() }
                            .help("Grava na partitura; a TAB fica nas mesmas casas e a Lente, a TAB sintetizada e os acordes passam a soar como o disco")
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
                } else if model.shapeOffset != 0 {
                    Label(model.shapeOffset > 0 ? "Capo \(model.capoFret)ª" : "Afinada \(model.offsetLabel)", systemImage: "tuningfork")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.shapeOffset != 0 {
                    Picker("Nomes", selection: Binding(get: { model.chordsByShape }, set: { model.chordsByShape = $0 })) {
                        Text("Como soam").tag(false)
                        Text("Como na TAB").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Os nomes na barra de acordes e aqui: como soam no disco, ou pela forma que a mão faz (com o capo ou a afinação da música)")
                }
                TimelineView(.periodic(from: .now, by: 0.15)) { _ in
                    let pair = model.chordPair()
                    HStack(alignment: .top, spacing: 10) {
                        if let now = pair.now {
                            ChordCard(model: model, chord: now, width: 120)
                        }
                        if let next = pair.next {
                            ChordCard(model: model, chord: next, width: 84, label: "depois")
                                .opacity(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
