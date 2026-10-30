import Foundation

// O repertório (engine/src/tracklab/repertoire.py): o estado de cada música, os trechos com meta, o treino de
// velocidade e o que vale tocar hoje.

/// O estado de estudo de uma música.
public enum StudyStatus: String, CaseIterable, Identifiable, Codable, Sendable {
    case learning, polishing, want, repertoire, archived

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .want: "Quero aprender"
        case .learning: "Aprendendo"
        case .polishing: "Polindo"
        case .repertoire: "No repertório"
        case .archived: "Arquivo"
        }
    }

    public init(text: String?) {
        self = text.flatMap(StudyStatus.init(rawValue:)) ?? .want
    }

    /// Na ordem de uma música pela vida: o seletor de estado mostra assim (a barra lateral agrupa por `allCases`,
    /// com o que se estuda agora em cima).
    public static let flow: [StudyStatus] = [.want, .learning, .polishing, .repertoire, .archived]
}

/// O tipo de um trecho, para a biblioteca de trechos (Fase 3b).
public enum SectionKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case trecho, lick, solo, riff, base, intro, final

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .trecho: "Trecho"
        case .lick: "Lick"
        case .solo: "Solo"
        case .riff: "Riff"
        case .base: "Base"
        case .intro: "Intro"
        case .final: "Final"
        }
    }

    /// O símbolo (SF Symbols) do tipo, no chip do trecho e na biblioteca.
    public var symbol: String {
        switch self {
        case .trecho: "music.note.list"
        case .lick: "bolt.fill"
        case .solo: "flame.fill"
        case .riff: "repeat"
        case .base: "square.stack.fill"
        case .intro: "arrow.right.to.line"
        case .final: "flag.checkered"
        }
    }
}

/// Um trecho da música para estudar: os compassos (em tiques, que não mudam com o mapa), a meta e o recorde em % da
/// velocidade, a última vez que foi tocado; o tipo, as etiquetas e o favorito organizam a biblioteca de trechos.
/// `start`, `seconds` e `bpm` vêm calculados pelo motor (pelo mapa de tempo) e não voltam para ele.
public struct StudySection: Codable, Identifiable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var from: Double
    public var to: Double
    public var goal: Int
    public var best: Int?
    public var practiced: String?
    public var kind: SectionKind
    public var tags: [String]
    public var favorite: Bool
    /// Quantos compassos o trecho tem (o app conta pelas barras da partitura ao gravar).
    public var bars: Int?
    public var start: Double?
    public var seconds: Double?
    public var bpm: Double?

    public init(id: String? = nil, name: String, from: Double, to: Double, goal: Int = 100, best: Int? = nil,
                practiced: String? = nil, kind: SectionKind = .trecho, tags: [String] = [], favorite: Bool = false,
                bars: Int? = nil) {
        self.id = id
        self.name = name
        self.from = from
        self.to = to
        self.goal = goal
        self.best = best
        self.practiced = practiced
        self.kind = kind
        self.tags = tags
        self.favorite = favorite
        self.bars = bars
    }

    enum CodingKeys: String, CodingKey {
        case id, name, from, to, goal, best, practiced, kind, tags, favorite, bars, start, seconds, bpm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        from = try c.decode(Double.self, forKey: .from)
        to = try c.decode(Double.self, forKey: .to)
        goal = try c.decodeIfPresent(Int.self, forKey: .goal) ?? 100
        best = try c.decodeIfPresent(Int.self, forKey: .best)
        practiced = try c.decodeIfPresent(String.self, forKey: .practiced)
        kind = (try? c.decodeIfPresent(SectionKind.self, forKey: .kind)) ?? .trecho
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        bars = try c.decodeIfPresent(Int.self, forKey: .bars)
        start = try c.decodeIfPresent(Double.self, forKey: .start)
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds)
        bpm = try c.decodeIfPresent(Double.self, forKey: .bpm)
    }

    /// O trecho ainda sem recorde começa a 70 %; depois, no recorde.
    public var startRate: Int { min(goal, max(StudySection.slowest, best ?? 70)) }
    public static let slowest = 50

    /// Dias desde a última vez; nil se nunca.
    public func daysSincePracticed(now: Date) -> Int? {
        guard let practiced, let date = StudyDates.parse(practiced) else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
    }

    /// As etiquetas de um texto separado por vírgulas, sem repetir (sem diferença de maiúscula), na ordem.
    public static func tags(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").compactMap { part in
            let tag = part.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !tag.isEmpty, seen.insert(tag.lowercased()).inserted else { return nil }
            return String(tag.prefix(30))
        }
    }
}

enum StudyDates {
    nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? { formatter.date(from: text) ?? plain.date(from: text) }
}

