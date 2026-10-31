import Foundation
import TrackLabCore

/// O corretor: "Corrigir pelo som" (⇧F na edição, ⌥⌘F) escreve, num passo só do Desfazer, o que o som de cada nota faz
/// onde ele discorda da TAB com segurança (`SoundNote.correction`); as notas mudadas ficam marcadas na Lente, e um
/// clique numa nota, na edição, mostra na coluna as leituras perto do som em cartões desenhados (`ReadingCards`): um
/// clique (ou ⌥1–⌥4) escolhe, o botão direito ouve. Com várias notas escolhidas, os cartões são o trecho em outras
/// posições do braço.
extension SongModel {
    static func correctionKey(track: Int, tick: Double, string: Int) -> String {
        "\(track):\(Int(tick.rounded())):\(string)"
    }

    /// Quantas notas da pista o corretor mudou (as que ainda estão como ele deixou).
    func correctedCount(track: Int) -> Int {
        corrections.keys.filter { $0.hasPrefix("\(track):") }.count
    }

    func isCorrected(_ note: ScoreNote, track: Int) -> Bool {
        corrections[Self.correctionKey(track: track, tick: note.tick, string: note.string)] != nil
    }

    /// Corrigir pelo som: a pista principal inteira, ou só o loop, se há um. Sem as curvas pedidas (a Lente fechada,
    /// ainda medindo), liga a Lente e corrige quando a medida termina (`afterMeasuring`: com o que chegou; uma nota que
    /// o motor não mede fica de fora, senão o pedido não acabava).
    func correctBySound(afterMeasuring: Bool = false) {
        let track = scoreTrack
        guard scoreNotes.indices.contains(track) else {
            tabMessage = "A partitura ainda está carregando; tente de novo em seguida."
            return
        }
        guard pitchStem(track: track).measured else {
            tabMessage = "Esta pista não tem altura para medir."
            return
        }
        let loop = engine.loop
        let chosen = scoreNotes[track].filter { note in loop.map { $0.contains(grid.seconds(at: note.tick)) } ?? true }
        if !afterMeasuring, !lensVisible || measuring || chosen.contains(where: { !curveAsked($0, track: track) }) {
            correctWhenMeasured = true
            if lensVisible { measureLater() } else { lensVisible = true }
            tabMessage = "Medindo o som da pista para corrigir…"
            return
        }
        var items: [[String: Any]] = []
        var pending: [String: (before: NoteReading, after: NoteReading)] = [:]
        for note in chosen {
            guard let sound = soundNotes[curveKey(note, track: track)] else { continue }
            let start = grid.seconds(at: note.tick)
            let end = grid.seconds(at: note.tick + note.duration)
            guard let fix = sound.correction(for: note, start: start, end: end) else { continue }
            var item = fitValue(fix, note: note, sound: sound)
            item["track"] = track
            item["tick"] = note.tick
            item["string"] = note.string
            items.append(item)
            let key = Self.correctionKey(track: track, tick: note.tick, string: note.string)
            pending[key] = (corrections[key]?.before ?? NoteReading(note: note, kind: .original, name: "Original"), fix)
        }
        guard !items.isEmpty else {
            tabMessage = loop == nil ? "Nada a corrigir pelo som nesta pista." : "Nada a corrigir pelo som no loop."
            return
        }
        corrections.merge(pending) { $1 }
        bridge.edit("fitMany", items)
        tabMessage = "Corrigindo \(items.count) nota\(items.count == 1 ? "" : "s") pelo som…"
    }

    /// A página aplicou um lote: quantas mudaram.
    func fitted(count: Int, asked: Int) {
        tabMessage = count == 0 ? "Nada mudou: as notas já estavam como soam."
            : "Corrigi \(count) nota\(count == 1 ? "" : "s") pelo som · ⌘Z desfaz · um clique numa nota mostra as leituras"
    }

