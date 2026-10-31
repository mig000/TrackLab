import Foundation

/// As faixas da separação na ordem do mixer, com o nome que o app mostra. `rhythm` é a guitarra base, quando a
/// separação (o MVSEP 101, uma multitrack) a dá à parte.
public enum Stem: String, CaseIterable, Identifiable, Sendable {
    case guitar, rhythm, bass, drums, vocals, piano, other

    public var id: String { rawValue }

    /// As guitarras: "Sem guitarra" cala todas.
    public var isGuitar: Bool { self == .guitar || self == .rhythm }

    public var label: String {
        switch self {
        case .guitar: "Guitarra"
        case .rhythm: "Base"
        case .bass: "Baixo"
        case .drums: "Bateria"
        case .vocals: "Voz"
        case .piano: "Teclado"
        case .other: "Outros"
        }
    }
}

/// Volume, mudo e solo de uma faixa.
public struct StemMix: Equatable, Sendable, Codable {
    public var volume: Float
    public var muted: Bool
    public var solo: Bool

    public init(volume: Float = 1, muted: Bool = false, solo: Bool = false) {
        self.volume = volume
        self.muted = muted
        self.solo = solo
    }
}

/// O ganho de cada faixa: com algum solo, só as em solo soam; mudo cala; o resto no próprio volume.
public func mixGains(_ mix: [String: StemMix]) -> [String: Float] {
    let soloing = mix.values.contains { $0.solo }
    var gains: [String: Float] = [:]
    for (id, entry) in mix {
        let audible = soloing ? entry.solo : !entry.muted
        gains[id] = audible ? Swift.min(Swift.max(entry.volume, 0), 1.5) : 0
    }
    return gains
}

/// Os atalhos do mixer: a banda sem a guitarra (para tocar junto), a guitarra sozinha (para tirar), tudo.
public enum MixPreset: String, CaseIterable, Identifiable, Sendable {
    case noGuitar, guitarOnly, full

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .noGuitar: "Sem guitarra"
        case .guitarOnly: "Só guitarra"
        case .full: "Banda inteira"
        }
    }

    /// A mixagem do atalho nas faixas da separação (`stems`); os volumes que o usuário já mexeu ficam, e as outras
    /// entradas também (as pistas da TAB sintetizada, `tab:…`, com volume e mudo; antes saíam do dicionário e a TAB
    /// ficava calada). Um solo em qualquer uma sai: o atalho diz o que se ouve.
    public func apply(to mix: [String: StemMix], stems: [String]) -> [String: StemMix] {
        var result = mix.mapValues { entry -> StemMix in
            var entry = entry
            entry.solo = false
            return entry
        }
        for id in stems {
            var entry = mix[id] ?? StemMix()
            entry.solo = false
            let guitar = Stem(rawValue: id)?.isGuitar ?? false
            switch self {
            case .noGuitar: entry.muted = guitar
            case .guitarOnly: entry.muted = !guitar
            case .full: entry.muted = false
            }
            result[id] = entry
        }
        return result
    }

    /// O atalho que a mixagem atual é, se for um.
    public static func matching(_ mix: [String: StemMix], stems: [String]) -> MixPreset? {
        let mine = mix.filter { stems.contains($0.key) }
        return allCases.first { $0.apply(to: mine, stems: stems) == mine }
    }
}

/// O que o motor de áudio agenda para tocar de `start` com um loop: o pedaço até o fim do loop e depois o loop de
/// novo, tantas vezes quanto couberem em `horizon` segundos de música; sem loop (ou começando depois dele), o resto
/// da música. O relógio usa `songTime` com o mesmo plano, então som e cursor dão a volta juntos.
public struct PlaybackPlan: Equatable, Sendable {
    public let start: Double
    public let loop: ClosedRange<Double>?
    public let duration: Double

    /// Vinte minutos de música agendados por vez (no máximo 400 voltas): perto do fim, o motor agenda de novo.
    public static let horizon = 1200.0
    public static let maxRepeats = 400

