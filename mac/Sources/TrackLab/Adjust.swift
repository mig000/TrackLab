import AppKit
import TrackLabCore

/// O que se ouve no Ajuste: o disco como está, o disco com o clique do mapa, ou só o clique sobre a bateria (onde o
/// clique fora do lugar mais aparece).
enum AdjustListen: String, CaseIterable, Identifiable {
    case record, withClick, clickAndDrums

    var id: String { rawValue }

    var label: String {
        switch self {
        case .record: "Disco"
        case .withClick: "Disco + clique"
        case .clickAndDrums: "Clique + bateria"
        }
    }
}

/// O alcance de um arrasto de batida no Ajuste: as vizinhas acompanham (até 8 batidas ou a próxima âncora), só esta
/// (⌥), tudo à direita junto (⇧) ou a música inteira (⌥⇧).
enum DragReach {
    case neighbours, only, right, whole

    static func current() -> DragReach {
        let flags = NSEvent.modifierFlags
        switch (flags.contains(.option), flags.contains(.shift)) {
        case (true, true): return .whole
        case (true, false): return .only
        case (false, true): return .right
        default: return .neighbours
        }
    }

    var label: String {
        switch self {
        case .neighbours: "as vizinhas acompanham"
        case .only: "só esta"
        case .right: "tudo à direita junto"
        case .whole: "a música inteira"
        }
    }
}

/// O roteiro do Ajuste, do geral para o particular: o mapa inteiro, os compassos que o som acusa (corrigíveis sem
/// ouvir), os duvidosos (que pedem o ouvido) e a música toda conferida. O passo da vez sai dos dados.
enum AdjustStep: Int, CaseIterable, Comparable {
    case whole = 1, fix, doubtful, check, done

    static func < (a: AdjustStep, b: AdjustStep) -> Bool { a.rawValue < b.rawValue }
}

extension SongModel {
    // MARK: - O roteiro

    /// Se já há o que ouvir para o roteiro (os ataques da guitarra ou as batidas da bateria).
    var adjustReady: Bool { heardBeats != nil || !heardSounds.isEmpty }

    /// O mapa inteiro contra o som.
    var adjustOverall: AdjustReview.Overall? { AdjustReview.overall(adjustReview) }

    /// Os compassos que o som acusa com as duas provas: dá para corrigir sem ouvir.
    var fixableBars: [BarReview] { adjustReview.filter(\.fixable) }

    /// Os que pedem o ouvido: a olhar, sem estar conferidos e sem as duas provas juntas (ou com elas, se o passo de
    /// corrigir foi pulado).
    var doubtfulToHear: [BarReview] {
        let skippedFix = adjustSkipped.contains(.fix)
        return adjustReview.filter { $0.doubtful && !checkedBars.contains($0.bar) && (skippedFix || !$0.fixable) }
    }

    /// O passo da vez: o primeiro que ainda tem o que fazer (e não foi pulado).
    var adjustStep: AdjustStep {
        if adjustOverall?.global == true, !adjustSkipped.contains(.whole) { return .whole }
        if !fixableBars.isEmpty, !adjustSkipped.contains(.fix) { return .fix }
        if !doubtfulToHear.isEmpty, !adjustSkipped.contains(.doubtful) { return .doubtful }
        if nextBarToCheck(after: 0, onlyDoubtful: false).bar != nil { return .check }
        return .done
    }

    /// Passo 1: o mapa todo anda a mediana do que o som diz.
    func shiftWholeMap() {
        guard let overall = adjustOverall, abs(overall.median) >= 0.005 else { return }
        let ms = Int((overall.median * 1000).rounded())
        editTempo(.init(action: "offset", seconds: overall.median),
                  message: "O mapa todo andou \(ms > 0 ? "+" : "−")\(abs(ms)) ms. Próximo: os compassos que o som acusa.")
    }

    func skipAdjustStep(_ step: AdjustStep) { adjustSkipped.insert(step) }

    // MARK: - O tempo ouvido

