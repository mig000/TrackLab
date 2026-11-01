import Foundation
import Testing
@testable import TrackLabCore

private let q = TempoGrid.ticksPerQuarter

/// Colcheias de um acorde (as notas MIDI) de `from` a `to` tempos, como uma base palhetada.
private func strum(_ pitches: [Int], from: Double, to: Double) -> [ScoreNote] {
    stride(from: from, to: to, by: 0.5).flatMap { beat in
        pitches.map { ScoreNote(tick: beat * q, duration: q / 2, pitch: $0, string: 1, fret: 0) }
    }
}

private func bass(_ pitch: Int, from: Double, to: Double) -> [ScoreNote] {
    stride(from: from, to: to, by: 1).map { ScoreNote(tick: $0 * q, duration: q, pitch: pitch, string: 1, fret: 0) }
}

/// O verso do Sultans: | Dm | C  Bb | A | A |, a base com uma nota de passagem (o Dó no 4 do primeiro compasso), a lead
/// fazendo frases de uma nota e o baixo nas fundamentais.
private func verse() -> [ChordReader.Track] {
    var rhythm = strum([50, 57, 62, 65], from: 0, to: 3.5)
    rhythm += [ScoreNote(tick: 3.5 * q, duration: q / 2, pitch: 48, string: 1, fret: 0)]
    rhythm += strum([48, 55, 60, 64], from: 4, to: 6) + strum([46, 53, 58, 62], from: 6, to: 8)
    rhythm += strum([45, 52, 57, 61], from: 8, to: 16)
    let lead = [72, 74, 77, 76, 74, 72, 70, 69].enumerated().map { index, pitch in
        ScoreNote(tick: Double(index) * 2 * q, duration: q, pitch: pitch, string: 1, fret: 0)
    }
    let low = bass(38, from: 0, to: 4) + bass(36, from: 4, to: 6) + bass(34, from: 6, to: 8) + bass(33, from: 8, to: 16)
    return [ChordReader.Track(name: "Lead Vocals", notes: lead.map { ScoreNote(tick: $0.tick, duration: $0.duration, pitch: $0.pitch + 1, string: 1, fret: 0) }),
            ChordReader.Track(name: "Mark Knopfler | Lead Guitar", notes: lead),
            ChordReader.Track(name: "David Knopfler | Rhythm Guitar", notes: rhythm),
            ChordReader.Track(name: "John Illsley | Bass", notes: low),
            ChordReader.Track(name: "Drums", notes: [])]
}

private let bars: [Double] = [0, 4, 8, 12, 16].map { $0 * q }

@Test func osPapeisDasPistasPeloNome() {
    #expect(HarmonyRole.of(name: "Mark Knopfler | Lead Vocals") == .vocal)
    #expect(HarmonyRole.of(name: "David Knopfler | Fender Stratocaster | Rhythm Guitar") == .rhythm)
    #expect(HarmonyRole.of(name: "Mark Knopfler | Fender Stratocaster | Lead Guitar") == .lead)
    #expect(HarmonyRole.of(name: "John Illsley | Fender Precision Bass") == .bass)
    #expect(HarmonyRole.of(name: "Pick Withers | Eddie Ryan Custom Kit | Drums") == .drums)
    #expect(HarmonyRole.of(name: "Jon Lord | Hammond Organ") == .keys)
    #expect(HarmonyRole.of(name: "Violão") == .rhythm)
}

/// A progressão sai pela base e pelo baixo, com as trocas no lugar; a nota de passagem e a melodia não viram acorde.
@Test func aProgressaoSaiDasNotas() {
    let spans = ChordReader.read(tracks: verse(), barTicks: bars)
    #expect(spans.map(\.name) == ["Dm", "C", "Bb", "A"])
    #expect(spans.map(\.from) == [0, 4 * q, 6 * q, 8 * q])
    #expect(spans.last?.to == 16 * q)
    #expect(spans.allSatisfy { $0.source == .score })
}

/// A lead que toca acorde vale como base; sem base nem baixo, a melodia sozinha não inventa acorde forte.
@Test func aLeadEmAcordeContaComoBase() {
    let lead = strum([57, 60, 64], from: 0, to: 4) + strum([55, 59, 62], from: 4, to: 8)
    let spans = ChordReader.read(tracks: [ChordReader.Track(name: "Lead Guitar", notes: lead)], barTicks: [0, 4 * q, 8 * q])
    #expect(spans.map(\.name) == ["Am", "G"])
}

