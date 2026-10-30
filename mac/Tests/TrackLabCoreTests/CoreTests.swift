import Foundation
import Testing
@testable import TrackLabCore

/// Compassos 4/4 de 2 s a partir de 1 s, batidas a cada 0,5 s, como o mapa que o motor faz do Songsterr.
private func grid(bars: Int = 3) -> TempoGrid {
    var points: [TempoPoint] = []
    for beat in 0...(bars * 4) {
        points.append(TempoPoint(tick: Double(beat) * 960, seconds: 1 + Double(beat) * 0.5,
                                 kind: beat % 4 == 0 ? "detected" : "interpolated"))
    }
    return TempoGrid(points: points)
}

@Test func segundosETiquesPeloMapa() {
    let g = grid()
    #expect(g.tick(at: 1) == 0)
    #expect(g.tick(at: 2.25) == 2400)
    #expect(g.seconds(at: 3840) == 3)
    #expect(g.bpm(at: 2) == 120)
    #expect(g.bars == [1, 3, 5, 7])
    #expect(g.bar(at: 3.5) == 2)
    #expect(g.bar(at: 0.5) == nil)
}

@Test func compassosPelaPartituraQuandoEleChega() {
    let g = TempoGrid(points: grid().points, barTicks: [0, 1920, 3840])
    #expect(g.bars == [1, 2, 3])
}

@Test func pontosForaDeOrdemSaem() {
    let g = TempoGrid(points: [TempoPoint(tick: 960, seconds: 2, kind: "x"), TempoPoint(tick: 0, seconds: 1, kind: "x"),
                               TempoPoint(tick: 1920, seconds: 1.5, kind: "x")])
    #expect(g.points.map(\.tick) == [0, 960])
}

@Test func ajusteAchaABatidaEOUm() {
    let g = TempoGrid(points: grid().points, barTicks: [0, 3840, 7680, 11520])
    #expect(g.beat(near: 2.08, within: 0.1)?.tick == 1920)
    #expect(g.beat(near: 2.25, within: 0.1) == nil)
    #expect(g.beat(near: 0.95, within: 0.1)?.tick == 0)
    // O 1 mais perto, nunca o fim do último compasso.
    #expect(g.nearestBarTick(2.9) == 3840)
    #expect(g.nearestBarTick(1.9) == 0)
    #expect(g.nearestBarTick(7.5) == 7680)
    #expect(TempoGrid(points: grid().points).nearestBarTick(2.9) == 3840)
    #expect(g.point(nearTick: 1300)?.tick == 960)
    #expect(g.point(nearTick: 1500)?.tick == 1920)
}

@Test func loopPresoNasBatidas() {
    let g = grid()
    #expect(LoopRegion.snapped(3.2, 1.6, grid: g, duration: 10) == 1.5...3)
    #expect(LoopRegion.snapped(2.0, 2.1, grid: g, duration: 10) == nil)
    #expect(LoopRegion.bar(containing: 3.4, grid: g) == 3...5)
}

@Test func soloEMudo() {
    let gains = mixGains(["guitar": StemMix(volume: 0.8, solo: true), "bass": StemMix(), "drums": StemMix(muted: true, solo: true)])
    #expect(gains["guitar"] == 0.8)
    #expect(gains["bass"] == 0)
    #expect(gains["drums"] == 1)
    #expect(mixGains(["bass": StemMix(muted: true), "drums": StemMix(volume: 0.5)]) == ["bass": 0, "drums": 0.5])
}

@Test func atalhosDoMixer() {
    let stems = Stem.allCases.map(\.rawValue)
    var mix: [String: StemMix] = [:]
    mix["bass"] = StemMix(volume: 0.6)
    let none = MixPreset.noGuitar.apply(to: mix, stems: stems)
    #expect(none["guitar"]?.muted == true)
    #expect(none["bass"] == StemMix(volume: 0.6))
    #expect(MixPreset.matching(none, stems: stems) == .noGuitar)
    let only = MixPreset.guitarOnly.apply(to: none, stems: stems)
    #expect(none["rhythm"]?.muted == true)    // a guitarra base também sai
    #expect(mixGains(only).filter { $0.value > 0 }.keys.sorted() == ["guitar", "rhythm"])
    #expect(MixPreset.matching(only, stems: stems) == .guitarOnly)
    #expect(MixPreset.matching(MixPreset.full.apply(to: only, stems: stems), stems: stems) == .full)
}

