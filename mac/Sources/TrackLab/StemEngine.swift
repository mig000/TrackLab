import AVFoundation
import Observation
import QuartzCore
import TrackLabCore

/// O áudio do estudo num só AVAudioEngine: o original e cada faixa da separação, cada um num player, todos
/// começando no mesmo instante de host (ficam alinhados amostra a amostra), somados num barramento que passa por
/// um AVAudioUnitTimePitch (velocidade 0,5–1,5 e tom −6…+6 em tempo real). O loop é agendado no próprio player
/// (o trecho até o fim do loop e depois o loop de novo, várias vezes), sem salto de seek a cada volta.
/// O relógio é tempo de host × velocidade desde a âncora do último play, menos a latência ouvida, como no
/// StemEngine do KaraokeLab e do TabLab.
@Observable
@MainActor
final class StemEngine {
    static let sourceID = "source"
    static let rates: ClosedRange<Float> = 0.5...1.5
    static let rateStep: Float = 0.05
    static let semitones: ClosedRange<Int> = -6...6
    static let cents: ClosedRange<Int> = -50...50
    static let clickID = "click"

    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var loaded = false
    /// Conta os seeks: a Fita traz o cursor de volta à vista quando ele salta.
    private(set) var seekCount = 0
    private(set) var playbackError: String?

    /// O trecho que se repete; mudar enquanto toca agenda de novo do ponto ouvido.
    var loop: ClosedRange<Double>? {
        didSet {
            guard loop != oldValue else { return }
            if isPlaying { restart(at: currentTime) }
            changed()
        }
    }

    /// Original (o áudio do vídeo) ou as faixas da separação.
    var useStems = false { didSet { applyMix() } }
    var mix: [String: StemMix] = [:] { didSet { applyMix() } }
    /// As chaves gerais do mixer: todo o áudio (o original ou as faixas) e toda a TAB sintetizada. Calar um grupo não
    /// mexe na mixagem de cada faixa dele.
    var audioOn = true { didSet { applyMix() } }
    var tabOn = false { didSet { applyMix() } }
    var masterVolume: Float = 1 { didSet { bus.outputVolume = masterVolume } }

    var rate: Float {
        get { rateValue }
        set { setRate(newValue) }
    }

    /// Tom em semitons; a duração não muda. Calculada, como a velocidade: com o `@Observable`, prender o valor no
    /// `didSet` atribuía de novo, que chamava o `didSet` de novo, até estourar a pilha (subir o tom fechava o app).
    var semitones: Int {
        get { semitoneValue }
        set {
            semitoneValue = min(max(newValue, Self.semitones.lowerBound), Self.semitones.upperBound)
            timePitch.pitch = Float(semitoneValue * 100 + centValue)
        }
    }

    /// Ajuste fino em cents, somado ao tom: a música afinada com o instrumento (ou no Lá 440, descontando a afinação
    /// da gravação).
    var cents: Int {
        get { centValue }
        set {
            centValue = min(max(newValue, Self.cents.lowerBound), Self.cents.upperBound)
            timePitch.pitch = Float(semitoneValue * 100 + centValue)
        }
    }

    /// O metrônomo: a faixa de cliques (`setClick`) soa por cima de tudo, no tempo do mapa.
    var clickOn = false { didSet { applyMix() } }

    private var rateValue: Float = 1
    private var semitoneValue = 0
    private var centValue = 0
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored private var observers: [UUID: () -> Void] = [:]

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let bus = AVAudioMixerNode()
    @ObservationIgnored private let timePitch = AVAudioUnitTimePitch()

    private struct Track {
        let file: AVAudioFile
        let player: AVAudioPlayerNode
    }