/// O nome de uma afinação pelas notas soltas (MIDI, da corda mais aguda à mais grave), como a busca e as coleções
/// mostram: "Padrão", "Mi bemol", "Drop D"…; as outras pelas notas.
public enum Tuning {
    static let standard = [64, 59, 55, 50, 45, 40]
    static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    public static func name(_ notes: [Int]?) -> String {
        guard let notes, !notes.isEmpty else { return "Sem afinação" }
        if notes.count == 6 {
            let shift = zip(notes, standard).map { $0 - $1 }
            if Set(shift).count == 1 {
                switch shift[0] {
                case 0: return "Padrão"
                case -1: return "Mi bemol"
                case -2: return "Ré"
                case -3: return "Dó sustenido"
                default: break
                }
            }
            if Array(shift.dropLast()) == Array(repeating: shift[0], count: 5), shift[5] == shift[0] - 2 {
                let low = names[((notes[5] % 12) + 12) % 12]
                return shift[0] == 0 ? "Drop D" : "Drop \(low)"
            }
            if notes == [62, 57, 55, 50, 45, 38] { return "DADGAD" }
        }
        return notes.reversed().map { names[(($0 % 12) + 12) % 12] }.joined(separator: " ")
    }
}

/// O treino de velocidade de um trecho: três "Limpo!" seguidos na mesma velocidade sobem 5 %, até a meta.
public struct SpeedTrainer: Sendable, Equatable {
    public static let streakToRise = 3
    public static let step = 5

    public private(set) var streak = 0
    private var rate: Int?

    public init() {}

    /// Uma passada limpa na velocidade `rate` (%): devolve a próxima velocidade quando é hora de subir.
    public mutating func clean(rate: Int, goal: Int) -> Int? {
        if self.rate != rate {
            self.rate = rate
            streak = 0
        }
        streak += 1
        guard streak >= Self.streakToRise, rate < goal else { return nil }
        streak = 0
        let next = min(goal, rate + Self.step)
        self.rate = next
        return next
    }

    /// Errou, mudou de trecho ou de velocidade à mão: a sequência recomeça.
    public mutating func reset() {
        streak = 0
        rate = nil
    }
}

/// A busca do repertório: cada palavra digitada precisa ser o começo de uma palavra da música (título, artista,
/// afinação, estado, trechos), sem diferença de acento ou maiúscula: "conferen" acha "Conferência", "whi roo" acha
/// "White Room".
public enum LibrarySearch {
    public static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    public static func matches(_ song: SongSummary, _ query: String) -> Bool {
        let wanted = words(query)
        guard !wanted.isEmpty else { return true }
        let have = words(([song.displayTitle, song.artist ?? "", song.tuningName, song.status.label]
            + song.sections.flatMap { [$0.name] + $0.tags }).joined(separator: " "))
        return wanted.allSatisfy { word in have.contains { $0.hasPrefix(word) } }
    }
}

/// Um item do Para hoje: um trecho (ou a música inteira) e por que ele subiu para hoje.
public struct TodayItem: Identifiable, Hashable, Sendable {
    public let songID: String
    public let sectionID: String?
    public let title: String
    public let detail: String
    public let reason: String
    public let best: Int?
    public let goal: Int?
    /// Menor é mais urgente.
    public let rank: Int

    public var id: String { "\(songID)/\(sectionID ?? "")" }
}

/// O que vale tocar hoje, por trecho: perto da meta, esquecido há dias, ainda sem recorde; no repertório, a revisão;
/// e as músicas novas com a sincronização conferida.
public enum TodayPlan {
    public static let limit = 8
    /// Dias sem tocar para um trecho em estudo voltar para hoje, e para um do repertório pedir revisão.
    public static let staleDays = 3
    public static let reviewDays = 7

    public static func items(_ songs: [SongSummary], now: Date = Date()) -> [TodayItem] {
        var items: [(item: TodayItem, days: Int)] = []
        for song in songs {
            let title = song.displayTitle
            switch song.status {
            case .learning, .polishing:
                if song.sections.isEmpty {
                    items.append((TodayItem(songID: song.id, sectionID: nil, title: title, detail: song.artist ?? "",
                                            reason: "Marque os trechos para estudar", best: nil, goal: nil, rank: 6), 0))
                }
                for section in song.sections {
                    let days = section.daysSincePracticed(now: now)
                    let reason: String
                    let rank: Int
                    if let best = section.best, best >= section.goal {
                        guard let days, days >= staleDays else { continue }
                        reason = "Na meta; sem tocar há \(days) dias"
                        rank = 5
                    } else if let days, days >= staleDays {
                        reason = "Sem tocar há \(days) dias"
                        rank = 2
                    } else if let best = section.best, section.goal - best <= 10 {
                        reason = "Meta quase lá"
                        rank = 1
                    } else if section.best == nil {
                        reason = "Ainda sem recorde"
                        rank = 3
                    } else {
                        reason = "Subindo a velocidade"
                        rank = 4
                    }
                    items.append((TodayItem(songID: song.id, sectionID: section.id, title: "\(title) · \(section.name)",
                                            detail: song.artist ?? "", reason: reason, best: section.best,
                                            goal: section.goal, rank: rank), days ?? 0))
                }
            case .repertoire:
                for section in song.sections {
                    let days = section.daysSincePracticed(now: now)
                    guard days == nil || days! >= reviewDays else { continue }
                    items.append((TodayItem(songID: song.id, sectionID: section.id, title: "\(title) · \(section.name)",
                                            detail: song.artist ?? "",
                                            reason: days.map { "Revisão: \($0) dias" } ?? "Revisão", best: section.best,
                                            goal: section.goal, rank: 7), days ?? Int.max / 2))
                }
            case .want:
                if let measures = song.measures, measures > 0, song.checked >= measures {
                    items.append((TodayItem(songID: song.id, sectionID: nil, title: title, detail: song.artist ?? "",
                                            reason: "Nova, sincronização conferida", best: nil, goal: nil, rank: 8), 0))
                }
            case .archived:
                break
            }
        }
        return items.sorted { ($0.item.rank, -$0.days, $0.item.title) < ($1.item.rank, -$1.days, $1.item.title) }
            .prefix(limit).map(\.item)
    }
}

