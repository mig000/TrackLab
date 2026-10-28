import Foundation

// O que o motor responde (engine/src/tracklab/api.py). Campos que o app não usa ficam de fora: o decodificador os
// ignora, e o motor pode crescer sem quebrar o app.

/// Uma música do repertório, como a lista a mostra (`GET /api/songs`).
public struct SongSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String?
    public let artist: String?
    public let folder: String
    public let hasAudio: Bool
    public let stems: [String]
    public let activeStems: String?
    public let updated: String?

    public init(id: String, title: String?, artist: String?, folder: String, hasAudio: Bool, stems: [String],
                activeStems: String?, updated: String?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.folder = folder
        self.hasAudio = hasAudio
        self.stems = stems
        self.activeStems = activeStems
        self.updated = updated
    }

    public var displayTitle: String { title?.isEmpty == false ? title! : folder }
}

public struct ScoreTrack: Codable, Hashable, Sendable {
    public let index: Int
    public let name: String
    public let instrument: String?

    public init(index: Int, name: String, instrument: String?) {
        self.index = index
        self.name = name
        self.instrument = instrument
    }

    /// Guitarra e não baixo: a pista que o estudo abre primeiro.
    public var isGuitar: Bool {
        let text = (name + " " + (instrument ?? "")).lowercased()
        return text.contains("guitar") && !text.contains("bass")
    }
}

public struct ScoreEntry: Codable, Hashable, Sendable {
    public let file: String
    public let measures: Int?
    public let tracks: [ScoreTrack]
}

public struct AudioEntry: Codable, Hashable, Sendable {
    public let file: String
    public let duration: Double?
    public let sampleRate: Int?
    public let channels: Int?
}

public struct TempoEntry: Codable, Hashable, Sendable {
    public let file: String
    public let source: String?
    public let points: Int?
}

/// Uma separação guardada no pacote: quem fez e o arquivo de cada faixa, relativo ao pacote.
public struct StemSet: Codable, Hashable, Sendable {
    public let provider: String?
    public let model: String?
    public let device: String?
    public let seconds: Double?
    public let files: [String: String]
    public let fallback: String?

    public init(provider: String?, model: String?, device: String?, seconds: Double?, files: [String: String], fallback: String?) {
        self.provider = provider
        self.model = model
        self.device = device
        self.seconds = seconds
        self.files = files
        self.fallback = fallback
    }
}

/// O manifesto de uma música (`GET /api/songs/{id}`), com a pasta do pacote no disco: o app lê os arquivos direto.
public struct SongDetail: Codable, Hashable, Sendable {
    public let id: String
    public let title: String?
    public let artist: String?
    public let folder: String
    public let score: ScoreEntry?
    public let audio: AudioEntry?
    public let tempoMap: TempoEntry?
    public let stems: [String: StemSet]
    public let activeStems: String?
    public let warnings: [String]
    /// Os compassos (a partir de 1) conferidos no Ajuste.
    public let checkedBars: [Int]

    public init(id: String, title: String?, artist: String?, folder: String, score: ScoreEntry?, audio: AudioEntry?,
                tempoMap: TempoEntry?, stems: [String: StemSet], activeStems: String?, warnings: [String],
                checkedBars: [Int] = []) {
        self.id = id
        self.title = title
        self.artist = artist
        self.folder = folder
        self.score = score
        self.audio = audio
        self.tempoMap = tempoMap
        self.stems = stems
        self.activeStems = activeStems
        self.warnings = warnings
        self.checkedBars = checkedBars
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, folder, score, audio, tempoMap, stems, activeStems, warnings, checkedBars
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        folder = try c.decode(String.self, forKey: .folder)
        score = try c.decodeIfPresent(ScoreEntry.self, forKey: .score)
        audio = try c.decodeIfPresent(AudioEntry.self, forKey: .audio)
        tempoMap = try c.decodeIfPresent(TempoEntry.self, forKey: .tempoMap)
        stems = try c.decodeIfPresent([String: StemSet].self, forKey: .stems) ?? [:]
        activeStems = try c.decodeIfPresent(String.self, forKey: .activeStems)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        checkedBars = try c.decodeIfPresent([Int].self, forKey: .checkedBars) ?? []
    }

