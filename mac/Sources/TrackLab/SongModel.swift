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
    private(set) var notice: String?
    /// A separação em curso (o id da tarefa e a última mensagem dela).
    private(set) var separating: (job: String, message: String, progress: Double?)?

    var preset: MixPreset? { MixPreset.matching(engine.mix, stems: engine.stemIDs) }

    init(id: String) {
        self.id = id
        bridge = ScoreBridge(engine: engine)
        bridge.onLoaded = { [weak self] tracks, ticks in
            guard let self else { return }
            scoreTracks = tracks
            grid = TempoGrid(points: grid.points, barTicks: ticks)
        }
        bridge.onRendered = { [weak self] _ in self?.scoreMessage = nil }
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
            if let map = try await Backend.shared.tempoMap(id) { grid = TempoGrid(points: map.points) }
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