    public init(start: Double, loop: ClosedRange<Double>?, duration: Double) {
        let clean = loop.flatMap { range -> ClosedRange<Double>? in
            let low = Swift.max(0, range.lowerBound)
            let high = Swift.min(range.upperBound, duration)
            return high - low >= LoopRegion.minimum ? low...high : nil
        }
        // Um play antes do loop entra nele; depois do fim, toca solto.
        if let clean, start < clean.upperBound {
            self.loop = clean
        } else {
            self.loop = nil
        }
        self.start = Swift.min(Swift.max(0, start), duration)
        self.duration = duration
    }

    /// Os trechos agendados, em ordem.
    public var segments: [ClosedRange<Double>] {
        guard let loop else { return start < duration ? [start...duration] : [] }
        var list = [start...loop.upperBound]
        let length = loop.upperBound - loop.lowerBound
        let repeats = Int(Swift.max(1, (Self.horizon / length).rounded(.down)))
        list.append(contentsOf: Array(repeating: loop, count: Swift.min(repeats, Self.maxRepeats)))
        return list
    }

    /// Quanto de música os trechos somam.
    public var length: Double { segments.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }

    /// Onde a música está depois de `elapsed` segundos de música tocados desde `start`.
    public func songTime(after elapsed: Double) -> Double {
        let raw = start + Swift.max(0, elapsed)
        guard let loop, raw >= loop.upperBound else { return Swift.min(raw, duration) }
        let length = loop.upperBound - loop.lowerBound
        return loop.lowerBound + (raw - loop.upperBound).truncatingRemainder(dividingBy: length)
    }

    /// Se a música termina depois de `elapsed` (nunca com loop).
    public func ended(after elapsed: Double) -> Bool {
        loop == nil && start + elapsed >= duration
    }
}

/// A janela da Fita e da TAB: a agulha numa fração da largura (`at`) e a tela correndo com ela; com a música dentro
/// de um loop que cabe, a tela parada no pino (`pin`) e só a agulha anda. As duas medidas só mudam num evento (um seek,
/// a rolagem, um loop novo, o zoom) e são escolhidas para a tela ficar onde estava: ela nunca salta sem a música
/// saltar. A TAB recebe as mesmas e faz a mesma conta (`score-core.js`).
public enum LoopView {
    public static let fits = 0.95

    /// O segundo do começo da tela com a música em `now`.
    public static func start(now: Double, loop: ClosedRange<Double>?, span: Double, at: Double, pin: Double?) -> Double {
        if let pin, let loop, now >= loop.lowerBound - 1e-3, now <= loop.upperBound + 1e-3 { return pin }
        return now - span * at
    }

    /// O pino depois de um evento, com a música em `now` e a agulha em `at`. Dentro do loop: a tela como está, se o loop
    /// inteiro está nela (senão nenhum: a tela corre com a agulha e volta junto com ela). Fora: onde a tela vai estar
    /// quando a música entrar no loop tocando (o começo dele sob a agulha), se dali ele cabe.
    public static func pin(now: Double, loop: ClosedRange<Double>?, span: Double, at: Double) -> Double? {
        guard let loop, span > 0 else { return nil }
        let length = loop.upperBound - loop.lowerBound
        guard length > 0, length <= span * fits else { return nil }
        if now >= loop.lowerBound - 1e-3, now <= loop.upperBound + 1e-3 {
            let view = now - span * at
            return loop.lowerBound >= view - 1e-3 && loop.upperBound <= view + span + 1e-3 ? view : nil
        }
        return length <= span * (1 - at) ? loop.lowerBound - span * at : nil
    }
}

extension Stem {
    /// A faixa em que uma pista da partitura soa, pelo nome (o Songsterr junta músico, instrumento e papel: "Jack
    /// Bruce | Gibson EB-3 | Bass"): a voz, o baixo, o teclado, a base ou a guitarra; nil para a bateria, que não tem
    /// altura. A base só se a separação tem a faixa (`available`); senão, a guitarra, que tem as duas.
    public static func pitchSource(forTrack name: String, available: Set<String>) -> Stem? {
        let text = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("drum", "bateria", "percuss") { return nil }
        if has("vocal", "voz", "voice", "vox") { return .vocals }
        if has("bass", "baixo") { return .bass }
        if has("piano", "keys", "keyboard", "teclado", "organ", "orgao", "synth") { return .piano }
        if has("rhythm", "ritmo", "base"), available.contains(Stem.rhythm.rawValue) { return .rhythm }
        return .guitar
    }
}