    /// Ao entrar no Ajuste: os ataques da faixa da pista (para o pente) e o tempo ouvido da faixa de ritmo (a força
    /// dos ataques e as batidas do detector), cada um pedido uma vez por faixa e andamento.
    func loadAdjust() async {
        guard let detail, let audio = detail.audio else { return }
        await loadSounds(stem: pitchStem(track: scoreTrack).stem)
        let bpm = typicalBPM
        let key = "\(audio.sha256 ?? "")/\(detail.activeStems ?? "")/\(bpm.map { Int($0.rounded()) } ?? 0)"
        guard key != beatsKey else { return }
        beatsKey = key
        if heardBeats == nil { adjustMessage = "Ouvindo as batidas…" }
        do {
            let found = try await Backend.shared.beats(id, bpm: bpm)
            guard beatsKey == key else { return }
            heardBeats = found
            if adjustMessage == "Ouvindo as batidas…" { adjustMessage = nil }
        } catch {
            beatsKey = nil
            adjustMessage = "Não ouvi as batidas: \(error.localizedDescription)"
        }
    }

    /// O andamento típico do mapa (a mediana dos compassos), para o detector começar nele.
    var typicalBPM: Double? {
        let gaps = zip(grid.beats, grid.beats.dropFirst()).map { $1 - $0 }.filter { $0 > 0.05 }
        guard !gaps.isEmpty else { return nil }
        let sorted = gaps.sorted()
        return 60 / sorted[sorted.count / 2]
    }

    /// Os ataques escritos da pista principal (o ritmo da TAB, sem as notas), em segundos pelo mapa de agora.
    var writtenAttacks: [Double] {
        guard scoreNotes.indices.contains(scoreTrack) else { return [] }
        let key = "\(notesVersion)/\(scoreTrack)/\(grid.beats.count)/\(grid.beats.first ?? 0)"
        if let attacksCache, attacksCache.key == key { return attacksCache.written }
        let ticks = Set(scoreNotes[scoreTrack].map(\.tick)).sorted()
        let written = ticks.map { grid.seconds(at: $0) }
        attacksCache = (key, written)
        return written
    }

    /// Os ataques ouvidos na faixa em que a pista soa.
    var heardAttacks: [Double] { heardSounds.map(\.seconds) }

    /// Cada compasso com o andamento e o que os ataques e o detector dizem dele (`AdjustReview`), refeito quando o
    /// mapa, as notas, os sons ou as batidas mudam.
    var adjustReview: [BarReview] {
        let key = "\(notesVersion)/\(soundsVersion)/\(heardBeats?.beats.count ?? -1)/\(grid.beats.count)/\(grid.bars.first ?? 0)/\(scoreTrack)"
        if let reviewCache, reviewCache.key == key { return reviewCache.bars }
        let bars = AdjustReview.bars(grid: grid, written: writtenAttacks, heard: heardAttacks,
                                     detected: heardBeats?.beats ?? [])
        reviewCache = (key, bars)
        return bars
    }

    /// Os compassos a olhar: onde o mapa discorda dos ataques ou do detector, ou o andamento salta.
    var doubtfulBars: [BarReview] { adjustReview.filter(\.doubtful) }

    /// O atraso dos ataques de cada compasso (índice 0…), para o "Pelo som": no Ajuste, o do pente (os ataques
    /// ouvidos da faixa, sem precisar da Lente); fora dele, o das curvas que a Lente mede.
    func soundOffsets() -> [Int: Double] {
        guard adjusting, !heardSounds.isEmpty else { return lensVisible ? barOffsets() : [:] }
        var out: [Int: Double] = [:]
        for review in adjustReview { if let attacks = review.attacks { out[review.bar - 1] = attacks } }
        return out
    }

    // MARK: - Arrastar e corrigir

    /// Leva a batida do `tick` até `seconds` com o alcance escolhido no arrasto.
    func moveBeat(tick: Double, to seconds: Double, reach: DragReach) {
        let current = grid.seconds(at: tick)
        switch reach {
        case .neighbours:
            moveBeat(tick: tick, to: seconds)
        case .only:
            editTempo(.init(action: "move", tick: tick, seconds: seconds, reach: 1),
                      message: "Só esta batida andou; as vizinhas ficaram.")
        case .right:
            editTempo(.init(action: "move", tick: tick, seconds: seconds, pull: "right"),
                      message: "A batida e tudo à direita dela andaram junto.")
        case .whole:
            shiftAll(by: seconds - current)
        }
    }

