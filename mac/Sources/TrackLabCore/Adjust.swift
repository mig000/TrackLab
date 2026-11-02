import Foundation

/// O tempo ouvido de uma faixa, como o motor manda (`GET songs/{id}/beats`): a força dos ataques (um byte por quadro,
/// `rate` quadros por segundo) e as batidas que o detector achou, em segundos. `stem` diz de que faixa veio (a bateria,
/// o baixo ou o original).
public struct HeardBeats: Codable, Sendable, Equatable {
    public let rate: Double
    public let envelope: [UInt8]
    public let beats: [Double]
    public let tempo: Double
    public let stem: String

    public init(rate: Double, envelope: [UInt8], beats: [Double], tempo: Double, stem: String) {
        self.rate = rate
        self.envelope = envelope
        self.beats = beats
        self.tempo = tempo
        self.stem = stem
    }

    /// A força (0…1) no instante `seconds`; 0 fora da música.
    public func strength(at seconds: Double) -> Double {
        let index = Int((seconds * rate).rounded())
        guard envelope.indices.contains(index) else { return 0 }
        return Double(envelope[index]) / 255
    }

    /// A maior força entre `from` e `to` (para desenhar um pixel que cobre vários quadros sem perder o pico).
    public func peak(from: Double, to: Double) -> Double {
        let a = max(0, Int((from * rate).rounded(.down)))
        let b = min(envelope.count - 1, Int((to * rate).rounded(.up)))
        guard a <= b else { return 0 }
        return Double(envelope[a...b].max() ?? 0) / 255
    }
}

/// O pente do Ajuste: os ataques escritos (o ritmo da TAB, sem as notas) ligados aos ouvidos (os ataques fortes da
/// faixa onde a pista soa). Cada escrito casa com o ouvido mais perto, até `within` segundos, um com um só, os mais
/// perto primeiro.
public enum Comb {
    public struct Pair: Hashable, Sendable {
        public let written: Double
        public let heard: Double
        public var offset: Double { heard - written }
    }

    public static func pairs(written: [Double], heard: [Double], within: Double = 0.12) -> [Pair] {
        let heard = heard.sorted()
        guard !heard.isEmpty else { return [] }
        // Os candidatos de cada escrito: os ouvidos dentro da janela.
        var candidates: [(distance: Double, written: Int, heard: Int)] = []
        for (w, time) in written.enumerated() {
            var low = 0
            var high = heard.count
            while low < high {
                let middle = (low + high) / 2
                if heard[middle] < time - within { low = middle + 1 } else { high = middle }
            }
            var h = low
            while h < heard.count, heard[h] <= time + within {
                candidates.append((abs(heard[h] - time), w, h))
                h += 1
            }
        }
        candidates.sort { $0.distance < $1.distance }
        var usedWritten = Set<Int>()
        var usedHeard = Set<Int>()
        var out: [Pair] = []
        for candidate in candidates where !usedWritten.contains(candidate.written) && !usedHeard.contains(candidate.heard) {
            usedWritten.insert(candidate.written)
            usedHeard.insert(candidate.heard)
            out.append(Pair(written: written[candidate.written], heard: heard[candidate.heard]))
        }
        return out.sorted { $0.written < $1.written }
    }
}

/// Um compasso visto no Ajuste: o andamento dele pelo mapa e o que as duas provas ouvidas dizem do começo dele.
public struct BarReview: Hashable, Sendable {
    /// O número do compasso (1…).
    public let bar: Int
    public let start: Double
    public let bpm: Double
    /// A mediana de quanto os ataques ouvidos chegam depois (+) ou antes (−) dos escritos no compasso (ao menos 3).
    public let attacks: Double?
    public let attackCount: Int
    /// Quanto a batida do detector mais perto do começo do compasso fica depois (+) ou antes (−) dele (até 150 ms).
    public let detector: Double?
    /// O começo do compasso parece fora do lugar pelo andamento: o compasso de antes sai rápido e este lento (ou o
    /// contrário), 3 % cada um contra os vizinhos, ou este foge 12 % sozinho.
    public let tempoJump: Bool

    /// Vale olhar: as duas provas dizem 25 ms ou mais para o mesmo lado, ou uma diz 40 ms ou mais e a outra não a
    /// contradiz (falta, ou vai para o mesmo lado), ou o andamento salta. Uma prova sozinha a 25 ms não basta: o
    /// detector erra ±20 ms numa banda de verdade (no Sultans, sozinho, ele marcava 61 dos 214 compassos).
    public var doubtful: Bool {
        if tempoJump { return true }
        let near = AdjustReview.threshold
        let far = AdjustReview.alone
        switch (attacks, detector) {
        case let (a?, d?):
            let same = (a > 0) == (d > 0)
            return same && ((abs(a) >= near && abs(d) >= near) || abs(a) >= far || abs(d) >= far)
        case let (a?, nil): return abs(a) >= far
        case let (nil, d?): return abs(d) >= far
        case (nil, nil): return false
        }
    }

