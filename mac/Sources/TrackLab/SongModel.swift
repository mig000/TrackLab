import Foundation
import Observation
import TrackLabCore

/// Uma música aberta para estudo: o manifesto, o mapa de tempo, as ondas da Fita, o áudio carregado no motor de
/// áudio e a partitura na página. A separação, se faltar, é pedida daqui.
@Observable
@MainActor
final class SongModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    let id: String
    let engine = StemEngine()
    @ObservationIgnored private(set) var bridge: ScoreBridge!

    private(set) var phase: Phase = .loading
    private(set) var detail: SongDetail?
    private(set) var grid = TempoGrid(points: [])
    private(set) var sourcePeaks: Peaks?
    private(set) var guitarPeaks: Peaks?
    /// As pistas da partitura como a página as leu.
    private(set) var scoreTracks: [ScoreBridge.PageTrack] = []
    var scoreTrack = 0 {
        didSet { if scoreTrack != oldValue { bridge.showTrack(scoreTrack) } }
    }
    private(set) var scoreMessage: String?
    /// A altura da pauta desenhada: a partitura não ganha mais que isso e o resto vai para a Fita.
    private(set) var scoreHeight: Double?
    private(set) var notice: String?
    /// A separação em curso (o id da tarefa e a última mensagem dela).
    private(set) var separating: (job: String, message: String, progress: Double?)?

    /// O modo Ajuste: a Fita mostra as batidas para arrastar e U põe o 1 no toque.
    var adjusting = false
    /// O mapa de tempo como o motor o gravou; os gestos do Ajuste partem dele.
    private(set) var tempoMap: TempoMapDocument?
    /// O que o último gesto recusado disse (some no próximo que der certo).
    private(set) var adjustMessage: String?
    private(set) var saving = false
    private var undoStack: [TempoMapDocument] = []
    private var redoStack: [TempoMapDocument] = []
    var canUndo: Bool { !undoStack.isEmpty && !saving }
    var canRedo: Bool { !redoStack.isEmpty && !saving }
    var anchorCount: Int { grid.points.filter(\.isAnchor).count }

    var preset: MixPreset? { MixPreset.matching(engine.mix, stems: engine.stemIDs) }

    init(id: String) {
        self.id = id
        bridge = ScoreBridge(engine: engine)
        bridge.onLoaded = { [weak self] tracks, ticks in
            guard let self else { return }
            scoreTracks = tracks
            grid = TempoGrid(points: grid.points, barTicks: ticks)
        }
        bridge.onRendered = { [weak self] _, height in
            self?.scoreMessage = nil
            if let height, height > 0 { self?.scoreHeight = height }
        }
        bridge.onError = { [weak self] text in self?.scoreMessage = text }
    }

    func close() {
        engine.stop()
        bridge.close()
    }

    func load() async {
        phase = .loading
        do {
            let detail = try await Backend.shared.song(id)
            self.detail = detail
            if let map = try await Backend.shared.tempoMap(id) {
                tempoMap = map
                grid = TempoGrid(points: map.points)
            }
            try loadAudio(detail)
            loadScore(detail)
            phase = .ready
            await loadPeaks(detail)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadAudio(_ detail: SongDetail) throws {
        var files: [(id: String, url: URL)] = []
        if let audio = detail.audio { files.append((StemEngine.sourceID, detail.url(audio.file))) }
        let active = detail.active?.files ?? [:]
        for stem in Stem.allCases {
            if let file = active[stem.rawValue] { files.append((stem.rawValue, detail.url(file))) }
        }
        guard !files.isEmpty else {
            notice = "Esta música não tem áudio: só a partitura."
            return
        }
        try engine.load(files)
        if !active.isEmpty {
            engine.useStems = true
            // Abre pronta para tocar junto: a banda sem a guitarra.
            engine.mix = MixPreset.noGuitar.apply(to: engine.mix, stems: engine.stemIDs)
        } else {
            engine.useStems = false
        }
    }

    private func loadScore(_ detail: SongDetail) {
        guard let score = detail.score else {
            scoreMessage = "Esta música não tem partitura."
            return
        }
        do {
            let data = try Data(contentsOf: detail.url(score.file))
            let first = score.tracks.first(where: \.isGuitar)?.index ?? 0
            scoreTrack = first
            bridge.load(gp: data, track: first, points: grid.points)
        } catch {
            scoreMessage = "Não consegui ler a partitura: \(error.localizedDescription)"
        }
    }

    private func loadPeaks(_ detail: SongDetail) async {
        if detail.audio != nil { sourcePeaks = try? await Backend.shared.peaks(id) }
        if detail.active?.files[Stem.guitar.rawValue] != nil {
            guitarPeaks = try? await Backend.shared.peaks(id, stem: Stem.guitar.rawValue)
        }
    }

    // MARK: - Mixer

    func apply(_ preset: MixPreset) {
        engine.mix = preset.apply(to: engine.mix, stems: engine.stemIDs)
    }

    func setVolume(_ stem: String, _ volume: Float) {
        engine.mix[stem, default: StemMix()].volume = volume
    }

    func toggleMute(_ stem: String) {
        engine.mix[stem, default: StemMix()].muted.toggle()
    }

    func toggleSolo(_ stem: String) {
        engine.mix[stem, default: StemMix()].solo.toggle()
    }

    // MARK: - Loop

    func setLoop(_ range: ClosedRange<Double>?) {
        engine.loop = range
        bridge.setLoop(range)
    }

    /// L: o compasso que toca vira o loop; de novo, solta.
    func toggleBarLoop() {
        if engine.loop != nil {
            setLoop(nil)
        } else {
            setLoop(LoopRegion.bar(containing: engine.currentTime, grid: grid))
        }
    }

    // MARK: - Ajuste

    /// Leva a batida do `tick` até `seconds` como âncora: as vizinhas acompanham até 8 batidas ou até a próxima âncora.
    func moveBeat(tick: Double, to seconds: Double) {
        edit(.init(action: "move", tick: tick, seconds: seconds))
    }

    /// Duplo clique: uma âncora se solta (fica onde está); uma batida solta vira âncora onde está.
    func toggleAnchor(_ point: TempoPoint) {
        edit(.init(action: point.isAnchor ? "release" : "move", tick: point.tick, seconds: point.isAnchor ? nil : point.seconds))
    }

    /// U, "o 1 é aqui": o início de compasso mais perto do que se ouve agora vai até este instante.
    func downbeatHere() {
        let now = engine.currentTime
        guard let tick = grid.nearestBarTick(now) else { return }
        moveBeat(tick: tick, to: now)
    }

    func undo() {
        guard canUndo, let current = tempoMap, let previous = undoStack.popLast() else { return }
        replace(with: previous) { [self] in redoStack.append(current) } failed: { [self] in undoStack.append(previous) }
    }

    func redo() {
        guard canRedo, let current = tempoMap, let next = redoStack.popLast() else { return }
        replace(with: next) { [self] in undoStack.append(current) } failed: { [self] in redoStack.append(next) }
    }

    /// Um gesto por vez: o motor aplica ao mapa gravado e devolve o novo, que entra no Desfazer.
    private func edit(_ gesture: Backend.TempoGesture) {
        guard !saving, let before = tempoMap else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let map = try await Backend.shared.editTempo(id, gesture)
                undoStack.append(before)
                redoStack.removeAll()
                show(map)
            } catch {
                adjustMessage = error.localizedDescription
            }
        }
    }

    private func replace(with map: TempoMapDocument, done: @escaping () -> Void, failed: @escaping () -> Void) {
        saving = true
        Task {
            defer { saving = false }
            do {
                show(try await Backend.shared.putTempo(id, map))
                done()
            } catch {
                failed()
                adjustMessage = error.localizedDescription
            }
        }
    }

    /// O mapa novo na Fita, no relógio do compasso e na partitura (que se redesenha na escala nova).
    private func show(_ map: TempoMapDocument) {
        adjustMessage = nil
        tempoMap = map
        grid = TempoGrid(points: map.points, barTicks: grid.barTicks)
        bridge.setTempo(map.points)
    }

    // MARK: - Separação

    func separate() async {
        guard separating == nil else { return }
        do {
            let ticket = try await Backend.shared.separate(id)
            separating = (ticket.id, "Na fila…", nil)
            while true {
                try await Task.sleep(for: .milliseconds(500))
                let job = try await Backend.shared.job(ticket.id)
                separating = (ticket.id, job.last?.message ?? "Separando…", job.last?.progress)
                guard job.finished else { continue }
                separating = nil
                if job.status == "done" {
                    let position = engine.currentTime
                    await load()
                    engine.seek(to: position)
                } else {
                    notice = job.error ?? "A separação não terminou."
                }
                return
            }
        } catch {
            separating = nil
            notice = error.localizedDescription
        }
    }
}