    /// "Corrigir pelo som" nos compassos que o som acusa: as batidas de dentro deles vão até os ataques da guitarra
    /// (a reta dos ataques casados em volta de cada uma, `follow` no motor), e o resto do mapa fica onde está. Num
    /// passo do Desfazer e no histórico do mapa. (Antes, o 1 de cada compasso andava como num arrasto e puxava os
    /// vizinhos certos: no Sultans, 17 compassos acusados viravam 34.)
    func fixDoubtfulBars() {
        let bars = fixableBars.filter { grid.barTicks.indices.contains($0.bar) }
        guard !bars.isEmpty, scoreNotes.indices.contains(scoreTrack) else {
            adjustMessage = "Nada a corrigir pelo som: nenhum compasso com as duas provas juntas."
            return
        }
        // Os ataques escritos com o tique de cada um, e os casados com os ouvidos.
        let ticks = Set(scoreNotes[scoreTrack].map(\.tick)).sorted()
        var tickOf: [Double: Double] = [:]
        for tick in ticks { tickOf[grid.seconds(at: tick)] = tick }
        let pairs: [[Double]] = Comb.pairs(written: Array(tickOf.keys), heard: heardAttacks).compactMap { pair in
            tickOf[pair.written].map { [$0, pair.heard] }
        }
        let ranges = bars.map { [grid.barTicks[$0.bar - 1], grid.barTicks[$0.bar]] }
        editTempo(.init(action: "follow", pairs: pairs, ranges: ranges),
                  message: "Levei \(bars.count) compassos até os ataques da guitarra · ⌘Z desfaz. Próximo: ouvir os duvidosos.")
    }

    /// Na conferência: o 1 do compasso até onde as provas dizem, e toca de novo.
    func snapCheckingBar() {
        guard let bar = checkingBar, adjustReview.indices.contains(bar - 1),
              let correction = adjustReview[bar - 1].correction else { return }
        nudgeCheckingBar(by: correction)
    }

    // MARK: - O que se ouve

    func applyAdjustListen() {
        switch adjustListen {
        case .record:
            if let before = listenBefore {
                engine.useStems = before.useStems
                engine.mix = before.mix
                metronome = before.metronome
                listenBefore = nil
            }
        case .withClick, .clickAndDrums:
            if listenBefore == nil { listenBefore = (engine.useStems, engine.mix, metronome) }
            if let before = listenBefore {
                engine.useStems = before.useStems
                engine.mix = before.mix
            }
            metronome = true
            if adjustListen == .clickAndDrums {
                let stems = engine.stemIDs
                let rhythm = [Stem.drums.rawValue, Stem.bass.rawValue].first(where: stems.contains)
                guard let rhythm else {
                    adjustMessage = "Sem bateria nem baixo separados: o clique toca sobre o disco."
                    return
                }
                engine.useStems = true
                var mix = engine.mix
                for id in stems {
                    var entry = mix[id] ?? StemMix()
                    entry.solo = false
                    entry.muted = id != rhythm
                    mix[id] = entry
                }
                engine.mix = mix
            }
        }
    }

    // MARK: - Conferir de ouvido

    /// O compasso seguinte a conferir depois de `bar` (pulando os conferidos e, se escolhido, os que concordam com o
    /// som) e quantos foram pulados por concordarem.
    func nextBarToCheck(after bar: Int, onlyDoubtful: Bool? = nil) -> (bar: Int?, skipped: Int) {
        let review = adjustReview
        let doubtfulOnly = onlyDoubtful ?? checkOnlyDoubtful
        let hear = Set(doubtfulToHear.map(\.bar))
        var skipped = 0
        var candidate = bar + 1
        while candidate <= review.count {
            if doubtfulOnly {
                if hear.contains(candidate) { return (candidate, skipped) }
            } else if !checkedBars.contains(candidate) {
                if checkSkipAgreeing, review[candidate - 1].agrees() {
                    skipped += 1
                } else {
                    return (candidate, skipped)
                }
            }
            candidate += 1
        }
        return (nil, skipped)
    }