/// O baixo noutra nota do acorde o trecho todo: inversão.
@Test func oBaixoNaQuintaViraBarra() {
    let tracks = [ChordReader.Track(name: "Rhythm", notes: strum([48, 52, 55, 60], from: 0, to: 4)),
                  ChordReader.Track(name: "Bass", notes: bass(43, from: 0, to: 4))]
    #expect(ChordReader.read(tracks: tracks, barTicks: [0, 4 * q]).map(\.name) == ["C/G"])
}

/// Os escritos no Guitar Pro valem por cima do lido, até a troca seguinte; as correções valem por cima de tudo.
@Test func escritosECorrecoesPorCima() {
    let written = [(tick: 4 * q, track: 2, name: "C(add9)"), (tick: 4 * q, track: 1, name: "C")]
    var spans = ChordReader.read(tracks: verse(), barTicks: bars, written: written)
    #expect(spans.map(\.name) == ["Dm", "C(add9)", "Bb", "A"])
    #expect(spans[1].source == .written && spans[1].to == 6 * q)
    let edits = [ChordEdit(from: 8 * q, to: 12 * q, name: "A7"), ChordEdit(from: 12 * q, to: 16 * q, name: "")]
    spans = ChordReader.read(tracks: verse(), barTicks: bars, written: written, edits: edits)
    #expect(spans.map(\.name) == ["Dm", "C(add9)", "Bb", "A7", ""])
    #expect(spans[3].source == .edited && spans[3].alternatives.contains("A"))
}

/// Numa música em Lá♭, os acordes saem em bemóis (antes: C# lido ao lado do D♭ escrito), e o escrito com ♭ ou com
/// outra grafia vira a da música.
@Test func aGrafiaSegueOTomDaMusica() {
    let rhythm = strum([56, 60, 63], from: 0, to: 4) + strum([49, 53, 56], from: 4, to: 8)
        + strum([51, 55, 58], from: 8, to: 12) + strum([56, 60, 63], from: 12, to: 16)
    let low = bass(44, from: 0, to: 4) + bass(37, from: 4, to: 8) + bass(39, from: 8, to: 12) + bass(44, from: 12, to: 16)
    let tracks = [ChordReader.Track(name: "Rhythm Guitar", notes: rhythm), ChordReader.Track(name: "Bass", notes: low)]
    #expect(ChordReader.read(tracks: tracks, barTicks: bars).map(\.name) == ["Ab", "Db", "Eb", "Ab"])
    let written = [(tick: 4 * q, track: 0, name: "C#"), (tick: 8 * q, track: 0, name: "E♭")]
    #expect(ChordReader.read(tracks: tracks, barTicks: bars, written: written).map(\.name) == ["Ab", "Db", "Eb", "Ab"])
    #expect(ChordReader.respell("C5 \\G", ChordReader.sharps) == "C5/G")
}

/// O c. 11 do Ramblin' Man: a base no Mi♭ com o pedaço da sexta (C+G+E♭) e o baixo andando E♭ C B♭ C é um Mi♭ só
/// (antes, Cm7); e o c. 5: a base em pedaços do Lá♭ com o baixo andando Lá♭ Dó Mi♭ Fá não troca de acorde.
@Test func pedacosDoAcordeEBaixoAndandoNaoTrocam() {
    var rhythm = strum([55, 58, 63], from: 1, to: 1.5) + strum([55, 60, 63], from: 1.5, to: 2.5) + strum([55, 58, 63], from: 3, to: 4)
    rhythm += strum([56, 60, 63], from: 5, to: 6) + strum([56, 63], from: 6.5, to: 7) + strum([60, 63], from: 7, to: 8)
    let low = [(39, 0), (36, 1), (34, 2), (36, 3), (44, 4), (48, 5.5), (51, 6.5), (53, 7)].map { pitch, beat in
        ScoreNote(tick: beat * q, duration: q, pitch: pitch, string: 1, fret: 0)
    }
    let tracks = [ChordReader.Track(name: "Rhythm Guitar", notes: rhythm), ChordReader.Track(name: "Bass", notes: low)]
    #expect(ChordReader.read(tracks: tracks, barTicks: [0, 4 * q, 8 * q]).map(\.name) == ["Eb", "Ab"])
}

