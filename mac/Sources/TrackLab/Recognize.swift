import Foundation
import TrackLabCore

/// A seleção no espectro: ⌥ + arrastar na Lente marca um retângulo (o tempo e as alturas); o motor ouve de novo só
/// aquele pedaço da faixa onde a pista soa e só naquela faixa de alturas, e a coluna da edição mostra dois cartões, "Como
/// está" e "Reconhecido" (as notas como faixas sobre os pontos do som). Um clique no reconhecido troca as notas da faixa de
/// alturas no trecho pelas achadas (`replaceRegion` na página, num passo do Desfazer); as outras ficam, e o que soa junto
/// vira acorde. Uma corda dupla se faz em dois retângulos, um em volta de cada nota.
extension SongModel {
    struct RegionReading {
        let track: Int
        /// O trecho em segundos e em tiques (preso na grade), e as alturas (com a afinação da gravação descontada).
        let seconds: ClosedRange<Double>
        let ticks: ClosedRange<Double>
        let pitches: ClosedRange<Double>
        /// As notas da pista que estão no trecho, nessa faixa de alturas (as que saem).
        let current: [ScoreNote]
        /// As achadas.
        let found: [RecognizedNote]
        /// Os pontos do som (segundo, altura com a afinação descontada), para os cartões.
        let sound: [(seconds: Double, pitch: Double)]
        /// A primeira achada continua a nota da faixa que já soava antes do trecho.
        let continues: Bool

        /// As achadas como a Lente as desenha.
        var shapes: [ScoreNote] { Recognition.scoreNotes(found) }
    }

    /// O motor ouve de novo o trecho de `from` a `to` (segundos) com altura de `low` a `high` (como a Lente mostra, com a
    /// afinação da gravação descontada).
    func recognize(from: Double, to: Double, low: Double, high: Double) {
        let track = scoreTrack
        guard scoreNotes.indices.contains(track), pitchStem(track: track).measured else {
            tabMessage = "Esta pista não tem altura para reconhecer."
            return
        }
        guard to - from >= 0.05, high - low >= 0.5 else { return }
        guard to - from <= 20 else {
            tabMessage = "Marque um trecho de até 20 segundos."
            return
        }
        if !editingTab { editingTab = true }
        recognizing = true
        regionReading = nil
        tabMessage = "Ouvindo o trecho…"
        let tuning = self.tuning
        let stem = pitchStem(track: track).stem
        // Só o pedido mais novo publica: um retângulo marcado antes que respondesse depois trazia de volta os cartões dele
        // (e o clique aplicaria o trecho antigo); mudar de pista, de afinação, de separação ou as notas também o descarta.
        let generation = invalidateRecognition()
        let version = notesVersion
        recognizeTask = Task { [weak self] in
            do {
                let heard = try await Backend.shared.transcribe(self?.id ?? "", from: from, to: to, low: low + tuning,
                                                                 high: high + tuning, stem: stem)
                guard let self, self.recognizeGeneration == generation, !Task.isCancelled else { return }
                self.recognizing = false
                guard self.scoreTrack == track, self.tuning == tuning, self.pitchStem(track: track).stem == stem,
                      self.notesVersion == version, self.editingTab else {
                    self.tabMessage = "O trecho mudou enquanto era ouvido: marque de novo."
                    return
                }
                self.showRegion(heard, track: track, seconds: from...to, pitches: low...high)
            } catch {
                guard let self, self.recognizeGeneration == generation, !Task.isCancelled else { return }
                self.recognizing = false
                self.tabMessage = "Não deu para ouvir o trecho: \(error.localizedDescription)"
            }
        }
    }

    /// Descarta o pedido em curso (o novo toma o lugar, ou a leitura foi dispensada) e devolve a geração nova.
    @discardableResult
    func invalidateRecognition() -> Int {
        recognizeTask?.cancel()
        recognizeTask = nil
        recognizeGeneration += 1
        return recognizeGeneration
    }

