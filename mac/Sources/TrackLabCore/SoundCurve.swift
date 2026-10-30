import Foundation

/// O que a curva do som diz de uma nota, como `fitCurve` da Lente do TabLab (`web/lens-core.js`): a altura presa no
/// traste (`base`, o grave do começo da nota), o bend em quartos de tom com os pontos do Guitar Pro (deslocamento de 0
/// a 60 ao longo da nota, até quatro), se há vibrato (oscilação de 3,5 a 9 Hz, ≥ 1,5 ciclo, ≥ 0,12 semitom em volta
/// da tendência) e se é trinado (ligados rápidos entre duas casas).
public struct CurveFit: Hashable, Sendable {
    public struct Trill: Hashable, Sendable {
        public let low: Int
        public let high: Int
        /// Segundos entre os saltos (a mediana).
        public let gap: Double
    }

    public let base: Int
    public let low: Double
    public let rise: Double
    public let quarterTones: Int
    public let points: [ScoreNote.BendPoint]?
    public let vibrato: Bool
    public let trill: Trill?
    public let depth: Double

    /// Os pontos no formato que o Guitar Pro 7 guarda (origem, meio de um valor só, destino): o bend que fica,
    /// `(sai, 0) → (chega, q)` (a altura segue depois do último ponto; o GP7 reduz um Bend a esses dois); o que volta,
    /// `(sai, 0) → (chega, q) → (segura, q) → (volta, 0)`. Os pontos da Lente perderiam o meio na gravação.
    public var guitarPro: [ScoreNote.BendPoint]? {
        guard var list = points, list.count >= 2 else { return nil }
        if list.count >= 3, list[0].value == 0, list[1].value == 0 { list.removeFirst() }
        if list.count == 3 {
            list.insert(.init(offset: max(list[1].offset + 1, list[2].offset - 4), value: list[1].value), at: 2)
        }
        return list
    }
}

/// A curva de uma nota pronta para a Fita: a do motor (já sem os pontos soltos), as tendências de 200 ms (sem o
/// vibrato) e de 40 ms, e o encaixe. `offset` é a forma da faixa (`shapeAt` da Lente): ela segue o som, não só a
/// escrita.
public struct SoundNote: Sendable {
    public let curve: PitchCurve
    public let level: [Double?]
    public let quick: [Double?]
    public let fit: CurveFit?
    /// Nota de acorde: a curva pula entre as cordas que soam juntas, então a faixa fica na escrita e não há trinado.
    public let chord: Bool
    private let topLevel: Double
    private let topQuick: Double

    public init(curve: PitchCurve, start: Double, end: Double, pitch: Double, chord: Bool = false) {
        self.curve = curve
        self.chord = chord
        level = SoundNote.trend(curve.values, width: Int((0.2 / curve.hop).rounded()))
        quick = SoundNote.trend(curve.values, width: max(3, Int((0.04 / curve.hop).rounded())))
        fit = SoundNote.fit(curve, start: start, end: end, pitch: pitch, trills: !chord)
        func top(_ series: [Double?]) -> Double {
            var best = -Double.infinity
            for (k, value) in series.enumerated() {
                let t = curve.from + Double(k) * curve.hop
                if let value, t >= start + 0.02, t <= end { best = max(best, value) }
            }
            return best
        }
        topLevel = top(level)
        topQuick = top(quick)
    }

    /// Quantos semitons acima da altura escrita a faixa passa no instante `t`: o trinado em dentes entre as duas
    /// casas; o bend pelo som quando ele também dobra (senão pelos pontos escritos); o vibrato copiado do som quando
    /// ele tem vibrato (senão a onda escrita).
    public func offset(_ note: ScoreNote, at t: Double, start: Double, end: Double) -> Double {
        if chord { return note.shape(fraction: (t - start) / max(1e-3, end - start), elapsed: t - start) }
        if let trill = fit?.trill, Double(note.pitch) >= Double(trill.low) - 0.5, Double(note.pitch) <= Double(trill.high) + 0.5 {
            guard let value = value(curve.values, at: t) else { return 0 }
            let level = abs(value - Double(trill.high)) < abs(value - Double(trill.low)) ? trill.high : trill.low
            return Double(level - note.pitch)
        }
        let length = max(1e-3, end - start)
        let vibrato = note.vibrato > 0
        var offset = bendFromSound(note, at: t, start: start, vibrato: vibrato) ?? note.bendOffset(fraction: (t - start) / length)
        if vibrato {
            let k = Int(((t - curve.from) / curve.hop).rounded())
            if let fit, fit.vibrato, curve.values.indices.contains(k), let value = curve.values[k], let trend = level[k] {
                offset += note.bend.isEmpty ? value - fit.low : value - trend
            } else {
                offset += note.vibratoOffset(elapsed: t - start)
            }
        }
        return offset
    }