/// O Yesterday: o violão afinado um tom abaixo, os acordes escritos pelas formas (G, F#m…), e o som um tom abaixo: a
/// barra mostra o que soa, com a forma entre os outros nomes.
@Test func escritosPelaFormaViramOQueSoa() {
    let progression: [([Int], Int)] = [([53, 57, 60], 41), ([52, 55, 59], 40), ([57, 61, 64], 45), ([50, 53, 57], 38)]
    var rhythm: [ScoreNote] = []
    var low: [ScoreNote] = []
    for (index, (pitches, root)) in progression.enumerated() {
        rhythm += strum(pitches, from: Double(index) * 4, to: Double(index + 1) * 4)
        low += bass(root, from: Double(index) * 4, to: Double(index + 1) * 4)
    }
    let tracks = [ChordReader.Track(name: "Guitar", notes: rhythm), ChordReader.Track(name: "Bass", notes: low)]
    let written = [(tick: 0.0, track: 0, name: "G"), (tick: 4 * q, track: 0, name: "F♯m"), (tick: 8 * q, track: 0, name: "B7"),
                   (tick: 12 * q, track: 0, name: "Em")]
    let spans = ChordReader.read(tracks: tracks, barTicks: bars, written: written)
    #expect(spans.map(\.name) == ["F", "Em", "A7", "Dm"])
    #expect(spans[0].alternatives.first == "G")
}

@Test func corrigirCortaAsCorrecoesDeAntes() {
    var edits = ChordReader.editing([], with: ChordEdit(from: 0, to: 100, name: "G"))
    edits = ChordReader.editing(edits, with: ChordEdit(from: 40, to: 60, name: "D"))
    #expect(edits == [ChordEdit(from: 0, to: 40, name: "G"), ChordEdit(from: 40, to: 60, name: "D"),
                      ChordEdit(from: 60, to: 100, name: "G")])
    #expect(ChordReader.clearing(edits, from: 30, to: 70) == [ChordEdit(from: 0, to: 30, name: "G"),
                                                               ChordEdit(from: 70, to: 100, name: "G")])
}

@Test func asNotasDeUmAcordePeloNome() {
    #expect(ChordReader.pitches(of: "Am7") == [45, 57, 60, 64, 67])
    #expect(ChordReader.pitches(of: "F/A") == [45, 53, 57, 60])
    #expect(ChordReader.pitches(of: "Bb") == [46, 58, 62, 65])
    #expect(ChordReader.pitches(of: "A#") == [46, 58, 62, 65])
    #expect(ChordReader.pitches(of: "xyz") == nil)
}