    private func showRegion(_ heard: [HeardNote], track: Int, seconds: ClosedRange<Double>, pitches: ClosedRange<Double>) {
        guard scoreNotes.indices.contains(track) else { return }
        let all = scoreNotes[track]
        let step = Double(gridTicks)
        let from = (grid.tick(at: seconds.lowerBound) / step).rounded(.down) * step
        let to = max(from + step, (grid.tick(at: seconds.upperBound) / step).rounded(.up) * step)
        let inBand = { (note: ScoreNote) in
            Double(note.pitch) >= pitches.lowerBound - 0.5 && Double(note.pitch) <= pitches.upperBound + 0.5
        }
        let current = all.filter { inBand($0) && $0.tick >= from && $0.tick < to }
        // A altura de cada corda solta: a afinação da pauta com o capo (todas as cordas, também as que a TAB não usa:
        // antes, uma nota que só cabia numa corda sem nota escrita sumia), e onde há nota, a que ela dá.
        var open: [Int: Int] = [:]
        if scoreTunings.indices.contains(track) {
            let capo = scoreCapos.indices.contains(track) ? scoreCapos[track] : 0
            for (index, pitch) in scoreTunings[track].enumerated() { open[index + 1] = pitch + capo }
        }
        for note in all where open[note.string] == nil || !scoreTunings.indices.contains(track) {
            open[note.string] = note.pitch - note.fret
        }
        let occupied = all.filter { !inBand($0) && $0.tick < to && $0.tick + $0.duration > from }
        // A posição de antes: a última nota da pista que começa antes do trecho (ou a primeira das que saem).
        let before = all.last { $0.tick < from } ?? current.first
        let heardNotes = Recognition.notes(heard, tuning: tuning, grid: grid, step: step, open: open,
                                           from: before.map { ($0.string, $0.fret) }, existing: current, occupied: occupied,
                                           keepUnplaced: true)
            .filter { $0.tick < to }
        // As que não couberam em corda nenhuma (fora do braço, ou com as cordas ocupadas pelas que ficam).
        let left = heardNotes.filter { $0.string == 0 }.count
        let found = heardNotes
            .filter { $0.string > 0 }
            .map { note -> RecognizedNote in
                var note = note
                note.end = min(note.end, to)
                return note
            }
        // A primeira achada, no começo do trecho, na altura de uma nota da faixa que já soava antes dele: é ela que
        // continua (sem isso, a nota de antes era cortada na borda do retângulo e a mesma altura atacava de novo).
        var continues = false
        if let first = found.first, first.tick <= from + step,
           all.contains(where: { inBand($0) && $0.pitch == first.pitch && $0.tick < from && $0.tick + $0.duration > from }) {
            continues = true
        }
        var sound: [(seconds: Double, pitch: Double)] = []
        for note in heard {
            for (k, value) in note.curve.values.enumerated() {
                if let value { sound.append((note.curve.from + Double(k) * note.curve.hop, value - tuning)) }
            }
        }
        regionReading = RegionReading(track: track, seconds: grid.seconds(at: from)...grid.seconds(at: to),
                                      ticks: from...to, pitches: pitches, current: current, found: found, sound: sound,
                                      continues: continues)
        let lost = left > 0 ? " · \(left) fora do braço ou sem corda livre" : ""
        tabMessage = found.isEmpty && left == 0 ? "Nenhuma nota nessa faixa de alturas: estreite ou mude o retângulo."
            : found.isEmpty ? "Ouvi \(left) nota\(left == 1 ? "" : "s"), mas nenhuma cabe numa corda livre."
            : "Reconhecido: \(found.count) nota\(found.count == 1 ? "" : "s")\(lost) · um clique no cartão troca"
    }

    /// Troca as notas do trecho pelas reconhecidas.
    func applyRegion() {
        guard let region = regionReading else { return }
        let notes: [[String: Any]] = region.found.enumerated().map { index, note in
            var item: [String: Any] = ["tick": note.tick, "end": note.end, "string": note.string, "fret": note.fret,
                                       "vibrato": note.vibrato ? 1 : 0]
            if index == 0, region.continues { item["continues"] = true }
            if !note.bend.isEmpty { item["bend"] = note.bend }
            if let slide = note.slide { item["slide"] = slide }
            return item
        }
        bridge.edit("replaceRegion", ["track": region.track, "from": region.ticks.lowerBound, "to": region.ticks.upperBound,
                                      "low": region.pitches.lowerBound, "high": region.pitches.upperBound, "notes": notes])
        regionReading = nil
        invalidateRecognition()
    }

    func dismissRegion() {
        regionReading = nil
        tabMessage = nil
        recognizing = false
        invalidateRecognition()
    }
}