    /// O bend escrito que o som também faz: a faixa sobe e desce com o som, até a altura escrita. Nil quando o som não
    /// dobra (vale a escrita).
    private func bendFromSound(_ note: ScoreNote, at t: Double, start: Double, vibrato: Bool) -> Double? {
        guard let fit, !note.bend.isEmpty, fit.quarterTones > 0, fit.trill == nil else { return nil }
        let useLevel = vibrato && fit.vibrato
        let top = useLevel ? topLevel : topQuick
        let base = Double(fit.base)
        guard top > base + 0.15 else { return nil }
        let reading = t < start + 0.02 ? base : value(useLevel ? level : quick, at: t)
        guard let reading else { return nil }
        let written = (note.bend.map(\.value).max() ?? 0) / 2
        return written * max(0, min(1, (reading - base) / (top - base)))
    }

    /// O valor da série no instante: o do quadro, ou o válido mais perto até 3 quadros; antes do primeiro válido,
    /// nil; depois do último, o último.
    public func value(_ series: [Double?], at t: Double) -> Double? {
        let k = Int(((t - curve.from) / curve.hop).rounded())
        for d in 0...3 {
            if series.indices.contains(k - d), let v = series[k - d] { return v }
            if series.indices.contains(k + d), let v = series[k + d] { return v }
        }
        var i = min(series.count - 1, k)
        while i >= 0 {
            if let v = series[i] { return v }
            i -= 1
        }
        return nil
    }

    // MARK: - As contas da Lente

    static func percentile(_ list: [Double], _ q: Double) -> Double {
        guard !list.isEmpty else { return .nan }
        let sorted = list.sorted()
        let at = max(0, min(Double(sorted.count - 1), q * Double(sorted.count - 1)))
        let i = Int(at)
        return sorted[i] + (sorted[min(sorted.count - 1, i + 1)] - sorted[i]) * (at - Double(i))
    }

    /// Média móvel de `width` pontos só entre os válidos: a tendência (200 ms anulam o vibrato de 4 a 7 Hz).
    public static func trend(_ values: [Double?], width: Int) -> [Double?] {
        let half = width / 2
        return values.indices.map { i in
            guard values[i] != nil else { return nil }
            var sum = 0.0
            var count = 0
            for j in max(0, i - half)...min(values.count - 1, i + half) {
                if let v = values[j] {
                    sum += v
                    count += 1
                }
            }
            return sum / Double(count)
        }
    }

    /// O bend em quartos de tom pela subida em semitons: abaixo de 0,85 é o ¼ do blues; depois ½, 1, 1½ e 2 tons.
    public static func quarterTones(rise: Double) -> Int {
        guard rise >= 0.3 else { return 0 }
        if rise < 0.85 { return 1 }
        if rise < 1.5 { return 2 }
        if rise < 2.5 { return 4 }
        if rise < 3.5 { return 6 }
        return 8
    }