/// Os acordes de uma música de verdade (`TRACKLAB_CHORDS_NOTES`: o JSON que `web/tools/chord-notes.cjs` tira de um
/// Guitar Pro), impressos compasso a compasso, para conferir de ouvido.
@Test func acordesDeUmaMusica() throws {
    guard let path = ProcessInfo.processInfo.environment["TRACKLAB_CHORDS_NOTES"] else { return }
    struct Dump: Decodable {
        let tracks: [String]
        let notes: [[[Double]]]
        let barTicks: [Double]
        let chords: [[ChordValue]]
    }
    enum ChordValue: Decodable {
        case number(Double), text(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
        }
    }
    let dump = try JSONDecoder().decode(Dump.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let tracks = zip(dump.tracks, dump.notes).map { ChordReader.Track(name: $0, notes: ScoreNote.list($1)) }
    let written = dump.chords.compactMap { item -> (tick: Double, track: Int, name: String)? in
        guard item.count == 3, case .number(let tick) = item[0], case .number(let track) = item[1],
              case .text(let name) = item[2] else { return nil }
        return (tick, Int(track), name)
    }
    // Os acordes pelo som (`TRACKLAB_CHORDS_SOUND`: `[[de, até, nome], …]` em tiques), se vierem.
    var heard: [(from: Double, to: Double, name: String)] = []
    if let file = ProcessInfo.processInfo.environment["TRACKLAB_CHORDS_SOUND"] {
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [[Any]] ?? []
        heard = rows.compactMap { row in
            guard row.count == 3, let a = row[0] as? Double, let b = row[1] as? Double, let n = row[2] as? String else { return nil }
            return (a, b, n)
        }
    }
    let clock = Date()
    let spans = ChordReader.read(tracks: tracks, barTicks: dump.barTicks, written: written, sound: heard)
    print("a conferir: \(spans.filter(\.disputed).count) de \(spans.count)")
    // A barra como o app mostra (com os escritos) num JSON (`TRACKLAB_CHORDS_FINAL`).
    if let out = ProcessInfo.processInfo.environment["TRACKLAB_CHORDS_FINAL"] {
        let rows = spans.map { ["from": $0.from, "to": $0.to, "name": $0.name] as [String: Any] }
        try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: out))
    }
    print("acordes: \(spans.count) em \(Int(Date().timeIntervalSince(clock) * 1000)) ms")
    // Sem os escritos: quantos deles a leitura acha sozinha (a mesma fundamental e a mesma terça, um tempo depois do
    // tique escrito), e quantas trocas por compasso.
    let read = ChordReader.read(tracks: tracks, barTicks: dump.barTicks, sound: heard)
    // A leitura sem os escritos num JSON (`TRACKLAB_CHORDS_OUT`), para comparar com outras fontes.
    if let out = ProcessInfo.processInfo.environment["TRACKLAB_CHORDS_OUT"] {
        let rows = read.map { ["from": $0.from, "to": $0.to, "name": $0.name] as [String: Any] }
        try JSONSerialization.data(withJSONObject: rows).write(to: URL(fileURLWithPath: out))
    }
    // A fundamental e a terça (nil num acorde sem terça, o 5 e os sus, que valem com qualquer uma).
    func sound(_ name: String) -> (Int, Bool?)? {
        guard let (root, rest) = ChordReader.rootOf(name.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")) else { return nil }
        if rest.hasPrefix("5") || rest.hasPrefix("sus") { return (root, nil) }
        return (root, rest.hasPrefix("m") && !rest.hasPrefix("maj"))
    }
    func same(_ a: (Int, Bool?), _ b: (Int, Bool?)) -> Bool { a.0 == b.0 && (a.1 == nil || b.1 == nil || a.1 == b.1) }
    var agree = 0
    var total = 0
    let ticks = Array(Set(written.map(\.tick))).sorted()
    for (index, tick) in ticks.enumerated() {
        guard let chord = written.first(where: { $0.tick == tick }), let want = sound(chord.name) else { continue }
        total += 1
        // No meio do acorde escrito (até um tempo depois dele).
        let next = index + 1 < ticks.count ? ticks[index + 1] : dump.barTicks.last!
        let at = tick + min(q, (next - tick) / 2)
        let found = read.first(where: { $0.from <= at && at < $0.to })
        if let got = found.flatMap({ sound($0.name) }), same(got, want) {
            agree += 1
        } else if let bar = dump.barTicks.lastIndex(where: { $0 <= tick }) {
            print(String(format: "  falta c.%d tempo %.1f: escrito %@, lido %@", bar + 1, (tick - dump.barTicks[bar]) / q + 1,
                         chord.name, found?.name ?? "-"))
        }
    }
    let bars = Double(dump.barTicks.count - 1)
    print(String(format: "escritos achados: %d de %d · trocas por compasso: %.2f", agree, total, Double(read.count) / bars))
    var line: [String] = []
    for (index, start) in dump.barTicks.dropLast().enumerated() {
        let end = dump.barTicks[index + 1]
        let names = spans.filter { $0.from >= start && $0.from < end }.map { span -> String in
            let beat = (span.from - start) / q + 1
            let mark = (span.source == .written ? "*" : "") + (span.disputed ? "?" + (span.heard ?? "") : "")
            let at = beat > 1.01 ? (beat == beat.rounded() ? "(\(Int(beat)))" : String(format: "(%.1f)", beat)) : ""
            return (span.name.isEmpty ? "N.C." : span.name) + mark + at
        }
        line.append(names.isEmpty ? "·" : names.joined(separator: " "))
        if index % 8 == 7 || index == dump.barTicks.count - 2 {
            print(String(format: "c.%3d: ", index - index % 8 + 1) + line.joined(separator: " | "))
            line = []
        }
    }
}
