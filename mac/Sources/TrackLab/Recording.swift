import AppKit
import AVFoundation
import Observation
import QuartzCore
import TrackLabCore

/// Os takes da música aberta e a gravação em curso (o modo Gravar). Os takes ficam no pacote (o áudio em
/// `takes/<id>.caf`, a lista no manifesto pelo motor); as pistas ("Guitarra 1" a 4) têm volume e mudo no mixer.
@Observable
@MainActor
final class TakeStudio {
    var takes: [Take] = []
    /// A pista em que a próxima gravação entra.
    var armed = UserDefaults.standard.object(forKey: "takes.armed") as? Int ?? 1 {
        didSet { UserDefaults.standard.set(armed, forKey: "takes.armed") }
    }
    /// Um compasso antes de começar (gravar com a música parada).
    var preRoll = UserDefaults.standard.object(forKey: "takes.preRoll") as? Bool ?? true {
        didSet { UserDefaults.standard.set(preRoll, forKey: "takes.preRoll") }
    }
    var volumes: [Int: Float] = [:]
    var muted: Set<Int> = []
    /// Todos os takes ligados ou calados (a chave do grupo no mixer).
    var on = true
    private(set) var recording = false
    /// Onde a gravação em curso começou na música (para a camada desenhar o take crescendo).
    private(set) var recordingFrom: Double?
    /// A onda de cada take (picos a cada 10 ms da música), calculada ao abrir.
    private(set) var peaks: [String: [Float]] = [:]
    /// A nota ao vivo (o afinador) com o tempo da música em que soou: o rastro na Lente.
    private(set) var trail: [(time: Double, pitch: Double)] = []

    @ObservationIgnored fileprivate var session: Session?
    @ObservationIgnored fileprivate var save: Task<Void, Never>?
    @ObservationIgnored fileprivate var watcher: UUID?

    fileprivate struct Session {
        let clock: StemEngine.Clock
        let lane: Int
        let cents: Int
        let chain: Data?
        let input: String
        let offset: Double
    }

    nonisolated static let peakStep = 0.01

    func volume(_ lane: Int) -> Float { volumes[lane] ?? 1 }

    /// As pistas à vista: as que têm takes e a armada, de 1 até a maior.
    var lanes: [Int] {
        let top = max(armed, takes.map(\.lane).max() ?? 1)
        return Array(1...min(top, Take.lanes.upperBound))
    }

    func takes(in lane: Int) -> [Take] { takes.filter { $0.lane == lane } }

    fileprivate func setRecording(_ value: Bool, from: Double?) {
        recording = value
        recordingFrom = from
    }

    fileprivate func setPeaks(_ id: String, _ values: [Float]) { peaks[id] = values }

    fileprivate func heard(_ pitch: Double?, at time: Double, playing: Bool) {
        if let last = trail.last, time < last.time - 0.05 || time > last.time + 1 { trail = [] }
        guard playing, let pitch else { return }
        trail.append((time, pitch))
        if trail.count > 400 { trail.removeFirst(trail.count - 400) }
    }

    func clearTrail() { trail = [] }
}

extension SongModel {
    // MARK: - Os takes da música

    func loadTakes(_ detail: SongDetail) {
        studio.takes = detail.takes
        applyTakes()
        computePeaks(for: detail.takes)
        InputEngine.shared.onPitch = { [weak self] frequency in
            guard let self else { return }
            // O tom do estudo sai: a nota ao vivo cai na altura escrita da TAB.
            let shift = Double(engine.semitones) + Double(engine.cents) / 100
            studio.heard(frequency.map { Tuner.pitch($0) - shift }, at: engine.currentTime, playing: engine.isPlaying)
        }
    }

    /// Os takes que soam (os escolhidos de cada pista) no motor de áudio, cada um no lugar e no tempo dele.
    func applyTakes() {
        guard let detail else { return }
        let list = studio.takes.filter(\.active).map { take in
            (id: StemEngine.takePrefix + take.id, url: detail.url(take.file),
             slot: StemEngine.TakeSlot(start: take.start, length: take.length, rate: take.rate, cents: take.cents))
        }
        engine.setTakes(list)
        applyTakeGains()
    }

    /// O volume de cada take: o da pista, calado no mudo, com o grupo desligado, ou na pista que está gravando (o take
    /// novo substitui o que estava ali; ouvir os dois juntos confunde).
    func applyTakeGains() {
        var gains: [String: Float] = [:]
        for take in studio.takes where take.active {
            let silent = !studio.on || studio.muted.contains(take.lane) || (studio.recording && take.lane == studio.armed)
            gains[StemEngine.takePrefix + take.id] = silent ? 0 : studio.volume(take.lane)
        }
        engine.takeGains = gains
    }