    public static func fit(_ curve: PitchCurve, start: Double, end: Double, pitch: Double?,
                           trills: Bool = true) -> CurveFit? {
        let length = end - start
        guard length > 0.04 else { return nil }
        var times: [Double] = []
        var values: [Double?] = []
        for (k, value) in curve.values.enumerated() {
            let t = curve.from + Double(k) * curve.hop
            guard t >= start + 0.02, t <= end else { continue }
            times.append(t)
            values.append(value)
        }
        let valid = values.compactMap { $0 }
        guard valid.count >= 6, Double(valid.count) >= 0.4 * Double(values.count) else { return nil }
        var head: [Double] = []
        for (i, value) in values.enumerated() where times[i] <= start + max(0.08, 0.4 * length) {
            if let value { head.append(value) }
        }
        let low = percentile(head.count >= 3 ? head : valid, 0.2)
        let base = Int(low.rounded())
        let level = trend(values, width: max(3, Int((0.2 / curve.hop).rounded())))
        var peak = -Double.infinity
        var peakAt = 0
        for (i, value) in level.enumerated() {
            if let value, value > peak {
                peak = value
                peakAt = i
            }
        }
        // O vibrato: o que sobra em volta da tendência, em meias voltas que passam de 0,12 semitom.
        var swings = 0
        var sign = 0
        var top = 0.0
        var firstSwing: Double?
        var lastSwing: Double?
        var sizes: [Double] = []
        for i in values.indices {
            guard let value = values[i], let trend = level[i] else { continue }
            let rest = value - trend
            let s = rest > 0 ? 1 : -1
            if s != sign {
                if sign != 0, top >= 0.12 {
                    swings += 1
                    sizes.append(top)
                    if firstSwing == nil { firstSwing = times[i] }
                    lastSwing = times[i]
                }
                sign = s
                top = 0
            }
            top = max(top, abs(rest))
        }
        let cycles = Double(swings) / 2
        let span = firstSwing.flatMap { first in lastSwing.map { $0 - first } } ?? 0
        let frequency = span > 0 ? Double(swings - 1) / 2 / span : 0
        let trill = trills ? trillOf(times: times, values: values, base: base, pitch: pitch) : nil
        let vibrato = trill == nil && cycles >= 1.5 && frequency >= 3.5 && frequency <= 9 && percentile(sizes, 0.5) >= 0.12
        let depth = sizes.isEmpty ? 0 : percentile(sizes, 0.5)
        // O vibrato da guitarra só sobe: a tendência fica meia oscilação acima da casa, e isso não é bend.
        let rise = peak - Double(base) - (vibrato ? depth : 0)
        let quarters = trill == nil ? quarterTones(rise: rise) : 0
        var points: [ScoreNote.BendPoint]?
        if quarters > 0 {
            // Quando o bend sai e chega, pela curva de 40 ms: a de 200 ms começa a subir 100 ms antes do som.
            func offset(_ t: Double) -> Double { max(0, min(60, ((t - start) / length * 60).rounded())) }
            let quick = trend(values, width: max(3, Int((0.04 / curve.hop).rounded())))
            let amount = Double(quarters) / 2
            var leave = 0
            while leave < values.count - 1, !((quick[leave] ?? -.infinity) > Double(base) + 0.2 * amount) { leave += 1 }
            var reach = leave
            while reach < values.count - 1, !((quick[reach] ?? -.infinity) >= Double(base) + 0.8 * min(amount, rise)) { reach += 1 }
            var back = -1
            for i in peakAt..<level.count {
                if let value = level[i], value < Double(base) + 0.4 * rise {
                    back = i
                    break
                }
            }
            // De 20 % a 80 % da subida, estendido até 0 % e 100 %.
            let pace = (times[reach] - times[leave]) / 3
            let leaveAt = max(start, times[leave] - pace)
            let reachAt = min(end, times[reach] + pace)
            var list = [ScoreNote.BendPoint(offset: 0, value: 0)]
            if offset(leaveAt) > 3 { list.append(.init(offset: offset(leaveAt), value: 0)) }
            list.append(.init(offset: max(list[list.count - 1].offset + 1, offset(reachAt)), value: Double(quarters)))
            if back >= 0, offset(times[back]) > list[list.count - 1].offset + 2 {
                list.append(.init(offset: offset(times[back]), value: 0))
            }
            points = list
        }
        return CurveFit(base: base, low: low, rise: rise, quarterTones: quarters, points: points, vibrato: vibrato,
                        trill: trill, depth: depth)
    }