    /// A separação ativa, se houver.
    public var active: StemSet? { activeStems.flatMap { stems[$0] } }

    /// Um arquivo do pacote no disco.
    public func url(_ relative: String) -> URL {
        URL(fileURLWithPath: folder, isDirectory: true).appending(path: relative)
    }
}

public struct TempoPoint: Codable, Hashable, Sendable {
    public let tick: Double
    public let seconds: Double
    /// `anchor` (posto à mão no Ajuste), `detected` (do Songsterr ou ouvido) ou `interpolated`.
    public let kind: String
    public let confidence: Double?

    public init(tick: Double, seconds: Double, kind: String, confidence: Double? = nil) {
        self.tick = tick
        self.seconds = seconds
        self.kind = kind
        self.confidence = confidence
    }

    public var isAnchor: Bool { kind == "anchor" }
}

/// O mapa de tempo do pacote (`score/tempo-map.json`): tiques da partitura (960 por semínima) → segundos do áudio.
public struct TempoMapDocument: Codable, Hashable, Sendable {
    public let source: String?
    public let algorithm: String?
    public let points: [TempoPoint]

    public init(source: String?, algorithm: String?, points: [TempoPoint]) {
        self.source = source
        self.algorithm = algorithm
        self.points = points
    }
}

/// Um resultado da busca do Songsterr (`GET /api/songsterr/search`).
public struct SearchResult: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let artist: String
    public let title: String
    public let tracks: Int
}

public struct SearchResponse: Codable, Sendable {
    public let results: [SearchResult]
}

public struct SongList: Codable, Sendable {
    public let songs: [SongSummary]
}

public struct JobEvent: Codable, Hashable, Sendable {
    public let seq: Int
    public let stage: String?
    public let message: String?
    public let progress: Double?
    public let status: String?
}

public struct JobResult: Codable, Hashable, Sendable {
    public let song: SongSummary?
    public let warning: String?
}

/// Uma tarefa do motor (`GET /api/jobs/{id}`): importar ou separar.
public struct Job: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: String
    public let project: String?
    public let status: String
    public let events: [JobEvent]?
    public let error: String?
    public let result: JobResult?

    public var finished: Bool { ["done", "error", "cancelled"].contains(status) }
    public var last: JobEvent? { events?.last }
}

/// O que `POST` de uma tarefa devolve: só a identidade e o estado.
public struct JobTicket: Codable, Sendable {
    public let id: String
    public let kind: String
    public let status: String
}

/// A onda de um áudio (`GET /api/songs/{id}/peaks`): mínimo e máximo do mono, `perSecond` janelas por segundo.
public struct Peaks: Codable, Hashable, Sendable {
    public let perSecond: Int
    public let min: [Float]
    public let max: [Float]

    public init(perSecond: Int, min: [Float], max: [Float]) {
        self.perSecond = perSecond
        self.min = min
        self.max = max
    }

    public var duration: Double { perSecond > 0 ? Double(max.count) / Double(perSecond) : 0 }

    /// A maior amplitude nas janelas de [start, end): o que um pixel da Fita mostra.
    public func amplitude(from start: Double, to end: Double) -> Float {
        guard perSecond > 0, !max.isEmpty else { return 0 }
        let first = Swift.max(0, Int((start * Double(perSecond)).rounded(.down)))
        let last = Swift.min(max.count, Swift.max(first + 1, Int((end * Double(perSecond)).rounded(.up))))
        guard first < last else { return 0 }
        var peak: Float = 0
        for index in first..<last {
            peak = Swift.max(peak, Swift.max(abs(min[index]), abs(max[index])))
        }
        return peak
    }
}

public struct EngineInfo: Codable, Sendable {
    public let version: String
    public let home: String
    public let songs: String
    public let machine: String?
    public let device: String?
}
