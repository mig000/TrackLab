import Foundation

// O que o motor responde (engine/src/tracklab/api.py). Campos que o app não usa ficam de fora: o decodificador os
// ignora, e o motor pode crescer sem quebrar o app.

/// Uma música do repertório, como a lista e o Para hoje a mostram (`GET /api/songs`).
public struct SongSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String?
    public let artist: String?
    public let folder: String
    public let hasAudio: Bool
    public let stems: [String]
    public let activeStems: String?
    public let updated: String?
    public let status: StudyStatus
    public let sections: [StudySection]
    /// A afinação da pista de guitarra (MIDI, da corda mais aguda à mais grave).
    public let tuning: [Int]?
    public let measures: Int?
    /// Compassos conferidos no Ajuste e avisos da importação.
    public let checked: Int
    public let warnings: Int

    public init(id: String, title: String?, artist: String?, folder: String, hasAudio: Bool, stems: [String],
                activeStems: String?, updated: String?, status: StudyStatus = .want, sections: [StudySection] = [],
                tuning: [Int]? = nil, measures: Int? = nil, checked: Int = 0, warnings: Int = 0) {
        self.id = id
        self.title = title
        self.artist = artist
        self.folder = folder
        self.hasAudio = hasAudio
        self.stems = stems
        self.activeStems = activeStems
        self.updated = updated
        self.status = status
        self.sections = sections
        self.tuning = tuning
        self.measures = measures
        self.checked = checked
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, folder, hasAudio, stems, activeStems, updated, status, sections, tuning, measures,
             checked, warnings
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try c.decodeIfPresent(String.self, forKey: .artist)
        folder = try c.decode(String.self, forKey: .folder)
        hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? false
        stems = try c.decodeIfPresent([String].self, forKey: .stems) ?? []
        activeStems = try c.decodeIfPresent(String.self, forKey: .activeStems)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        status = StudyStatus(text: try c.decodeIfPresent(String.self, forKey: .status))
        sections = try c.decodeIfPresent([StudySection].self, forKey: .sections) ?? []
        tuning = try c.decodeIfPresent([Int].self, forKey: .tuning)
        measures = try c.decodeIfPresent(Int.self, forKey: .measures)
        checked = try c.decodeIfPresent(Int.self, forKey: .checked) ?? 0
        warnings = try c.decodeIfPresent(Int.self, forKey: .warnings) ?? 0
    }

    public var displayTitle: String { title?.isEmpty == false ? title! : folder }
    public var tuningName: String { Tuning.name(tuning) }
    /// Ainda falta conferir a sincronização: há aviso da importação ou compassos não conferidos.
    public var needsSync: Bool { warnings > 0 || (measures.map { checked < $0 } ?? false) }
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
    /// O nome do modelo do MVSEP, ou artista e título da multitrack.
    public let name: String?
    public let created: String?
    /// A multitrack: o caminho na biblioteca e onde ela caiu no vídeo.
    public let library: String?
    public let alignment: StemAlignment?

    public init(provider: String?, model: String?, device: String?, seconds: Double?, files: [String: String],
                fallback: String?, name: String? = nil, created: String? = nil, library: String? = nil,
                alignment: StemAlignment? = nil) {
        self.provider = provider
        self.model = model
        self.device = device
        self.seconds = seconds
        self.files = files
        self.fallback = fallback
        self.name = name
        self.created = created
        self.library = library
        self.alignment = alignment
    }

    /// Como o mixer chama a separação.
    public var label: String {
        switch provider {
        case "demucs", nil: "Demucs 6s"
        case "multitrack": "Multitrack"
        case "mvsep": name ?? "MVSEP"
        default: model ?? provider ?? "Faixas"
        }
    }

    /// O degrau da escada (Demucs, multitrack, MVSEP): a ordem do seletor.
    public var rank: Int {
        switch provider {
        case "demucs", nil: 0
        case "multitrack": 1
        case "mvsep": ["mvsep63": 2, "mvsep31": 3, "mvsep101": 4][model ?? ""] ?? 5
        default: 4
        }
    }

    /// O que a dica do seletor conta: de onde veio e, na multitrack, onde caiu no vídeo.
    public var detail: String {
        var parts: [String] = []
        if let library { parts.append(library) }
        if let alignment {
            parts.append(String(format: "começa %+.3f s no vídeo", alignment.offset))
            if abs(alignment.speed - 1) > 0.00001 {
                parts.append(String(format: "velocidade corrigida %.3f %%", (alignment.speed - 1) * 100))
            }
            if let agreed = alignment.agreed, let windows = alignment.windows {
                parts.append("\(agreed) de \(windows) trechos de acordo")
            }
        }
        if provider == "mvsep" {
            parts.append(model == "mvsep63" ? "as seis faixas do MVSEP" : "resto da banda pelo Demucs local")
        }
        if let fallback { parts.append(fallback) }
        return parts.joined(separator: " · ")
    }
}

/// A TAB sintetizada: uma faixa por pista do Guitar Pro (pelo índice da pista), feita no mapa de tempo de então;
/// `stale` quando o mapa mudou depois (o Ajuste).
public struct SynthSet: Codable, Hashable, Sendable {
    public let key: String
    public let soundfont: String?
    public let tracks: [String: SynthTrack]
    public let stale: Bool?

