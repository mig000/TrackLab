import AVFoundation
import TrackLabCore

/// Uma volta tocada no Estudar (gravada sem virar take): a velocidade, a nota dela e o arquivo (até a próxima, para
/// ouvir), e o que o Miguel achou antes de ver a nota.
struct StudyPass: Identifiable {
    let id: String
    let rate: Int
    let score: PassScore
    let file: String
    var rating: String?
}

/// O que se ouve no Gravar depois das voltas: você no lugar da guitarra do disco, ou o disco, ou os dois alternando.
enum BandListen: String, CaseIterable, Identifiable {
    case you, record, alternate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .you: "Você"
        case .record: "O disco"
        case .alternate: "Alternar a cada volta"
        }
    }
}

extension SongModel {
    // MARK: - A nota de uma volta

    /// As notas da pista principal que começam no trecho, para a nota da volta (a altura esperada com o tom do estudo).
    func passNotes(from: Double, to: Double, cents: Int) -> [PassNote] {
        guard scoreNotes.indices.contains(scoreTrack) else { return [] }
        let notes = scoreNotes[scoreTrack]
        var perTick: [Double: Int] = [:]
        for note in notes { perTick[note.tick, default: 0] += 1 }
        return notes.compactMap { note in
            let start = grid.seconds(at: note.tick)
            guard start >= from - 0.01, start < to - 0.03 else { return nil }
            let end = min(to, grid.seconds(at: note.tick + note.duration))
            return PassNote(key: "\(Int(note.tick)):\(note.string)", start: start, end: end,
                            pitch: Double(note.pitch) + Double(cents) / 100, bar: grid.bar(at: start + 0.001) ?? 0,
                            chord: (perTick[note.tick] ?? 0) > 1, bend: !note.bend.isEmpty)
        }
    }

    /// A nota de uma volta gravada no arquivo `file` do pacote (`takes/<nome>`), que começa em `start` da música e foi
    /// tocada a `rate` e com o tom `cents`: o motor mede cada nota no arquivo e o núcleo compara com a TAB.
    func scorePass(file: String, start: Double, length: Double, rate: Double, cents: Int) async -> PassScore? {
        let notes = passNotes(from: start, to: start + length, cents: cents)
        let rate = rate > 0 ? rate : 1
        let requests = notes.compactMap { note -> (key: String, start: Double, end: Double, pitch: Double)? in
            let a = max(0, (note.start - start) / rate)
            let b = min(a + 8, (note.end - start) / rate)
            return b > a + 0.03 && (20...110).contains(note.pitch) ? (note.key, a, b, note.pitch) : nil
        }
        guard !requests.isEmpty else { return nil }
        var curves: [String: PitchCurve] = [:]
        do {
            for first in stride(from: 0, to: requests.count, by: 200) {
                let chunk = Array(requests[first..<min(first + 200, requests.count)])
                curves.merge(try await Backend.shared.takeCurves(id, file: file, notes: chunk)) { $1 }
            }
        } catch {
            notice = "Não consegui dar nota à volta: \(error.localizedDescription)"
            return nil
        }
        return PassScore.evaluate(notes: notes.filter { curves[$0.key] != nil }, curves: curves, start: start, rate: rate)
    }

    // MARK: - Gravar: a nota dos takes

    /// A nota de cada take que ainda não tem; com `batch`, são as voltas que acabaram de ser gravadas: a melhor passa a
    /// soar e o Gravar pergunta como foram antes de mostrar os números.
    func scoreTakes(_ takes: [Take], batch: Bool) async {
        if batch {
            takeBatch = takes.map(\.id)
            takeRating = nil
        }
        for take in takes where takeScores[take.id] == nil {
            if let score = await scorePass(file: take.file, start: take.start, length: take.length, rate: take.rate,
                                           cents: take.cents) {
                takeScores[take.id] = score
            }
        }
        guard batch, takes.count > 1 else { return }
        let scored = takes.compactMap { take in takeScores[take.id].map { (take, $0) } }
        guard let best = scored.max(by: { $0.1.share < $1.1.share }) else { return }
        chooseTake(best.0.id)
        notice = "Soa a melhor volta: \(best.0.name) (\(Int((best.1.share * 100).rounded())) %). Antes dos números: como foram?"
    }

