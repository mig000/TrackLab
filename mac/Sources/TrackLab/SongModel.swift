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
    var adjusting = false {
        didSet { bridge.setAdjusting(adjusting) }
    }
    /// ⇧ + arrastar em curso: quanto a onda da Fita andou sob as linhas paradas, em segundos.
    private(set) var soundShift = 0.0
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
    // O estudo (Fase 3): o estado da música, os trechos com meta e o treino de velocidade no trecho ativo.
    private(set) var status: StudyStatus = .want
    private(set) var sections: [StudySection] = []
    private(set) var activeSectionID: String?
    /// As seções marcadas no Guitar Pro (Intro, Verse 1…), para criar trechos de uma vez.
    private(set) var markers: [(tick: Double, name: String)] = []
    private(set) var streak = 0
    private(set) var trainingMessage: String?
    @ObservationIgnored private var trainer = SpeedTrainer()
    /// Avisa a lista (a barra lateral e o Para hoje) quando o estado, os trechos ou o treino mudam.
    @ObservationIgnored var onStudyChange: (() -> Void)?
    /// O trecho a abrir quando a música carregar (vindo do Para hoje).
    @ObservationIgnored var startSection: String?

    var activeSection: StudySection? { sections.first { $0.id == activeSectionID } }

    /// Os compassos (a partir de 1) já conferidos no Ajuste.
    private(set) var checkedBars: Set<Int> = []
    var barCount: Int { max(0, grid.bars.count - 1) }
    /// Bater junto: os toques do trecho em curso, em segundos ouvidos.
    private(set) var taps: [Double] = []
    @ObservationIgnored private var tapsEnd: Task<Void, Never>?

    var preset: MixPreset? { MixPreset.matching(engine.mix, stems: engine.stemIDs) }

    init(id: String) {
        self.id = id
        bridge = ScoreBridge(engine: engine)
        bridge.onLoaded = { [weak self] tracks, ticks, markers in
            guard let self else { return }
            scoreTracks = tracks
            grid = TempoGrid(points: grid.points, barTicks: ticks)
            self.markers = markers
        }
        bridge.onRendered = { [weak self] _, height in
            self?.scoreMessage = nil
            if let height, height > 0 { self?.scoreHeight = height }
        }
        bridge.onError = { [weak self] text in self?.scoreMessage = text }
        bridge.onShift = { [weak self] seconds in self?.soundShift = seconds }
        bridge.onShiftEnd = { [weak self] seconds in
            self?.soundShift = 0
            self?.alignBeat(shiftedBy: seconds)
        }
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
            checkedBars = Set(detail.checkedBars)
            status = detail.status
            sections = detail.sections
            if let map = try await Backend.shared.tempoMap(id) {
                tempoMap = map
                grid = TempoGrid(points: map.points)
            }
            try loadAudio(detail)
            loadScore(detail)
            phase = .ready
            if let start = startSection, let section = sections.first(where: { $0.id == start }) { activate(section) }
            startSection = nil
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

    // MARK: - Rolagem

    /// Dois dedos ou a roda do mouse sobre a TAB ou a Fita: a música anda o deslocamento, na escala da tela (`span`
    /// segundos em `width` pontos), como se a fita fosse puxada. Tocando, pausa: rolar é para conferir.
    func scrub(dx: Double, dy: Double, width: Double, span: Double) {
        let delta = abs(dx) >= abs(dy) ? dx : dy
        guard delta != 0, width > 0 else { return }
        if engine.isPlaying { engine.pause() }
        engine.seek(to: engine.currentTime - delta / width * span)
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
            activeSectionID = nil
        } else {
            setLoop(LoopRegion.bar(containing: engine.currentTime, grid: grid))
        }
    }

    // MARK: - Estudo

    func setStatus(_ value: StudyStatus) {
        let before = status
        status = value
        Task {
            do {
                status = try await Backend.shared.setStatus(id, value)
                onStudyChange?()
            } catch {
                status = before
                notice = error.localizedDescription
            }
        }
    }

    /// "+ Trecho do loop": o loop vira um trecho de estudo (nos tiques da partitura) e fica ativo.
    func addSectionFromLoop() {
        guard let loop = engine.loop, !grid.isEmpty else { return }
        let from = grid.tick(at: loop.lowerBound).rounded()
        let to = grid.tick(at: loop.upperBound).rounded()
        save(sections + [StudySection(name: "Trecho \(sections.count + 1)", from: from, to: to)], select: (from, to))
    }

    /// Um trecho por seção marcada no Guitar Pro, de uma seção até a seguinte (a última até o fim).
    func addSectionsFromMarkers() {
        guard let end = grid.barTicks.last else { return }
        var made: [StudySection] = []
        for (index, marker) in markers.enumerated() {
            let to = index + 1 < markers.count ? markers[index + 1].tick : end
            if to > marker.tick { made.append(StudySection(name: marker.name, from: marker.tick, to: to)) }
        }
        save(sections + made)
    }

    func rename(_ section: StudySection, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        save(sections.map { $0.id == section.id ? StudySection(id: $0.id, name: clean, from: $0.from, to: $0.to, goal: $0.goal) : $0 })
    }

    func setGoal(_ section: StudySection, _ goal: Int) {
        save(sections.map { $0.id == section.id ? StudySection(id: $0.id, name: $0.name, from: $0.from, to: $0.to, goal: goal) : $0 })
    }

    func delete(_ section: StudySection) {
        if activeSectionID == section.id { deactivateSection() }
        save(sections.filter { $0.id != section.id })
    }

    private func save(_ list: [StudySection], select range: (Double, Double)? = nil) {
        Task {
            do {
                sections = try await Backend.shared.putSections(id, list)
                if let range, let made = sections.first(where: { $0.from == range.0 && $0.to == range.1 }) { activate(made) }
                onStudyChange?()
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// Um trecho ativo: o loop nos compassos dele, a música no começo e a velocidade no recorde (ou 70 %).
    func activate(_ section: StudySection) {
        guard !grid.isEmpty else { return }
        activeSectionID = section.id
        let range = grid.seconds(at: section.from)...grid.seconds(at: section.to)
        setLoop(range)
        if !engine.isPlaying { engine.seek(to: range.lowerBound) }
        engine.rate = Float(section.startRate) / 100
        trainer.reset()
        streak = 0
        trainingMessage = nil
    }

    func deactivateSection() {
        activeSectionID = nil
        setLoop(nil)
        trainingMessage = nil
        streak = 0
    }

    /// Limpo! (⏎): uma passada sem erro na velocidade de agora. Três seguidas sobem 5 %, até a meta; o recorde fica
    /// no pacote.
    func markClean() {
        guard let section = activeSection, let sectionID = section.id else { return }
        let rate = Int((engine.rate * 100).rounded())
        let next = trainer.clean(rate: rate, goal: section.goal)
        streak = trainer.streak
        if let next {
            engine.rate = Float(next) / 100
            trainingMessage = "Três limpos a \(rate) %: agora \(next) %"
        } else if rate >= section.goal {
            trainingMessage = "Limpo na meta (\(rate) %)"
        } else {
            trainingMessage = "Limpo \(streak) de \(SpeedTrainer.streakToRise) a \(rate) %"
        }
        Task {
            do {
                let saved = try await Backend.shared.practice(id, section: sectionID, rate: rate, clean: true)
                if let index = sections.firstIndex(where: { $0.id == sectionID }) {
                    sections[index].best = saved.best
                    sections[index].practiced = saved.practiced
                }
                onStudyChange?()
            } catch {
                trainingMessage = error.localizedDescription
            }
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

    /// T, bater junto: um toque por batida, com a música tocando. Quando os toques param (ou o loop volta ao início),
    /// o trecho é regravado por eles.
    func tap() {
        guard engine.isPlaying else {
            adjustMessage = "Para bater junto, toque a música e aperte T em cada batida."
            return
        }
        let now = engine.currentTime
        if let last = taps.last {
            if now <= last {
                finishTaps()  // o loop voltou: o trecho anterior fecha e este começa outro
            } else if now - last < 0.1 {
                return  // a tecla segurada repete: não é outra batida
            }
        }
        taps.append(now)
        adjustMessage = nil
        // Espera duas batidas e meia sem toque (no mínimo 1,5 s) antes de aplicar.
        let gaps = zip(taps, taps.dropFirst()).map { $1 - $0 }.sorted()
        let wait = max(1.5, (gaps.isEmpty ? 0 : gaps[gaps.count / 2]) * 2.5)
        tapsEnd?.cancel()
        tapsEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.finishTaps()
        }
    }

    private func finishTaps() {
        tapsEnd?.cancel()
        let list = taps
        taps = []
        guard list.count >= 4 else {
            if !list.isEmpty { adjustMessage = "Bata ao menos 4 vezes, uma em cada batida." }
            return
        }
        edit(.init(action: "tap", taps: list))
    }

    /// Metade e Dobro: menos ou mais batidas no mapa, sem mudar o tempo (o passo do arrasto e do Bater junto).
    func halveBeats() { edit(.init(action: "half")) }
    /// Atraso do vídeo: o mapa inteiro `seconds` para frente (positivo) ou para trás.
    func shiftAll(by seconds: Double) { edit(.init(action: "offset", seconds: seconds)) }
    func doubleBeats() { edit(.init(action: "double")) }

    /// Os compassos do trecho a conferir: os do loop, ou o que está tocando.
    var currentBars: [Int] {
        let starts = grid.bars
        guard starts.count >= 2 else { return [] }
        if let loop = engine.loop {
            let inside = (0..<(starts.count - 1)).filter { starts[$0] >= loop.lowerBound - 0.01 && starts[$0] < loop.upperBound - 0.01 }
            if !inside.isEmpty { return inside.map { $0 + 1 } }
        }
        return grid.bar(at: engine.currentTime).map { [$0] } ?? []
    }

    /// Trecho conferido: marca os compassos do trecho (o loop, ou o que toca); se já estavam todos, desmarca.
    func toggleChecked() {
        let bars = currentBars
        guard !bars.isEmpty else { return }
        var next = checkedBars
        if bars.allSatisfy(next.contains) { next.subtract(bars) } else { next.formUnion(bars) }
        let before = checkedBars
        checkedBars = next
        Task {
            do {
                checkedBars = Set(try await Backend.shared.putChecked(id, bars: next.sorted()))
            } catch {
                checkedBars = before
                adjustMessage = error.localizedDescription
            }
        }
    }

    /// Recomeça o Ajuste: o mapa volta a ser o do Songsterr; o atual vai para o histórico do pacote e para o Desfazer.
    func restartFromSongsterr() {
        guard !saving, let current = tempoMap else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let original = try await Backend.shared.originalTempo(id)
                show(try await Backend.shared.putTempo(id, original))
                undoStack.append(current)
                redoStack.removeAll()
            } catch {
                adjustMessage = error.localizedDescription
            }
        }
    }

    /// ⇧ + arrastar, ao soltar: a onda andou `shift` segundos sob a linha parada, então o som que ficou sob ela é o
    /// desta posição da TAB. A batida mais perto do cursor anda o mesmo para trás e vira âncora.
    func alignBeat(shiftedBy shift: Double) {
        guard adjusting, let point = grid.point(nearTick: grid.tick(at: engine.currentTime)) else { return }
        moveBeat(tick: point.tick, to: point.seconds - shift)
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