    /// As duas provas concordam que o mapa está fora (para o mesmo lado, 25 ms as duas ou 40 ms uma): dá para
    /// corrigir sem ouvir. O resto dos "a olhar" (uma prova só, o andamento saltando) pede o ouvido.
    public var fixable: Bool {
        guard let a = attacks, let d = detector, (a > 0) == (d > 0) else { return false }
        let near = AdjustReview.threshold
        let far = AdjustReview.alone
        return (abs(a) >= near && abs(d) >= near) || abs(a) >= far || abs(d) >= far
    }

    /// O deslocamento a usar para corrigir o começo do compasso: a média das duas provas quando vão para o mesmo lado;
    /// senão a dos ataques, ou a do detector.
    public var correction: Double? {
        if let a = attacks, let d = detector, (a > 0) == (d > 0) { return (a + d) / 2 }
        return attacks ?? detector
    }

    /// As duas provas concordam com o mapa (a menos de `close`): o compasso pode ser pulado na conferência.
    public func agrees(within close: Double = 0.015) -> Bool {
        guard attacks != nil || detector != nil else { return false }
        return abs(attacks ?? 0) < close && abs(detector ?? 0) < close && !tempoJump
    }
}

public enum AdjustReview {
    public static let threshold = 0.025
    /// Uma prova sozinha só acusa a partir daqui.
    public static let alone = 0.04

    /// Cada compasso do mapa (`grid`) com o andamento e as provas: `written` são os ataques escritos (em segundos, pelo
    /// mapa de agora), `heard` os ataques ouvidos da faixa, `detected` as batidas do detector.
    public static func bars(grid: TempoGrid, written: [Double], heard: [Double], detected: [Double]) -> [BarReview] {
        let starts = grid.bars
        guard starts.count >= 2 else { return [] }
        let count = starts.count - 1
        // O andamento de cada compasso: as batidas dele na duração dele.
        var bpm = [Double](repeating: 0, count: count)
        var beatIndex = 0
        let beats = grid.beats
        for i in 0..<count {
            while beatIndex < beats.count, beats[beatIndex] < starts[i] - 1e-6 { beatIndex += 1 }
            var inside = 0
            var j = beatIndex
            while j < beats.count, beats[j] < starts[i + 1] - 1e-6 {
                inside += 1
                j += 1
            }
            let length = starts[i + 1] - starts[i]
            bpm[i] = length > 0 ? 60 * Double(max(1, inside)) / length : 0
        }
        // Os ataques casados, por compasso.
        var offsets = [[Double]](repeating: [], count: count)
        for pair in Comb.pairs(written: written, heard: heard) {
            guard let index = index(of: pair.written, in: starts) else { continue }
            offsets[index].append(pair.offset)
        }
        let detectedSorted = detected.sorted()
        // Quanto cada compasso foge do andamento dos vizinhos (a mediana de até 4 de cada lado, sem ele). Um ponto do
        // mapa fora do lugar encurta um compasso e alonga o vizinho: os dois fogem para lados opostos. A variação de
        // uma banda tocando ao vivo fica nos 1–3 % e não tem esse par.
        var deviation = [Double](repeating: 0, count: count)
        for i in 0..<count where bpm[i] > 0 {
            var neighbours: [Double] = []
            for k in max(0, i - 4)...min(count - 1, i + 4) where k != i && bpm[k] > 0 { neighbours.append(bpm[k]) }
            let typical: Double = neighbours.isEmpty ? bpm[i] : SoundNote.percentile(neighbours, 0.5)
            deviation[i] = typical > 0 ? bpm[i] / typical - 1 : 0
        }
        var out: [BarReview] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let paired: Bool = i > 0 && abs(deviation[i]) > 0.03 && abs(deviation[i - 1]) > 0.03
                && (deviation[i] > 0) != (deviation[i - 1] > 0)
            let jump: Bool = paired || abs(deviation[i]) > 0.12
            let attack: Double? = offsets[i].count >= 3 ? SoundNote.percentile(offsets[i], 0.5) : nil
            let start = starts[i]
            let detector: Double? = nearest(start, in: detectedSorted, within: 0.15).map { $0 - start }
            out.append(BarReview(bar: i + 1, start: start, bpm: bpm[i], attacks: attack, attackCount: offsets[i].count,
                                 detector: detector, tempoJump: jump))
        }
        return out
    }

    /// O mapa inteiro contra o som: a mediana das correções dos compassos com prova, quantos têm prova e que parte
    /// deles vai para o lado da mediana (10 ms ou mais). `global` quando a música toda está deslocada: 8 compassos ou
    /// mais com prova, a mediana a 15 ms ou mais e 60 % deles do mesmo lado. É o primeiro passo do Ajuste: com tudo
    /// deslocado, quase todo compasso acusa, e acertar um por um é trabalho perdido.
    public struct Overall: Hashable, Sendable {
        public let median: Double
        public let count: Int
        public let share: Double
        public var global: Bool { count >= 8 && abs(median) >= 0.015 && share >= 0.6 }
    }

    public static func overall(_ bars: [BarReview]) -> Overall? {
        let values = bars.compactMap(\.correction)
        guard !values.isEmpty else { return nil }
        let median = SoundNote.percentile(values, 0.5)
        let side = values.filter { abs($0) >= 0.01 && ($0 > 0) == (median > 0) }.count
        return Overall(median: median, count: values.count, share: Double(side) / Double(values.count))
    }

    /// Os deslocamentos para corrigir só os compassos duvidosos: o deles nos duvidosos e zero nos outros (que assim
    /// ficam onde estão no `SoundSync.synced`), pelo índice do compasso (0…).
    public static func corrections(_ bars: [BarReview]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for review in bars {
            out[review.bar - 1] = review.doubtful ? max(-0.25, min(0.25, review.correction ?? 0)) : 0
        }
        return out
    }

    private static func index(of seconds: Double, in starts: [Double]) -> Int? {
        guard let first = starts.first, let last = starts.last, seconds >= first, seconds < last else { return nil }
        var low = 0
        var high = starts.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if starts[middle] <= seconds { low = middle } else { high = middle }
        }
        return low
    }

    private static func nearest(_ seconds: Double, in sorted: [Double], within: Double) -> Double? {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < seconds { low = middle + 1 } else { high = middle }
        }
        let options = [low - 1, low].filter { sorted.indices.contains($0) }.map { sorted[$0] }
        guard let best = options.min(by: { abs($0 - seconds) < abs($1 - seconds) }), abs(best - seconds) <= within else { return nil }
        return best
    }
}