    /// Sai das correções o que não está mais como o corretor deixou (desfeito, mudado de novo, outra corda). Uma nota
    /// ligada volta da página com o bend repartido pelas partes: vale o mesmo tipo e alturas, não os mesmos pontos.
    func pruneCorrections() {
        guard !corrections.isEmpty else { return }
        var notes: [String: ScoreNote] = [:]
        for (track, list) in scoreNotes.enumerated() {
            for note in list { notes[Self.correctionKey(track: track, tick: note.tick, string: note.string)] = note }
        }
        corrections = corrections.filter { key, value in
            guard let note = notes[key] else { return false }
            let now = NoteReading(note: note)
            return now.pitch == value.after.pitch && now.vibrato == value.after.vibrato && now.trill == value.after.trill
                && now.bend.isEmpty == value.after.bend.isEmpty && now.form?.spoken == value.after.form?.spoken
        }
    }

    /// O que o `fit` da página escreve para uma leitura (o trinado com a figura medida contra a semínima ali).
    func fitValue(_ reading: NoteReading, note: ScoreNote, sound: SoundNote?) -> [String: Any] {
        var value: [String: Any] = ["pitch": reading.pitch, "bend": reading.bend.isEmpty ? NSNull() : reading.bend,
                                    "vibrato": reading.vibrato, "trill": reading.trill ?? NSNull()]
        if reading.trill != nil {
            let beat = grid.seconds(at: note.tick + TempoGrid.ticksPerQuarter) - grid.seconds(at: note.tick)
            value["trillSpeed"] = sound?.fit?.trill?.speed(beatSeconds: beat) ?? 16
        }
        return value
    }

    // MARK: - As leituras da nota escolhida

    struct ReadingCard: Identifiable {
        let id: Int
        let reading: NoteReading
        let closeness: Double
        /// É o que está escrito agora.
        let current: Bool
    }

    /// Os cartões da nota escolhida e o que eles desenham: os pontos do som (fração 0–1 da nota, semitons acima da
    /// altura escrita), a altura e a casa escritas.
    struct ReadingSheet {
        let cards: [ReadingCard]
        let sound: [(fraction: Double, semitones: Double)]
        let pitch: Int
        let fret: Int
    }

    /// As leituras da nota escolhida (uma só, fora de acorde, com a curva medida), das mais perto do som.
    func selectedReadings() -> ReadingSheet? {
        _ = pitchCurvesVersion
        guard editingTab, let selection = tabSelection, selection.count <= 1, let (note, track) = selectedScoreNote(),
              let sound = soundNotes[curveKey(note, track: track)], !sound.chord else { return nil }
        let start = grid.seconds(at: note.tick)
        let end = grid.seconds(at: note.tick + note.duration)
        guard end > start else { return nil }
        let original = corrections[Self.correctionKey(track: track, tick: note.tick, string: note.string)]?.before
        let written = NoteReading(note: note)
        let cards = sound.readings(for: note, start: start, end: end, original: original).enumerated().map {
            ReadingCard(id: $0.offset, reading: $0.element.reading, closeness: $0.element.closeness,
                        current: $0.element.reading.writesSame(as: written))
        }
        guard !cards.isEmpty else { return nil }
        var points: [(fraction: Double, semitones: Double)] = []
        for (k, value) in sound.curve.values.enumerated() {
            let t = sound.curve.from + Double(k) * sound.curve.hop
            guard let value, t >= start, t <= end else { continue }
            points.append(((t - start) / (end - start), value - Double(note.pitch)))
        }
        return ReadingSheet(cards: cards, sound: points, pitch: note.pitch, fret: note.fret)
    }

    /// Escolhe a leitura do cartão `index` (o clique, ⌥1–⌥4) para a nota escolhida.
    func chooseReading(_ index: Int) {
        guard let sheet = selectedReadings(), sheet.cards.indices.contains(index),
              let (note, track) = selectedScoreNote() else { return }
        let card = sheet.cards[index]
        guard !card.current else {
            tabMessage = "\(card.reading.name): já está assim."
            return
        }
        bridge.edit("fit", fitValue(card.reading, note: note, sound: soundNotes[curveKey(note, track: track)]))
        let changes = card.reading.changes(from: NoteReading(note: note)).joined(separator: ", ")
        tabMessage = "\(card.reading.name): \(changes) · ⌘Z desfaz"
    }

