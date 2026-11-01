import AppKit
import TrackLabCore

/// A barra de acordes: o que as notas das pistas dizem (`ChordReader`), com os escritos no Guitar Pro e as correções
/// por cima; as correções vão ao pacote (`PUT songs/{id}/chords`), uma gravação por vez.
extension SongModel {
    /// Lê de novo (as notas, as pistas, os compassos ou os escritos mudaram): fora da linha principal, um pouco depois
    /// da última mudança.
    func refreshChords() {
        chordsTask?.cancel()
        let bars = grid.barTicks
        guard bars.count >= 2, !scoreNotes.isEmpty else {
            chordBase = []
            chordSpans = []
            return
        }
        let names = Dictionary(scoreTracks.map { ($0.index, $0.name) }, uniquingKeysWith: { a, _ in a })
        let tracks = scoreNotes.enumerated().map { ChordReader.Track(name: names[$0.offset] ?? "", notes: $0.element) }
        let written = writtenChords
        let grid = grid
        let sound = soundChords.map { (from: grid.tick(at: $0.start), to: grid.tick(at: $0.end), name: $0.name) }
        chordsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let base = await Task.detached(priority: .userInitiated) {
                ChordReader.read(tracks: tracks, barTicks: bars, written: written, sound: sound)
            }.value
            guard !Task.isCancelled, let self else { return }
            chordBase = base
            chordSpans = ChordReader.apply(chordEdits, to: base)
        }
    }

    /// Pede ao motor os acordes pelo som, presos às batidas do mapa de agora (um segundo depois da última mudança do
    /// mapa). Na primeira vez o motor ouve a música inteira (~1 min); depois só decodifica. Sem o motor de separação
    /// (o torch) a barra fica só com as notas.
    func hearChords() {
        soundChordsTask?.cancel()
        let beats = soundBeats()
        guard !beats.isEmpty, beats != soundChordsBeats else { return }
        soundChordsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            hearingChords = true
            do {
                let rows = try await Backend.shared.chordsBySound(id, beats: beats)
                if !Task.isCancelled {
                    soundChordsBeats = beats
                    soundChords = rows
                }
            } catch {
                if !Task.isCancelled { NSLog("TrackLab: acordes pelo som: \(error.localizedDescription)") }
            }
            if !Task.isCancelled { hearingChords = false }
        }
    }

    /// As batidas do mapa como o motor pede: `[segundo, tipo]`, 2 no 1 do compasso, 3 no meio dele (num compasso de
    /// tempos pares), 4 nos outros tempos.
    func soundBeats() -> [[Double]] {
        let bars = grid.barTicks
        guard bars.count >= 2, grid.points.count >= 2 else { return [] }
        let quarter = TempoGrid.ticksPerQuarter
        return grid.points.compactMap { point -> [Double]? in
            guard let bar = bars.lastIndex(where: { $0 <= point.tick + 0.5 }), bar + 1 < bars.count else { return nil }
            let offset = point.tick - bars[bar]
            let length = bars[bar + 1] - bars[bar]
            let even = (length / quarter).truncatingRemainder(dividingBy: 2) == 0
            let kind = abs(offset) < 1 ? 2.0 : (even && abs(offset - length / 2) < 1 ? 3.0 : 4.0)
            return [point.seconds, kind]
        }
    }

    /// Usa o nome que o som ouve no trecho.
    func useHeardChord(_ span: ChordSpan) {
        guard let heard = span.heard else { return }
        renameChord(span, to: heard)
    }

    /// O acorde que cobre o tique.
    func chord(atTick tick: Double) -> ChordSpan? {
        chordSpans.first { $0.from <= tick && tick < $0.to }
    }

    /// O tique na grade de colcheias mais perto de `seconds` (onde uma troca de acorde cai).
    func chordTick(at seconds: Double) -> Double {
        let step = TempoGrid.ticksPerQuarter / 2
        return (grid.tick(at: seconds) / step).rounded() * step
    }

    func renameChord(_ span: ChordSpan, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        saveChordEdits(ChordReader.editing(chordEdits, with: ChordEdit(from: span.from, to: span.to, name: clean)))
        chosenChord = span.from
        tabMessage = clean.isEmpty ? "Sem acorde aqui" : "Acorde: \(clean)"
    }

    /// Divide o acorde no tique (na grade de colcheias); a parte de depois fica com o mesmo nome até ser renomeada.
    /// Devolve a parte nova.
    @discardableResult
    func splitChord(_ span: ChordSpan, at tick: Double) -> ChordSpan? {
        let step = TempoGrid.ticksPerQuarter / 2
        guard tick >= span.from + step - 0.5, tick <= span.to - step + 0.5 else {
            tabMessage = "O acorde é curto demais para dividir ali"
            return nil
        }
        var edits = ChordReader.editing(chordEdits, with: ChordEdit(from: span.from, to: tick, name: span.name))
        edits = ChordReader.editing(edits, with: ChordEdit(from: tick, to: span.to, name: span.name))
        saveChordEdits(edits)
        chosenChord = tick
        return ChordSpan(from: tick, to: span.to, name: span.name, source: .edited, alternatives: span.alternatives)
    }

    /// Junta o acorde com o vizinho (o de antes ou o de depois): os dois com o nome do primeiro.
    func mergeChord(_ span: ChordSpan, withNext: Bool) {
        guard let index = chordSpans.firstIndex(where: { $0.from == span.from }) else { return }
        let other = withNext ? index + 1 : index - 1
        guard chordSpans.indices.contains(other) else { return }
        let first = chordSpans[min(index, other)]
        let second = chordSpans[max(index, other)]
        saveChordEdits(ChordReader.editing(chordEdits, with: ChordEdit(from: first.from, to: second.to, name: first.name)))
        chosenChord = first.from
    }

    /// Leva a troca entre dois acordes de `old` para `tick` (na grade de colcheias, sem engolir um dos dois).
    func moveChordChange(from old: Double, to tick: Double) {
        guard let index = chordSpans.firstIndex(where: { abs($0.from - old) < 0.5 }), index > 0 else { return }
        let before = chordSpans[index - 1]
        let after = chordSpans[index]
        let step = TempoGrid.ticksPerQuarter / 2
        let target = min(max(tick, before.from + step), after.to - step)
        guard abs(target - old) >= 0.5 else { return }
        var edits = ChordReader.editing(chordEdits, with: ChordEdit(from: before.from, to: target, name: before.name))
        edits = ChordReader.editing(edits, with: ChordEdit(from: target, to: after.to, name: after.name))
        saveChordEdits(edits)
        chosenChord = target
    }

    /// O trecho do acorde volta ao que as notas (e os escritos) dizem.
    func revertChord(_ span: ChordSpan) {
        saveChordEdits(ChordReader.clearing(chordEdits, from: span.from, to: span.to))
        tabMessage = "Acorde de volta ao lido nas notas"
    }

    func revertAllChords() {
        saveChordEdits([])
        tabMessage = "Todos os acordes de volta ao lido nas notas"
    }

    func loopChord(_ span: ChordSpan) {
        setLoop(grid.seconds(at: span.from)...grid.seconds(at: span.to), seekToStart: true)
    }

    /// O acorde sintetizado (um violão de aço), no tom do estudo.
    func playChord(_ span: ChordSpan) {
        guard let pitches = ChordReader.pitches(of: span.name) else {
            tabMessage = span.name.isEmpty ? "Sem acorde aqui" : "Não sei tocar \"\(span.name)\""
            return
        }
        do {
            try NoteSynth.shared.play(pitches: pitches, seconds: 1.8, program: 25, percussion: false,
                                      transpose: Double(engine.semitones) + Double(engine.cents) / 100, shape: nil)
        } catch {
            tabMessage = error.localizedDescription
        }
    }

    /// As correções na tela já e no pacote depois, uma gravação por vez com a lista mais nova.
    func saveChordEdits(_ edits: [ChordEdit]) {
        chordEdits = edits
        chordsRevision += 1
        let revision = chordsRevision
        let previous = chordsSave
        chordsSave = Task {
            await previous?.value
            do {
                let saved = try await Backend.shared.putChordEdits(id, edits)
                if revision == chordsRevision { chordEdits = saved }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// O menu do acorde (o botão direito na barra): os outros nomes que as notas aceitam, renomear, dividir no lugar
    /// do clique, juntar, sem acorde, voltar ao lido, ouvir e loop.
    func showChordMenu(_ span: ChordSpan, clickTick: Double, at point: CGPoint, in view: NSView,
                       rename: @escaping (ChordSpan) -> Void) {
        chosenChord = span.from
        let menu = NSMenu()
        menu.autoenablesItems = false
        let first = grid.bar(at: grid.seconds(at: span.from) + 0.001)
        let last = grid.bar(at: grid.seconds(at: span.to) - 0.001)
        let place = [first, last].compactMap { $0 }
        let where_ = place.count == 2 ? (place[0] == place[1] ? "c. \(place[0])" : "c. \(place[0])–\(place[1])") : ""
        let origin: String
        switch span.source {
        case .score: origin = "lido nas notas"
        case .written: origin = "escrito na TAB"
        case .edited: origin = "corrigido"
        }
        let heard = span.heard.map { "o som ouve \($0)" }
        menu.addTitle(span.name.isEmpty ? "Sem acorde" : span.name,
                      detail: [where_, origin, heard].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        menu.addSeparator()
        if let heardName = span.heard, heardName != span.name {
            menu.add("Usar o do som: \(heardName)") { [weak self] in self?.useHeardChord(span) }
        }
        for name in span.alternatives.prefix(4) where name != span.heard {
            menu.add(name) { [weak self] in self?.renameChord(span, to: name) }
        }
        if !span.alternatives.isEmpty { menu.addSeparator() }
        menu.add("Renomear…") { rename(span) }
        let index = chordSpans.firstIndex { $0.from == span.from }
        menu.add("Dividir aqui") { [weak self] in
            guard let self, let part = splitChord(span, at: clickTick) else { return }
            rename(part)
        }
        menu.add("Juntar com o anterior", enabled: (index ?? 0) > 0) { [weak self] in self?.mergeChord(span, withNext: false) }
        menu.add("Juntar com o seguinte", enabled: index.map { $0 + 1 < chordSpans.count } ?? false) { [weak self] in
            self?.mergeChord(span, withNext: true)
        }
        menu.add("Sem acorde (N.C.)", enabled: !span.name.isEmpty) { [weak self] in self?.renameChord(span, to: "") }
        menu.add("Voltar ao lido nas notas", enabled: span.source == .edited) { [weak self] in self?.revertChord(span) }
        menu.addSeparator()
        menu.add("Ouvir o acorde", enabled: ChordReader.pitches(of: span.name) != nil) { [weak self] in self?.playChord(span) }
        menu.add("Loop neste acorde") { [weak self] in self?.loopChord(span) }
        if !chordEdits.isEmpty {
            menu.addSeparator()
            menu.add("Desfazer todas as correções dos acordes") { [weak self] in self?.revertAllChords() }
        }
        menu.popUp(positioning: nil, at: menuPoint(point, in: view), in: view)
    }
}