    /// O que se ouve no Gravar depois das voltas.
    func applyBandListen(_ choice: BandListen) {
        bandListen = choice
        switch choice {
        case .you, .alternate:
            studio.on = true
            if !engine.stemIDs.isEmpty {
                engine.useStems = true
                apply(.noGuitar)
            }
        case .record:
            studio.on = false
            if !engine.stemIDs.isEmpty { apply(.full) }
        }
        applyTakeGains()
        bandPass = 0
    }

    // MARK: - As voltas do loop

    /// Vigia as voltas do loop (a música volta ao começo dele): o Eco cala e devolve a guitarra, o Estudar grava e dá
    /// nota a cada volta, o Gravar conta as voltas, e "Alternar" troca você e o disco.
    func startPassWatcher() {
        passWatcher?.cancel()
        passWatcher = Task { @MainActor [weak self] in
            var last: Double?
            var version = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard let self else { return }
                let now = engine.currentTime
                // A volta: o tempo cai no mesmo plano de tocar (um salto, uma pausa ou outra velocidade mudam o plano e
                // não contam como volta).
                if engine.isPlaying, engine.loop != nil, let last, now < last - 0.15, engine.transportVersion == version {
                    loopWrapped()
                }
                last = engine.isPlaying ? now : nil
                version = engine.transportVersion
                studyTick()
            }
        }
    }

    /// Ao fechar a música: a vigia para, a volta que estava entrando e a última guardada saem, o Eco devolve a mixagem.
    func stopPasses() {
        passWatcher?.cancel()
        passWatcher = nil
        passPlayer?.stop()
        discardStudyPass()
        if let file = studyPass?.file, let detail { try? FileManager.default.removeItem(at: detail.url(file)) }
        studyPass = nil
        if eco { setEco(false) }
    }

    private func loopWrapped() {
        if eco {
            ecoPass += 1
            applyEco()
        }
        if studio.recording { recordPass += 1 }
        if recordMode, bandListen == .alternate, !studio.recording {
            bandPass += 1
            studio.on = bandPass % 2 == 0
            if !engine.stemIDs.isEmpty { apply(bandPass % 2 == 0 ? .noGuitar : .full) }
            applyTakeGains()
        }
        if studySession != nil { finishStudyPass(restart: true) }
    }

    // MARK: - Eco

    /// O Eco (pergunta e resposta): numa volta a guitarra do disco toca, na seguinte cala e você responde.
    func setEco(_ on: Bool) {
        if on {
            guard !engine.stemIDs.isEmpty, engine.stemIDs.contains(where: { Stem(rawValue: $0)?.isGuitar == true }) else {
                notice = "O Eco precisa das faixas separadas (a guitarra sozinha)."
                return
            }
            ecoBefore = engine.mix
            ecoUseStems = engine.useStems
            engine.useStems = true
            ecoPass = 1
            eco = true
            applyEco()
            if engine.loop == nil { notice = "Eco ligado: marque um loop (L) para a pergunta e a resposta." }
        } else {
            eco = false
            if let before = ecoBefore { engine.mix = before }
            if let useStems = ecoUseStems { engine.useStems = useStems }
            ecoBefore = nil
            ecoUseStems = nil
        }
    }

    private func applyEco() {
        var mix = engine.mix
        let answer = ecoPass % 2 == 0
        for id in engine.stemIDs where Stem(rawValue: id)?.isGuitar == true {
            var entry = mix[id] ?? StemMix()
            entry.muted = answer
            entry.solo = false
            mix[id] = entry
        }
        engine.mix = mix
    }

    // MARK: - Estudar: cada volta gravada e com nota

    /// Grava as voltas do loop no Estudar quando a guitarra está ligada (o grupo Guitarra do inspetor), tocando, com um
    /// loop e sem estar gravando takes; para e joga fora o que estava entrando quando uma dessas coisas muda.
    private func studyTick() {
        let input = InputEngine.shared
        let wanted = mode == .study && input.running && engine.isPlaying && engine.loop != nil && !studio.recording
        if let session = studySession {
            if !wanted || engine.transportVersion != session.clock.version { discardStudyPass() }
        } else if wanted, let clock = engine.clock {
            do {
                try input.startRecording()
                studySession = (clock, engine.semitones * 100 + engine.cents, input.offsetMS / 1000)
            } catch {
                // A entrada não deixou: tenta de novo no próximo passo.
            }
        }
    }

    /// A volta que estava entrando sai sem nota (parou, saltou, mudou a velocidade, outro modo, ou o Gravar vai gravar).
    func discardStudyPass() {
        guard studySession != nil else { return }
        studySession = nil
        if let raw = InputEngine.shared.stopRecording(at: CACurrentMediaTime()) {
            try? FileManager.default.removeItem(at: raw.url)
        }
    }

    /// No fim de uma volta: a gravação dela para (e a seguinte começa), a volta inteira é recortada, vai ao motor e
    /// ganha a nota; uma volta limpa no trecho ativo vale Limpo, contado pelo som.
    private func finishStudyPass(restart: Bool) {
        guard let session = studySession, let detail else { return }
        guard engine.transportVersion == session.clock.version else {
            discardStudyPass()
            return
        }
        let input = InputEngine.shared
        studySession = nil
        guard let raw = input.stopRecording(at: CACurrentMediaTime()) else { return }
        if restart, let clock = engine.clock, clock.version == session.clock.version {
            if (try? input.startRecording()) != nil { studySession = (clock, session.cents, session.offset) }
        }
        let clock = session.clock
        let elapsed = clock.elapsed(raw.firstHost) + session.offset * clock.rate
        let passes = TakeCut.passes(plan: clock.plan, elapsed: elapsed, frames: raw.frames, sampleRate: raw.sampleRate,
                                    rate: clock.rate)
        let loopLength = clock.plan.loop.map { $0.upperBound - $0.lowerBound } ?? 0
        guard let pass = passes.last(where: { loopLength > 0 && $0.length >= loopLength * 0.85 }) else {
            try? FileManager.default.removeItem(at: raw.url)
            return
        }
        let name = "volta-\(UUID().uuidString.prefix(8).lowercased()).caf"
        let folder = detail.url("takes")
        let source = raw.url
        let rate = Int((clock.rate * 100).rounded())
        Task {
            let copied = await Task.detached(priority: .userInitiated) { () -> Bool in
                defer { try? FileManager.default.removeItem(at: source) }
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = try AVAudioFile(forReading: source)
                    try SongModel.copy(file, from: pass.frame, frames: pass.frames, to: folder.appending(path: name))
                    return true
                } catch {
                    return false
                }
            }.value
            guard copied, let score = await scorePass(file: "takes/\(name)", start: pass.start, length: pass.length,
                                                      rate: clock.rate, cents: session.cents) else { return }
            if let old = studyPass?.file { try? FileManager.default.removeItem(at: detail.url(old)) }
            studyPass = StudyPass(id: name, rate: rate, score: score, file: "takes/\(name)")
            studyHistory.append((rate, score.share, score.clean))
            if studyHistory.count > 8 { studyHistory.removeFirst(studyHistory.count - 8) }
            // O espelho conta pelo som: limpa vale o Limpo (a sequência e a escada), suja zera a sequência.
            guard activeSection != nil, score.total >= 3 else { return }
            if score.clean {
                markClean()
                trainingMessage = (trainingMessage ?? "Limpo") + " · contado pelo som"
            } else {
                markMissed(rate: rate)
                trainingMessage = "\(Int((score.share * 100).rounded())) % a \(rate) %: ainda não limpo"
            }
        }
    }

    /// Ouve a última volta tocada (como foi gravada, na velocidade do estudo).
    func hearStudyPass() {
        guard let pass = studyPass, let detail else { return }
        passPlayer?.stop()
        passPlayer = try? AVAudioPlayer(contentsOf: detail.url(pass.file))
        if engine.isPlaying { engine.pause() }
        passPlayer?.play()
    }
}

extension SongModel {
    /// O loop no compasso `bar` (a partir de 1), do começo dele ao começo do seguinte.
    func loopOnBar(_ bar: Int) {
        let bars = grid.bars
        guard bars.indices.contains(bar - 1) else { return }
        let end = bars.indices.contains(bar) ? bars[bar] : engine.duration
        guard end > bars[bar - 1] else { return }
        setLoop(bars[bar - 1]...end, seekToStart: true)
    }
}