    /// Ouve a leitura do cartão `index` sintetizada (o botão direito no cartão).
    func hearReading(_ index: Int) {
        guard let sheet = selectedReadings(), sheet.cards.indices.contains(index),
              let (note, track) = selectedScoreNote() else { return }
        let reading = sheet.cards[index].reading
        let start = grid.seconds(at: note.tick)
        let end = grid.seconds(at: note.tick + note.duration)
        let shaped = ScoreNote(tick: note.tick, duration: note.duration, pitch: reading.pitch, string: note.string,
                               fret: note.fret, vibrato: reading.vibrato ? 1 : 0,
                               bend: reading.bend.map { ScoreNote.BendPoint(offset: $0[0], value: $0[1]) })
        playSynth(pitch: reading.pitch, seconds: end - start, track: track) { fraction, elapsed in
            if let high = reading.trill {
                // O trinado: troca de nota a cada semicolcheia do estudo, mais ou menos (só para ouvir).
                return Int(elapsed / 0.07) % 2 == 0 ? 0 : Double(high - reading.pitch)
            }
            return shaped.shape(fraction: fraction, elapsed: elapsed)
        }
    }

    // MARK: - Um trecho: as posições no braço

    struct PositionCard: Identifiable {
        /// Quantas cordas o trecho anda (+1: para a mais aguda, como o "string" da página).
        let id: Int
        let dots: [(string: Int, fret: Int)]
        let frets: ClosedRange<Int>
        let strings: Int
        let current: Bool
    }

    /// O trecho escolhido (várias notas) em outras posições do braço: o mesmo trecho uma, duas ou três cordas acima ou
    /// abaixo, onde todas as notas cabem (casa de 0 a 24, uma nota por corda em cada batida); a afinação de cada corda
    /// sai das notas da pista. A posição de agora primeiro, e até três outras, das mais perto.
    func selectedPositions() -> [PositionCard]? {
        guard editingTab, let selection = tabSelection, selection.count > 1, let range = selection.range,
              scoreNotes.indices.contains(selection.track) else { return nil }
        let all = scoreNotes[selection.track]
        let notes = all.filter { range.contains($0.tick) }
        guard notes.count > 1 else { return nil }
        var tuning: [Int: Int] = [:]
        for note in all where tuning[note.string] == nil { tuning[note.string] = note.pitch - note.fret }
        let strings = tuning.keys.max() ?? 6
        var cards: [PositionCard] = []
        for delta in [0, 1, -1, 2, -2, 3, -3] {
            var dots: [(string: Int, fret: Int)] = []
            var taken: Set<String> = []
            var fits = true
            for note in notes {
                let string = note.string - delta
                guard let open = tuning[string] else { fits = false; break }
                let fret = note.pitch - open
                guard (0...SongModel.maxFret).contains(fret), taken.insert("\(Int(note.tick)):\(string)").inserted else {
                    fits = false
                    break
                }
                dots.append((string, fret))
            }
            guard fits else { continue }
            let fretted = dots.map(\.fret).filter { $0 > 0 }
            let low = fretted.min() ?? 0
            cards.append(PositionCard(id: delta, dots: dots, frets: low...max(low, fretted.max() ?? 0), strings: strings,
                                      current: delta == 0))
            if cards.count == 4 { break }
        }
        return cards.count > 1 ? cards : nil
    }

    /// Leva o trecho escolhido para a posição do cartão.
    func choosePosition(_ delta: Int) {
        guard delta != 0 else { return }
        bridge.edit("string", delta)
        tabMessage = "O trecho foi para outra posição do braço · ⌘Z desfaz"
    }

    static let maxFret = 24
}
