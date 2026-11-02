import Foundation
import Testing
@testable import TrackLabCore

/// O chords-db do projeto (`mac/Resources/chords-db/guitar.json`).
private func library() throws -> ChordLibrary {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Resources/chords-db/guitar.json")
    return try ChordLibrary(json: Data(contentsOf: file))
}

@Test func asDigitacoesPeloNomeDaBarra() throws {
    let chords = try library()
    #expect(chords.shapes(for: "C").first?.frets == [-1, 3, 2, 0, 1, 0])
    // As casas da base passam a contar do começo do braço (o Dó com pestana na 3ª).
    #expect(chords.shapes(for: "C")[1].frets == [-1, 3, 5, 5, 5, 3] && chords.shapes(for: "C")[1].baseFret == 3)
    #expect(chords.shapes(for: "C/G").first?.frets == [3, 3, 2, 0, 1, 0])
    #expect(chords.shapes(for: "Bb").first?.frets.first == -1)
    #expect(!chords.shapes(for: "F#m7b5").isEmpty && !chords.shapes(for: "A♭").isEmpty)
    // Um nome que a base não tem: o mais perto (Cmadd11 → Dó menor; C(add9) → Cadd9).
    #expect(chords.shapes(for: "Cmadd11").map(\.frets) == chords.shapes(for: "Cm").map(\.frets))
    #expect(chords.shapes(for: "Cmadd11").first?.drawn == "Cm" && chords.shapes(for: "Cm").first?.drawn == nil)
    #expect(chords.shapes(for: "C(add9)") == chords.shapes(for: "Cadd9"))
    #expect(chords.shapes(for: "xyz").isEmpty)
}

/// A forma que a TAB toca vem primeiro; as da base, pela distância da mão (o Lá com a mão na 5ª: a pestana na 5ª).
@Test func aFormaDaTabEAMaoNoBraco() throws {
    let chords = try library()
    // Um Lá com pestana na 5ª, da corda Mi grave (6) à aguda (1), e um baixo solto antes.
    let frets = [5, 7, 7, 6, 5, 5]
    var notes = frets.enumerated().map { index, fret in
        ScoreNote(tick: 960, duration: 960, pitch: 40 + fret, string: 6 - index, fret: fret)
    }
    notes.append(ScoreNote(tick: 0, duration: 480, pitch: 45, string: 5, fret: 0))
    let played = ChordShape.played(notes, from: 0, to: 3840)
    #expect(played?.frets == frets && played?.fromTab == true)
    #expect(ChordShape.played(Array(notes.prefix(2)), from: 0, to: 3840) == nil)
    let hand = ChordShape.hand(notes, from: 0, to: 3840)
    let shapes = chords.shapes(for: "A", played: nil, hand: hand)
    #expect(shapes.first?.frets == [5, 7, 7, 6, 5, 5])
    #expect(chords.shapes(for: "A", played: ChordShape(frets: [-1, 0, 2, 2, 2, -1], fromTab: true), hand: hand).first?.fromTab == true)
}

/// Um acorde com baixo que não é tríade maior nem menor não pega a inversão do maior: o C7/G desenha um C7 (com o Si♭) e
/// o Csus4/G um Csus4 (com o Fá), e o cartão diz que o desenho é sem o baixo.
@Test func inversoesNaoPerdemAQualidade() throws {
    let chords = try library()
    let standard = [40, 45, 50, 55, 59, 64]
    func classes(_ shape: ChordShape) -> Set<Int> {
        Set(zip(shape.frets, standard).compactMap { $0 < 0 ? nil : ($0 + $1) % 12 })
    }
    for (name, needs) in [("C7/G", 10), ("Csus4/G", 5), ("Cmaj7/G", 11), ("Caug/G", 8), ("Am7/G", 7)] {
        let shapes = chords.shapes(for: name)
        #expect(!shapes.isEmpty, "\(name)")
        #expect(shapes.allSatisfy { classes($0).contains(needs) }, "\(name)")
        #expect(shapes.first?.drawn == name.split(separator: "/").first.map(String.init), "\(name)")
    }
    #expect(chords.shapes(for: "Csus4/G").allSatisfy { !classes($0).contains(4) })
    // As tríades com baixo continuam com a inversão da base.
    #expect(chords.shapes(for: "C/G").first?.frets == [3, 3, 2, 0, 1, 0] && chords.shapes(for: "C/G").first?.drawn == nil)
    #expect(chords.shapes(for: "Am/G").first?.drawn == nil)
}

/// As guitarras de seis cordas pela afinação da pauta: uma que não toca a sexta corda continua (com o capo dela), uma de
/// sete que só desce à sexta não entra, e a base vem antes do solo.
@Test func guitarrasDeSeisCordasPelaAfinacao() {
    let six = [64, 59, 55, 50, 45, 40]
    let high = [ScoreNote(tick: 0, duration: 960, pitch: 69, string: 1, fret: 5)]
    let toSixth = [ScoreNote(tick: 0, duration: 960, pitch: 40, string: 6, fret: 0)]
    let names = [(index: 0, name: "Lead Guitar"), (index: 1, name: "Rhythm Guitar"), (index: 2, name: "7-string Guitar"),
                 (index: 3, name: "Guitar 3")]
    #expect(ChordReader.guitarTracks(names: names, tunings: [six, six, six + [35], six], notes: [toSixth, high, toSixth, []])
            == [1, 0])
    // Sem a afinação (antes de a página mandar), pela corda mais grave tocada.
    #expect(ChordReader.guitarTracks(names: names, tunings: [], notes: [toSixth, high, toSixth, []]) == [2, 0])
}