    /// O trinado: a curva alterna entre dois níveis a ao menos 0,7 semitom, cruzando o meio a cada 35 a 200 ms, em
    /// degraus (metade dos saltos em até dois quadros: o ligado pula de casa, o vibrato desliza).
    static func trillOf(times: [Double], values: [Double?], base: Int, pitch: Double?) -> CurveFit.Trill? {
        let valid = values.compactMap { $0 }
        let bottom = percentile(valid, 0.1)
        let top = percentile(valid, 0.9)
        let span = top - bottom
        guard span >= 0.7 else { return nil }
        let middle = (bottom + top) / 2
        var changes: [Double] = []
        var side = 0
        for (i, value) in values.enumerated() {
            guard let value else { continue }
            let now = value > middle ? 1 : -1
            if side != 0, now != side { changes.append(times[i]) }
            side = now
        }
        guard changes.count >= 2 else { return nil }
        let gap = percentile(zip(changes, changes.dropFirst()).map { $1 - $0 }, 0.5)
        guard gap >= 0.035, gap <= 0.2 else { return nil }
        var steps = 0
        var last = -1
        for (i, value) in values.enumerated() {
            guard let value else { continue }
            if last >= 0, i - last <= 2, let previous = values[last], abs(value - previous) >= 0.5 * span { steps += 1 }
            last = i
        }
        guard steps >= (changes.count + 1) / 2 else { return nil }
        return CurveFit.Trill(low: Int(bottom.rounded()), high: Int(top.rounded()), gap: gap)
    }
}

/// O que o som diz contra a nota escrita: as notas suspeitas da Fita (contorno vermelho) e o Tab do editor, que vai de
/// uma a outra. É o que o Encaixar (F) mudaria no que se toca, com folga para não acusar à toa: a altura, o bend com
/// meio tom de diferença e o trinado. O vibrato fica de fora (no Sunshine eram 22 das 75, quase sempre um vibrato que a
/// TAB não escreve; o F ainda o põe). Sem curva clara ou numa nota de acorde (a curva pula entre as cordas) não há o
/// que dizer.
public enum SoundDisagreement: Hashable, Sendable {
    /// Soa noutra altura (a medida, presa no semitom).
    case pitch(Int)
    /// O bend que soa, em quartos de tom (0: o som não dobra), longe do escrito.
    case bend(Int)
    /// Ligados rápidos entre duas casas, que a TAB não tem (ou tem entre outras).
    case trill(low: Int, high: Int)
    /// O trinado escrito que o som não faz.
    case noTrill
}

extension SoundNote {
    public func disagreements(with note: ScoreNote) -> [SoundDisagreement] {
        guard !chord, let fit else { return [] }
        if let trill = fit.trill {
            // O trinado escrito entre as mesmas duas notas (de qualquer uma para a outra) está certo.
            let written = note.trill.map { Set([note.pitch, $0]) }
            return written == Set([trill.low, trill.high]) ? [] : [.trill(low: trill.low, high: trill.high)]
        }
        if note.trill != nil { return [.noTrill] }
        // Noutra altura, o bend e o vibrato foram medidos em volta da nota errada: só a altura.
        if fit.base != note.pitch { return [.pitch(fit.base)] }
        let written = Int(note.bend.map(\.value).max() ?? 0)
        guard abs(fit.quarterTones - written) >= 2 else { return [] }
        // Uma subida que só sai no último quarto da nota é a passagem para a seguinte (ligado, slide), não um bend.
        let leave = fit.points?.prefix { $0.value == 0 }.last?.offset ?? 0
        if written == 0, leave >= 45 { return [] }
        return [.bend(fit.quarterTones)]
    }
}

extension PitchCurve {
    /// A mesma curva `semitones` acima (abaixo, se negativo): a afinação da gravação descontada.
    public func shifted(by semitones: Double) -> PitchCurve {
        semitones == 0 ? self
            : PitchCurve(from: from, hop: hop, values: values.map { $0.map { $0 + semitones } }, attack: attack)
    }
}

/// A afinação da gravação: quanto as notas soam acima (ou abaixo) do Lá 440, em semitons (+0,35 = 35 cents). Muita
/// gravação antiga foi feita com a fita mais rápida ou a banda afinada entre si; sem descontar, os pontos ficam sempre
/// no alto da faixa, um bend parece maior e uma nota a meio caminho vira suspeita.
public enum RecordingTuning {
    public struct Sample: Sendable {
        public let curve: PitchCurve
        public let start: Double
        public let end: Double
        public let pitch: Int
        /// Sem bend escrito e fora de acorde: a altura parada diz a afinação.
        public let plain: Bool

        public init(curve: PitchCurve, start: Double, end: Double, pitch: Int, plain: Bool) {
            self.curve = curve
            self.start = start
            self.end = end
            self.pitch = pitch
            self.plain = plain
        }
    }

