import Foundation

/// Uma nota da TAB para a nota da volta: onde ela começa e acaba na música (segundos), a altura esperada (a escrita
/// mais o tom do estudo na hora), o compasso, e se é de acorde (outra nota da pista começa junto) ou tem bend escrito
/// (a altura não se julga nesses: a curva de acorde vem dos harmônicos, e o bend sobe).
public struct PassNote: Hashable, Sendable {
    public let key: String
    public let start: Double
    public let end: Double
    public let pitch: Double
    public let bar: Int
    public let chord: Bool
    public let bend: Bool

    public init(key: String, start: Double, end: Double, pitch: Double, bar: Int, chord: Bool = false, bend: Bool = false) {
        self.key = key
        self.start = start
        self.end = end
        self.pitch = pitch
        self.bar = bar
        self.chord = chord
        self.bend = bend
    }
}

/// O que uma nota tocada foi: no tempo e na altura, cedo, tarde, outra altura ou não soou.
public enum NoteVerdict: String, Sendable, CaseIterable {
    case ok, early, late, wrongPitch, missed

    public var label: String {
        switch self {
        case .ok: "no tempo"
        case .early: "cedo"
        case .late: "tarde"
        case .wrongPitch: "outra altura"
        case .missed: "não soou"
        }
    }
}

/// A nota de uma volta (uma passada pelo loop, gravada no Estudar ou um take do Gravar) contra a TAB: cada nota com o
/// veredito, o atraso do ataque e o desvio da altura; o total, a mediana do atraso, se vale Limpo e os lugares a
/// treinar. A medida é a do motor (`POST songs/{id}/pitch` com o arquivo da volta): a curva de altura e o ataque.
public struct PassScore: Hashable, Sendable {
    public struct Result: Hashable, Sendable {
        public let note: PassNote
        public let verdict: NoteVerdict
        /// O ataque menos o começo escrito, em segundos da música (nil sem ataque claro: ligado, slide).
        public let offset: Double?
        /// A altura tocada menos a esperada, em semitons (nil em acorde, bend ou sem som).
        public let deviation: Double?
    }

    /// Um lugar a treinar: o compasso, o que deu errado e quantas notas.
    public struct Trouble: Hashable, Sendable {
        public let bar: Int
        public let verdict: NoteVerdict
        public let count: Int
        public let typical: Double?
        public let from: Double
        public let to: Double

        public var text: String {
            switch verdict {
            case .early: "adiantou \(Self.ms(typical)) ms"
            case .late: "atrasou \(Self.ms(typical)) ms"
            case .wrongPitch: typical.map { "\($0 > 0 ? "acima" : "abaixo") \(String(format: "%.1f", abs($0))) semitom" } ?? "outra altura"
            case .missed: count == 1 ? "uma nota não soou" : "\(count) notas não soaram"
            case .ok: ""
            }
        }

        static func ms(_ value: Double?) -> Int { Int((abs(value ?? 0) * 1000).rounded()) }
    }

    /// O que vale no tempo (o ataque a até 35 ms do escrito) e na altura (a até 0,4 semitom: o vibrato e a afinação
    /// da gravação cabem).
    public static let timing = 0.035
    public static let tuning = 0.4

    public let results: [Result]

    public var total: Int { results.count }
    public var good: Int { results.filter { $0.verdict == .ok }.count }
    public func count(_ verdict: NoteVerdict) -> Int { results.filter { $0.verdict == verdict }.count }
    public var share: Double { total == 0 ? 0 : Double(good) / Double(total) }

    /// Limpo: 9 de cada 10 notas boas e nenhuma em outra altura.
    public var clean: Bool { total > 0 && share >= 0.9 && count(.wrongPitch) == 0 }

    /// A mediana do atraso dos ataques medidos (+ depois do escrito).
    public var medianOffset: Double? {
        let values = results.compactMap(\.offset).sorted()
        return values.isEmpty ? nil : values[values.count / 2]
    }

    /// Os atrasos de todos os ataques medidos (para o histograma).
    public var offsets: [Double] { results.compactMap(\.offset) }

    /// A nota de cada compasso (a fração de notas boas).
    public var byBar: [Int: Double] {
        var groups: [Int: (good: Int, total: Int)] = [:]
        for result in results {
            var entry = groups[result.note.bar] ?? (0, 0)
            entry.total += 1
            if result.verdict == .ok { entry.good += 1 }
            groups[result.note.bar] = entry
        }
        return groups.mapValues { Double($0.good) / Double(max(1, $0.total)) }
    }

    /// Os compassos com mais erro, os dois piores, cada um com o erro que mais aparece nele.
    public var troubles: [Trouble] {
        var groups: [Int: [Result]] = [:]
        for result in results where result.verdict != .ok { groups[result.note.bar, default: []].append(result) }
        let ranked = groups.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        return ranked.prefix(2).map { bar, items in
            let kinds = Dictionary(grouping: items, by: \.verdict)
            let verdict = kinds.max { $0.value.count < $1.value.count }?.key ?? .missed
            let chosen = kinds[verdict] ?? []
            let values: [Double] = chosen.compactMap { verdict == .wrongPitch ? $0.deviation : $0.offset }.sorted()
            return Trouble(bar: bar, verdict: verdict, count: chosen.count,
                           typical: values.isEmpty ? nil : values[values.count / 2],
                           from: items.map(\.note.start).min() ?? 0, to: items.map(\.note.end).max() ?? 0)
        }
    }

    public init(results: [Result]) {
        self.results = results
    }

    /// A nota da volta: `curves` são as medidas do motor no arquivo da volta, pela chave da nota, com os tempos nos
    /// segundos do arquivo; o arquivo começa em `start` da música e foi tocado a `rate` (a velocidade do estudo).
    public static func evaluate(notes: [PassNote], curves: [String: PitchCurve], start: Double, rate: Double) -> PassScore {
        let rate = rate > 0 ? rate : 1
        var results: [Result] = []
        for note in notes {
            guard let curve = curves[note.key] else { continue }
            // O corpo da nota: sem os primeiros 25 ms (a palhetada) e sem o último quinto (a passagem à seguinte).
            let length = (note.end - note.start) / rate
            var body: [Double] = []
            var counted = 0
            for (index, value) in curve.values.enumerated() {
                let t = Double(index) * curve.hop
                guard t >= min(0.025, length * 0.2), t <= length * 0.8 else { continue }
                counted += 1
                if let value { body.append(value) }
            }
            let sounded = counted == 0 ? 0 : Double(body.count) / Double(counted)
            let offset = curve.attack.map { start + $0 * rate - note.start }
            guard sounded >= 0.2 || offset != nil else {
                results.append(Result(note: note, verdict: .missed, offset: nil, deviation: nil))
                continue
            }
            var deviation: Double?
            if !note.chord, !note.bend, body.count >= 3 {
                let sorted = body.sorted()
                deviation = sorted[sorted.count / 2] - note.pitch
            }
            let verdict: NoteVerdict
            if let deviation, abs(deviation) > tuning {
                verdict = .wrongPitch
            } else if let offset, offset < -timing {
                verdict = .early
            } else if let offset, offset > timing {
                verdict = .late
            } else {
                verdict = .ok
            }
            results.append(Result(note: note, verdict: verdict, offset: offset, deviation: deviation))
        }
        return PassScore(results: results)
    }
}