@Test func planoSemLoop() {
    let plan = PlaybackPlan(start: 10, loop: nil, duration: 60)
    #expect(plan.segments == [10...60])
    #expect(plan.songTime(after: 5) == 15)
    #expect(plan.songTime(after: 100) == 60)
    #expect(plan.ended(after: 50))
}

@Test func planoComLoopDaAVolta() {
    let plan = PlaybackPlan(start: 2, loop: 4...6, duration: 60)
    #expect(plan.segments.first == 2...6)
    #expect(plan.segments[1] == 4...6)
    #expect(plan.songTime(after: 3) == 5)
    #expect(plan.songTime(after: 4) == 4)
    #expect(abs(plan.songTime(after: 5.5) - 5.5) < 1e-9)
    #expect(!plan.ended(after: 1000))
    // Loop de 2 s: o limite de 400 voltas vem antes dos 20 min.
    #expect(plan.length == 4 + Double(PlaybackPlan.maxRepeats) * 2)
}

@Test func playDepoisDoLoopTocaSolto() {
    let plan = PlaybackPlan(start: 7, loop: 4...6, duration: 60)
    #expect(plan.loop == nil)
    #expect(plan.segments == [7...60])
    #expect(PlaybackPlan(start: 0, loop: 4...4.1, duration: 60).loop == nil)
}

@Test func ondaPorJanela() {
    let peaks = Peaks(perSecond: 4, min: [-0.1, -0.5, 0, -0.2], max: [0.2, 0.1, 0.9, 0.1])
    #expect(peaks.duration == 1)
    #expect(peaks.amplitude(from: 0, to: 0.5) == 0.5)
    #expect(peaks.amplitude(from: 0.5, to: 0.75) == 0.9)
    #expect(peaks.amplitude(from: 2, to: 3) == 0)
}

@Test func manifestoDoMotor() throws {
    let json = """
    {"schema": 1, "id": "song-1", "title": "Sunshine", "artist": "Cream", "folder": "/tmp/x.tracklab",
     "score": {"file": "score/original.gp", "sha256": "a", "measures": 2,
               "tracks": [{"index": 0, "name": "Bass", "instrument": "Bass", "tuning": null},
                          {"index": 1, "name": "Lead Guitar", "instrument": "Distortion Guitar", "tuning": [64]}]},
     "audio": {"file": "audio/source.flac", "sha256": "b", "duration": 12.5, "sampleRate": 44100, "channels": 2},
     "tempoMap": {"file": "score/tempo-map.json", "source": "songsterr", "points": 9},
     "stems": {"demucs6s-1": {"provider": "demucs", "model": "htdemucs_6s", "device": "mps", "seconds": 52.1,
                              "created": "x", "files": {"guitar": "stems/demucs6s-1/guitar.flac"}}},
     "activeStems": "demucs6s-1", "warnings": [], "origin": {"kind": "songsterr"}}
    """
    let song = try JSONDecoder().decode(SongDetail.self, from: Data(json.utf8))
    #expect(song.active?.files["guitar"] == "stems/demucs6s-1/guitar.flac")
    #expect(song.score?.tracks.first(where: \.isGuitar)?.index == 1)
    #expect(song.url("audio/source.flac").path == "/tmp/x.tracklab/audio/source.flac")
}


// MARK: - Repertório

@Test func nomesDasAfinacoes() {
    #expect(Tuning.name([64, 59, 55, 50, 45, 40]) == "Padrão")
    #expect(Tuning.name([63, 58, 54, 49, 44, 39]) == "Mi bemol")
    #expect(Tuning.name([64, 59, 55, 50, 45, 38]) == "Drop D")
    #expect(Tuning.name([63, 58, 54, 49, 44, 37]) == "Drop C#")
    #expect(Tuning.name([62, 57, 55, 50, 45, 38]) == "DADGAD")
    #expect(Tuning.name([43, 38, 33, 28]) == "E A D G")
    #expect(Tuning.name(nil) == "Sem afinação")
}