/// Um trecho na biblioteca de trechos: o trecho e a música de onde ele vem.
public struct SectionItem: Identifiable, Hashable, Sendable {
    public let songID: String
    public let songTitle: String
    public let artist: String?
    public let tuning: String
    public let status: StudyStatus
    public let section: StudySection

    public var id: String { "\(songID)/\(section.id ?? section.name)" }
}

/// A biblioteca de trechos (Fase 3b): todos os trechos de todas as músicas, com busca (sem acento, pelo começo das
/// palavras: nome, tipo, etiquetas, música, artista, afinação), filtros e ordens.
public enum SectionLibrary {
    public enum Order: String, CaseIterable, Identifiable, Sendable {
        case recent, forgotten, nearGoal, song

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .recent: "Tocados há pouco"
            case .forgotten: "Esquecidos"
            case .nearGoal: "Perto da meta"
            case .song: "Por música"
            }
        }
    }

    public static func items(_ songs: [SongSummary]) -> [SectionItem] {
        songs.flatMap { song in
            song.sections.map { section in
                SectionItem(songID: song.id, songTitle: song.displayTitle, artist: song.artist, tuning: song.tuningName,
                            status: song.status, section: section)
            }
        }
    }

    public static func filter(_ items: [SectionItem], query: String = "", kinds: Set<SectionKind> = [],
                              tags: Set<String> = [], favoritesOnly: Bool = false) -> [SectionItem] {
        let wanted = LibrarySearch.words(query)
        let tagKeys = Set(tags.map { $0.lowercased() })
        return items.filter { item in
            let section = item.section
            if favoritesOnly && !section.favorite { return false }
            if !kinds.isEmpty && !kinds.contains(section.kind) { return false }
            if !tagKeys.isEmpty && tagKeys.isDisjoint(with: section.tags.map { $0.lowercased() }) { return false }
            guard !wanted.isEmpty else { return true }
            let have = LibrarySearch.words(([section.name, section.kind.label, item.songTitle, item.artist ?? "",
                                             item.tuning] + section.tags).joined(separator: " "))
            return wanted.allSatisfy { word in have.contains { $0.hasPrefix(word) } }
        }
    }

    public static func sorted(_ items: [SectionItem], by order: Order, now: Date = Date()) -> [SectionItem] {
        func date(_ item: SectionItem) -> Date? { item.section.practiced.flatMap(StudyDates.parse) }
        switch order {
        case .recent:
            return items.sorted { (date($0) ?? .distantPast, $1.section.name) > (date($1) ?? .distantPast, $0.section.name) }
        case .forgotten:
            // Nunca tocados primeiro, depois os de mais tempo sem tocar.
            return items.sorted { (date($0) ?? .distantPast, $0.section.name) < (date($1) ?? .distantPast, $1.section.name) }
        case .nearGoal:
            func gap(_ item: SectionItem) -> Int { item.section.goal - (item.section.best ?? 0) }
            return items.sorted { (gap($0), $0.section.name) < (gap($1), $1.section.name) }
        case .song:
            return items.sorted { ($0.songTitle, $0.section.from) < ($1.songTitle, $1.section.from) }
        }
    }

    /// As etiquetas mais usadas (empate em ordem alfabética), escritas como na primeira vez.
    public static func topTags(_ items: [SectionItem], limit: Int = 12) -> [String] {
        var counts: [String: (name: String, count: Int)] = [:]
        for tag in items.flatMap(\.section.tags) {
            counts[tag.lowercased(), default: (tag, 0)].count += 1
        }
        return counts.values.sorted { ($1.count, $0.name.lowercased()) < ($0.count, $1.name.lowercased()) }
            .prefix(limit).map(\.name)
    }
}
