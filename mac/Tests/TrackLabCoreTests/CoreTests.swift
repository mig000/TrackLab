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
    #expect(mixGains(only).filter { $0.value > 0 }.keys.sorted() == ["guitar"])
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
