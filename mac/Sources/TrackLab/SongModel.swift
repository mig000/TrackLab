import AppKit
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
    @ObservationIgnored private var synthRetried = false
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
            if !editingTab { Task { await finishScoreEdits() } }
        }
    }

    /// Saindo da edição: a última mudança gravada já (sem esperar os 1,5 s da página) e, se a partitura mudou, a TAB
    /// sintetizada refeita. Antes, concluir logo depois de uma mudança deixava a síntese da partitura de antes.
    private func finishScoreEdits() async {
        if let data = await bridge.flush() { saveScore(data) }
        await scoreSave?.value
        if !editingTab, !adjusting, synthOutdated { await synthesize(quiet: true) }
    }
    private(set) var tabSelection: TabSelection?
    /// O cursor de inserção da edição (uma corda vazia de uma batida), ou nil.
    private(set) var tabCaret: TabCaret?
    /// O compasso da escolha na edição (para pôr, apagar e mudar a fórmula), ou nil.
    private(set) var tabBar: TabBarInfo?
    private(set) var canUndoTab = false
    private(set) var canRedoTab = false
    var tabMessage: String?

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

    /// O começo da tela (Fita e TAB) com a música em `now`; parada enquanto uma nota clicada toca.
    func viewStart(now: Double) -> Double {
        if engine.auditionActive, let auditionView { return auditionView }
        return LoopView.start(now: now, loop: engine.loop, span: span, at: playheadAt, pin: loopPin)
    }

    /// A tela enquanto uma nota clicada toca (ela não anda: só a agulha passa pela nota).
    @ObservationIgnored private var auditionView: Double?

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

    /// A curva da nota já foi pedida ao motor (chegou, ou o motor não a mede).
    func curveAsked(_ note: ScoreNote, track: Int) -> Bool { curvesAsked.contains(curveKey(note, track: track)) }
    /// Muda quando chega uma curva: a Fita desenha de novo.
    private(set) var pitchCurvesVersion = 0
    /// A janela de alturas do espectro na Fita (desliza até a das notas do trecho).
    @ObservationIgnored let pitchWindow = PitchWindow()
    /// As notas de cada pista da partitura (pelo índice da pista), para as barras sobre o espectro.
    private(set) var scoreNotes: [[ScoreNote]] = [] {
        didSet {
            notesVersion += 1
            pruneCorrections()
            measureLater()
        }
    }
    /// As notas que o corretor mudou (`correctionKey`: pista, tique e corda) e como estavam e ficaram, para a marca na
    /// Lente, o "Original" entre as leituras e a contagem (Corretor.swift).
    var corrections: [String: (before: NoteReading, after: NoteReading)] = [:]
    /// Corrigir assim que as curvas da pista chegarem (a Lente estava fechada ou ainda medindo).
    @ObservationIgnored var correctWhenMeasured = false
    /// Muda com as notas e com o mapa (as chaves das curvas levam o tempo da nota): a lista de suspeitas se refaz.
    @ObservationIgnored private var notesVersion = 0
    @ObservationIgnored private var suspectCache: (key: [Int], list: [Suspect])?
    /// Os sons da faixa da pista (`GET songs/{id}/sounds`), para o som sem nota escrita.
    private(set) var heardSounds: [HeardSound] = []
    @ObservationIgnored private var soundsVersion = 0
    @ObservationIgnored private var soundsKey: String?

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
        engine.onAuditionEnd = { [weak self] in
            guard let self else { return }
            auditionView = nil
            bridge.setView(at: playheadAt, pin: loopPin)
        }
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
        bridge.onCaret = { [weak self] caret in self?.tabCaret = caret }
        bridge.onClip = { [weak self] clip, beats, cut in self?.storeClip(clip, beats: beats, cut: cut) }
        bridge.onBar = { [weak self] bar in self?.tabBar = bar }
        bridge.onStructure = { [weak self] points, ticks, markers, change in
            self?.restructure(points: points, barTicks: ticks, markers: markers, change: change)
        }
        bridge.onHear = { [weak self] body in
            func number(_ key: String) -> Double? { (body[key] as? NSNumber)?.doubleValue }
            guard let self, let track = number("track"), let tick = number("tick"), let string = number("string"),
                  let pitch = number("pitch"), let from = number("from"), let to = number("to") else { return }
            hear(track: Int(track), tick: tick, string: Int(string), pitch: Int(pitch), from: from, to: to,
                 synth: body["synth"] as? Bool ?? false)
        }
        bridge.onSave = { [weak self] data in self?.saveScore(data) }
        bridge.onNotes = { [weak self] notes in self?.scoreNotes = notes }
        bridge.onFitted = { [weak self] count, asked in self?.fitted(count: count, asked: asked) }
        bridge.onShiftEnd = { [weak self] seconds in
            self?.soundShift = 0
            self?.alignBeat(shiftedBy: seconds)
        }
    }

    /// A música aberta (o app grava a TAB dela antes de sair; presa aqui, ela sobrevive à janela fechada, que também
    /// encerra o app) e o fechamento da última que fechou (a música seguinte espera: reaberta logo, ela leria o Guitar
    /// Pro de antes da gravação).
    static var opened: SongModel?
    private static var closing: Task<Void, Never>?

    /// Fecha a música: o som para já; a edição que a página ainda não mandou é gravada antes de a página deixar de
    /// falar com o app (antes, trocar de música até 1,5 s depois de uma mudança perdia a mudança).
    func close() {
        engine.stop()
        let previous = Self.closing
        Self.closing = Task {
            await previous?.value
            await saveEverything()
            bridge.close()
        }
    }

    /// Tudo o que está a caminho do motor: a edição pendente na página, a gravação da TAB e a dos trechos.
    func saveEverything() async {
        if let data = await bridge.flush() { saveScore(data) }
        await scoreSave?.value
        await sectionsSave?.value
    }

    /// Antes de o app sair: a música aberta e as que fecharam gravam o que tinham.
    static func finishAll() async {
        await opened?.saveEverything()
        await closing?.value
    }

    func load() async {
        phase = .loading
        await Self.closing?.value
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
            // A TAB sintetizada é feita em segundo plano ao abrir (ou refeita, se o mapa, a partitura ou a versão da
            // síntese mudou depois dela).
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
        // A TAB sintetizada é um extra: um arquivo dela que falta (apagado, uma síntese interrompida) não impede a música
        // de abrir; o motor a dá como velha e ela é refeita.
        for (id, track) in detail.synth?.ids ?? [] where FileManager.default.fileExists(atPath: detail.url(track.file).path) {
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

    /// A chave da curva de uma nota: a pista, o tique, a corda, a altura, a duração e o começo e o fim em segundos (o
    /// mapa novo ou a nota editada pedem de novo: a busca é em volta da altura escrita, no trecho do áudio da nota; um
    /// ajuste que mudasse só o fim deixava a curva do trecho de antes).
    func curveKey(_ note: ScoreNote, track: Int) -> String {
        "\(detail?.activeStems ?? ""):\(track):\(Int(note.tick)):\(note.string):\(note.pitch):\(Int(note.duration)):"
            + "\(Int((grid.seconds(at: note.tick) * 100).rounded())):"
            + "\(Int((grid.seconds(at: note.tick + note.duration) * 100).rounded()))"
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
        guard pitchStem(track: track).measured, Date() >= curvesRetryAt else { return }
        let batch = Array(notes.filter { !curvesAsked.contains(curveKey($0, track: track)) }.prefix(120))
        guard !batch.isEmpty else { return }
        batch.forEach { curvesAsked.insert(curveKey($0, track: track)) }
        DispatchQueue.main.async { [weak self] in
            Task { await self?.fetchCurves(batch, track: track) }
        }
    }

    /// Até quando não pedir curvas, depois de um pedido que falhou (a Fita pede a cada quadro).
    @ObservationIgnored private var curvesRetryAt = Date.distantPast

    /// As curvas de `batch` (já marcadas como pedidas), guardadas como `SoundNote`. Se o motor falha, as notas deixam
    /// de estar pedidas (voltam a ser pedidas daqui a pouco; antes ficavam sem curva até reabrir a música) e devolve
    /// false. Uma nota que o motor não mede (mais de 8 s) não volta na resposta e não é pedida de novo.
    @discardableResult
    private func fetchCurves(_ batch: [ScoreNote], track: Int) async -> Bool {
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
        else {
            for item in list { curvesAsked.remove(item.key) }
            curvesRetryAt = Date().addingTimeInterval(5)
            return false
        }
        // A nota seguinte da corda, se começa onde a nota acaba (a subida no fim que chega a ela é a passagem).
        let line = scoreNotes.indices.contains(track) ? scoreNotes[track] : []
        func next(_ note: ScoreNote) -> Int? {
            line.first { $0.string == note.string && abs($0.tick - (note.tick + note.duration)) < 1 }?.pitch
        }
        for (item, note) in zip(list, batch) {
            guard let curve = curves[item.key] else { continue }
            let raw = RawCurve(curve: curve, start: item.start, end: item.end, pitch: item.pitch,
                               chord: chords.contains(item.key), plain: note.bend.isEmpty, next: next(note),
                               written: note.bend, approached: note.approached, slidesOut: note.slidesOut)
            rawCurves[item.key] = raw
            soundNotes[item.key] = raw.sound(tuning: tuning)
        }
        pitchCurvesVersion += 1
        return true
    }

    /// A curva como veio do motor (na altura da gravação) e o que a nota precisa para virar `SoundNote`.
    private struct RawCurve {
        let curve: PitchCurve
        let start: Double
        let end: Double
        let pitch: Int
        let chord: Bool
        let plain: Bool
        let next: Int?
        let written: [ScoreNote.BendPoint]
        let approached: Bool
        let slidesOut: Bool

        func sound(tuning: Double) -> SoundNote {
            SoundNote(curve: curve.shifted(by: -tuning), start: start, end: end, pitch: Double(pitch), chord: chord,
                      next: next, written: written, approached: approached, slidesOut: slidesOut)
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
    func measureLater() {
        measureTask?.cancel()
        guard lensVisible else { return }
        measureTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            measuring = true
            defer { measuring = false }
            for track in shownTracks
            where scoreNotes.indices.contains(track) && pitchStem(track: track).measured {
                var failures = 0
                while !Task.isCancelled {
                    let batch = Array(scoreNotes[track].filter { !self.curvesAsked.contains(self.curveKey($0, track: track)) }
                        .prefix(120))
                    guard !batch.isEmpty else { break }
                    batch.forEach { self.curvesAsked.insert(self.curveKey($0, track: track)) }
                    if await fetchCurves(batch, track: track) { continue }
                    // O motor falhou: tenta de novo daqui a 5 s, três vezes no máximo.
                    failures += 1
                    guard failures < 3 else { break }
                    try? await Task.sleep(for: .seconds(5))
                }
            }
            if !Task.isCancelled {
                updateTuning()
                if correctWhenMeasured {
                    correctWhenMeasured = false
                    correctBySound(afterMeasuring: true)
                }
            }
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
            await loadSounds(stem: stem)
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
            // Pede de novo na próxima vez (a Lente ligada outra vez, outra pista), se nenhum pedido mais novo tomou o
            // lugar: antes a chave ficava e o espectro não vinha até reabrir a música.
            if spectrumKey == key { spectrumKey = nil }
        }
        await loadSounds(stem: stem)
    }

    /// Os sons da faixa em que a pista soa (para o som sem nota escrita); uma vez por faixa.
    func loadSounds(stem: String?) async {
        let key = "\(detail?.activeStems ?? "")/\(stem ?? "original")"
        guard key != soundsKey else { return }
        soundsKey = key
        do {
            let found = try await Backend.shared.sounds(id, stem: stem)
            guard soundsKey == key else { return }
            heardSounds = found
            soundsVersion += 1
        } catch {
            soundsKey = nil
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

    /// As gravações dos trechos, uma por vez e cada uma com a lista mais nova: a lista muda na tela já, e a mudança
    /// seguinte parte dela (antes, duas mudanças antes da resposta do motor partiam da mesma lista velha e a segunda
    /// desfazia a primeira).
    @ObservationIgnored private var sectionsSave: Task<Void, Never>?
    @ObservationIgnored private var sectionsRevision = 0

    private func save(_ list: [StudySection], select range: (Double, Double)? = nil) {
        // Os compassos de cada trecho, pelas barras da partitura (a biblioteca de trechos mostra; o motor não as tem).
        let bars = grid.barTicks
        let counted = list.map { section -> StudySection in
            var copy = section
            if copy.id == nil { copy.id = StudySection.newID() }
            let inside = bars.filter { $0 >= section.from - 1 && $0 < section.to - 1 }.count
            if inside > 0 { copy.bars = inside }
            return copy
        }
        sections = counted
        if let range, let made = counted.first(where: { $0.from == range.0 && $0.to == range.1 }) { activate(made) }
        sectionsRevision += 1
        let revision = sectionsRevision
        let previous = sectionsSave
        sectionsSave = Task {
            await previous?.value
            do {
                let saved = try await Backend.shared.putSections(id, counted)
                // A lista do motor (com o treino de cada trecho), se nenhuma mudança mais nova está a caminho.
                if revision == sectionsRevision { sections = saved }
                onStudyChange?()
            } catch {
                notice = error.localizedDescription
                if revision == sectionsRevision, let fresh = try? await Backend.shared.song(id) { sections = fresh.sections }
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

    // MARK: - Bend (o editor da coluna)

    /// O bend nas notas escolhidas: os pontos da forma (nil tira). A página confere se cabem no Guitar Pro 7.
    func setBend(_ form: BendForm?) {
        tabEdit("bend", ["points": form?.valid().points ?? []])
    }

    /// B: a altura do bend da nota (½, 1, 1½, 2 e tira, como a tecla fazia); sem bend, um bend de ½ rápido.
    func cycleBendHeight() {
        guard let selection = tabSelection else { return }
        guard var form = selection.bendForm else {
            setBend(BendForm.make(.bend, carried: selection.carried).with(height: 2))
            return
        }
        // A Volta parte da altura que vem ligada: B nela só tira.
        let current = form.kind.usesTop ? form.top : form.pre
        guard form.kind != .release, let next = [2, 4, 6, 8].first(where: { $0 > current }) else {
            setBend(nil)
            return
        }
        form = form.with(height: next)
        setBend(form)
    }

    /// ⇧B: o tipo seguinte (Bend, Bend e volta, Pré-bend, Pré e bend, Pré e volta e, numa ligada que traz um bend, a
    /// Volta), com as alturas que dá para aproveitar.
    func cycleBendKind() {
        guard let selection = tabSelection else { return }
        var kinds: [BendForm.Kind] = [.bend, .bendRelease, .prebend, .prebendBend, .prebendRelease]
        if selection.carried > 0 { kinds.append(.release) }
        let current = selection.bendForm
        let next = current.flatMap { kinds.firstIndex(of: $0.kind) }.map { kinds[($0 + 1) % kinds.count] } ?? .bend
        setBend(BendForm.make(next, from: current, carried: selection.carried))
    }

    /// O som da nota escolhida no tempo dela, para o gráfico do bend: (fração 0–1 da batida, quartos de tom acima da
    /// altura escrita), da curva medida pela Lente (já com a afinação da gravação descontada). Vazio sem medida.
    func selectedBendSound() -> [(fraction: Double, quarterTones: Double)] {
        _ = pitchCurvesVersion   // as curvas refeitas (a afinação da gravação recalculada) redesenham o gráfico
        guard let selection = tabSelection, let tick = selection.ownTick, let own = selection.ownLength, own > 0,
              let (note, track) = selectedScoreNote(), let sound = soundNotes[curveKey(note, track: track)] else { return [] }
        let start = grid.seconds(at: tick)
        let end = grid.seconds(at: tick + own)
        guard end > start else { return [] }
        var out: [(fraction: Double, quarterTones: Double)] = []
        for (index, value) in sound.quick.enumerated() {
            guard let value else { continue }
            let t = sound.curve.from + Double(index) * sound.curve.hop
            guard t >= start, t <= end else { continue }
            out.append(((t - start) / (end - start), (value - Double(selection.pitch)) * 2))
        }
        return out
    }

    /// O bend que o som da nota escolhida faz (o que o F escreveria), para o gráfico do editor: nil sem medida, sem bend
    /// no som, noutra casa, ou numa nota ligada (o som é medido na cadeia inteira, e os pontos da nota são da batida).
    func selectedBendSuggestion() -> BendForm? {
        _ = pitchCurvesVersion
        guard let selection = tabSelection, let own = selection.ownLength, let length = selection.length,
              abs(own - length) < 1, let (note, track) = selectedScoreNote(),
              let fit = soundNotes[curveKey(note, track: track)]?.fit, fit.base == selection.pitch else { return nil }
        return fit.form
    }

    // MARK: - Notas no espectro (a Lente do TabLab)

    /// Um clique numa faixa do espectro: liga a edição e escolhe a nota na TAB.
    func selectNote(_ note: ScoreNote, track: Int) {
        if !editingTab { editingTab = true }
        tabMessage = nil
        bridge.edit("select", ["track": track, "tick": note.tick, "string": note.string])
    }

    /// A nota escolhida, na lista da pista (com a curva, se já chegou).
    func selectedScoreNote() -> (note: ScoreNote, track: Int)? {
        guard let selection = tabSelection, scoreNotes.indices.contains(selection.track) else { return nil }
        return scoreNotes[selection.track].first { selection.matches($0, track: selection.track) }
            .map { ($0, selection.track) }
    }

    /// As notas da pista em que o som discorda da escrita (`SoundNote.disagreements`), em ordem de tempo e de corda.
    /// Uma suspeita: uma nota escrita em que o som discorda (`note` e os motivos), ou um som forte sem nota escrita
    /// (`note` nil). `seconds` e `pitch` dizem onde, para a navegação e a Lente.
    struct Suspect {
        let note: ScoreNote?
        let seconds: Double
        let pitch: Int
        let reasons: [SoundDisagreement]
        let kind: SuspectKind
    }

    /// Os tipos de suspeita ligados no filtro da coluna (guardados); o vibrato, o ataque e o som sem nota vêm
    /// desligados. A escolha de antes (`suspectKinds`, quando os dois vinham ligados) passa sem eles, uma vez.
    var suspectKinds: Set<SuspectKind> = {
        let defaults = UserDefaults.standard
        if let saved = defaults.stringArray(forKey: "suspectKinds2") {
            return Set(saved.compactMap(SuspectKind.init(rawValue:)))
        }
        let old = defaults.stringArray(forKey: "suspectKinds").map { Set($0.compactMap(SuspectKind.init(rawValue:))) }
        return old?.subtracting([.attack, .unwritten]) ?? SuspectKind.standard
    }() {
        didSet { UserDefaults.standard.set(suspectKinds.map(\.rawValue).sorted(), forKey: "suspectKinds2") }
    }

    /// Todas as suspeitas da pista, de todos os tipos, em ordem de tempo (o filtro escolhe as que aparecem).
    func allSuspects(track: Int) -> [Suspect] {
        guard scoreNotes.indices.contains(track) else { return [] }
        let key = [pitchCurvesVersion, notesVersion, track, soundsVersion]
        if let suspectCache, suspectCache.key == key { return suspectCache.list }
        var list: [Suspect] = []
        for note in scoreNotes[track] {
            guard let sound = soundNotes[curveKey(note, track: track)] else { continue }
            let start = grid.seconds(at: note.tick)
            let end = grid.seconds(at: note.tick + note.duration)
            let reasons = sound.checks(with: note, start: start, end: end)
            guard let first = reasons.first else { continue }
            list.append(Suspect(note: note, seconds: start, pitch: note.pitch, reasons: reasons, kind: first.kind))
        }
        // O som forte sem nota escrita: nos sons da faixa da pista, contra as notas de todas as pistas (o vazamento de
        // outro instrumento na faixa não conta).
        if pitchStem(track: track).measured, !heardSounds.isEmpty {
            let notes = scoreNotes.flatMap { $0 }.map { note in
                (start: grid.seconds(at: note.tick), end: grid.seconds(at: note.tick + note.duration), pitch: note.pitch)
            }
            for sound in HeardSound.unwritten(heardSounds, notes: notes) {
                list.append(Suspect(note: nil, seconds: sound.seconds, pitch: sound.pitch, reasons: [], kind: .unwritten))
            }
        }
        list.sort { ($0.seconds, $0.note?.string ?? 0) < ($1.seconds, $1.note?.string ?? 0) }
        suspectCache = (key, list)
        return list
    }

    /// As suspeitas que aparecem: as dos tipos ligados (numa nota, só os motivos desses tipos).
    func suspects(track: Int) -> [Suspect] {
        allSuspects(track: track).compactMap { suspect in
            guard suspect.note != nil else { return suspectKinds.contains(.unwritten) ? suspect : nil }
            let reasons = suspect.reasons.filter { suspectKinds.contains($0.kind) }
            guard let first = reasons.first else { return nil }
            return Suspect(note: suspect.note, seconds: suspect.seconds, pitch: suspect.pitch, reasons: reasons, kind: first.kind)
        }
    }

    /// Quantas suspeitas de cada tipo a pista tem (para o filtro).
    func suspectCounts(track: Int) -> [SuspectKind: Int] {
        var counts: [SuspectKind: Int] = [:]
        for suspect in allSuspects(track: track) {
            if suspect.note == nil {
                counts[.unwritten, default: 0] += 1
            } else {
                for kind in Set(suspect.reasons.map(\.kind)) { counts[kind, default: 0] += 1 }
            }
        }
        return counts
    }

    /// As notas suspeitas (dos tipos ligados) da pista, para o contorno vermelho na Lente.
    func suspectNotes(track: Int) -> Set<ScoreNote> {
        Set(suspects(track: track).compactMap(\.note))
    }

    /// Os sons sem nota escrita (se o tipo está ligado), para a Lente.
    func unwrittenSounds(track: Int) -> [Suspect] {
        suspectKinds.contains(.unwritten) ? allSuspects(track: track).filter { $0.note == nil } : []
    }

    /// Tab e ⇧Tab: a suspeita seguinte (ou a anterior) da pista, a partir da nota escolhida ou da agulha. Numa nota,
    /// escolhe a nota (liga a edição); num som sem nota, põe o cursor de inserção ali, na corda mais à mão e com a casa
    /// sugerida. Leva a agulha até lá e diz o que o som tem.
    func nextSuspect(_ delta: Int) {
        let track = scoreTrack
        let list = suspects(track: track)
        guard !list.isEmpty else {
            tabMessage = measuring ? "Medindo o som das notas…" : "Nenhuma suspeita desses tipos nesta pista."
            return
        }
        let here = selectedScoreNote().flatMap { $0.track == track ? grid.seconds(at: $0.note.tick) : nil }
            ?? engine.currentTime
        let index: Int
        if delta > 0 {
            index = list.firstIndex { $0.seconds > here + 0.005 } ?? 0
        } else {
            index = list.lastIndex { $0.seconds < here - 0.005 } ?? list.count - 1
        }
        let suspect = list[index]
        let counter = "Suspeita \(index + 1) de \(list.count)\(measuring ? "…" : ""): "
        if let note = suspect.note {
            selectNote(note, track: track)
            engine.seek(to: suspect.seconds)
            tabMessage = counter + Self.describe(suspect.reasons) + " · F encaixa"
        } else {
            if !editingTab { editingTab = true }
            bridge.edit("caretPitch", ["track": track, "tick": grid.tick(at: suspect.seconds), "pitch": suspect.pitch])
            engine.seek(to: suspect.seconds)
            tabMessage = counter + "soa \(Self.pitchName(suspect.pitch)) sem nota escrita · Pôr nota (ou a casa) escreve"
        }
    }

    /// O que o som tem, em palavras.
    static func describe(_ reasons: [SoundDisagreement]) -> String {
        reasons.map { reason in
            switch reason {
            case let .pitch(pitch): "soa \(pitchName(pitch))"
            case let .bend(quarterTones): quarterTones > 0 ? "o som dobra \(bendName(quarterTones))" : "o som não dobra"
            case let .prebend(quarterTones): "o som já começa dobrado (pré-bend \(bendName(quarterTones)))"
            case .noPrebend: "o pré-bend escrito não soa (o som parte da casa)"
            case let .release(quarterTones): "o som volta" + (quarterTones > 0 ? " a \(bendName(quarterTones))" : "")
            case .noRelease: "a volta escrita não soa"
            case let .trill(low, high): "trinado \(pitchName(low))⇄\(pitchName(high))"
            case .noTrill: "o som não faz o trinado escrito"
            case let .attack(ms): "o ataque soa \(abs(ms)) ms \(ms < 0 ? "antes" : "depois")"
            case .silent: "a nota não soa"
            case .vibrato: "o som tem vibrato, não escrito"
            }
        }
        .joined(separator: ", ")
    }

    /// O que o som fez na nota escolhida, em palavras (a linha embaixo da escolha na barra de edição): "soou D4 +12
    /// cents · bend 1 tom, 90 % do escrito · vibrato de 25 cents". Com a afinação da gravação já descontada.
    var soundSummary: String? {
        _ = pitchCurvesVersion   // a linha acompanha as curvas refeitas (antes podia ficar com a medida de antes)
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
        if let form = report.form {
            parts.append("bend: " + form.spoken + (report.reached.map { ", \($0) % do escrito" } ?? ", não escrito"))
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

    /// Uma nota para ouvir (o clique na TAB ou na Lente toca o som gravado; o botão direito, a nota sintetizada). O som
    /// gravado é o trecho dela na faixa onde a pista soa (o original sem separação), sozinho, e a agulha volta ao
    /// começo; tocando, não interrompe. A sintetizada usa o SoundFont da TAB sintetizada, com o bend e o vibrato
    /// escritos, no tom e na velocidade do estudo.
    func hear(track: Int, tick: Double, string: Int, pitch: Int, from: Double, to: Double, synth: Bool) {
        guard !grid.isEmpty, to > from else { return }
        let start = grid.seconds(at: from)
        let end = grid.seconds(at: to)
        guard end > start else { return }
        if synth {
            let written = scoreNotes.indices.contains(track)
                ? scoreNotes[track].first { abs($0.tick - tick) < 1 && $0.string == string } : nil
            playSynth(pitch: pitch, seconds: end - start, track: track,
                      shape: written.map { note in { note.shape(fraction: $0, elapsed: $1) } })
            return
        }
        let view = viewStart(now: engine.currentTime)
        keepView = view
        engine.audition(from: start, to: end, track: pitchStem(track: track).stem)
        if engine.auditionActive {
            auditionView = view
            bridge.setView(at: playheadAt, pin: loopPin, hold: view)
        }
    }

    // MARK: - Compassos

    /// Os compassos da partitura mudaram na edição: a Fita passa a ter os compassos novos, o mapa de tempo que a página
    /// fez acompanhar é gravado (vai para o histórico do pacote), e os trechos de estudo e os compassos conferidos andam
    /// junto.
    func restructure(points: [TempoPoint], barTicks: [Double], markers: [(tick: Double, name: String)], change: BarChange?) {
        self.markers = markers
        if points.count >= 2 { grid = TempoGrid(points: points, barTicks: barTicks) }
        if let map = tempoMap, points.count >= 2, map.points != points {
            replace(with: TempoMapDocument(source: map.source, algorithm: map.algorithm, points: points), done: {}, failed: {})
        }
        guard let change else { return }
        let moved = sections.compactMap { section -> StudySection? in
            var copy = section
            copy.from = change.moved(section.from)
            copy.to = change.moved(section.to, end: true)
            return copy.to - copy.from > 1 ? copy : nil
        }
        if moved != sections { save(moved) }
        let checked = change.moved(checked: checkedBars)
        if checked != checkedBars {
            checkedBars = checked
            Task { checkedBars = Set((try? await Backend.shared.putChecked(id, bars: checked.sorted())) ?? checked.sorted()) }
        }
    }

    /// Pôr um compasso antes ou depois do da escolha, apagá-lo, ou mudar a fórmula dele (todas as pistas).
    func editBar(_ action: String, numerator: Int? = nil, denominator: Int? = nil) {
        var value: [String: Any] = ["action": action]
        if let numerator, let denominator {
            value["numerator"] = numerator
            value["denominator"] = denominator
        }
        tabEdit("bar", value)
    }

    // MARK: - Copiar e colar na TAB

    /// O tipo do recorte da TAB na área de transferência do macOS: cola noutra música (e depois de reabrir o app).
    static let clipType = NSPasteboard.PasteboardType("local.tracklab.tab-clip")

    /// ⌘C e ⌘X na edição: a página faz o recorte das notas escolhidas (as batidas inteiras) e o manda para cá.
    func copyTab(cut: Bool) {
        guard tabSelection != nil else {
            tabMessage = "Escolha as notas para copiar (um clique, ⇧ clique ou ⇧← →)."
            return
        }
        tabEdit(cut ? "cut" : "copy")
    }

    /// ⌘V na edição: o recorte entra a partir da nota escolhida ou do cursor de inserção, por cima do que estava.
    func pasteTab() {
        guard let data = NSPasteboard.general.data(forType: Self.clipType),
              let clip = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            tabMessage = "Nada da TAB copiado ainda: ⌘C numa nota ou num trecho escolhido."
            return
        }
        tabEdit("paste", clip)
    }

    private func storeClip(_ clip: [String: Any], beats: Int, cut: Bool) {
        guard let data = try? JSONSerialization.data(withJSONObject: clip) else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(data, forType: Self.clipType)
        board.setString("TrackLab: \(beats) \(beats == 1 ? "batida" : "batidas") da TAB", forType: .string)
        tabMessage = (cut ? "Recortado" : "Copiado") + ": \(beats) \(beats == 1 ? "batida" : "batidas")"
            + " · ⌘V cola a partir da nota ou da linha escolhida (também noutra música)"
    }

    /// Uma nota da Lente (clicada ou com o botão direito).
    func hearNote(_ note: ScoreNote, track: Int, synth: Bool) {
        hear(track: track, tick: note.tick, string: note.string, pitch: note.pitch, from: note.tick,
             to: note.tick + note.duration, synth: synth)
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

    /// Dividir (/): a nota vira duas ligadas com o mesmo som, para a segunda ter articulação dela (o vibrato no fim de
    /// um bend). A página divide no cursor de inserção, se ele está dentro de uma nota, senão na agulha, se ela está
    /// dentro da escolhida, senão no meio; na grade.
    func splitNote() {
        guard editingTab, tabSelection != nil || tabCaret != nil, !grid.isEmpty else { return }
        bridge.edit("split", grid.tick(at: engine.currentTime))
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
                SoundNote(curve: $0.shifted(by: -tuning), start: start, end: end, pitch: Double(pitch), chord: chord,
                          approached: note.approached, slidesOut: note.slidesOut)
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
        // Só o que muda, como a Lente: a altura, o bend (o tipo, as alturas e o tempo) e o vibrato.
        let written = BendForm(points: note.bend.map { [$0.offset, $0.value] })
        var parts: [String] = []
        if fit.base != note.pitch { parts.append(Self.pitchName(fit.base)) }
        if let heard = fit.form, let written, heard.kind == written.kind, heard.spoken == written.spoken {
            if heard.points != written.points { parts.append("o tempo do bend") }
        } else if fit.form != nil || !note.bend.isEmpty {
            parts.append(fit.form.map { "bend: \($0.spoken)" } ?? "sem bend")
        }
        if fit.vibrato != (note.vibrato > 0) { parts.append(fit.vibrato ? "vibrato" : "sem vibrato") }
        if note.trill != nil { parts.append("sem trinado") }
        // Numa nota ligada com vibrato escrito numa parte só, o vibrato pode ir às outras em que o som vibra (a página
        // decide pela medida e não muda nada se já está assim; antes o F nem mandava, "Já está como soa").
        let chain = (tabSelection?.ownLength).map { own in (tabSelection?.length ?? own) - own > 1 } ?? false
        if parts.isEmpty, fit.vibrato, chain {
            parts.append("vibrato nas partes ligadas em que o som vibra")
        }
        guard !parts.isEmpty else {
            tabMessage = "Já está como soa."
            return
        }
        let bend: Any = fit.guitarPro.map { $0.map { [$0.offset, $0.value] } } ?? NSNull()
        var value: [String: Any] = ["pitch": fit.base, "bend": bend, "vibrato": fit.vibrato]
        if fit.vibrato, let from = vibratoFrom(note, fit: fit) { value["vibratoFrom"] = from }
        bridge.edit("fit", value)
        tabMessage = "Encaixou no som: " + parts.joined(separator: ", ") + " · ⌘Z desfaz"
    }

    /// Toca uma nota sintetizada no instrumento da pista (o da TAB sintetizada), no tom e na velocidade do estudo:
    /// `seconds` do áudio, `shape(fração, segundos)` semitons a mais a cada instante (o bend e o vibrato).
    func playSynth(pitch: Int, seconds: Double, track: Int, shape: ((Double, Double) -> Double)?) {
        let info = detail?.synth?.tracks[String(track)]
        let name = (scoreTracks.first { $0.index == track }?.name ?? "").lowercased()
        let program = info?.program ?? (name.contains("bass") || name.contains("baixo") ? 33 : 29)
        do {
            try NoteSynth.shared.play(pitch: pitch, seconds: seconds / Double(max(engine.rate, 0.1)),
                                      program: program, percussion: info?.percussion ?? false,
                                      transpose: Double(engine.semitones) + Double(engine.cents) / 100, shape: shape)
        } catch {
            tabMessage = error.localizedDescription
        }
    }

    static func pitchName(_ midi: Int) -> String {
        TabSelection.name(midi)
    }

    static func bendName(_ quarterTones: Int) -> String {
        let name = BendForm.name(quarterTones)
        return quarterTones < 4 ? name : quarterTones < 8 ? "\(name) tom" : "\(name) tons"
    }

    /// A gravação da TAB em curso: a seguinte espera por ela.
    @ObservationIgnored private var scoreSave: Task<Void, Never>?

    /// Uma gravação por vez, na ordem em que a página manda: uma mais velha que demorasse (o motor ocupado) chegaria
    /// depois da mais nova e desfaria a última edição no pacote.
    private func saveScore(_ data: Data) {
        let previous = scoreSave
        scoreSave = Task {
            await previous?.value
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
                // A partitura ou o mapa mudou durante a síntese (uma edição concluída enquanto ela rodava): outra
                // vez, uma só, com o que está gravado agora.
                if fresh.synth?.stale == true, !editingTab, !adjusting, !synthRetried {
                    synthRetried = true
                    Task { await synthesize(quiet: true) }
                } else {
                    synthRetried = false
                }
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
