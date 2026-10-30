import CoreGraphics
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
    /// A maior amplitude do original (ou da guitarra, sem ele): a borda da faixa da Onda.
    var waveLoudest: Float { loudestCache ?? 1 }
    @ObservationIgnored private var loudestCache: Float?
    /// As pistas da partitura como a página as leu.
    private(set) var scoreTracks: [ScoreBridge.PageTrack] = []
    var scoreTrack = 0 {
        didSet {
            guard scoreTrack != oldValue else { return }
            if scoreOthers.contains(scoreTrack) { scoreOthers.removeAll { $0 == scoreTrack } }
            bridge.showTrack(scoreTrack)
            measureLater()
            Task { await loadSpectrum() }
        }
    }
    /// As outras pistas embaixo da principal (a base, o baixo, a bateria…), quantas quiser, nos mesmos compassos.
    var scoreOthers: [Int] = [] {
        didSet {
            guard scoreOthers != oldValue else { return }
            bridge.showOthers(scoreOthers)
            measureLater()
        }
    }

    /// A principal e as outras pistas à vista, nessa ordem (as que a Lente desenha e mede).
    var shownTracks: [Int] { [scoreTrack] + scoreOthers.filter { $0 != scoreTrack } }
    private(set) var scoreMessage: String?
    /// A altura da pauta desenhada: a partitura não ganha mais que isso e o resto vai para a Fita.
    private(set) var scoreHeight: Double?
    private(set) var notice: String?
    /// A separação em curso (o id da tarefa, o que ela faz e a última mensagem).
    private(set) var stemJob: (job: String, request: StemRequest, message: String, progress: Double?)?
    /// A TAB sintetizada ficou para trás: o mapa de tempo mudou depois dela (o motor diz ao abrir; o Ajuste, depois).
    var synthOutdated: Bool { synthChanged || detail?.synth?.stale == true }
    /// Por que a síntese automática (ao abrir) não saiu; fica na linha TAB do mixer, sem aviso no cabeçalho.
    private(set) var synthMessage: String?
    private var synthChanged = false
    /// A multitrack da biblioteca que é esta música (para "Faixas da multitrack").
    private(set) var multitrack: MultitrackSong?
    private(set) var mvsepUsage: MVSEPUsage?
    /// O outro lado do A/B: a separação que estava tocando antes, ou a nova que acabou de chegar.
    private(set) var compareKey: String?

    /// A edição da TAB (⌘E): um clique escolhe a nota; teclas e a paleta mudam casa, corda e articulações; o Guitar Pro
    /// editado é gravado no pacote (o original fica). Saindo, a TAB sintetizada é refeita se a partitura mudou.
    var editingTab = false {
        didSet {
            guard editingTab != oldValue else { return }
            if editingTab { adjusting = false }
            bridge.setEditing(editingTab)
            if !editingTab, synthOutdated { Task { await synthesize(quiet: true) } }
        }
    }
    private(set) var tabSelection: TabSelection?
    private(set) var canUndoTab = false
    private(set) var canRedoTab = false
    private(set) var tabMessage: String?

    /// O modo Ajuste: a Fita mostra as batidas para arrastar e U põe o 1 no toque.
    var adjusting = false {
        didSet {
            if adjusting { editingTab = false }
            bridge.setAdjusting(adjusting)
            // Saindo do Ajuste com o mapa mudado, a TAB sintetizada é refeita em segundo plano.
            if oldValue, !adjusting, synthOutdated { Task { await synthesize(quiet: true) } }
        }
    }
    /// A Fita mostra a onda ou o espectro (com as notas da TAB por cima).
    /// As camadas da tela embaixo da TAB, cada uma à vista ou não (guardado entre as músicas e as aberturas): a Onda e
    /// a Lente (o espectro com as notas, que mede as curvas).
    /// A TAB em páginas (ler a música de cima para baixo, com o cursor na batida) ou na faixa da Fita (guardado).
    /// A janela da Fita e da TAB (`LoopView`): onde a agulha fica na largura (0,4 de início) e, com um loop que cabe,
    /// onde a tela para enquanto a música está nele. Só mudam num evento, escolhidas para a tela ficar onde estava.
    private(set) var playheadAt = 0.4
    private(set) var loopPin: Double?
    /// A tela que o próximo seek deve manter (um clique, um loop marcado nela); sem ela, a tela anda junto com o seek.
    @ObservationIgnored private var keepView: Double?

    /// Os segundos na largura da Fita e da TAB (o zoom); no zoom a agulha fica onde está.
    @ObservationIgnored var span = 10.0 {
        didSet {
            guard span != oldValue, span > 0 else { return }
            let now = engine.currentTime
            let view = LoopView.start(now: now, loop: engine.loop, span: oldValue, at: playheadAt, pin: loopPin)
            place(at: (now - view) / oldValue, now: now)
        }
    }

    /// O começo da tela (Fita e TAB) com a música em `now`.
    func viewStart(now: Double) -> Double {
        LoopView.start(now: now, loop: engine.loop, span: span, at: playheadAt, pin: loopPin)
    }

    private func place(at: Double, now: Double) {
        playheadAt = min(1, max(0, at))
        loopPin = LoopView.pin(now: now, loop: engine.loop, span: span, at: playheadAt)
        bridge.setView(at: playheadAt, pin: loopPin)
    }

    /// Leva a música até `seconds` com a agulha em `at` da largura (o lugar do clique): a tela fica onde está.
    func seek(to seconds: Double, at fraction: Double) {
        keepView = seconds - span * fraction
        engine.seek(to: max(0, seconds))
    }

    /// Depois de todo seek: a tela fica (um clique, um loop marcado nela) ou anda junto com a música, a agulha no mesmo
    /// lugar (a rolagem, as teclas). Um seek para fora da tela (um trecho, uma nota longe) põe a agulha no lugar dela.
    private func seeked(from: Double, to: Double) {
        let view = keepView ?? viewStart(now: from) + (to - from)
        keepView = nil
        let at = (to - view) / span
        place(at: at >= 0 && at <= 1 ? at : playheadAt, now: to)
    }

    var scorePage = UserDefaults.standard.bool(forKey: "scorePage") {
        didSet {
            UserDefaults.standard.set(scorePage, forKey: "scorePage")
            bridge.showPage(scorePage)
        }
    }
    var waveVisible = UserDefaults.standard.object(forKey: "waveVisible") as? Bool ?? true {
        didSet { UserDefaults.standard.set(waveVisible, forKey: "waveVisible") }
    }
    var lensVisible = UserDefaults.standard.bool(forKey: "lensVisible") {
        didSet {
            UserDefaults.standard.set(lensVisible, forKey: "lensVisible")
            if lensVisible { Task { await loadSpectrum() } }
            measureLater()
        }
    }
    /// O espectro da guitarra separada (ou do original) e a imagem dele, feitos uma vez por música.
    private(set) var spectrum: Spectrum?
    @ObservationIgnored private(set) var spectrumImage: CGImage?
    private(set) var spectrumMessage: String?
    /// Z: a janela de alturas do espectro em volta da nota que toca (de 2 semitons abaixo a 6 acima, para ver o bend).
    var pitchZoom = false
    /// As curvas de altura do som, por nota (`curveKey`), já com o encaixe (`SoundNote`: altura, bend, vibrato); chegam
    /// aos poucos, pedidas pelas notas que aparecem.
    @ObservationIgnored private(set) var soundNotes: [String: SoundNote] = [:]
    @ObservationIgnored private var curvesAsked: Set<String> = []
    /// Muda quando chega uma curva: a Fita desenha de novo.
    private(set) var pitchCurvesVersion = 0
    /// A janela de alturas do espectro na Fita (desliza até a das notas do trecho).
    @ObservationIgnored let pitchWindow = PitchWindow()
    /// As notas de cada pista da partitura (pelo índice da pista), para as barras sobre o espectro.
    private(set) var scoreNotes: [[ScoreNote]] = [] {
        didSet {
            notesVersion += 1
            measureLater()
        }
    }
    /// Muda com as notas e com o mapa (as chaves das curvas levam o tempo da nota): a lista de suspeitas se refaz.
    @ObservationIgnored private var notesVersion = 0
    @ObservationIgnored private var suspectCache: (key: [Int], list: [(note: ScoreNote, reasons: [SoundDisagreement])])?

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
        engine.onSeek = { [weak self] from, to in self?.seeked(from: from, to: to) }
        bridge.onLoaded = { [weak self] tracks, ticks, markers, notes in
            guard let self else { return }
            scoreTracks = tracks
            Task { await self.loadSpectrum() }
            self.refreshClick(force: true)
            grid = TempoGrid(points: grid.points, barTicks: ticks)
            self.markers = markers
            scoreNotes = notes
            bridge.setDurations(showDurations, grid: gridTicks)
        }
        bridge.onRendered = { [weak self] _, height in
            self?.scoreMessage = nil
            if let height, height > 0 { self?.scoreHeight = height }
        }
        bridge.onError = { [weak self] text in self?.scoreMessage = text }
        bridge.onNotice = { [weak self] text in self?.tabMessage = text }
        bridge.onSeek = { [weak self] seconds, at in self?.seek(to: seconds, at: at) }
        // O loop arrastado na pauta: preso nas batidas, como o arrastado na Fita.
        bridge.onLoop = { [weak self] start, end in
            guard let self, let range = LoopRegion.snapped(start, end, grid: grid, duration: engine.duration) else { return }
            setLoop(range, seekToStart: true)
        }
        bridge.onShift = { [weak self] seconds in self?.soundShift = seconds }
        bridge.onSelection = { [weak self] note, undo, redo in
            self?.tabSelection = note
            self?.canUndoTab = undo
            self?.canRedoTab = redo
        }
        bridge.onSave = { [weak self] data in self?.saveScore(data) }
        bridge.onNotes = { [weak self] notes in self?.scoreNotes = notes }
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
            try loadAudio(detail, keepMix: false)
            loadScore(detail)
            // Com mais de uma separação guardada, o A/B já abre pronto: a seguinte na escada.
            if compareKey == nil, let active = detail.activeStems {
                let keys = detail.stemKeys
                compareKey = keys.first { $0 != active && (keys.firstIndex(of: $0) ?? 0) > (keys.firstIndex(of: active) ?? 0) }
                    ?? keys.first { $0 != active }
            }
            phase = .ready
            Task { await loadSources() }
            // A TAB sintetizada é feita em segundo plano ao abrir (ou refeita, se o mapa mudou depois dela).
            if detail.score != nil, detail.tempoMap != nil, detail.audio != nil,
               detail.synth == nil || detail.synth?.stale == true {
                Task { await synthesize(quiet: true) }
            }
            if let start = startSection, let section = sections.first(where: { $0.id == start }) { activate(section) }
            startSection = nil
            await loadPeaks(detail)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadAudio(_ detail: SongDetail, keepMix: Bool) throws {
        var files: [(id: String, url: URL)] = []
        if let audio = detail.audio { files.append((StemEngine.sourceID, detail.url(audio.file))) }
        let active = detail.active?.files ?? [:]
        for stem in Stem.allCases {
            if let file = active[stem.rawValue] { files.append((stem.rawValue, detail.url(file))) }
        }
        for (id, track) in detail.synth?.ids ?? [] {
            files.append((id, detail.url(track.file)))
        }
        guard !files.isEmpty else {
            notice = "Esta música não tem áudio: só a partitura."
            return
        }
        let preset = preset
        try engine.load(files)
        // A recarga tira todas as faixas, o metrônomo junto.
        refreshClick(force: true)
        // A TAB sintetizada chega com todas as faixas abertas, mas o grupo desligado (o botão TAB do mixer liga).
        for id in engine.synthIDs where engine.mix[id] == nil {
            engine.mix[id] = StemMix(volume: 0.8)
        }
        if active.isEmpty {
            engine.useStems = false
        } else if keepMix {
            // A/B: a mesma escuta na separação nova (o atalho de antes vale para as faixas que ela tem, a Base inclusa).
            if let preset { apply(preset) }
        } else {
            engine.useStems = true
            // Abre pronta para tocar junto: a banda sem a guitarra.
            engine.mix = MixPreset.noGuitar.apply(to: engine.mix, stems: engine.stemIDs)
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
            bridge.load(gp: data, track: first, points: grid.points, page: scorePage)
        } catch {
            scoreMessage = "Não consegui ler a partitura: \(error.localizedDescription)"
        }
    }

    private func loadPeaks(_ detail: SongDetail) async {
        if detail.audio != nil { sourcePeaks = try? await Backend.shared.peaks(id) }
        loudestCache = sourcePeaks.map(\.loudest)
        await loadGuitarPeaks(detail)
    }

    private func loadGuitarPeaks(_ detail: SongDetail) async {
        guitarPeaks = detail.active?.files[Stem.guitar.rawValue] != nil
            ? try? await Backend.shared.peaks(id, stem: Stem.guitar.rawValue) : nil
        if sourcePeaks == nil { loudestCache = guitarPeaks.map(\.loudest) }
    }

    /// A multitrack que casa com a música e a cota do MVSEP, para o menu de faixas melhores.
    private func loadSources() async {
        multitrack = try? await Backend.shared.songMultitrack(id)
        mvsepUsage = try? await Backend.shared.mvsepUsage()
    }

    // MARK: - Espectro

    /// A chave da curva de uma nota: a pista, o tique, a corda, a altura, a duração e o segundo (o mapa novo ou a
    /// nota editada pedem de novo: a busca é em volta da altura escrita).
    func curveKey(_ note: ScoreNote, track: Int) -> String {
        "\(detail?.activeStems ?? ""):\(track):\(Int(note.tick)):\(note.string):\(note.pitch):\(Int(note.duration)):"
            + "\(Int((grid.seconds(at: note.tick) * 100).rounded()))"
    }

    /// A faixa da separação ativa onde a pista soa (`Stem.pitchSource`: o baixo no baixo, a base na Base…), para a
    /// altura das notas e o espectro; nil sem separação (o motor usa o original). `measured` diz se a pista tem altura
    /// (a bateria não).
    func pitchStem(track: Int) -> (stem: String?, measured: Bool) {
        let name = scoreTracks.first { $0.index == track }?.name ?? ""
        let available = Set(detail?.active?.files.keys.map { $0 } ?? [])
        guard let wanted = Stem.pitchSource(forTrack: name, available: available) else { return (nil, false) }
        if available.contains(wanted.rawValue) { return (wanted.rawValue, true) }
        return (available.contains(Stem.guitar.rawValue) ? Stem.guitar.rawValue : nil, true)
    }

    /// Pede ao motor as curvas das notas que aparecem e ainda não têm (de fora do desenho: a Fita chama no quadro).
    func askCurves(_ notes: [ScoreNote], track: Int) {
        guard pitchStem(track: track).measured else { return }
        let batch = Array(notes.filter { !curvesAsked.contains(curveKey($0, track: track)) }.prefix(120))
        guard !batch.isEmpty else { return }
        batch.forEach { curvesAsked.insert(curveKey($0, track: track)) }
        DispatchQueue.main.async { [weak self] in
            Task { await self?.fetchCurves(batch, track: track) }
        }
    }

    /// As curvas de `batch` (já marcadas como pedidas), guardadas como `SoundNote`.
    private func fetchCurves(_ batch: [ScoreNote], track: Int) async {
        let list = batch.map { note in
            (key: curveKey(note, track: track), start: grid.seconds(at: note.tick),
             end: grid.seconds(at: note.tick + note.duration), pitch: note.pitch)
        }
        // As notas de acorde (outra nota da pista na mesma batida): o motor mede cada uma entre as outras; a faixa
        // fica na escrita, sem trinado, e não entram nas suspeitas (a do meio ainda oscila).
        let ticks = Set(batch.map(\.tick))
        var together: [Double: [Int]] = [:]
        if scoreNotes.indices.contains(track) {
            for note in scoreNotes[track] where ticks.contains(note.tick) { together[note.tick, default: []].append(note.pitch) }
        }
        var others: [String: [Int]] = [:]
        for note in batch {
            let rest = (together[note.tick] ?? []).filter { $0 != note.pitch }
            if !rest.isEmpty { others[curveKey(note, track: track)] = rest }
        }
        let chords = Set(others.keys)
        guard let curves = try? await Backend.shared.pitchCurves(id, notes: list, others: others,
                                                                stem: pitchStem(track: track).stem)
        else { return }
        for (item, note) in zip(list, batch) {
            guard let curve = curves[item.key] else { continue }
            let raw = RawCurve(curve: curve, start: item.start, end: item.end, pitch: item.pitch,
                               chord: chords.contains(item.key), plain: note.bend.isEmpty)
            rawCurves[item.key] = raw
            soundNotes[item.key] = raw.sound(tuning: tuning)
        }
        pitchCurvesVersion += 1
    }

    /// A curva como veio do motor (na altura da gravação) e o que a nota precisa para virar `SoundNote`.
    private struct RawCurve {
        let curve: PitchCurve
        let start: Double
        let end: Double
        let pitch: Int
        let chord: Bool
        let plain: Bool

        func sound(tuning: Double) -> SoundNote {
            SoundNote(curve: curve.shifted(by: -tuning), start: start, end: end, pitch: Double(pitch), chord: chord)
        }
    }

    @ObservationIgnored private var rawCurves: [String: RawCurve] = [:]
    /// A afinação da gravação (semitons acima do Lá 440, `RecordingTuning`), medida nas notas paradas da música e
    /// descontada das curvas, do espectro, do encaixe e das suspeitas. Zero até haver notas bastantes.
    private(set) var tuning = 0.0

    /// Com as curvas da pista medidas: a afinação de novo e, se mudou, as `SoundNote` refeitas com ela.
    private func updateTuning() {
        // Só as notas de agora (uma nota editada ou um mapa novo deixam curvas de chaves que não existem mais).
        var current: Set<String> = []
        for (track, notes) in scoreNotes.enumerated() { notes.forEach { current.insert(curveKey($0, track: track)) } }
        rawCurves = rawCurves.filter { current.contains($0.key) }
        let samples = rawCurves.values.map {
            RecordingTuning.Sample(curve: $0.curve, start: $0.start, end: $0.end, pitch: $0.pitch, plain: $0.plain && !$0.chord)
        }
        let found = RecordingTuning.estimate(samples) ?? 0
        guard abs(found - tuning) >= 0.02 else { return }
        tuning = found
        soundNotes = rawCurves.mapValues { $0.sound(tuning: found) }
        pitchCurvesVersion += 1
    }

    /// No espectro, as curvas da pista inteira (e da segunda), em lotes, um pouco depois da última mudança (notas,
    /// pista, mapa): as suspeitas valem para a música toda, não só para a tela.
    private func measureLater() {
        measureTask?.cancel()
        guard lensVisible else { return }
        measureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            measuring = true
            defer { measuring = false }
            for track in shownTracks
            where scoreNotes.indices.contains(track) && pitchStem(track: track).measured {
                while !Task.isCancelled {
                    let batch = Array(scoreNotes[track].filter { !self.curvesAsked.contains(self.curveKey($0, track: track)) }
                        .prefix(120))
                    guard !batch.isEmpty else { break }
                    batch.forEach { self.curvesAsked.insert(self.curveKey($0, track: track)) }
                    await fetchCurves(batch, track: track)
                }
            }
            if !Task.isCancelled { updateTuning() }
        }
    }

    @ObservationIgnored private var measureTask: Task<Void, Never>?
    /// Medindo as curvas da pista inteira (as suspeitas ainda podem aumentar).
    private(set) var measuring = false

    /// O espectro da faixa onde a pista escolhida soa (a da guitarra para a bateria), feito uma vez por faixa: trocar
    /// de pista ou de separação troca a imagem; as duas últimas ficam guardadas.
    func loadSpectrum() async {
        guard let detail, lensVisible else { return }
        let stem = pitchStem(track: scoreTrack).stem
            ?? (detail.active?.files[Stem.guitar.rawValue] != nil ? Stem.guitar.rawValue : nil)
        let key = "\(detail.activeStems ?? "")/\(stem ?? "original")/\(paper ? "papel" : "escuro")"
        guard key != spectrumKey else { return }
        spectrumKey = key
        if let kept = spectra[key] {
            spectrumImage = kept.image
            spectrum = kept.spectrum
            return
        }
        spectrumMessage = "Calculando o espectro…"
        do {
            guard let found = try await Backend.shared.spectrum(id, stem: stem) else {
                spectrumMessage = "Esta música não tem áudio para o espectro."
                return
            }
            let image = await SpectrumPalette.image(found, paper: paper)
            guard spectrumKey == key else { return }
            if spectra.count >= 2 { spectra.removeAll() }
            if let image { spectra[key] = (found, image) }
            spectrumImage = image
            spectrum = found
            spectrumMessage = nil
        } catch {
            spectrumMessage = error.localizedDescription
        }
    }

    @ObservationIgnored private var spectrumKey: String?
    /// A Lente no papel (a aparência clara): a imagem do espectro é feita de novo com a paleta de tinta.
    @ObservationIgnored var paper = false {
        didSet { if paper != oldValue { Task { await loadSpectrum() } } }
    }
    @ObservationIgnored private var spectra: [String: (spectrum: Spectrum, image: CGImage)] = [:]

    // MARK: - Metrônomo e afinação

    /// O metrônomo (K): um clique em cada batida do mapa de tempo, refeito quando o mapa muda.
    var metronome = false {
        didSet {
            engine.clickOn = metronome
            refreshClick()
        }
    }
    @ObservationIgnored private var clickBeats: [Double]?

    /// A faixa de cliques das batidas de agora (em segundo plano), se o metrônomo está ligado e ela mudou.
    func refreshClick(force: Bool = false) {
        guard metronome, grid.beats.count >= 2, engine.duration > 0 else { return }
        let beats = grid.beats
        guard force || beats != clickBeats else { return }
        clickBeats = beats
        let bars = grid.bars
        let duration = engine.duration
        let url = FileManager.default.temporaryDirectory.appending(path: "tracklab-click-\(id)-\(beats.count)-\(Int(beats.reduce(0, +))).caf")
        Task {
            let written = await Task.detached(priority: .userInitiated) { () -> Bool in
                let samples = Metronome.samples(beats: beats, bars: bars, duration: duration)
                return (try? StemEngine.writeClick(samples, to: url)) != nil
            }.value
            guard written, clickBeats == beats else { return }
            try? engine.setClick(url)
        }
    }

    /// Lá 440: o ajuste fino desconta a afinação medida da gravação (`tuning`), e a música soa no Lá 440.
    func tuneTo440() {
        engine.cents = -Int((tuning * 100).rounded())
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

    /// X: troca o que soa: o áudio pela TAB sintetizada, ou o contrário (os dois ligados ou desligados: só a TAB).
    func swapAudioAndTab() {
        guard !engine.synthIDs.isEmpty else { return }
        let tab = !engine.tabOn || engine.audioOn == engine.tabOn
        engine.tabOn = tab
        engine.audioOn = !tab
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

    /// A tela não salta: um loop marcado nela fica onde está (parada, a música vai ao começo dele, `seekToStart`); ao
    /// soltar o loop, a agulha fica onde estava e a tela volta a andar dali.
    func setLoop(_ range: ClosedRange<Double>?, seekToStart: Bool = false) {
        let now = engine.currentTime
        let view = viewStart(now: now)
        engine.loop = range
        place(at: (now - view) / span, now: now)
        bridge.setLoop(range)
        if seekToStart, let range, !engine.isPlaying {
            keepView = view
            engine.seek(to: range.lowerBound)
        }
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

    /// "+ Trecho do loop": o loop vira um trecho de estudo do tipo escolhido (nos tiques da partitura) e fica ativo.
    func addSectionFromLoop(kind: SectionKind = .trecho) {
        guard let loop = engine.loop, !grid.isEmpty else { return }
        let from = grid.tick(at: loop.lowerBound).rounded()
        let to = grid.tick(at: loop.upperBound).rounded()
        let number = sections.filter { $0.kind == kind }.count + 1
        save(sections + [StudySection(name: "\(kind.label) \(number)", from: from, to: to, kind: kind)],
             select: (from, to))
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
        change(section) { $0.name = clean }
    }

    func setGoal(_ section: StudySection, _ goal: Int) { change(section) { $0.goal = goal } }

    func setKind(_ section: StudySection, _ kind: SectionKind) { change(section) { $0.kind = kind } }

    /// As etiquetas de um texto separado por vírgulas ("blues, bend").
    func setTags(_ section: StudySection, _ text: String) { change(section) { $0.tags = StudySection.tags(from: text) } }

    func toggleFavorite(_ section: StudySection) { change(section) { $0.favorite.toggle() } }

    /// As etiquetas já usadas nos trechos desta música, para sugerir.
    var knownTags: [String] { Array(Set(sections.flatMap(\.tags))).sorted() }

    private func change(_ section: StudySection, _ edit: (inout StudySection) -> Void) {
        save(sections.map { item in
            guard item.id == section.id else { return item }
            var copy = item
            edit(&copy)
            return copy
        })
    }

    func delete(_ section: StudySection) {
        if activeSectionID == section.id { deactivateSection() }
        save(sections.filter { $0.id != section.id })
    }

    private func save(_ list: [StudySection], select range: (Double, Double)? = nil) {
        // Os compassos de cada trecho, pelas barras da partitura (a biblioteca de trechos mostra; o motor não as tem).
        let bars = grid.barTicks
        let counted = list.map { section -> StudySection in
            var copy = section
            let inside = bars.filter { $0 >= section.from - 1 && $0 < section.to - 1 }.count
            if inside > 0 { copy.bars = inside }
            return copy
        }
        Task {
            do {
                sections = try await Backend.shared.putSections(id, counted)
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
        setLoop(range, seekToStart: true)
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
    func moveBeat(tick: Double, to seconds: Double, message: String? = nil) {
        edit(.init(action: "move", tick: tick, seconds: seconds), message: message)
    }

    /// Duplo clique: uma âncora se solta (fica onde está); uma batida solta vira âncora onde está.
    func toggleAnchor(_ point: TempoPoint) {
        edit(.init(action: point.isAnchor ? "release" : "move", tick: point.tick, seconds: point.isAnchor ? nil : point.seconds))
    }

    /// Em cada compasso (índice 0…), quanto os ataques medidos das notas (da pista e da segunda) chegam depois (+) ou
    /// antes (−) da escrita: `SoundSync.barOffsets`. Vem das curvas, então só com o espectro, que as mede.
    func barOffsets() -> [Int: Double] {
        let key = [pitchCurvesVersion, notesVersion]
        if let offsetCache, offsetCache.key == key { return offsetCache.offsets }
        var notes: [(start: Double, attack: Double?)] = []
        for track in shownTracks where scoreNotes.indices.contains(track) {
            for note in scoreNotes[track] {
                guard let sound = soundNotes[curveKey(note, track: track)], !sound.chord else { continue }
                notes.append((grid.seconds(at: note.tick), sound.curve.attack))
            }
        }
        let offsets = SoundSync.barOffsets(notes, bars: grid.bars)
        offsetCache = (key, offsets)
        return offsets
    }

    @ObservationIgnored private var offsetCache: (key: [Int], offsets: [Int: Double])?

    /// A: o 1 do compasso que toca vai para onde os ataques dele soam (a mediana, `barOffsets`); vira âncora e as
    /// vizinhas acompanham, como num arrasto.
    func syncBarToSound() {
        guard let bar = grid.bar(at: engine.currentTime), grid.barTicks.indices.contains(bar - 1) else { return }
        guard lensVisible else {
            adjustMessage = "Abra o espectro: é ele que mede quando as notas soam."
            return
        }
        guard let offset = barOffsets()[bar - 1] else {
            adjustMessage = measuring ? "Medindo o som das notas…" : "Compasso \(bar): poucas notas com ataque claro para dizer."
            return
        }
        guard abs(offset) >= 0.01 else {
            adjustMessage = "Compasso \(bar): o som já cai na batida."
            return
        }
        moveBeat(tick: grid.barTicks[bar - 1], to: grid.bars[bar - 1] + offset,
                 message: "Compasso \(bar): o som vinha \(Int((abs(offset) * 1000).rounded())) ms "
                    + (offset > 0 ? "depois" : "antes") + "; o 1 foi até ele.")
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

    /// Um comando da edição da TAB para a página.
    func tabEdit(_ op: String, _ value: Any? = nil) {
        guard editingTab else { return }
        bridge.edit(op, value)
    }

    /// Liga ou desliga uma articulação na nota escolhida; `cycle` passa pela lista (a tecla repetida troca de forma e,
    /// depois da última, desliga).
    func toggleTechnique(_ key: String) { tabEdit("technique", key) }

    func cycleTechnique(_ keys: [String]) {
        let on = tabSelection?.techniques ?? []
        guard let current = keys.firstIndex(where: on.contains) else {
            if let first = keys.first { toggleTechnique(first) }
            return
        }
        // Desliga a de agora; a seguinte (se houver) liga no lugar.
        if current + 1 < keys.count { toggleTechnique(keys[current + 1]) } else { toggleTechnique(keys[current]) }
    }

    // MARK: - Notas no espectro (a Lente do TabLab)

    /// Um clique numa faixa do espectro: liga a edição e escolhe a nota na TAB.
    func selectNote(_ note: ScoreNote, track: Int) {
        if !editingTab { editingTab = true }
        tabMessage = nil
        bridge.edit("select", ["track": track, "tick": note.tick, "string": note.string])
    }

    /// A nota escolhida, na lista da pista (com a curva, se já chegou).
    private func selectedScoreNote() -> (note: ScoreNote, track: Int)? {
        guard let selection = tabSelection, scoreNotes.indices.contains(selection.track) else { return nil }
        return scoreNotes[selection.track].first { selection.matches($0, track: selection.track) }
            .map { ($0, selection.track) }
    }

    /// As notas da pista em que o som discorda da escrita (`SoundNote.disagreements`), em ordem de tempo e de corda.
    func suspects(track: Int) -> [(note: ScoreNote, reasons: [SoundDisagreement])] {
        guard scoreNotes.indices.contains(track) else { return [] }
        let key = [pitchCurvesVersion, notesVersion, track]
        if let suspectCache, suspectCache.key == key { return suspectCache.list }
        let list = scoreNotes[track].compactMap { note -> (note: ScoreNote, reasons: [SoundDisagreement])? in
            guard let reasons = soundNotes[curveKey(note, track: track)]?.disagreements(with: note), !reasons.isEmpty
            else { return nil }
            return (note, reasons)
        }
        .sorted { ($0.note.tick, $0.note.string) < ($1.note.tick, $1.note.string) }
        suspectCache = (key, list)
        return list
    }

    /// Tab e ⇧Tab: a suspeita seguinte (ou a anterior) da pista, a partir da nota escolhida ou da agulha. Escolhe a
    /// nota (liga a edição), leva a agulha até ela e diz o que o som tem.
    func nextSuspect(_ delta: Int) {
        let track = scoreTrack
        let list = suspects(track: track)
        guard !list.isEmpty else {
            tabMessage = measuring ? "Medindo o som das notas…" : "Nenhuma nota suspeita nesta pista."
            return
        }
        let here: (tick: Double, string: Int)? = selectedScoreNote().flatMap { $0.track == track ? ($0.note.tick, $0.note.string) : nil }
        let index: Int
        if let here {
            let key = (here.tick, here.string)
            if delta > 0 {
                index = list.firstIndex { ($0.note.tick, $0.note.string) > key } ?? 0
            } else {
                index = list.lastIndex { ($0.note.tick, $0.note.string) < key } ?? list.count - 1
            }
        } else {
            let now = grid.tick(at: engine.currentTime)
            if delta > 0 {
                index = list.firstIndex { $0.note.tick >= now - 1 } ?? 0
            } else {
                index = list.lastIndex { $0.note.tick < now - 1 } ?? list.count - 1
            }
        }
        let (note, reasons) = list[index]
        selectNote(note, track: track)
        engine.seek(to: grid.seconds(at: note.tick))
        tabMessage = "Suspeita \(index + 1) de \(list.count)\(measuring ? "…" : ""): " + Self.describe(reasons) + " · F encaixa"
    }

    /// O que o som tem, em palavras.
    static func describe(_ reasons: [SoundDisagreement]) -> String {
        reasons.map { reason in
            switch reason {
            case let .pitch(pitch): "soa \(pitchName(pitch))"
            case let .bend(quarterTones): quarterTones > 0 ? "o som dobra \(bendName(quarterTones))" : "o som não dobra"
            case let .trill(low, high): "trinado \(pitchName(low))⇄\(pitchName(high))"
            case .noTrill: "o som não faz o trinado escrito"
            }
        }
        .joined(separator: ", ")
    }

    /// O que o som fez na nota escolhida, em palavras (a linha embaixo da escolha na barra de edição): "soou D4 +12
    /// cents · bend 1 tom, 90 % do escrito · vibrato de 25 cents". Com a afinação da gravação já descontada.
    var soundSummary: String? {
        guard let (note, track) = selectedScoreNote() else { return nil }
        guard pitchStem(track: track).measured else { return nil }
        // Sem o espectro as curvas não são medidas: nada a dizer.
        guard let sound = soundNotes[curveKey(note, track: track)] else { return lensVisible ? "Medindo o som…" : nil }
        let start = grid.seconds(at: note.tick)
        guard let report = sound.report(for: note, start: start, end: grid.seconds(at: note.tick + note.duration)) else {
            return "O som não tem uma altura clara."
        }
        if let trill = report.trill { return "Trinado \(Self.pitchName(trill.low))⇄\(Self.pitchName(trill.high))" }
        var parts = ["Soou \(Self.pitchName(report.pitch))"
                     + (abs(report.cents) >= 5 ? " \(report.cents > 0 ? "+" : "−")\(abs(report.cents)) cents" : "")]
        let written = Int(note.bend.map(\.value).max() ?? 0)
        if report.bend > 0 {
            parts.append("bend \(Self.bendName(report.bend))"
                         + (report.reached.map { ", \($0) % do escrito" } ?? ", não escrito"))
        } else if written > 0 {
            parts.append("não dobrou (escrito: \(Self.bendName(written)))")
        }
        if let vibrato = report.vibrato { parts.append("vibrato de \(vibrato) cents") }
        return parts.joined(separator: " · ")
    }

    /// F: encaixa a nota escolhida no som (a altura medida, o bend que ele faz e o vibrato), como o Encaixar da Lente.
    func fitToSound() {
        guard editingTab, let (note, track) = selectedScoreNote() else { return }
        guard let sound = soundNotes[curveKey(note, track: track)] else {
            tabMessage = "A curva do som desta nota ainda não chegou."
            return
        }
        apply(sound.fit, to: note, center: Double(note.pitch))
    }

    /// Arrastar a faixa para os lados (ou ⌥← ⌥→ na edição): a batida da nota anda `steps` semicolcheias no tempo; a
    /// anterior encurta ou cresce e o que sobra vira pausa (`edit.shift` na página).
    func shiftNote(_ note: ScoreNote, track: Int, steps: Int) {
        guard steps != 0 else { return }
        selectNote(note, track: track)
        bridge.edit("nudge", steps)
        let name = Self.grids.first { $0.ticks == gridTicks }?.name ?? "passo"
        tabMessage = "A nota andou \(abs(steps)) × \(name) " + (steps > 0 ? "para depois" : "para antes") + " · ⌘Z desfaz"
    }

    /// As grades do tempo das notas (tiques a 960 por semínima) e o nome de cada uma.
    static let grids: [(ticks: Int, name: String)] = [(480, "1/8"), (240, "1/16"), (120, "1/32"), (320, "tercina de 1/8"),
                                                       (160, "tercina de 1/16")]

    /// A grade do arrasto das barras, do ⌥← ⌥→ e do arrasto lateral da Lente (guardada).
    var gridTicks = UserDefaults.standard.object(forKey: "gridTicks") as? Int ?? 240 {
        didSet {
            UserDefaults.standard.set(gridTicks, forKey: "gridTicks")
            bridge.setDurations(showDurations, grid: gridTicks)
        }
    }

    /// As barras de duração embaixo das notas da TAB na edição (D; guardado).
    var showDurations = UserDefaults.standard.bool(forKey: "showDurations") {
        didSet {
            UserDefaults.standard.set(showDurations, forKey: "showDurations")
            bridge.setDurations(showDurations, grid: gridTicks)
        }
    }

    /// As figuras da coluna de edição, da semibreve à fusa (tiques a 960 por semínima).
    static let figures: [(ticks: Int, label: String, name: String)] = [
        (3840, "1", "semibreve"), (1920, "½", "mínima"), (960, "¼", "semínima"), (480, "⅛", "colcheia"),
        (240, "1/16", "semicolcheia"), (120, "1/32", "fusa"),
    ]

    /// A figura da nota escolhida: a base nova, ou ligar e desligar o ponto ou a tercina (um tira o outro); o começo
    /// fica, mais curta sobra pausa, mais longa não passa da seguinte.
    func setFigure(base: Int? = nil, dotted: Bool? = nil, triplet: Bool? = nil) {
        guard let selection = tabSelection else { return }
        guard let base = base ?? selection.base else {
            tabMessage = "A nota soa por notas ligadas: escolha primeiro a figura (1 … 1/32)."
            return
        }
        var dot = dotted ?? selection.dotted
        var three = triplet ?? selection.triplet
        if dotted == true { three = false }
        if triplet == true { dot = false }
        tabEdit("length", TabSelection.ticks(base: base, dotted: dot, triplet: three))
    }

    /// Ouvir (⌥Espaço): o trecho das notas escolhidas vira o loop e toca (no ritmo do estudo); a tela fica onde está.
    func listenSelection() {
        guard let range = tabSelection?.range, !grid.isEmpty else { return }
        let seconds = grid.seconds(at: range.lowerBound)...grid.seconds(at: range.upperBound)
        guard seconds.upperBound - seconds.lowerBound >= LoopRegion.minimum else { return }
        if engine.isPlaying { engine.pause() }
        setLoop(seconds, seekToStart: true)
        engine.play()
    }

    /// − e = na edição: a figura da metade ou do dobro (com o mesmo ponto ou tercina).
    func stepFigure(_ direction: Int) {
        guard let base = tabSelection?.base else { return }
        let next = direction < 0 ? base / 2 : base * 2
        guard Self.figures.contains(where: { $0.ticks == next }) else { return }
        setFigure(base: next)
    }

    /// ⌥← ⌥→ na edição: a nota escolhida um passo da grade mais cedo ou mais tarde.
    /// Com várias notas escolhidas, todas andam juntas (sem escolher de novo, que deixaria só uma).
    func shiftSelected(_ steps: Int) {
        if let count = tabSelection?.count, count > 1, steps != 0 {
            tabEdit("nudge", steps)
            let name = Self.grids.first { $0.ticks == gridTicks }?.name ?? "passo"
            tabMessage = "As \(count) notas andaram \(abs(steps)) × \(name) " + (steps > 0 ? "para depois" : "para antes")
                + " · ⌘Z desfaz"
            return
        }
        guard let (note, track) = selectedScoreNote() else { return }
        shiftNote(note, track: track, steps: steps)
    }

    /// Arrastar a faixa para cima ou para baixo: a nota anda de semitom em semitom e, ao soltar perto do som, encaixa
    /// nele (medido de novo em volta da altura nova); com ⌥, só a altura.
    func dragPitch(_ note: ScoreNote, track: Int, semitones: Int, onlyPitch: Bool) {
        guard semitones != 0 else { return }
        selectNote(note, track: track)
        let pitch = note.pitch + semitones
        if onlyPitch {
            bridge.edit("transpose", semitones)
            return
        }
        let start = grid.seconds(at: note.tick)
        let end = grid.seconds(at: note.tick + note.duration)
        Task {
            let key = "drag"
            let curves = try? await Backend.shared.pitchCurves(id, notes: [(key, start, end, pitch)],
                                                              stem: pitchStem(track: track).stem)
            let chord = scoreNotes.indices.contains(track)
                && scoreNotes[track].contains { $0.tick == note.tick && $0.string != note.string }
            let fit = curves?[key].map {
                SoundNote(curve: $0.shifted(by: -tuning), start: start, end: end, pitch: Double(pitch), chord: chord)
            }?.fit
            if let fit, abs(Double(fit.base) - Double(pitch)) <= 1 {
                apply(fit, to: note, center: Double(pitch))
            } else {
                bridge.edit("transpose", semitones)
            }
        }
    }

    private func apply(_ fit: CurveFit?, to note: ScoreNote, center: Double) {
        guard let fit, abs(Double(fit.base) - center) <= 1 else {
            tabMessage = "O som não tem uma altura clara nesta nota."
            return
        }
        if let trill = fit.trill {
            // O trinado: a nota na de baixo e o trinado na de cima (como o Guitar Pro escreve), sem bend nem vibrato.
            let name = "trinado \(Self.pitchName(trill.low))⇄\(Self.pitchName(trill.high))"
            guard note.pitch != trill.low || note.trill != trill.high || !note.bend.isEmpty || note.vibrato > 0 else {
                tabMessage = "Já está como soa."
                return
            }
            // A velocidade: as trocas medidas contra a semínima ali (o Guitar Pro guarda a figura de cada troca).
            let beat = grid.seconds(at: note.tick + TempoGrid.ticksPerQuarter) - grid.seconds(at: note.tick)
            let speed = trill.speed(beatSeconds: beat)
            bridge.edit("fit", ["pitch": trill.low, "bend": NSNull(), "vibrato": false, "trill": trill.high,
                                "trillSpeed": speed])
            let figure = [8: "colcheias", 16: "semicolcheias", 32: "fusas", 64: "semifusas"][speed] ?? ""
            tabMessage = "Encaixou no som: \(name) em \(figure) · ⌘Z desfaz"
            return
        }
        // Só o que muda, como a Lente: a altura, o bend (pelo tamanho) e o vibrato.
        let before = Int(note.bend.map(\.value).max() ?? 0)
        var parts: [String] = []
        if fit.base != note.pitch { parts.append(Self.pitchName(fit.base)) }
        if fit.quarterTones != before { parts.append(fit.quarterTones > 0 ? "bend \(Self.bendName(fit.quarterTones))" : "sem bend") }
        if fit.vibrato != (note.vibrato > 0) { parts.append(fit.vibrato ? "vibrato" : "sem vibrato") }
        if note.trill != nil { parts.append("sem trinado") }
        guard !parts.isEmpty else {
            tabMessage = "Já está como soa."
            return
        }
        let bend: Any = fit.guitarPro.map { $0.map { [$0.offset, $0.value] } } ?? NSNull()
        bridge.edit("fit", ["pitch": fit.base, "bend": bend, "vibrato": fit.vibrato])
        tabMessage = "Encaixou no som: " + parts.joined(separator: ", ") + " · ⌘Z desfaz"
    }

    static func pitchName(_ midi: Int) -> String {
        TabSelection.name(midi)
    }

    static func bendName(_ quarterTones: Int) -> String {
        [1: "¼", 2: "½", 3: "¾", 4: "1 tom", 6: "1½ tom", 8: "2 tons"][quarterTones] ?? "\(Double(quarterTones) / 4) tom"
    }

    private func saveScore(_ data: Data) {
        Task {
            do {
                try await Backend.shared.putScore(id, data)
                tabMessage = "Guardado"
                synthChanged = true
                if let fresh = try? await Backend.shared.song(id) { detail = fresh }
            } catch {
                tabMessage = "Não consegui guardar a TAB: \(error.localizedDescription)"
            }
        }
    }

    var canUndoAny: Bool { editingTab ? canUndoTab : canUndo }
    var canRedoAny: Bool { editingTab ? canRedoTab : canRedo }

    /// ⌘Z: na edição da TAB, a TAB; senão, o mapa de tempo.
    func undoAny() { if editingTab { tabEdit("undo") } else { undo() } }
    func redoAny() { if editingTab { tabEdit("redo") } else { redo() } }

    func undo() {
        guard canUndo, let current = tempoMap, let previous = undoStack.popLast() else { return }
        replace(with: previous) { [self] in redoStack.append(current) } failed: { [self] in undoStack.append(previous) }
    }

    func redo() {
        guard canRedo, let current = tempoMap, let next = redoStack.popLast() else { return }
        replace(with: next) { [self] in undoStack.append(current) } failed: { [self] in redoStack.append(next) }
    }

    /// Um gesto por vez: o motor aplica ao mapa gravado e devolve o novo, que entra no Desfazer.
    /// `message`: o aviso do Ajuste depois que o mapa novo chega (o mapa novo limpa o anterior).
    private func edit(_ gesture: Backend.TempoGesture, message: String? = nil) {
        guard !saving, let before = tempoMap else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let map = try await Backend.shared.editTempo(id, gesture)
                undoStack.append(before)
                redoStack.removeAll()
                show(map)
                if let message { adjustMessage = message }
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
        if detail?.synth != nil, map != tempoMap { synthChanged = true }
        adjustMessage = nil
        tempoMap = map
        grid = TempoGrid(points: map.points, barTicks: grid.barTicks)
        bridge.setTempo(map.points)
        notesVersion += 1
        measureLater()
        refreshClick()
    }

    // MARK: - Separação (a escada da Fase 4)

    /// A separação que toca agora (uma das guardadas): o áudio é recarregado no mesmo ponto, tocando se tocava, com
    /// a mesma mixagem. A anterior fica como o outro lado do A/B.
    func useStems(_ key: String) async {
        guard let detail, key != detail.activeStems, detail.stems[key] != nil, stemSwitching == false else { return }
        stemSwitching = true
        defer { stemSwitching = false }
        do {
            try await Backend.shared.setActiveStems(id, key: key)
            let fresh = try await Backend.shared.song(id)
            let previous = detail.activeStems
            let wasPlaying = engine.isPlaying
            self.detail = fresh
            try loadAudio(fresh, keepMix: true)
            engine.useStems = true
            if wasPlaying { engine.play() }
            compareKey = previous
            await loadGuitarPeaks(fresh)
            await loadSpectrum()
            measureLater()
        } catch {
            notice = error.localizedDescription
        }
    }

    @ObservationIgnored private var stemSwitching = false

    /// B: troca entre as duas separações do A/B.
    func toggleAB() {
        guard let compareKey else { return }
        Task { await useStems(compareKey) }
    }

    enum StemRequest: Equatable {
        case demucs
        case multitrack
        case mvsep(Int)
        case synth

        var label: String {
            switch self {
            case .synth: "TAB sintetizada"
            case .demucs: "Demucs 6s"
            case .multitrack: "Multitrack"
            case .mvsep(63): "MVSEP 6 faixas"
            case .mvsep(101): "MVSEP solo e base"
            case .mvsep: "MVSEP Guitar"
            }
        }
    }

    func separate() async { await improve(.demucs) }

    /// Pede faixas (o Demucs, a multitrack ou o MVSEP) e acompanha a fila; a nova separação vira o outro lado do A/B
    /// (ou a ativa, se não havia nenhuma).
    func improve(_ request: StemRequest) async {
        guard stemJob == nil else { return }
        do {
            let ticket: JobTicket
            switch request {
            case .demucs:
                ticket = try await Backend.shared.separate(id)
            case .multitrack:
                ticket = try await Backend.shared.importMultitrack(id)
            case let .mvsep(model):
                guard let key = MVSEPKey.read() else {
                    notice = "Falta a chave do MVSEP: TrackLab › Ajustes (⌘,)."
                    return
                }
                ticket = try await Backend.shared.separateMVSEP(id, model: model, key: key)
            case .synth:
                await synthesize()
                return
            }
            stemJob = (ticket.id, request, "Na fila…", nil)
            while true {
                try await Task.sleep(for: .milliseconds(500))
                let job = try await Backend.shared.job(ticket.id)
                stemJob = (ticket.id, request, job.last?.message ?? "Trabalhando…", job.last?.progress)
                guard job.finished else { continue }
                stemJob = nil
                if case .mvsep = request { mvsepUsage = try? await Backend.shared.mvsepUsage() }
                guard job.status == "done" else {
                    notice = job.error ?? "\(request.label): não terminou."
                    return
                }
                let previous = detail
                let fresh = try await Backend.shared.song(id)
                self.detail = fresh
                if previous?.activeStems != fresh.activeStems {
                    try loadAudio(fresh, keepMix: false)
                    await loadGuitarPeaks(fresh)
                    await loadSpectrum()
                    measureLater()
                } else if let added = fresh.stemKeys.first(where: { previous?.stems[$0] == nil }) {
                    compareKey = added
                    notice = "\(fresh.stems[added]?.label ?? request.label) pronta: compare com A/B (B)."
                }
                return
            }
        } catch {
            stemJob = nil
            notice = error.localizedDescription
        }
    }

    /// A TAB sintetizada (todas as pistas, no mapa de tempo de agora), na fila; ao terminar, entra no mixer no mesmo
    /// ponto, tocando se tocava, com a mixagem de antes.
    func synthesize(quiet: Bool = false) async {
        guard stemJob == nil else { return }
        synthMessage = nil
        do {
            let ticket = try await Backend.shared.synthesize(id)
            stemJob = (ticket.id, .synth, "Na fila…", nil)
            while true {
                try await Task.sleep(for: .milliseconds(500))
                let job = try await Backend.shared.job(ticket.id)
                stemJob = (ticket.id, .synth, job.last?.message ?? "Sintetizando…", job.last?.progress)
                guard job.finished else { continue }
                stemJob = nil
                guard job.status == "done" else {
                    let text = job.error ?? "A síntese da TAB não terminou."
                    if quiet { synthMessage = text } else { notice = text }
                    return
                }
                let fresh = try await Backend.shared.song(id)
                let wasPlaying = engine.isPlaying
                detail = fresh
                synthChanged = false
                try loadAudio(fresh, keepMix: true)
                if wasPlaying { engine.play() }
                return
            }
        } catch {
            stemJob = nil
            if quiet { synthMessage = error.localizedDescription } else { notice = error.localizedDescription }
        }
    }

    func cancelStemJob() {
        guard let job = stemJob?.job else { return }
        Task { try? await Backend.shared.cancel(job) }
    }
}

/// A janela de alturas do espectro: tocando, anda um quarto do caminho por quadro até a que as notas do trecho pedem
/// (como a Lente do TabLab); parado, vai direto. Sem notas no trecho, fica onde estava.
final class PitchWindow {
    private(set) var range: ClosedRange<Double> = 40...80

    func update(target: ClosedRange<Double>?, easing: Bool) -> ClosedRange<Double> {
        guard let target else { return range }
        if !easing || (abs(range.lowerBound - target.lowerBound) < 0.05 && abs(range.upperBound - target.upperBound) < 0.05) {
            range = target
        } else {
            let low = range.lowerBound + (target.lowerBound - range.lowerBound) * 0.25
            let high = range.upperBound + (target.upperBound - range.upperBound) * 0.25
            range = low...max(high, low + 1)
        }
        return range
    }
}