    @ObservationIgnored private var tracks: [String: Track] = [:]
    @ObservationIgnored private(set) var sources: [String: URL] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var plan = PlaybackPlan(start: 0, loop: nil, duration: 0)
    /// Quanto de música o plano agendou (`plan.length`, guardado: o tique pergunta 20 vezes por segundo).
    @ObservationIgnored private var planLength: Double = 0
    // Tempo da música = plan.songTime(after: (agora − anchorHost − latência) × velocidade + anchorElapsed).
    private var anchorTime: Double = 0
    @ObservationIgnored private var anchorHost: CFTimeInterval = 0
    /// Música já tocada no plano atual antes da âncora (uma mudança de velocidade no meio dele).
    @ObservationIgnored private var anchorElapsed: Double = 0
    /// A latência ouvida (saída + time-pitch), relida a cada segundo: perguntar ao Core Audio a cada quadro custa.
    @ObservationIgnored private var latency: Double = 0
    @ObservationIgnored private var latencyRead: CFTimeInterval = 0
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?

    init() {
        engine.attach(bus)
        engine.attach(timePitch)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    /// A saída mudou (fone, AirPlay): o motor parou sozinho; retoma do mesmo ponto no dispositivo novo.
    private func outputChanged() {
        let wasPlaying = isPlaying
        let position = currentTime
        pause()
        anchorTime = position
        guard loaded else { return }
        engine.prepare()
        if wasPlaying { startPlayers() }
    }

    // MARK: - Arquivos

    /// Carrega o original e as faixas (id → arquivo). A posição fica onde estava, dentro da duração nova.
    func load(_ files: [(id: String, url: URL)]) throws {
        stop()   // tocando, guarda o ponto ouvido em `anchorTime`: o A/B recarrega no mesmo lugar
        let position = anchorTime
        for track in tracks.values {
            engine.disconnectNodeOutput(track.player)
            engine.detach(track.player)
        }
        tracks = [:]
        sources = [:]
        engine.disconnectNodeOutput(bus)
        engine.disconnectNodeOutput(timePitch)
        var opened: [(id: String, file: AVAudioFile)] = []
        for item in files {
            opened.append((item.id, try AVAudioFile(forReading: item.url)))
            sources[item.id] = item.url
        }
        guard let first = opened.first else {
            duration = 0
            anchorTime = 0
            return
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: first.file.processingFormat.sampleRate, channels: 2)
        for item in opened {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: bus, format: item.file.processingFormat)
            tracks[item.id] = Track(file: item.file, player: player)
        }
        engine.connect(bus, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()
        // O original manda na duração: as faixas têm o mesmo tamanho, mas um arredondamento não cria silêncio no fim.
        let source = opened.first { $0.id == Self.sourceID } ?? first
        duration = Double(source.file.length) / source.file.processingFormat.sampleRate
        anchorTime = min(position, duration)
        loaded = true
        applyMix()
    }

    /// Grava as amostras do metrônomo (mono, `Metronome.rate`) num arquivo que `setClick` abre.
    nonisolated static func writeClick(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Metronome.rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count)))
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    /// Troca a faixa do metrônomo (nil tira), sem recarregar as outras; tocando, segue do ponto ouvido.
    func setClick(_ url: URL?) throws {
        let file = try url.map { try AVAudioFile(forReading: $0) }
        let wasPlaying = isPlaying
        let position = currentTime
        if wasPlaying { pause() }
        if let old = tracks.removeValue(forKey: Self.clickID) {
            engine.disconnectNodeOutput(old.player)
            engine.detach(old.player)
        }
        if let file {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: bus, format: file.processingFormat)
            tracks[Self.clickID] = Track(file: file, player: player)
        }
        applyMix()
        if wasPlaying {
            anchorTime = min(max(0, position), duration)
            startPlayers()
        }
    }

    /// As faixas da separação carregadas (sem o original e sem a TAB sintetizada).
    var stemIDs: [String] {
        tracks.keys.filter { $0 != Self.sourceID && $0 != Self.clickID && !$0.hasPrefix(SynthTrack.prefix) }.sorted()
    }

    /// As faixas da TAB sintetizada carregadas ("tab:1"…).
    var synthIDs: [String] { tracks.keys.filter { $0.hasPrefix(SynthTrack.prefix) }.sorted() }

    // MARK: - Relógio

    /// O tempo da música ouvido agora, em segundos (contínuo, para desenhar).
    var currentTime: Double { songTime(atHost: CACurrentMediaTime()) }

    /// Quanto falta, em segundos de relógio, para o som do play chegar à saída (a latência); zero parado.
    var startDelay: Double {
        guard isPlaying else { return 0 }
        return max(0, anchorHost + latency - CACurrentMediaTime())
    }

    func songTime(atHost host: Double) -> Double {
        guard isPlaying else { return anchorTime }
        return plan.songTime(after: elapsed(atHost: host, rate: rateValue))
    }

    /// Música tocada no plano atual até `host`.
    private func elapsed(atHost host: Double, rate: Float) -> Double {
        anchorElapsed + max(0, host - anchorHost - latency) * Double(rate)
    }

    private func readLatency(force: Bool = false) {
        let now = CACurrentMediaTime()
        guard force || now - latencyRead > 1 else { return }
        latencyRead = now
        latency = engine.outputNode.presentationLatency + timePitch.auAudioUnit.latency
    }

    // MARK: - Transporte

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard loaded, !tracks.isEmpty, !isPlaying else { return }
        if loop == nil, anchorTime >= duration - 0.05 { anchorTime = 0 }
        startPlayers()
    }

    private func startPlayers() {
        guard loaded, !tracks.isEmpty, !isPlaying else { return }
        plan = PlaybackPlan(start: anchorTime, loop: loop, duration: duration)
        let segments = plan.segments
        guard !segments.isEmpty else { return }
        planLength = segments.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        for track in tracks.values { schedule(track, segments) }
        do {
            if !engine.isRunning { try engine.start() }
            playbackError = nil
        } catch {
            for track in tracks.values { track.player.stop() }
            playbackError = "O áudio não ligou na saída atual: \(error.localizedDescription)"
            return
        }
        readLatency(force: true)
        // Um início comum um pouco à frente, para todos os players estarem prontos no mesmo instante.
        let lead = 0.05
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: lead))
        for track in tracks.values { track.player.play(at: start) }
        anchorHost = CACurrentMediaTime() + lead
        anchorElapsed = 0
        isPlaying = true
        startTimer()
        changed()
    }

    func pause() {
        // A nota que tocava sozinha (`audition`) acaba: os players param antes de a mixagem voltar.
        defer { endAudition() }
        guard isPlaying else { return }
        anchorTime = currentTime
        isPlaying = false
        for track in tracks.values { track.player.stop() }
        stopTimer()
        changed()
    }

    /// A faixa que soa sozinha enquanto uma nota clicada toca (`audition`); nil no estudo.
    @ObservationIgnored private var auditioning: String?
    @ObservationIgnored private var auditionTask: Task<Void, Never>?
    /// Se uma nota clicada está tocando (a tela fica parada enquanto isso).
    private(set) var auditionActive = false
    /// Quando a nota clicada acaba (antes de a agulha voltar ao começo dela).
    @ObservationIgnored var onAuditionEnd: (() -> Void)?

    /// Uma nota clicada na edição: toca de `from` a `to` só a faixa `id` (a da pista; o original se ela não está
    /// carregada) e volta ao começo dela. Tocando, não faz nada (não interrompe o estudo); um play, um seek ou outro
    /// clique encerram.
    func audition(from: Double, to: Double, track id: String?) {
        guard loaded, !isPlaying, to > from else { return }
        let solo = id.flatMap { tracks[$0] == nil ? nil : $0 } ?? Self.sourceID
        seek(to: from)
        auditioning = solo
        auditionActive = true
        applyMix()
        play()
        guard isPlaying else {
            endAudition()
            return
        }
        let wait = (to - from) / Double(max(rate, 0.1)) + latency + 0.08
        auditionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled, self.auditioning != nil else { return }
            self.pause()
            self.seek(to: from)
        }
    }

    private func endAudition() {
        guard auditioning != nil else { return }
        auditioning = nil
        auditionActive = false
        auditionTask?.cancel()
        auditionTask = nil
        applyMix()
        onAuditionEnd?()
    }

    /// Depois de cada seek, de onde a música saiu e para onde foi (a tela decide se fica ou anda junto).
    @ObservationIgnored var onSeek: ((_ from: Double, _ to: Double) -> Void)?

    func seek(to seconds: Double) {
        let from = currentTime
        // Uma nota clicada que tocava sozinha acaba parada: o seek (o clique noutra nota) não vira o estudo tocando.
        let wasPlaying = isPlaying && auditioning == nil
        pause()
        anchorTime = min(max(0, seconds), duration)
        seekCount += 1
        if wasPlaying { startPlayers() } else { changed() }
        onSeek?(from, anchorTime)
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    /// Volta ao começo do loop, ou da música.
    func toStart() { seek(to: loop?.lowerBound ?? 0) }

    func stop() {
        pause()
        engine.stop()
        loaded = false
    }

    /// Agenda de novo do ponto dado, tocando (o loop mudou, ou o plano agendado está acabando).
    private func restart(at seconds: Double) {
        pause()
        anchorTime = min(max(0, seconds), duration)
        startPlayers()
    }

    private func setRate(_ value: Float) {
        let clean = Self.snap(value)
        guard clean != rateValue else { return }
        if isPlaying {
            // O que já está na fila de saída ainda soa na velocidade antiga: a âncora nova é o instante em que a
            // velocidade nova começa a ser ouvida.
            let now = CACurrentMediaTime()
            anchorElapsed = elapsed(atHost: now + latency, rate: rateValue)
            anchorHost = now
        }
        rateValue = clean
        timePitch.rate = clean
        changed()
    }

    static func snap(_ value: Float) -> Float {
        let stepped = (value / rateStep).rounded() * rateStep
        return min(max(stepped, rates.lowerBound), rates.upperBound)
    }

    // MARK: - Mix

    /// O original ou as faixas da separação (`useStems`); a TAB sintetizada soa por cima de qualquer um dos dois, no
    /// volume do mixer. Um solo vale para tudo: com alguma faixa em solo, o original também cala. `audioOn` e `tabOn`
    /// ligam e desligam cada grupo inteiro.
    private func applyMix() {
        if let auditioning {
            for (id, track) in tracks { track.player.volume = id == auditioning ? 1 : 0 }
            return
        }
        let gains = mixGains(mix)
        let soloing = mix.values.contains { $0.solo }
        for (id, track) in tracks {
            if id == Self.sourceID {
                track.player.volume = audioOn && !useStems && !soloing ? 1 : 0
            } else if id == Self.clickID {
                track.player.volume = clickOn ? 0.9 : 0
            } else if id.hasPrefix(SynthTrack.prefix) {
                track.player.volume = tabOn ? (gains[id] ?? 0) : 0
            } else {
                track.player.volume = audioOn && useStems ? (gains[id] ?? 1) : 0
            }
        }
    }

    // MARK: - Observadores (a página da partitura segue o relógio)

    func observe(_ f: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = f
        return id
    }

    func unobserve(_ id: UUID) { observers[id] = nil }

    private func changed() { observers.values.forEach { $0() } }

    // MARK: - Tique

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard isPlaying else { return }
        readLatency()
        let played = elapsed(atHost: CACurrentMediaTime(), rate: rateValue)
        if plan.ended(after: played) {
            pause()
            anchorTime = duration
            onEnded?()
            return
        }
        // Vinte minutos de loop agendados acabando: agenda mais, do ponto ouvido.
        if plan.loop != nil, played > planLength - 5 {
            restart(at: currentTime)
        }
    }

    private func schedule(_ track: Track, _ segments: [ClosedRange<Double>]) {
        track.player.stop()
        let file = track.file
        let rate = file.processingFormat.sampleRate
        for segment in segments {
            let first = AVAudioFramePosition((segment.lowerBound * rate).rounded())
            let last = min(file.length, AVAudioFramePosition((segment.upperBound * rate).rounded()))
            guard last > first else { continue }
            track.player.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(last - first), at: nil)
        }
    }
}