    public init(key: String, soundfont: String?, tracks: [String: SynthTrack], stale: Bool? = nil) {
        self.key = key
        self.soundfont = soundfont
        self.tracks = tracks
        self.stale = stale
    }

    /// O id de cada faixa no motor de áudio e no mixer ("tab:1"), na ordem das pistas.
    public var ids: [(id: String, track: SynthTrack)] {
        tracks.compactMap { key, track in Int(key).map { (index: $0, track: track) } }
            .sorted { $0.index < $1.index }
            .map { (SynthTrack.prefix + String($0.index), $0.track) }
    }
}

public struct SynthTrack: Codable, Hashable, Sendable {
    public static let prefix = "tab:"

    public let file: String
    public let name: String?
    public let percussion: Bool?
    public let program: Int?

    public init(file: String, name: String?, percussion: Bool? = nil, program: Int? = nil) {
        self.file = file
        self.name = name
        self.percussion = percussion
        self.program = program
    }

    /// O nome curto para o mixer: do Songsterr vem "Músico | Parte - Instrumento"; fica a parte.
    public var shortName: String {
        let full = name ?? "Pista"
        let afterBar = full.split(separator: "|", maxSplits: 1).last.map(String.init) ?? full
        let part = afterBar.components(separatedBy: " - ").first ?? afterBar
        let clean = part.trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? full : clean
    }
}

/// Onde a multitrack caiu sobre o áudio do vídeo.
public struct StemAlignment: Codable, Hashable, Sendable {
    public let offset: Double
    public let speed: Double
    public let agreed: Int?
    public let windows: Int?

    public init(offset: Double, speed: Double = 1, agreed: Int? = nil, windows: Int? = nil) {
        self.offset = offset
        self.speed = speed
        self.agreed = agreed
        self.windows = windows
    }
}

/// Quantas conversões do MVSEP o TrackLab usou hoje.
public struct MVSEPUsage: Codable, Hashable, Sendable {
    public let usedToday: Int
    public let limit: Int
    public let left: Int

    public init(usedToday: Int, limit: Int, left: Int) {
        self.usedToday = usedToday
        self.limit = limit
        self.left = left
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
    public let status: StudyStatus
    public let sections: [StudySection]
    /// A TAB sintetizada (uma faixa por pista do Guitar Pro), se houver.
    public let synth: SynthSet?

    public init(id: String, title: String?, artist: String?, folder: String, score: ScoreEntry?, audio: AudioEntry?,
                tempoMap: TempoEntry?, stems: [String: StemSet], activeStems: String?, warnings: [String],
                checkedBars: [Int] = [], status: StudyStatus = .want, sections: [StudySection] = [],
                synth: SynthSet? = nil) {
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
        self.status = status
        self.sections = sections
        self.synth = synth
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, folder, score, audio, tempoMap, stems, activeStems, warnings, checkedBars, status,
             sections, synth
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
        status = StudyStatus(text: try c.decodeIfPresent(String.self, forKey: .status))
        sections = try c.decodeIfPresent([StudySection].self, forKey: .sections) ?? []
        synth = try c.decodeIfPresent(SynthSet.self, forKey: .synth)
    }

    /// A separação ativa, se houver.
    public var active: StemSet? { activeStems.flatMap { stems[$0] } }

    /// As separações guardadas, na ordem da escada (Demucs, multitrack, MVSEP) e depois da mais nova.
    public var stemKeys: [String] {
        stems.keys.sorted { a, b in
            let (x, y) = (stems[a]!, stems[b]!)
            if x.rank != y.rank { return x.rank < y.rank }
            return (x.created ?? "", a) < (y.created ?? "", b)
        }
    }

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
    /// A mesma música na biblioteca de multitracks, se houver.
    public let multitrack: MultitrackSong?
}

/// Uma música da biblioteca de multitracks (`GET /api/multitracks/search`): as faixas da gravação, por instrumento.
public struct MultitrackSong: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let path: String
    public let artist: String?
    public let title: String
    public let album: String?
    public let year: String?
    /// `clonehero` (pasta com song.ini), `mogg` (todas as faixas num arquivo) ou `stems` (faixas soltas).
    public let format: String
    public let collection: String
    public let kinds: [String]

    /// Os instrumentos em português, na ordem do mixer.
    public var instruments: [String] {
        let names = ["guitar": "Guitarra", "rhythm": "Base/baixo", "bass": "Baixo", "drums": "Bateria",
                     "vocals": "Voz", "keys": "Teclados", "backing": "Banda", "other": "Outros"]
        let order = ["guitar", "rhythm", "bass", "drums", "vocals", "keys", "backing", "other"]
        return order.filter(kinds.contains).compactMap { names[$0] }
    }

    public var formatLabel: String {
        switch format {
        case "clonehero": "Clone Hero"
        case "mogg": "Rock Band (.mogg)"
        default: "Faixas de estúdio"
        }
    }
}

/// O índice de multitracks (`GET /api/multitracks`): onde está a biblioteca, se o HD está ligado e o que o índice tem.
public struct MultitrackStatus: Codable, Hashable, Sendable {
    public let root: String
    public let available: Bool
    public let count: Int
    public let scanned: String?
}

public struct MultitrackSearch: Codable, Sendable {
    public let results: [MultitrackSong]
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
