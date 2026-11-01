import AppKit
import AVFoundation
import AudioToolbox
import CoreAudioKit
import CoreAudio
import Observation
import QuartzCore
import TrackLabCore

/// Um dispositivo de entrada do Core Audio (a interface, o Helix, o microfone do Mac).
struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputs: Int
    let outputs: Int

    /// Os dispositivos com entrada, na ordem do sistema.
    static func all() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            let inputs = channels(id, scope: kAudioDevicePropertyScopeInput)
            guard inputs > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return InputDevice(id: id, uid: uid, name: name, inputs: inputs,
                               outputs: channels(id, scope: kAudioDevicePropertyScopeOutput))
        }
    }

    static func defaultInput() -> AudioDeviceID? { systemDevice(kAudioHardwarePropertyDefaultInputDevice) }

    /// O UID da saída padrão do sistema.
    static func defaultOutputUID() -> String? {
        systemDevice(kAudioHardwarePropertyDefaultOutputDevice).flatMap { string($0, kAudioDevicePropertyDeviceUID) }
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// O que gravar da entrada: um par estéreo (1/2, 3/4…) ou um canal só (o DI do Helix é o 7).
struct InputChannels: Hashable, Codable {
    /// O primeiro canal, a partir de 0.
    var first: Int
    var stereo: Bool

    var count: Int { stereo ? 2 : 1 }
    var label: String { stereo ? "\(first + 1)/\(first + 2)" : "\(first + 1)" }

    static func choices(for inputs: Int) -> [InputChannels] {
        let pairs = stride(from: 0, to: inputs - 1, by: 2).map { InputChannels(first: $0, stereo: true) }
        return pairs + (0..<inputs).map { InputChannels(first: $0, stereo: false) }
    }
}

/// Um efeito AU no caminho da guitarra (o simulador de amplificador, o reverb), na ordem.
struct InputEffect: Identifiable {
    let id = UUID()
    let name: String
    let maker: String
    let unit: AVAudioUnit
    var bypass: Bool {
        get { unit.auAudioUnit.shouldBypassEffect }
        nonmutating set { unit.auAudioUnit.shouldBypassEffect = newValue }
    }
}

/// O que a gravação devolve: o arquivo bruto (tudo o que entrou do primeiro ao último quadro), o instante do
/// primeiro quadro (em tempo de host, já sem a latência da entrada) e o tamanho.
struct RawRecording {
    let url: URL
    let firstHost: Double
    let frames: Int
    let sampleRate: Double
}

/// O lado do áudio que roda fora da thread principal: o tap da entrada mede o nível, junta o som para o afinador e,
/// gravando, escreve no arquivo. Uma trava curta protege o estado.
private final class InputTap: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var firstHost: Double?
    private var frames = 0
    private var stopHost: Double?
    private var tuner: [Float] = []
    private var tunerBusy = false
    var level: Float = 0
    var onPitch: (@Sendable (Double?) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    private let analysis = DispatchQueue(label: "tracklab.tuner", qos: .userInitiated)

    func start(_ file: AVAudioFile) {
        lock.lock()
        self.file = file
        firstHost = nil
        frames = 0
        stopHost = nil
        lock.unlock()
    }

    /// Para de gravar: os quadros depois de `host` (a música parou ou saltou ali) ficam de fora.
    func stop(at host: Double?) -> (file: AVAudioFile, firstHost: Double, frames: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let file, let firstHost else {
            self.file = nil
            return nil
        }
        self.file = nil
        var count = frames
        if let host {
            count = min(count, max(0, Int(((host - firstHost) * file.processingFormat.sampleRate).rounded())))
        }
        return (file, firstHost, count)
    }

    func handle(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime, inputLatency: Double) {
        let count = Int(buffer.frameLength)
        guard count > 0, let data = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channels {
            let samples = data[channel]
            for i in 0..<count {
                let value = samples[i]
                mono[i] += value / Float(channels)
                peak = max(peak, abs(value))
            }
        }
        onLevel?(peak)
        lock.lock()
        if let file {
            if firstHost == nil {
                let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : CACurrentMediaTime()
                firstHost = host - inputLatency
            }
            try? file.write(from: buffer)
            frames += count
        }
        tuner.append(contentsOf: mono)
        let size = 4096
        if tuner.count > size * 2 { tuner.removeFirst(tuner.count - size) }
        let ready = !tunerBusy && tuner.count >= size
        let window = ready ? Array(tuner.suffix(size)) : []
        if ready { tunerBusy = true }
        lock.unlock()
        guard ready else { return }
        let rate = buffer.format.sampleRate
        analysis.async { [weak self] in
            let frequency = Tuner.frequency(window, sampleRate: rate)
            guard let self else { return }
            self.lock.lock()
            self.tunerBusy = false
            self.lock.unlock()
            self.onPitch?(frequency)
        }
    }
}

/// A entrada da guitarra: um AVAudioEngine só dela, no dispositivo escolhido (entrada e saída no mesmo, quando ele
/// tem saída: um relógio só, sem o descompasso de dois dispositivos), com os efeitos AU no caminho, o monitor (ouvir a
/// entrada pelo Mac, desligado: com o Helix, ele mesmo devolve o som sem atraso), o nível, o afinador e a gravação.
/// O tempo da gravação é o de host, o mesmo do relógio do estudo (`StemEngine.songTime(atHost:)`).
@Observable
@MainActor
final class InputEngine {
    static let shared = InputEngine()

    private(set) var devices: [InputDevice] = []
    private(set) var running = false
    private(set) var error: String?
    /// O pico da entrada (0 a 1), para o medidor.
    private(set) var level: Float = 0
    @ObservationIgnored private var levelPeak: Float = 0
    /// A frequência que soa agora (o afinador), nil em silêncio.
    private(set) var frequency: Double?
    private(set) var effects: [InputEffect] = []
    private(set) var recording = false
    /// Quando a frequência mudou (para a nota ao vivo na Lente).
    @ObservationIgnored var onPitch: ((Double?) -> Void)?

    var deviceUID: String? = UserDefaults.standard.string(forKey: "input.device") {
        didSet {
            UserDefaults.standard.set(deviceUID, forKey: "input.device")
            if running { restart() }
        }
    }
    var channels: InputChannels = {
        guard let data = UserDefaults.standard.data(forKey: "input.channels"),
              let value = try? JSONDecoder().decode(InputChannels.self, from: data) else { return InputChannels(first: 0, stereo: true) }
        return value
    }() {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(channels), forKey: "input.channels")
            if running { restart() }
        }
    }
    /// Ouvir a entrada pelo Mac (com os efeitos AU).
    var monitor = UserDefaults.standard.bool(forKey: "input.monitor") {
        didSet {
            UserDefaults.standard.set(monitor, forKey: "input.monitor")
            applyMonitor()
        }
    }
    var monitorVolume: Float = UserDefaults.standard.object(forKey: "input.monitorVolume") as? Float ?? 0.8 {
        didSet {
            UserDefaults.standard.set(monitorVolume, forKey: "input.monitorVolume")
            applyMonitor()
        }
    }
    /// Um ajuste à mão da posição dos takes, em ms (o que a latência medida não pega: o conversor do Helix).
    var offsetMS: Double = UserDefaults.standard.double(forKey: "input.offsetMS") {
        didSet { UserDefaults.standard.set(offsetMS, forKey: "input.offsetMS") }
    }

    @ObservationIgnored private var engine = AVAudioEngine()
    @ObservationIgnored private var monitorMixer = AVAudioMixerNode()
    @ObservationIgnored private let tap = InputTap()
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var tapped: AVAudioNode?
    @ObservationIgnored private var configurationObserver: NSObjectProtocol?
    /// O dispositivo agregado (a entrada escolhida com a saída padrão) que a entrada sem saída pede.
    @ObservationIgnored private var aggregate: AudioDeviceID?
    /// Os formatos do dispositivo na montagem e as últimas vezes que a configuração mudou.
    @ObservationIgnored private var builtFormats: (input: AVAudioFormat, output: AVAudioFormat)?
    @ObservationIgnored private var changes: [Date] = []

    private init() {
        devices = InputDevice.all()
        tap.onLevel = { [weak self] peak in
            Task { @MainActor in
                self?.level = max(peak, (self?.level ?? 0) * 0.8)
                self?.levelPeak = max(peak, self?.levelPeak ?? 0)
            }
        }
        tap.onPitch = { [weak self] frequency in
            Task { @MainActor in
                guard let self else { return }
                self.frequency = frequency
                self.onPitch?(frequency)
            }
        }
    }

    /// O dispositivo escolhido (o padrão do sistema se nenhum, ou se o escolhido não está ligado).
    var device: InputDevice? {
        devices.first { $0.uid == deviceUID } ?? devices.first { $0.id == InputDevice.defaultInput() } ?? devices.first
    }

    var label: String {
        guard let device else { return "Sem entrada" }
        return "\(device.name) · \(channels.label)"
    }

    /// A latência da entrada (o dispositivo e o buffer), em segundos.
    var inputLatency: Double { running ? engine.inputNode.presentationLatency : 0 }

    func refreshDevices() { devices = InputDevice.all() }

    /// Liga a entrada (pede o microfone ao macOS na primeira vez).
    func start() {
        guard !running else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            error = "Esperando a permissão do macOS para ouvir a entrada."
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.start() } else { self.error = "O macOS não deixou o TrackLab ouvir a entrada." }
                }
            }
            return
        default:
            error = "O TrackLab não tem acesso à entrada de áudio: Ajustes do Sistema › Privacidade e Segurança › Microfone."
            return
        }
        refreshDevices()
        // O Core Audio recusa umas combinações conforme o dispositivo (o mapa de canais, a saída no mesmo dispositivo):
        // tenta da mais completa à mais simples e anota no registro o que falhou.
        var failures: [String] = []
        for setup in Setup.attempts {
            do {
                try build(setup)
                try engine.start()
                running = true
                error = nil
                self.setup = setup
                log("ligou: \(label) · \(setup)" + (failures.isEmpty ? "" : " (antes: \(failures.joined(separator: "; ")))"))
                return
            } catch {
                failures.append("\(setup): \(error.localizedDescription)")
                teardown()
            }
        }
        log("não ligou: \(label) · " + failures.joined(separator: "; "))
        error = "A entrada não ligou: \(failures.last ?? "")"
    }

    /// Como a entrada foi montada: com o mapa de canais, no dispositivo escolhido ou no que o sistema dá.
    struct Setup: CustomStringConvertible {
        var map: Bool
        var chosenDevice: Bool
        static let attempts = [Setup(map: true, chosenDevice: true),
                               Setup(map: false, chosenDevice: true),
                               Setup(map: false, chosenDevice: false)]
        var description: String {
            [map ? "mapa" : "sem mapa", chosenDevice ? "dispositivo escolhido" : "dispositivo padrão"]
                .joined(separator: ", ")
        }
    }
    @ObservationIgnored private(set) var setup: Setup?

    private func log(_ text: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/TrackLab-entrada.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    func stop() {
        guard running else { return }
        if recording { _ = stopRecording(at: nil) }
        teardown()
        running = false
        level = 0
        frequency = nil
    }

    private func restart() {
        stop()
        start()
    }

    private func teardown() {
        tapped?.removeTap(onBus: 0)
        tapped = nil
        engine.stop()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        // Um motor novo: o AUHAL do motor velho fica preso ao dispositivo antigo.
        for effect in effects { engine.detach(effect.unit) }
        engine = AVAudioEngine()
        if let aggregate { AudioHardwareDestroyAggregateDevice(aggregate) }
        aggregate = nil
    }

    /// Monta a cadeia: entrada (no dispositivo e nos canais escolhidos) → efeitos → monitor → saída.
    private func build(_ setup: Setup) throws {
        guard let device else { throw InputError.noDevice }
        let input = engine.inputNode
        guard let inputUnit = input.audioUnit else { throw InputError.noDevice }
        // No Mac a entrada e a saída do motor são uma unidade só (um AUHAL): o dispositivo dela é o das duas. Um
        // dispositivo sem saída (o microfone do iMac) deixava a saída sem canais, e o motor não ligava (−10875); sem
        // escolher, a unidade fica na saída padrão e a entrada liga, mas só dá silêncio (medido em 1/11). Com saída (o
        // Helix), a entrada e o monitor ficam nele; sem saída, num agregado da entrada com a saída padrão.
        if setup.chosenDevice, var id = try ioDevice(for: device) {
            try check(AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &id, UInt32(MemoryLayout<AudioDeviceID>.size)))
        }
        // Os canais: o mapa diz de que canal do dispositivo sai cada canal que o motor recebe. Sem o mapa, os primeiros.
        let available = Int(input.inputFormat(forBus: 0).channelCount)
        var chosen = channels.first + channels.count <= max(available, 1) ? channels
            : InputChannels(first: 0, stereo: available > 1)
        // O mapa só quando muda alguma coisa: os primeiros canais são o que o dispositivo já dá.
        if setup.map, chosen.first > 0 {
            var map = (0..<chosen.count).map { Int32(chosen.first + $0) }
            _ = AudioUnitSetProperty(inputUnit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, &map,
                                     UInt32(MemoryLayout<Int32>.size * map.count))
        } else {
            chosen = InputChannels(first: 0, stereo: available > 1)
        }
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: AVAudioChannelCount(chosen.count))
        else { throw InputError.noDevice }
        self.format = format
        // Nós novos a cada montagem: um nó preso ao motor de antes não entra no novo.
        monitorMixer = AVAudioMixerNode()
        let capture = AVAudioMixerNode()
        engine.attach(monitorMixer)
        engine.attach(capture)
        var previous: AVAudioNode = input
        for effect in effects {
            engine.attach(effect.unit)
            engine.connect(previous, to: effect.unit, format: format)
            previous = effect.unit
        }
        // O que se grava sai de um nó de passagem no formato escolhido (os canais certos, depois dos efeitos).
        engine.connect(previous, to: capture, format: format)
        engine.connect(capture, to: monitorMixer, format: format)
        // O formato explícito também aqui: com nil a entrada inteira dava zero, já no tap do próprio dispositivo (medido
        // em 1/11 no Helix e no microfone, num AVAudioEngine fora do app: com o formato, o som chega).
        engine.connect(monitorMixer, to: engine.mainMixerNode, format: format)
        applyMonitor()
        let tap = self.tap
        let latency = input.presentationLatency
        capture.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, when in
            tap.handle(buffer, when, inputLatency: latency)
        }
        tapped = capture
        probeSignal(input)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.configurationChanged() }
        }
        builtFormats = (input.inputFormat(forBus: 0), engine.outputNode.outputFormat(forBus: 0))
        engine.prepare()
    }

    /// O motor para quando a configuração do dispositivo muda. Trocar o dispositivo da unidade já avisa uma mudança
    /// logo depois de ligar: remontar a cada aviso fazia a entrada do Helix religar sem parar (137 vezes em 7 s). Com
    /// os mesmos formatos basta ligar o motor de novo; com outros, remonta; muitas mudanças seguidas desligam a entrada.
    private func configurationChanged() {
        guard running else { return }
        let now = Date()
        changes = changes.filter { now.timeIntervalSince($0) < 10 } + [now]
        guard changes.count <= 5 else {
            log("a configuração mudou \(changes.count) vezes em 10 s: entrada desligada")
            stop()
            error = "O dispositivo mudou de configuração várias vezes seguidas: ligue a entrada de novo."
            return
        }
        let input = engine.inputNode.inputFormat(forBus: 0)
        let output = engine.outputNode.outputFormat(forBus: 0)
        func same(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
            a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
        }
        if let builtFormats, same(input, builtFormats.input), same(output, builtFormats.output) {
            if engine.isRunning { return }
            do {
                try engine.start()
                return
            } catch {
                log("não religou depois da mudança de configuração: \(error.localizedDescription)")
            }
        }
        log("a configuração mudou (entrada \(input), saída \(output)): remontando")
        restart()
    }

    /// O dispositivo da unidade de entrada e saída para a entrada escolhida.
    private func ioDevice(for device: InputDevice) throws -> AudioDeviceID? {
        if device.outputs > 0 { return device.id }
        guard let output = InputDevice.defaultOutputUID() else { throw InputError.noDevice }
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "local.tracklab.entrada.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "TrackLab entrada",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: device.uid, kAudioSubDeviceDriftCompensationKey: 1],
                [kAudioSubDeviceUIDKey: output],
            ],
        ]
        var id = AudioDeviceID(0)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id))
        aggregate = id
        return id
    }

    /// Anota no registro o pico do que entra (antes e depois da cadeia) nos primeiros segundos: uma entrada que liga e
    /// dá silêncio (a permissão, o dispositivo, o mapa) aparece ali.
    private func probeSignal(_ input: AVAudioInputNode) {
        final class Peak: @unchecked Sendable {
            let lock = NSLock()
            var value: Float = 0
            func add(_ buffer: AVAudioPCMBuffer) {
                guard let data = buffer.floatChannelData else { return }
                var peak: Float = 0
                for channel in 0..<Int(buffer.format.channelCount) {
                    for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[channel][i])) }
                }
                lock.lock(); value = max(value, peak); lock.unlock()
            }
            var read: Float { lock.lock(); defer { lock.unlock() }; return value }
        }
        let raw = Peak()
        levelPeak = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in raw.add(buffer) }
        let started = engine
        let format = input.inputFormat(forBus: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.engine === started else { return }
            input.removeTap(onBus: 0)
            func db(_ value: Float) -> String { value > 0 ? String(format: "%.0f dB", 20 * log10(value)) : "silêncio" }
            self.log("sinal nos 3 s: entrada \(db(raw.read)) (\(format)), depois da cadeia \(db(self.levelPeak))")
        }
    }

    private func check(_ status: OSStatus) throws {
        if status != noErr { throw InputError.coreAudio(status) }
    }

    private func applyMonitor() {
        monitorMixer.outputVolume = monitor ? monitorVolume : 0
    }

    // MARK: - Efeitos

    /// Os efeitos AU instalados (os de efeito e os de efeito com MIDI), por fabricante e nome.
    static func availableEffects() -> [AVAudioUnitComponent] {
        let manager = AVAudioUnitComponentManager.shared()
        let kinds = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        return kinds.flatMap { kind in
            manager.components(matching: AudioComponentDescription(componentType: kind, componentSubType: 0,
                                                                   componentManufacturer: 0, componentFlags: 0,
                                                                   componentFlagsMask: 0))
        }
        .filter { !$0.manufacturerName.isEmpty }
        .sorted { ($0.manufacturerName, $0.name) < ($1.manufacturerName, $1.name) }
    }

    func addEffect(_ component: AVAudioUnitComponent) async {
        do {
            let unit = try await AVAudioUnit.instantiate(with: component.audioComponentDescription, options: [])
            effects.append(InputEffect(name: component.name, maker: component.manufacturerName, unit: unit))
            if running { restart() }
            saveChain()
        } catch {
            self.error = "O efeito \(component.name) não abriu: \(error.localizedDescription)"
        }
    }

    func removeEffect(_ id: UUID) {
        effects.removeAll { $0.id == id }
        if running { restart() }
        saveChain()
    }

    func moveEffect(_ id: UUID, by step: Int) {
        guard let index = effects.firstIndex(where: { $0.id == id }) else { return }
        let target = index + step
        guard effects.indices.contains(target) else { return }
        effects.swapAt(index, target)
        if running { restart() }
        saveChain()
    }

    /// Abre a janela do efeito (a interface dele).
    func openEditor(_ effect: InputEffect) {
        effect.unit.auAudioUnit.requestViewController { controller in
            Task { @MainActor in
                guard let controller else {
                    self.error = "\(effect.name) não tem janela própria."
                    return
                }
                let window = NSWindow(contentViewController: controller)
                window.title = "\(effect.name) — \(effect.maker)"
                window.styleMask.insert(.resizable)
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
                EffectWindows.keep(window)
            }
        }
    }

    /// A cadeia de agora (cada efeito com a descrição e o estado), para guardar com o take ou entre as aberturas.
    func chainData() -> Data? {
        let list: [[String: Any]] = effects.map { effect in
            let description = effect.unit.audioComponentDescription
            var entry: [String: Any] = [
                "name": effect.name, "maker": effect.maker,
                "type": description.componentType, "subtype": description.componentSubType,
                "manufacturer": description.componentManufacturer, "bypass": effect.bypass,
            ]
            if let state = effect.unit.auAudioUnit.fullState { entry["state"] = state }
            return entry
        }
        return try? PropertyListSerialization.data(fromPropertyList: list, format: .binary, options: 0)
    }

    /// Troca a cadeia pela guardada (a de um take, ou a da última vez).
    func loadChain(_ data: Data) async {
        guard let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else { return }
        var loaded: [InputEffect] = []
        for entry in list {
            guard let type = entry["type"] as? UInt32, let subtype = entry["subtype"] as? UInt32,
                  let manufacturer = entry["manufacturer"] as? UInt32 else { continue }
            let description = AudioComponentDescription(componentType: type, componentSubType: subtype,
                                                        componentManufacturer: manufacturer, componentFlags: 0,
                                                        componentFlagsMask: 0)
            guard let unit = try? await AVAudioUnit.instantiate(with: description, options: []) else {
                error = "\(entry["name"] as? String ?? "Um efeito") não está instalado."
                continue
            }
            if let state = entry["state"] as? [String: Any] { unit.auAudioUnit.fullState = state }
            unit.auAudioUnit.shouldBypassEffect = entry["bypass"] as? Bool ?? false
            loaded.append(InputEffect(name: entry["name"] as? String ?? "Efeito", maker: entry["maker"] as? String ?? "",
                                      unit: unit))
        }
        effects = loaded
        if running { restart() }
        saveChain()
    }

    func setBypass(_ id: UUID, _ value: Bool) {
        effects.first { $0.id == id }?.bypass = value
        saveChain()
    }

    private func saveChain() {
        UserDefaults.standard.set(chainData(), forKey: "input.chain")
    }

    /// A cadeia da última vez, ao abrir o app.
    func restoreChain() async {
        guard effects.isEmpty, let data = UserDefaults.standard.data(forKey: "input.chain") else { return }
        await loadChain(data)
    }

    // MARK: - Gravação

    /// Começa a gravar num arquivo temporário (tudo o que entra; o corte em takes é depois).
    func startRecording() throws {
        guard running, let format else { throw InputError.notRunning }
        let url = FileManager.default.temporaryDirectory.appending(path: "tracklab-take-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        tap.start(file)
        recording = true
    }

    /// Para de gravar; `host`: o instante em que a música parou ou saltou (o que veio depois fica de fora).
    func stopRecording(at host: Double?) -> RawRecording? {
        guard recording else { return nil }
        recording = false
        guard let done = tap.stop(at: host) else { return nil }
        return RawRecording(url: done.file.url, firstHost: done.firstHost, frames: done.frames,
                            sampleRate: done.file.processingFormat.sampleRate)
    }
}

enum InputError: LocalizedError {
    case noDevice
    case notRunning
    case coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDevice: "nenhum dispositivo de entrada."
        case .notRunning: "a entrada está desligada."
        case let .coreAudio(status): "o Core Audio recusou (\(status))."
        }
    }
}

/// As janelas dos efeitos abertas (sem isso, a janela fecha ao sair do escopo).
@MainActor
enum EffectWindows {
    private static var windows: [NSWindow] = []

    static func keep(_ window: NSWindow) {
        windows.removeAll { !$0.isVisible }
        windows.append(window)
    }
}