    /// A mediana do desvio das notas paradas (o meio de cada uma, sem o ataque e o fim; a mediana dos pontos), das
    /// que ficam a menos de 0,6 semitom da escrita; nil com menos de `minimum` notas.
    public static func estimate(_ samples: [Sample], minimum: Int = 20) -> Double? {
        var deviations: [Double] = []
        for sample in samples where sample.plain {
            let length = sample.end - sample.start
            let from = sample.start + 0.25 * length
            let to = sample.end - 0.25 * length
            var middle: [Double] = []
            for (k, value) in sample.curve.values.enumerated() {
                let t = sample.curve.from + Double(k) * sample.curve.hop
                if let value, t >= from, t <= to { middle.append(value) }
            }
            guard middle.count >= 5 else { continue }
            let deviation = SoundNote.percentile(middle, 0.5) - Double(sample.pitch)
            if abs(deviation) < 0.6 { deviations.append(deviation) }
        }
        guard deviations.count >= minimum else { return nil }
        return SoundNote.percentile(deviations, 0.5)
    }
}

/// O que o som fez numa nota, para a linha da nota escolhida: a altura (o semitom e os cents, no meio da nota), o bend
/// que soou (e quanto do escrito ele alcança), a largura do vibrato e o trinado.
public struct SoundReport: Hashable, Sendable {
    public let pitch: Int
    public let cents: Int
    /// O bend que soa, em quartos de tom (0: o som não dobra).
    public let bend: Int
    /// Quanto do bend escrito o som alcança, em %; nil sem bend escrito.
    public let reached: Int?
    /// A meia oscilação do vibrato, em cents; nil sem vibrato.
    public let vibrato: Int?
    public let trill: CurveFit.Trill?
}

extension SoundNote {
    /// A mediana do meio da nota (sem o primeiro e o último quarto): a altura em que ela fica.
    public func middle(start: Double, end: Double) -> Double? {
        let length = end - start
        var values: [Double] = []
        for (k, value) in curve.values.enumerated() {
            let t = curve.from + Double(k) * curve.hop
            if let value, t >= start + 0.25 * length, t <= end - 0.25 * length { values.append(value) }
        }
        return values.count >= 3 ? SoundNote.percentile(values, 0.5) : nil
    }

    /// nil sem altura clara. Numa nota de acorde o motor mede entre as outras notas dele (sem trinado).
    public func report(for note: ScoreNote, start: Double, end: Double) -> SoundReport? {
        guard let fit else { return nil }
        let written = note.bend.map(\.value).max() ?? 0
        // Com bend, o meio da nota já subiu: a altura é a de partida.
        let held = fit.quarterTones > 0 ? fit.low : (middle(start: start, end: end) ?? fit.low)
        return SoundReport(pitch: fit.base, cents: Int(((held - Double(fit.base)) * 100).rounded()),
                           bend: fit.quarterTones,
                           reached: written > 0 ? Int((max(0, fit.rise) / (written / 2) * 100).rounded()) : nil,
                           vibrato: fit.vibrato ? Int((fit.depth * 100).rounded()) : nil, trill: fit.trill)
    }
}

/// O mapa de tempo contra o som: em cada compasso, quanto os ataques das notas chegam depois (+) ou antes (−) do começo
/// escrito delas. A mediana, com ao menos `minimum` ataques no compasso: uma nota sozinha pode ser um atraso de
/// propósito; várias juntas dizem que a batida está no lugar errado.
public enum SoundSync {
    /// `bars`: o início de cada compasso em segundos (com o fim do último). A chave é o índice do compasso (0…).
    public static func barOffsets(_ notes: [(start: Double, attack: Double?)], bars: [Double],
                                  minimum: Int = 3) -> [Int: Double] {
        guard bars.count >= 2 else { return [:] }
        var lists: [Int: [Double]] = [:]
        for note in notes {
            guard let attack = note.attack, note.start >= bars[0], note.start < bars[bars.count - 1] else { continue }
            var low = 0
            var high = bars.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if bars[middle] <= note.start { low = middle } else { high = middle }
            }
            lists[low, default: []].append(attack - note.start)
        }
        return lists.compactMapValues { $0.count >= minimum ? SoundNote.percentile($0, 0.5) : nil }
    }
}