    private func computePeaks(for takes: [Take]) {
        guard let detail else { return }
        for take in takes where studio.peaks[take.id] == nil {
            let url = detail.url(take.file)
            let rate = take.rate
            let id = take.id
            Task.detached(priority: .utility) {
                let values = Self.peaks(of: url, rate: rate)
                await MainActor.run { self.studio.setPeaks(id, values) }
            }
        }
    }

    /// Os picos do take a cada 10 ms da música (o arquivo tem o tempo da gravação: a 85 %, cada 10 ms da música são
    /// 11,8 ms dele).
    nonisolated private static func peaks(of url: URL, rate: Double) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return [] }
        let step = max(1, Int(TakeStudio.peakStep / rate * file.processingFormat.sampleRate))
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var values: [Float] = []
        values.reserveCapacity(count / step + 1)
        var index = 0
        while index < count {
            var peak: Float = 0
            for channel in 0..<channels {
                let samples = data[channel]
                for i in index..<min(count, index + step) { peak = max(peak, abs(samples[i])) }
            }
            values.append(peak)
            index += step
        }
        let loudest = values.max() ?? 0
        return loudest > 0 ? values.map { min(1, $0 / loudest) } : values
    }

    private func saveTakes() {
        let previous = studio.save
        let list = studio.takes
        let id = id
        studio.save = Task {
            await previous?.value
            do {
                _ = try await Backend.shared.putTakes(id, list)
            } catch {
                notice = "Os takes não foram guardados: \(error.localizedDescription)"
            }
        }
    }

    private func change(_ update: (inout [Take]) -> Void) {
        update(&studio.takes)
        applyTakes()
        saveTakes()
    }

    // MARK: - Gravar

    /// R no modo Gravar: começa (com a música parada, do loop ou da agulha, com um compasso antes) ou para.
    func toggleRecording() {
        studio.recording ? finishRecording() : startRecording()
    }

    func startRecording() {
        guard detail != nil, !studio.recording else { return }
        let input = InputEngine.shared
        if !input.running { input.start() }
        guard input.running else {
            notice = input.error ?? "A entrada da guitarra está desligada."
            return
        }
        if !engine.isPlaying {
            let target = engine.loop?.lowerBound ?? engine.currentTime
            let from = studio.preRoll ? preRollStart(before: target) : target
            engine.seek(to: from)
            engine.play()
        }
        guard let clock = engine.clock else { return }
        do {
            try input.startRecording()
        } catch {
            notice = "A gravação não começou: \(error.localizedDescription)"
            return
        }
        studio.session = TakeStudio.Session(
            clock: clock, lane: studio.armed, cents: engine.semitones * 100 + engine.cents,
            chain: input.effects.isEmpty ? nil : input.chainData(), input: input.label, offset: input.offsetMS / 1000)
        studio.setRecording(true, from: engine.loop?.lowerBound ?? engine.currentTime)
        applyTakeGains()
        // Uma pausa, um salto, uma volta reagendada ou outra velocidade acabam a gravação ali.
        studio.watcher = engine.observe { [weak self] in
            guard let self, let session = studio.session, studio.recording else { return }
            if engine.transportVersion != session.clock.version { finishRecording(stopHost: CACurrentMediaTime()) }
        }
        // A entrada desligada ou remontada no meio (o botão, outro dispositivo, outros canais, um efeito, o próprio
        // dispositivo) termina a gravação com o que já entrou, em vez de perdê-la.
        input.onInterrupt = { [weak self] in self?.finishRecording(stopHost: CACurrentMediaTime()) }
        notice = "Gravando a Guitarra \(studio.armed)" + (engine.loop != nil ? ": cada volta do loop vira um take." : ".")
    }

    /// O começo do compasso antes de `seconds` (o pré-rolo), ou 2 s antes sem mapa.
    private func preRollStart(before seconds: Double) -> Double {
        let starts = grid.bars
        guard let previous = starts.last(where: { $0 < seconds - 0.05 }) else { return max(0, seconds - 2) }
        return previous
    }

    /// Para de gravar e guarda os takes (cada volta do loop um, recortada nele).
    func finishRecording(stopHost: Double? = nil) {
        guard studio.recording, let session = studio.session, let detail else { return }
        if let watcher = studio.watcher { engine.unobserve(watcher) }
        studio.watcher = nil
        studio.session = nil
        InputEngine.shared.onInterrupt = nil
        let raw = InputEngine.shared.stopRecording(at: stopHost ?? CACurrentMediaTime())
        studio.setRecording(false, from: nil)
        applyTakeGains()
        guard let raw, raw.frames > 0 else {
            notice = "Nada gravado: a entrada não mandou som."
            return
        }
        let clock = session.clock
        let elapsed = clock.elapsed(raw.firstHost) + session.offset * clock.rate
        let passes = TakeCut.passes(plan: clock.plan, elapsed: elapsed, frames: raw.frames, sampleRate: raw.sampleRate,
                                    rate: clock.rate)
        guard !passes.isEmpty else {
            try? FileManager.default.removeItem(at: raw.url)
            notice = "Curto demais: nenhum take."
            return
        }
        let created = ISO8601DateFormatter().string(from: Date())
        let existing = studio.takes(in: session.lane).count
        var made: [Take] = []
        for (index, pass) in passes.enumerated() {
            let id = "t" + UUID().uuidString.prefix(8).lowercased()
            made.append(Take(id: id, lane: session.lane, start: pass.start, length: pass.length, rate: clock.rate,
                             cents: session.cents, name: "Take \(existing + index + 1)", created: created,
                             active: false, input: session.input))
        }
        let folder = detail.url("takes")
        let chain = session.chain
        let jobs = zip(made, passes).map { (take: $0.0, pass: $0.1) }
        let source = raw.url
        Task {
            let failed = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = try AVAudioFile(forReading: source)
                    for job in jobs {
                        try Self.copy(file, from: job.pass.frame, frames: job.pass.frames,
                                      to: folder.appending(path: "\(job.take.id).caf"))
                        if let chain { try chain.write(to: folder.appending(path: "\(job.take.id).chain.plist")) }
                    }
                    try? FileManager.default.removeItem(at: source)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let failed {
                notice = "Os takes não foram gravados no pacote: \(failed)"
                return
            }
            var added = made.map { take -> Take in
                var take = take
                if chain != nil { take.chain = "takes/\(take.id).chain.plist" }
                return take
            }
            // O último soa; os de antes ficam para comparar (B).
            studio.takes += added
            if let last = added.last { studio.takes = TakeLanes.choose(last.id, in: studio.takes) }
            added = []
            applyTakes()
            saveTakes()
            computePeaks(for: made)
            let bars = passes.first.flatMap { pass in grid.bar(at: pass.start + 0.01) }.map { " (c. \($0))" } ?? ""
            notice = made.count == 1
                ? "\(made[0].name) na Guitarra \(session.lane)\(bars). B compara com o anterior."
                : "\(made.count) takes na Guitarra \(session.lane)\(bars), um por volta; soa o último. B compara."
        }
    }

    nonisolated private static func copy(_ file: AVAudioFile, from frame: Int, frames: Int, to url: URL) throws {
        let format = file.processingFormat
        let out = try AVAudioFile(forWriting: url, settings: file.fileFormat.settings, commonFormat: .pcmFormatFloat32,
                                  interleaved: false)
        file.framePosition = AVAudioFramePosition(frame)
        var left = frames
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
        while left > 0 {
            try file.read(into: buffer, frameCount: min(chunk, AVAudioFrameCount(left)))
            guard buffer.frameLength > 0 else { break }
            try out.write(from: buffer)
            left -= Int(buffer.frameLength)
        }
    }

    // MARK: - Escolher, comparar, organizar

    func chooseTake(_ id: String) {
        change { $0 = TakeLanes.choose(id, in: $0) }
    }

    /// B no modo Gravar: o take escolhido no loop (ou em volta da agulha) passa ao anterior, na pista armada.
    func alternateTake() {
        let range = engine.loop ?? (engine.currentTime...(engine.currentTime + 0.01))
        guard let next = TakeLanes.alternate(around: range, lane: studio.armed, in: studio.takes),
              let take = studio.takes.first(where: { $0.id == next }) else {
            notice = "Só um take aqui na Guitarra \(studio.armed): grave outro para comparar."
            return
        }
        chooseTake(next)
        notice = "Soa o \(take.name)."
    }

    func toggleFavorite(_ id: String) {
        change { list in
            if let index = list.firstIndex(where: { $0.id == id }) { list[index].favorite.toggle() }
        }
    }

    func renameTake(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        change { list in
            if let index = list.firstIndex(where: { $0.id == id }) { list[index].name = String(clean.prefix(80)) }
        }
    }

    func moveTake(_ id: String, to lane: Int) {
        change { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index].lane = lane
            if list[index].active { list = TakeLanes.choose(id, in: list) }
        }
    }

    func deleteTake(_ id: String) {
        guard let take = studio.takes.first(where: { $0.id == id }) else { return }
        change { list in
            list.removeAll { $0.id == id }
            // Se era o que soava, o mais novo dos que sobram ali passa a soar.
            if take.active, let other = TakeLanes.around(take.range, lane: take.lane, in: list).last {
                list = TakeLanes.choose(other.id, in: list)
            }
        }
        notice = "\(take.name) apagado."
    }

    func loopOnTake(_ id: String) {
        guard let take = studio.takes.first(where: { $0.id == id }) else { return }
        setLoop(LoopRegion.snapped(take.start, take.end, grid: grid, duration: engine.duration) ?? take.range,
                seekToStart: true)
    }

    /// Ouve só o take (sem a banda), do começo ao fim dele.
    func auditionTake(_ id: String) {
        guard let take = studio.takes.first(where: { $0.id == id }) else { return }
        if !take.active { chooseTake(id) }
        engine.audition(from: take.start, to: take.end, track: StemEngine.takePrefix + id)
    }

    /// O timbre do take (os efeitos e os ajustes deles) volta à entrada.
    func useChain(of id: String) {
        guard let detail, let take = studio.takes.first(where: { $0.id == id }), let chain = take.chain,
              let data = try? Data(contentsOf: detail.url(chain)) else {
            notice = "Este take foi gravado sem efeitos do Mac."
            return
        }
        Task {
            await InputEngine.shared.loadChain(data)
            notice = "O timbre do \(take.name) voltou à entrada."
        }
    }

    func revealTake(_ id: String) {
        guard let detail, let take = studio.takes.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([detail.url(take.file)])
    }

    /// Exporta o take num WAV de 24 bits (como foi gravado: na velocidade e no tom do estudo daquela hora).
    func exportTake(_ id: String) {
        guard let detail, let take = studio.takes.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(detail.title ?? "Música") – \(take.name).wav"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let source = detail.url(take.file)
        Task.detached(priority: .userInitiated) {
            let result: String
            do {
                let file = try AVAudioFile(forReading: source)
                let format = file.processingFormat
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ]
                try? FileManager.default.removeItem(at: target)
                let out = try AVAudioFile(forWriting: target, settings: settings, commonFormat: .pcmFormatFloat32,
                                          interleaved: false)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return }
                while file.framePosition < file.length {
                    try file.read(into: buffer)
                    if buffer.frameLength == 0 { break }
                    try out.write(from: buffer)
                }
                result = "\(take.name) exportado: \(target.lastPathComponent)."
            } catch {
                result = "Não exportou: \(error.localizedDescription)"
            }
            await MainActor.run { self.notice = result }
        }
    }

    func setLaneVolume(_ lane: Int, _ value: Float) {
        studio.volumes[lane] = value
        applyTakeGains()
    }

    func toggleLaneMute(_ lane: Int) {
        if studio.muted.contains(lane) { studio.muted.remove(lane) } else { studio.muted.insert(lane) }
        applyTakeGains()
    }

    func setTakesOn(_ value: Bool) {
        studio.on = value
        applyTakeGains()
    }

    /// O menu do take (o botão direito na camada dos takes).
    func showTakeMenu(_ id: String, at point: CGPoint, in view: NSView, rename: @escaping (Take) -> Void) {
        guard let take = studio.takes.first(where: { $0.id == id }) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let place = TakeLanes.place(first: grid.bar(at: take.start + 0.01),
                                    last: grid.bar(at: max(take.start, take.end - 0.01)))
        menu.addTitle("\(take.name) · Guitarra \(take.lane)",
                      detail: "\(place)\(String(format: "%.1f", take.length)) s · \(Int((take.rate * 100).rounded())) %"
                        + (take.input.map { " · \($0)" } ?? ""))
        menu.addSeparator()
        menu.add("Ouvir sozinho") { [weak self] in self?.auditionTake(id) }
        menu.add("Este é o escolhido", checked: take.active) { [weak self] in self?.chooseTake(id) }
        menu.add("Comparar com o anterior", key: "b", modifiers: []) { [weak self] in self?.alternateTake() }
        menu.add(take.favorite ? "Tirar dos favoritos" : "Favorito") { [weak self] in self?.toggleFavorite(id) }
        menu.addSeparator()
        menu.add("Renomear…") { rename(take) }
        menu.addSubmenu("Levar para") { sub in
            for lane in Take.lanes {
                sub.add("Guitarra \(lane)", checked: lane == take.lane) { [weak self] in self?.moveTake(id, to: lane) }
            }
        }
        menu.add("Usar o timbre dele", enabled: take.chain != nil) { [weak self] in self?.useChain(of: id) }
        menu.add("Loop neste take") { [weak self] in self?.loopOnTake(id) }
        menu.addSeparator()
        menu.add("Exportar o take…") { [weak self] in self?.exportTake(id) }
        menu.add("Mostrar no Finder") { [weak self] in self?.revealTake(id) }
        menu.addSeparator()
        menu.add("Apagar") { [weak self] in self?.deleteTake(id) }
        menu.popUp(positioning: nil, at: menuPoint(point, in: view), in: view)
    }
}
