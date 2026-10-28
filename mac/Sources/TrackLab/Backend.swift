import Darwin
import Foundation
import TrackLabCore

enum BackendError: LocalizedError {
    case noRepo, noEngine(String), launch(String), stopped(Int32, String), timeout(String), http(Int, String), notReady

    var errorDescription: String? {
        switch self {
        case .noRepo: "Não sei onde está o repositório do TrackLab (TLRepoPath / TRACKLAB_REPO) para iniciar o motor."
        case let .noEngine(path): "Não encontrei o motor em \(path). Prepare-o com `cd engine && uv sync --extra separate`."
        case let .launch(detail): "Não consegui iniciar o motor: \(detail)"
        case let .stopped(code, detail): "O motor encerrou ao iniciar (código \(code)).\(detail.isEmpty ? "" : "\n\(detail)")"
        case let .timeout(detail): "O motor não respondeu a tempo.\(detail.isEmpty ? "" : "\n\(detail)")"
        // O `detail` do motor já é uma frase em português para o usuário.
        case let .http(code, detail): detail.isEmpty ? "O motor recusou o pedido (erro \(code))." : detail
        case .notReady: "O motor ainda não está pronto."
        }
    }
}

/// O motor Python (`tracklab serve`), privado do app: iniciado por ele numa porta que o sistema escolhe, com
/// `--parent-pid` (sai junto com o app, até num crash) e encerrado ao sair. `TRACKLAB_URL` aponta para um motor
/// que o app não iniciou (testes). Mesmo arranjo do KaraokeLab.
@MainActor
final class Backend {
    static let shared = Backend()

    private(set) var root: URL?
    private var process: Process?
    private var logURL: URL?
    // "api" como pasta: com "api/", o appending(path:) seguinte gera "api//info".
    var base: URL? { root?.appending(path: "api", directoryHint: .isDirectory) }