@Test func tresLimposSobemCincoPorCento() {
    var trainer = SpeedTrainer()
    #expect(trainer.clean(rate: 80, goal: 100) == nil)
    #expect(trainer.clean(rate: 80, goal: 100) == nil)
    #expect(trainer.clean(rate: 80, goal: 100) == 85)
    // Mudar a velocidade à mão recomeça a contagem.
    #expect(trainer.clean(rate: 90, goal: 100) == nil)
    #expect(trainer.streak == 1)
    trainer.reset()
    for _ in 0..<2 { _ = trainer.clean(rate: 98, goal: 100) }
    #expect(trainer.clean(rate: 98, goal: 100) == 100)
    // Na meta, não sobe mais.
    for _ in 0..<2 { _ = trainer.clean(rate: 100, goal: 100) }
    #expect(trainer.clean(rate: 100, goal: 100) == nil)
}

@Test func paraHoje() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z"))
    func section(_ name: String, best: Int?, goal: Int = 100, daysAgo: Int?) -> StudySection {
        let practiced = daysAgo.map { ISO8601DateFormatter().string(from: now.addingTimeInterval(-Double($0) * 86400)) }
        return StudySection(id: name, name: name, from: 0, to: 1920, goal: goal, best: best, practiced: practiced)
    }
    let songs = [
        SongSummary(id: "a", title: "Sunshine", artist: "Cream", folder: "a", hasAudio: true, stems: [],
                    activeStems: nil, updated: nil, status: .learning,
                    sections: [section("Riff", best: 92, daysAgo: 1), section("Solo", best: 60, daysAgo: 9),
                               section("Intro", best: nil, daysAgo: nil), section("Fim", best: 100, daysAgo: 1)]),
        SongSummary(id: "b", title: "White Room", artist: "Cream", folder: "b", hasAudio: true, stems: [],
                    activeStems: nil, updated: nil, status: .repertoire,
                    sections: [section("Riff", best: 100, daysAgo: 10), section("Verso", best: 100, daysAgo: 2)]),
        SongSummary(id: "c", title: "Rebel Rebel", artist: "Bowie", folder: "c", hasAudio: true, stems: [],
                    activeStems: nil, updated: nil, status: .want, measures: 4, checked: 4),
        SongSummary(id: "d", title: "Nova", artist: nil, folder: "d", hasAudio: true, stems: [], activeStems: nil,
                    updated: nil, status: .want, measures: 4, checked: 1),
        SongSummary(id: "e", title: "Velha", artist: nil, folder: "e", hasAudio: true, stems: [], activeStems: nil,
                    updated: nil, status: .archived, sections: [section("x", best: 50, daysAgo: 30)]),
    ]
    let items = TodayPlan.items(songs, now: now)
    #expect(items.map(\.title) == ["Sunshine · Riff", "Sunshine · Solo", "Sunshine · Intro", "White Room · Riff",
                                    "Rebel Rebel"])
    #expect(items.map(\.reason) == ["Meta quase lá", "Sem tocar há 9 dias", "Ainda sem recorde", "Revisão: 10 dias",
                                     "Nova, sincronização conferida"])
    #expect(songs[3].needsSync && !songs[2].needsSync)
}

