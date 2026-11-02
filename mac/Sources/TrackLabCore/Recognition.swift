import Foundation

/// A seleção no espectro: um retângulo de tempo × altura na Lente, que o motor reconhece de novo (`POST
/// songs/{id}/transcribe`: as notas daquele pedaço do som, só naquela faixa de alturas) e o app escreve como notas da TAB
/// (`Recognition.notes`), para trocar as que estavam ali (`replaceRegion` na página).
public struct HeardNote: Decodable, Hashable, Sendable {
    public let start: Double
    public let end: Double
    /// A altura do começo, sem a afinação da gravação descontada.
    public let level: Double
    /// Como a nota chega por slide: "previous" (da nota anterior), "below" ou "above" (de fora); nil sem slide.
    public let slide: String?
    public let curve: PitchCurve

    public init(start: Double, end: Double, level: Double, slide: String? = nil, curve: PitchCurve) {
        self.start = start
        self.end = end
        self.level = level
        self.slide = slide
        self.curve = curve
    }
}

/// Uma nota reconhecida, pronta para a TAB: o tempo em tiques (preso na grade), a altura, a corda (1 é a mais aguda) e a
/// casa, o vibrato, o bend (os pontos do Guitar Pro 7) e o slide de chegada.
public struct RecognizedNote: Hashable, Sendable {
    public var tick: Double
    public var end: Double
    public var pitch: Int
    public var string: Int
    public var fret: Int
    public var vibrato: Bool
    public var bend: [[Double]]
    public var slide: String?

    public init(tick: Double, end: Double, pitch: Int, string: Int, fret: Int, vibrato: Bool = false, bend: [[Double]] = [],
                slide: String? = nil) {
        self.tick = tick
        self.end = end
        self.pitch = pitch
        self.string = string
        self.fret = fret
        self.vibrato = vibrato
        self.bend = bend
        self.slide = slide
    }
}

public enum Recognition {
    /// As notas reconhecidas como a Lente as desenha (a faixa com o bend, o vibrato e os slides).
    public static func scoreNotes(_ notes: [RecognizedNote]) -> [ScoreNote] {
        notes.enumerated().map { index, note in
            let next = index + 1 < notes.count ? notes[index + 1] : nil
            let out = next.flatMap { $0.slide == "previous" && $0.string == note.string ? Double($0.pitch - note.pitch) : nil }
            return ScoreNote(tick: note.tick, duration: note.end - note.tick, pitch: note.pitch, string: note.string,
                             fret: note.fret, vibrato: note.vibrato ? 1 : 0,
                             bend: note.bend.map { ScoreNote.BendPoint(offset: $0[0], value: $0[1]) },
                             approached: note.slide != nil, slidesOut: out != nil,
                             slideIn: note.slide == "below" ? -ScoreNote.outsideSlide
                                : note.slide == "above" ? ScoreNote.outsideSlide : 0,
                             slideOut: out ?? 0)
        }
    }