    /// O compasso em que a conferência da música toda começaria agora.
    var nextBarToCheckPreview: Int? { nextBarToCheck(after: 0, onlyDoubtful: false).bar }

    /// Começa a conferência no compasso dado (ou no primeiro que falta).
    func startChecking(from bar: Int? = nil, onlyDoubtful: Bool = false) {
        checkOnlyDoubtful = onlyDoubtful
        checkSession = (0, 0, 0)
        checkChange = nil
        let found = nextBarToCheck(after: 0)
        if bar == nil { checkSession.skipped = found.skipped }
        guard let first = bar ?? found.bar else {
            adjustMessage = "Nada a conferir: os compassos estão conferidos ou concordam com o som."
            return
        }
        if adjustListen == .record { adjustListen = .withClick }
        checkingBar = first
        playCheckingBar()
    }

    /// O compasso em conferência, em loop.
    func playCheckingBar() {
        guard let bar = checkingBar, let range = barRange(bar) else { return }
        setLoop(range, seekToStart: true)
        if !engine.isPlaying { engine.play() }
    }

    /// Certo: o compasso fica conferido, o 1 dele vira âncora (preso onde está: os empurrões seguintes param nele e
    /// não mexem mais no começo dele) e a conferência segue.
    func checkBarOK() {
        guard let bar = checkingBar else { return }
        if !checkedBars.contains(bar) { toggleChecked(bars: [bar]) }
        if grid.barTicks.indices.contains(bar - 1),
           let point = grid.points.first(where: { abs($0.tick - grid.barTicks[bar - 1]) < 0.5 }), !point.isAnchor {
            let tick = point.tick
            let seconds = point.seconds
            Task {
                while saving { try? await Task.sleep(for: .milliseconds(30)) }
                editTempo(.init(action: "move", tick: tick, seconds: seconds))
            }
        }
        checkSession.checked += 1
        advanceChecking(from: bar)
    }

    /// Cedo ou Tarde: o 1 do compasso anda `seconds` (para depois se o mapa vinha antes do som) e toca de novo. O mapa
    /// estica as batidas de antes até a âncora anterior (o compasso conferido antes deste) ou 8 batidas, e encolhe as
    /// de depois até 8 batidas; `checkChange` guarda o que mudou, para a conferência mostrar.
    func nudgeCheckingBar(by seconds: Double) {
        guard let bar = checkingBar, grid.barTicks.indices.contains(bar - 1), grid.bars.indices.contains(bar - 1) else { return }
        checkSession.nudged += 1
        Task {
            while saving { try? await Task.sleep(for: .milliseconds(30)) }
            guard checkingBar == bar else { return }
            let before = grid
            moveBeat(tick: before.barTicks[bar - 1], to: before.bars[bar - 1] + seconds,
                     message: "Compasso \(bar): o 1 andou \(seconds > 0 ? "+" : "−")\(Int((abs(seconds) * 1000).rounded())) ms.")
            while saving { try? await Task.sleep(for: .milliseconds(30)) }
            guard checkingBar == bar else { return }
            checkChange = MapChange.between(before, grid, bars: bar - 2, bar + 2)
            playCheckingBar()
        }
    }

    func skipCheckingBar() {
        guard let bar = checkingBar else { return }
        advanceChecking(from: bar)
    }

    private func advanceChecking(from bar: Int) {
        checkChange = nil
        let found = nextBarToCheck(after: bar)
        checkSession.skipped += found.skipped
        guard let next = found.bar else {
            adjustMessage = checkOnlyDoubtful
                ? "Os duvidosos estão ouvidos (\(checkSession.checked) certos, \(checkSession.nudged) empurrões). Próximo: conferir a música."
                : "Conferência no fim: \(checkSession.checked) conferidos, \(checkSession.nudged) empurrões, "
                    + "\(checkSession.skipped) pulados por concordarem."
            stopChecking()
            return
        }
        checkingBar = next
        playCheckingBar()
    }

    func stopChecking() {
        guard checkingBar != nil else { return }
        checkingBar = nil
        engine.pause()
    }
}