@Test func resumoDoRepertorio() throws {
    let json = """
    {"id": "song-1", "title": "White Room", "artist": "Cream", "folder": "x.tracklab", "hasAudio": true,
     "stems": ["demucs6s-1"], "activeStems": "demucs6s-1", "status": "polishing", "tuning": [64, 59, 55, 50, 45, 40],
     "sections": [{"id": "sec-1", "name": "Riff", "from": 0, "to": 3840, "goal": 100, "best": 85,
                   "practiced": "2026-10-28T20:00:00.123456+00:00"}],
     "measures": 131, "checked": 3, "warnings": 1}
    """
    let song = try JSONDecoder().decode(SongSummary.self, from: Data(json.utf8))
    #expect(song.status == .polishing && song.tuningName == "Padrão" && song.needsSync)
    #expect(song.sections.first?.startRate == 85)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-10-30T21:00:00Z"))
    #expect(song.sections.first?.daysSincePracticed(now: now) == 2)
    let old = try JSONDecoder().decode(SongSummary.self, from: Data(#"{"id": "s", "folder": "f"}"#.utf8))
    #expect(old.status == .want && old.sections.isEmpty && !old.hasAudio)
}


@Test func buscaSemAcentoPorComecoDePalavra() {
    let song = SongSummary(id: "a", title: "White Room", artist: "Cream", folder: "a", hasAudio: true, stems: [],
                           activeStems: nil, updated: nil, status: .repertoire,
                           sections: [StudySection(name: "Solo de guitarra", from: 0, to: 1), StudySection(name: "Introdução", from: 1, to: 2)],
                           tuning: [63, 58, 54, 49, 44, 39])
    #expect(LibrarySearch.matches(song, "whi roo"))
    #expect(LibrarySearch.matches(song, "CREAM"))
    #expect(LibrarySearch.matches(song, "introducao"))
    #expect(LibrarySearch.matches(song, "mi bemol"))
    #expect(LibrarySearch.matches(song, "no repertorio"))
    #expect(LibrarySearch.matches(song, ""))
    #expect(!LibrarySearch.matches(song, "oom"))
    #expect(!LibrarySearch.matches(song, "white sunshine"))
}

@Test func separacoesNaOrdemDaEscada() throws {
    let json = #"""
    {"id": "s", "folder": "/f", "activeStems": "demucs6s-a",
     "stems": {
       "mvsep101-c": {"provider": "mvsep", "model": "mvsep101", "name": "MVSEP Solo e base", "files": {}},
       "mvsep63-e": {"provider": "mvsep", "model": "mvsep63", "name": "MVSEP 6 faixas (SW)", "files": {}},
       "mvsep31-b": {"provider": "mvsep", "model": "mvsep31", "name": "MVSEP Guitar", "files": {"guitar": "g"}},
       "multitrack-d": {"provider": "multitrack", "model": "multitrack", "library": "Pack/Cream - X",
                        "alignment": {"offset": 0.75, "speed": 0.9917, "agreed": 14, "windows": 24},
                        "files": {"guitar": "g", "bass": "b"}},
       "demucs6s-a": {"provider": "demucs", "model": "htdemucs_6s", "files": {"guitar": "g"}}}}
    """#
    let song = try JSONDecoder().decode(SongDetail.self, from: Data(json.utf8))
    #expect(song.stemKeys == ["demucs6s-a", "multitrack-d", "mvsep63-e", "mvsep31-b", "mvsep101-c"])
    #expect(song.stemKeys.map { song.stems[$0]!.label }
            == ["Demucs 6s", "Multitrack", "MVSEP 6 faixas (SW)", "MVSEP Guitar", "MVSEP Solo e base"])
    #expect(song.stems["multitrack-d"]!.detail
            == "Pack/Cream - X · começa +0.750 s no vídeo · velocidade corrigida -0.830 % · 14 de 24 trechos de acordo")
    #expect(song.active?.label == "Demucs 6s")
}

@Test func bibliotecaDeTrechos() throws {
    let json = #"""
    [{"id": "a", "title": "White Room", "artist": "Cream", "folder": "a", "tuning": [63, 58, 54, 49, 44, 39],
      "sections": [
        {"id": "s1", "name": "Wah do solo", "from": 0, "to": 3840, "goal": 100, "best": 95, "kind": "lick",
         "tags": ["Blues", "wah"], "favorite": true, "bars": 1, "start": 12.5, "seconds": 2.1, "bpm": 112.0,
         "practiced": "2026-10-27T10:00:00Z"},
        {"id": "s2", "name": "Riff", "from": 3840, "to": 7680, "goal": 100}]},
     {"id": "b", "title": "Sunshine of Your Love", "artist": "Cream", "folder": "b", "tuning": [64, 59, 55, 50, 45, 40],
      "sections": [{"id": "s3", "name": "Solo", "from": 0, "to": 9600, "goal": 90, "best": 60, "kind": "solo",
                    "tags": ["blues", "bend"], "practiced": "2026-10-28T10:00:00Z"}]}]
    """#
    let songs = try JSONDecoder().decode([SongSummary].self, from: Data(json.utf8))
    let items = SectionLibrary.items(songs)
    #expect(items.count == 3)
    #expect(items[1].section.kind == .trecho && items[1].section.tags.isEmpty && !items[1].section.favorite)
    #expect(items[0].section.bpm == 112 && items[0].tuning == "Mi bemol")
    // Busca: tipo, etiqueta, música e afinação, sem acento, pelo começo das palavras.
    #expect(SectionLibrary.filter(items, query: "lick").map(\.section.id) == ["s1"])
    #expect(SectionLibrary.filter(items, query: "bend sunsh").map(\.section.id) == ["s3"])
    #expect(SectionLibrary.filter(items, query: "mi bem").map(\.section.id) == ["s1", "s2"])
    #expect(SectionLibrary.filter(items, kinds: [.solo, .lick]).count == 2)
    #expect(SectionLibrary.filter(items, tags: ["BLUES"]).count == 2)
    #expect(SectionLibrary.filter(items, favoritesOnly: true).map(\.section.id) == ["s1"])
    // Ordens: tocados há pouco, esquecidos (nunca tocado primeiro), perto da meta.
    #expect(SectionLibrary.sorted(items, by: .recent).map(\.section.id) == ["s3", "s1", "s2"])
    #expect(SectionLibrary.sorted(items, by: .forgotten).map(\.section.id) == ["s2", "s1", "s3"])
    #expect(SectionLibrary.sorted(items, by: .nearGoal).map(\.section.id) == ["s1", "s3", "s2"])
    #expect(SectionLibrary.topTags(items) == ["Blues", "bend", "wah"])
    #expect(StudySection.tags(from: " blues,  bend  duplo ,Blues,, ") == ["blues", "bend duplo"])
    // O que vai ao motor leva tipo, etiquetas e favorito.
    let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(items[0].section)) as? [String: Any]
    #expect(sent?["kind"] as? String == "lick" && sent?["favorite"] as? Bool == true)
}

@Test func loopQueCabeNaTelaParaAJanela() {
    #expect(LoopView.windowStart(now: 11, loop: 10...14, span: 10, playheadAt: 0.4) == 6)
    #expect(LoopView.windowStart(now: 12, loop: 10...18, span: 10, playheadAt: 0.4) == 9)
    #expect(LoopView.windowStart(now: 12, loop: 10...20, span: 10, playheadAt: 0.4) == nil)
    #expect(LoopView.windowStart(now: 9, loop: 10...14, span: 10, playheadAt: 0.4) == nil)
    #expect(LoopView.windowStart(now: 9, loop: nil, span: 10, playheadAt: 0.4) == nil)
}

@Test func tabSintetizadaNoManifesto() throws {
    let json = #"""
    {"id": "s", "folder": "/f", "synth": {"key": "tab-1", "soundfont": "GeneralUser.sf2", "stale": true,
     "tracks": {"10": {"file": "synth/tab-1/t10.flac", "name": "Ginger Baker | Drums - Ludwig", "percussion": true},
                "2": {"file": "synth/tab-1/t2.flac", "name": "Eric Clapton | Rhythm Guitar I - 1964 Gibson SG"}}}}
    """#
    let song = try JSONDecoder().decode(SongDetail.self, from: Data(json.utf8))
    let ids = try #require(song.synth).ids
    #expect(ids.map(\.id) == ["tab:2", "tab:10"])
    #expect(ids.map(\.track.shortName) == ["Rhythm Guitar I", "Drums"])
    #expect(song.synth?.stale == true)
}

@Test func notasEEspectroDaFita() throws {
    let notes = ScoreNote.list([[0, 4800, 74, 1, 10], [960, 0, 60, 2, 1], [1, 2]])
    #expect(notes == [ScoreNote(tick: 0, duration: 4800, pitch: 74, string: 1, fret: 10)])
    // Bend de um tom (4 quartos) que sobe até a metade da nota; vibrato leve.
    let bent = try #require(ScoreNote.list([[0, 960, 64, 2, 5, 0, 0, 0, 30, 4, 60, 4]]).first)
    #expect(bent.shape(fraction: 0, elapsed: 0) == 0 && bent.shape(fraction: 1, elapsed: 1) == 2)
    #expect(abs(bent.shape(fraction: 0.25, elapsed: 0) - 1) < 1e-9)
    let wavy = try #require(ScoreNote.list([[0, 960, 64, 2, 5, 1]]).first)
    #expect(wavy.shape(fraction: 0, elapsed: 0) == 0 && abs(wavy.shape(fraction: 0.5, elapsed: 1 / 11.0) - 0.44) < 1e-9)
    var data = [UInt8](repeating: 0, count: 4 * 10)
    data[3 * 10 + 9] = 200
    let spectrum = try #require(Spectrum(frames: 4, rows: 10, hop: 0.01, low: 40, perSemitone: 3, data: data))
    #expect(spectrum.pitch(row: 9) == 43 && spectrum.row(pitch: 43) == 9)
    #expect(spectrum.ceiling == 200)
    #expect(Spectrum(frames: 3, rows: 10, hop: 0.01, low: 40, perSemitone: 3, data: data) == nil)
}

@Test func notaEscolhidaNaEdicao() {
    let page: [String: Any] = ["track": NSNumber(value: 1), "string": NSNumber(value: 3), "fret": NSNumber(value: 7),
                               "pitch": NSNumber(value: 62), "techniques": ["vibrato", "bend-full"]]
    let note = TabSelection(page: page)
    #expect(note?.fret == 7 && note?.techniques == ["vibrato", "bend-full"] && note?.pitchName == "Ré 4")
    #expect(TabSelection(page: ["track": NSNumber(value: 1)]) == nil)
}

/// Uma curva do som a cada 8 ms de `start` a `end` pela função.
private func soundCurve(_ start: Double, _ end: Double, _ f: (Double) -> Double) -> PitchCurve {
    let count = Int(((end - start) / 0.008).rounded()) + 1
    return PitchCurve(from: start, hop: 0.008, values: (0..<count).map { f(start + Double($0) * 0.008) })
}

@Test func encaixeNoSomComoALente() throws {
    // Vibrato de 6 Hz que só sobe (0,3 semitom) sobre o Dó 4: vibrato, sem bend.
    let wavy = SoundNote(curve: soundCurve(1, 2) { 60 + 0.15 * (1 - cos(2 * .pi * 6 * ($0 - 1))) }, start: 1, end: 2, pitch: 60)
    let vibrato = try #require(wavy.fit)
    #expect(vibrato.base == 60 && vibrato.vibrato && vibrato.quarterTones == 0 && vibrato.trill == nil)
    // A faixa copia o som: no topo da oscilação, ~0,3 acima da casa (a nota escrita sem vibrato fica reta).
    let written = ScoreNote(tick: 0, duration: 960, pitch: 60, string: 2, fret: 1, vibrato: 1)
    #expect(abs(wavy.offset(written, at: 1 + 1 / 12.0 + 0.5, start: 1, end: 2) - 0.3) < 0.05)

    // Parado no Dó 4 e, depois de 0,25 s, subindo um tom: bend de 1 tom (4 quartos), pontos do Guitar Pro.
    let bend = try #require(SoundNote(curve: soundCurve(1, 2) { $0 < 1.25 ? 60 : min(62, 60 + ($0 - 1.25) * 20) },
                                      start: 1, end: 2, pitch: 60).fit)
    #expect(bend.base == 60 && bend.quarterTones == 4 && !bend.vibrato)
    let points = try #require(bend.points)
    #expect(points.first == .init(offset: 0, value: 0) && points.last?.value == 4 && points.count <= 4)
    // No Guitar Pro 7: sai (o ponto 0 parado some) e chega; a altura fica.
    let gp = try #require(bend.guitarPro)
    #expect(gp.count == 2 && gp[0].value == 0 && gp[0].offset > 3 && gp[1].value == 4)
    let back = try #require(SoundNote(curve: soundCurve(1, 2) { t in
        t < 1.25 ? 60 : t < 1.6 ? min(62, 60 + (t - 1.25) * 20) : max(60, 62 - (t - 1.6) * 20)
    }, start: 1, end: 2, pitch: 60).fit?.guitarPro)
    #expect(back.map(\.value) == [0, 4, 4, 0] && zip(back, back.dropFirst()).allSatisfy { $0.offset < $1.offset })

    // Ligados rápidos entre Dó e Ré a cada 80 ms: trinado, nem bend nem vibrato.
    let trill = try #require(SoundNote(curve: soundCurve(1, 2) { Int(($0 - 1) / 0.08) % 2 == 0 ? 60 : 62 },
                                       start: 1, end: 2, pitch: 60).fit)
    #expect(trill.trill?.low == 60 && trill.trill?.high == 62 && trill.quarterTones == 0 && !trill.vibrato)

    // Sem som claro: nada a dizer.
    #expect(SoundNote(curve: PitchCurve(from: 1, hop: 0.008, values: Array(repeating: nil, count: 120)),
                      start: 1, end: 2, pitch: 60).fit == nil)
}

@Test func notasSuspeitasPeloSom() throws {
    let plain = ScoreNote(tick: 0, duration: 960, pitch: 60, string: 2, fret: 1)
    let flat = SoundNote(curve: soundCurve(1, 2) { _ in 60.1 }, start: 1, end: 2, pitch: 60)
    #expect(flat.disagreements(with: plain).isEmpty)
    // Um semitom acima do escrito: só a altura.
    let sharp = SoundNote(curve: soundCurve(1, 2) { _ in 61 }, start: 1, end: 2, pitch: 60)
    #expect(sharp.disagreements(with: plain) == [.pitch(61)])
    // Bend de um tom escrito que o som não faz; e o mesmo som numa nota de acorde: nada a dizer.
    let bent = ScoreNote(tick: 0, duration: 960, pitch: 60, string: 2, fret: 1,
                         bend: [.init(offset: 0, value: 0), .init(offset: 30, value: 4)])
    #expect(flat.disagreements(with: bent) == [.bend(0)])
    #expect(SoundNote(curve: soundCurve(1, 2) { _ in 61 }, start: 1, end: 2, pitch: 60, chord: true)
        .disagreements(with: plain).isEmpty)
    // O som sobe um tom e a nota não tem bend; com o bend escrito de um tom, nada.
    let rising = SoundNote(curve: soundCurve(1, 2) { $0 < 1.25 ? 60 : min(62, 60 + ($0 - 1.25) * 20) },
                           start: 1, end: 2, pitch: 60)
    #expect(rising.disagreements(with: plain) == [.bend(4)])
    #expect(rising.disagreements(with: bent).isEmpty)
    // Subindo só nos últimos 120 ms: a passagem para a nota seguinte, não um bend.
    let leaving = SoundNote(curve: soundCurve(1, 2) { $0 < 1.88 ? 60 : 60 + ($0 - 1.88) * 25 }, start: 1, end: 2, pitch: 60)
    #expect((leaving.fit?.quarterTones ?? 0) >= 2 && leaving.disagreements(with: plain).isEmpty)
    // Vibrato no som e não na nota: não é suspeita (a TAB costuma não escrever).
    let wavy = SoundNote(curve: soundCurve(1, 2) { 60 + 0.15 * (1 - cos(2 * .pi * 6 * ($0 - 1))) }, start: 1, end: 2, pitch: 60)
    #expect(wavy.disagreements(with: plain).isEmpty)
}

@Test func afinacaoDaGravacao() throws {
    // Trinta notas paradas 35 cents acima do escrito (com o ataque subindo de baixo) e duas fora (uma nota errada, um
    // bend): a afinação é +0,35.
    var samples: [RecordingTuning.Sample] = []
    for i in 0..<30 {
        let start = Double(i)
        let pitch = 50 + i % 12
        samples.append(.init(curve: soundCurve(start, start + 0.5) { $0 < start + 0.05 ? Double(pitch) - 0.5 : Double(pitch) + 0.35 },
                             start: start, end: start + 0.5, pitch: pitch, plain: true))
    }
    samples.append(.init(curve: soundCurve(40, 40.5) { _ in 63 }, start: 40, end: 40.5, pitch: 60, plain: true))
    samples.append(.init(curve: soundCurve(41, 41.5) { _ in 62 }, start: 41, end: 41.5, pitch: 60, plain: false))
    let tuning = try #require(RecordingTuning.estimate(samples))
    #expect(abs(tuning - 0.35) < 0.01)
    // Poucas notas: nada a dizer.
    #expect(RecordingTuning.estimate(Array(samples.prefix(5))) == nil)
    // Descontada, a nota que soava 35 cents acima fica no lugar.
    let curve = samples[0].curve.shifted(by: -tuning)
    #expect(abs((curve.values.last ?? 0)! - 50) < 0.01)
}
