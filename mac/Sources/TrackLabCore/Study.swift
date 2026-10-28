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

/// Um trecho da música para estudar: os compassos (em tiques, que não mudam com o mapa), a meta e o recorde em % da
/// velocidade, a última vez que foi tocado.
public struct StudySection: Codable, Identifiable, Hashable, Sendable {
    public var id: String?
    public var name: String
    public var from: Double
    public var to: Double
    public var goal: Int
    public var best: Int?
    public var practiced: String?

    public init(id: String? = nil, name: String, from: Double, to: Double, goal: Int = 100, best: Int? = nil,
                practiced: String? = nil) {
        self.id = id
        self.name = name
        self.from = from
        self.to = to
        self.goal = goal
        self.best = best
        self.practiced = practiced
    }

    /// O trecho ainda sem recorde começa a 70 %; depois, no recorde.
    public var startRate: Int { min(goal, max(StudySection.slowest, best ?? 70)) }
    public static let slowest = 50

    /// Dias desde a última vez; nil se nunca.
    public func daysSincePracticed(now: Date) -> Int? {
        guard let practiced, let date = StudyDates.parse(practiced) else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
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
            + song.sections.map(\.name)).joined(separator: " "))
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
