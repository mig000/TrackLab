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
    #expect(chords.shapes(for: "Cmadd11") == chords.shapes(for: "Cm"))
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