    /// As notas da TAB para o que o motor ouviu: a altura e o bend pelo mesmo encaixe do F (`SoundNote.fit`, com a
    /// afinação da gravação `tuning` descontada); o começo e o fim presos na grade de `step` tiques (o fim estica até a
    /// nota seguinte se sobra menos de um passo, e uma nota não passa do começo da seguinte); a corda onde a casa fica
    /// mais perto da posição de antes (`from`, a nota tocada antes do trecho), a mesma da nota que já estava ali com essa
    /// altura, e a mesma da anterior num slide. `open`: a altura de cada corda solta (1 é a mais aguda). `occupied`: as
    /// notas que ficam (fora da faixa de alturas): a corda de uma delas, enquanto ela soa, não serve. `keepUnplaced`:
    /// devolve também as que não couberam em corda nenhuma, com a corda 0 (para dizer quantas ficaram de fora).
    public static func notes(_ heard: [HeardNote], tuning: Double, grid: TempoGrid, step: Double, open: [Int: Int],
                             from: (string: Int, fret: Int)? = nil, existing: [ScoreNote] = [],
                             occupied: [ScoreNote] = [], keepUnplaced: Bool = false) -> [RecognizedNote] {
        let step = max(30, step)
        func snap(_ seconds: Double) -> Double { (grid.tick(at: seconds) / step).rounded() * step }
        var placed: [RecognizedNote] = []
        let sorted = heard.sorted { $0.start < $1.start }
        for (index, note) in sorted.enumerated() {
            let guess = Int((note.level - tuning).rounded())
            let next = index + 1 < sorted.count ? sorted[index + 1] : nil
            let sound = SoundNote(curve: note.curve.shifted(by: -tuning), start: note.start, end: note.end,
                                  pitch: Double(guess), approached: note.slide != nil,
                                  slidesOut: next?.slide == "previous")
            var pitch = guess
            var bend: [[Double]] = []
            var vibrato = false
            if let fit = sound.fit {
                pitch = fit.trill?.low ?? fit.base
                // A nota de onde sai um slide não leva bend: a subida no fim dela é o próprio slide (no c. 105 do Sultans,
                // no app, o 11 do slide até o 14 saía com bend de 1 tom).
                if fit.trill == nil {
                    bend = next?.slide == "previous" ? [] : fit.form?.points ?? []
                    vibrato = fit.vibrato
                }
            }
            let tick = snap(note.start)
            placed.append(RecognizedNote(tick: tick, end: max(tick + step, snap(note.end)), pitch: pitch, string: 0, fret: 0,
                                         vibrato: vibrato, bend: bend, slide: note.slide))
        }
        // Uma depois da outra: a que começa no mesmo passo de outra sai (a mais curta), a de antes acaba onde a seguinte
        // começa, e um espaço menor que um passo vira nota.
        var line: [RecognizedNote] = []
        for note in placed {
            if let last = line.last, last.tick == note.tick {
                if note.end - note.tick > last.end - last.tick { line[line.count - 1] = note }
                continue
            }
            if let last = line.last {
                if last.end > note.tick || note.tick - last.end < step { line[line.count - 1].end = note.tick }
            }
            line.append(note)
        }
        // A corda e a casa.
        let strings = open.keys.sorted()
        var position = from
        for index in line.indices {
            let pitch = line[index].pitch
            let span = line[index].tick..<line[index].end
            let busy = Set(occupied.filter { $0.tick < span.upperBound && $0.tick + $0.duration > span.lowerBound }.map(\.string))
            let choices = strings.compactMap { string -> (string: Int, fret: Int)? in
                guard let base = open[string], (0...24).contains(pitch - base), !busy.contains(string) else { return nil }
                return (string, pitch - base)
            }
            guard !choices.isEmpty else { continue }
            var choice: (string: Int, fret: Int)?
            if line[index].slide == "previous", index > 0, let base = open[line[index - 1].string],
               line[index - 1].string > 0, (0...24).contains(pitch - base), !busy.contains(line[index - 1].string) {
                choice = (line[index - 1].string, pitch - base)
            } else if let same = existing.first(where: { $0.pitch == pitch && abs($0.tick - line[index].tick) <= step }),
                      let base = open[same.string], (0...24).contains(pitch - base), !busy.contains(same.string) {
                choice = (same.string, pitch - base)
            } else if let position {
                choice = choices.min { a, b in
                    Double(abs(a.fret - position.fret)) + 1.5 * Double(abs(a.string - position.string))
                        < Double(abs(b.fret - position.fret)) + 1.5 * Double(abs(b.string - position.string))
                }
            } else {
                // Sem posição de antes: a casa mais baixa que não é a corda solta (a mais comum num solo).
                choice = choices.filter { $0.fret > 0 }.min { $0.fret < $1.fret } ?? choices.first
            }
            if let choice {
                line[index].string = choice.string
                line[index].fret = choice.fret
                position = choice
            }
        }
        return keepUnplaced ? line : line.filter { $0.string > 0 }
    }
}