    func connect() async throws {
        if let given = ProcessInfo.processInfo.environment["TRACKLAB_URL"], let url = URL(string: given) {
            root = url
            guard await alive() else { throw BackendError.timeout("Nada responde em \(given).") }
            return
        }
        if root != nil, await alive() { return }
        stop()
        guard let repo = Self.repository else { throw BackendError.noRepo }
        let engine = URL(fileURLWithPath: repo, isDirectory: true).appending(path: "engine", directoryHint: .isDirectory)
        let executable = engine.appending(path: ".venv/bin/tracklab")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw BackendError.noEngine(executable.path)
        }
        let p = Process()
        p.executableURL = executable
        p.currentDirectoryURL = engine
        p.arguments = ["serve", "--port", "0", "--parent-pid", String(getpid())]
        var environment = ProcessInfo.processInfo.environment
        // Aberto pelo Finder, o PATH não tem o Homebrew: o ffmpeg e o node moram lá.
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        p.environment = environment
        let output = Pipe()
        p.standardOutput = output
        let log = FileManager.default.temporaryDirectory.appending(path: "TrackLab-motor-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        p.standardError = handle
        let port = PortReader()
        output.fileHandleForReading.readabilityHandler = { file in
            let data = file.availableData
            if data.isEmpty {
                file.readabilityHandler = nil
                return
            }
            port.feed(data)
        }
        do {
            try p.run()
        } catch {
            try? handle.close()
            throw BackendError.launch(error.localizedDescription)
        }
        try? handle.close()
        process = p
        logURL = log
        let deadline = ContinuousClock.now + .seconds(90)
        while ContinuousClock.now < deadline {
            if let found = port.port {
                root = URL(string: "http://127.0.0.1:\(found)/")
                if await alive() { return }
            }
            if !p.isRunning {
                let detail = startupLog()
                let code = p.terminationStatus
                stop()
                throw BackendError.stopped(code, detail)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let detail = startupLog()
        stop()
        throw BackendError.timeout(detail)
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        if ProcessInfo.processInfo.environment["TRACKLAB_URL"] == nil { root = nil }
        if let logURL { try? FileManager.default.removeItem(at: logURL) }
        logURL = nil
    }

    private func startupLog() -> String {
        guard let logURL, let data = try? Data(contentsOf: logURL) else { return "" }
        return String(String(decoding: data, as: UTF8.self).suffix(1_200)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Onde está o repositório: variável de ambiente, Info.plist gravado pelo build.sh, ou, rodando por `swift run`,
    /// a pasta acima que contém engine/pyproject.toml.
    static var repository: String? {
        if let env = ProcessInfo.processInfo.environment["TRACKLAB_REPO"] { return env }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "TLRepoPath") as? String { return plist }
        var folder = Bundle.main.executableURL?.deletingLastPathComponent()
        while let current = folder, current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appending(path: "engine/pyproject.toml").path) {
                return current.path
            }
            folder = current.deletingLastPathComponent()
        }
        return nil
    }

    /// A página da partitura: a do bundle, ou a do repositório quando roda por `swift run`.
    static var webFolder: URL? {
        if let bundled = Bundle.main.resourceURL?.appending(path: "web", directoryHint: .isDirectory),
           FileManager.default.fileExists(atPath: bundled.appending(path: "score.html").path) {
            return bundled
        }
        guard let repo = repository else { return nil }
        let folder = URL(fileURLWithPath: repo, isDirectory: true).appending(path: "web", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: folder.appending(path: "score.html").path) ? folder : nil
    }

    private func alive() async -> Bool {
        guard let base else { return false }
        var request = URLRequest(url: base.appending(path: "info"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - Rotas

    func info() async throws -> EngineInfo { try await get("info") }

    func songs() async throws -> [SongSummary] {
        let list: SongList = try await get("songs")
        return list.songs
    }

    func song(_ id: String) async throws -> SongDetail { try await get("songs/\(id)") }

    func tempoMap(_ id: String) async throws -> TempoMapDocument? {
        do {
            return try await get("songs/\(id)/tempo-map")
        } catch BackendError.http(404, _) {
            return nil
        }
    }

    /// A onda do áudio original (`stem` nil) ou de uma faixa da separação ativa; nil se não houver.
    func peaks(_ id: String, stem: String? = nil) async throws -> Peaks? {
        let query = stem.map { [URLQueryItem(name: "stem", value: $0)] } ?? []
        do {
            return try await get("songs/\(id)/peaks", query: query)
        } catch BackendError.http(404, _) {
            return nil
        }
    }

    func search(_ text: String) async throws -> [SearchResult] {
        let response: SearchResponse = try await get("songsterr/search", query: [URLQueryItem(name: "q", value: text)])
        return response.results
    }

    struct ImportBody: Encodable {
        let url: String
        let separate: Bool
    }

    func importSong(_ url: String, separate: Bool = true) async throws -> JobTicket {
        try await send("POST", "songs/import", body: ImportBody(url: url, separate: separate))
    }

    func separate(_ id: String) async throws -> JobTicket {
        try await send("POST", "songs/\(id)/separate", body: Optional<String>.none)
    }

    func job(_ id: String) async throws -> Job { try await get("jobs/\(id)") }

    func cancel(_ id: String) async throws {
        struct Answer: Decodable { let cancelled: Bool }
        let _: Answer = try await send("POST", "jobs/\(id)/cancel", body: Optional<String>.none)
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let base else { throw BackendError.notReady }
        var url = base.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(data, response)
        return try await Self.decode(data)
    }

    private func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B?) async throws -> T {
        guard let base else { throw BackendError.notReady }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 60
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(data, response)
        return try await Self.decode(data)
    }

    /// Fora da thread principal: a onda de uma música longa tem centenas de milhares de números.
    private nonisolated static func decode<T: Decodable>(_ data: Data) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try JSONDecoder().decode(T.self, from: data) }.value
    }

    private nonisolated static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            struct Detail: Decodable { let detail: String? }
            let detail = (try? JSONDecoder().decode(Detail.self, from: data))?.detail ?? ""
            throw BackendError.http(http.statusCode, detail)
        }
    }
}

/// Lê `TRACKLAB_PORT=<n>` do stdout do motor, que chega em pedaços numa thread qualquer.
private final class PortReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var found: Int?

    var port: Int? {
        lock.lock()
        defer { lock.unlock() }
        return found
    }

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard found == nil else { return }
        buffer += String(decoding: data, as: UTF8.self)
        for line in buffer.split(separator: "\n") where line.hasPrefix("TRACKLAB_PORT=") {
            found = Int(line.dropFirst("TRACKLAB_PORT=".count).trimmingCharacters(in: .whitespaces))
        }
        if buffer.count > 10_000 { buffer = String(buffer.suffix(1_000)) }
    }
}