/// O que um ajuste mudou no mapa em volta de um compasso, para a conferência mostrar: cada batida antes e depois (o
/// 1 de cada compasso marcado) e, por compasso, o andamento antes e depois e quanto o 1 andou. O áudio não muda: só
/// onde as batidas da TAB caem nele.
public struct MapChange: Sendable, Equatable {
    public struct Beat: Sendable, Equatable {
        public let before: Double
        public let after: Double
        public let downbeat: Bool
    }

    public struct Bar: Sendable, Equatable {
        public let bar: Int
        public let bpmBefore: Double
        public let bpmAfter: Double
        public let shift: Double
    }

    public let beats: [Beat]
    public let bars: [Bar]

    /// O andamento de um compasso (índice 0…): as batidas dele na duração dele.
    static func bpm(_ grid: TempoGrid, _ index: Int) -> Double {
        guard grid.bars.indices.contains(index + 1) else { return 0 }
        let start = grid.bars[index]
        let end = grid.bars[index + 1]
        let inside = grid.beats.filter { $0 >= start - 1e-6 && $0 < end - 1e-6 }.count
        return end > start ? 60 * Double(max(1, inside)) / (end - start) : 0
    }

    /// Entre o mapa de antes e o de depois, nos compassos `first…last` (1…): as batidas casadas pelo tique.
    public static func between(_ before: TempoGrid, _ after: TempoGrid, bars first: Int, _ last: Int) -> MapChange? {
        let count = min(before.barTicks.count, after.barTicks.count) - 1
        guard count >= 1 else { return nil }
        let a = max(1, first)
        let b = min(count, last)
        guard a <= b else { return nil }
        let from = before.barTicks[a - 1]
        let to = before.barTicks[b]
        let downbeats = Set(before.barTicks)
        var beats: [Beat] = []
        for point in before.points where point.tick >= from - 0.5 && point.tick <= to + 0.5 {
            beats.append(Beat(before: point.seconds, after: after.seconds(at: point.tick), downbeat: downbeats.contains(point.tick)))
        }
        let bars = (a...b).map { n in
            Bar(bar: n, bpmBefore: bpm(before, n - 1), bpmAfter: bpm(after, n - 1),
                shift: after.bars[n - 1] - before.bars[n - 1])
        }
        return MapChange(beats: beats, bars: bars)
    }
}
