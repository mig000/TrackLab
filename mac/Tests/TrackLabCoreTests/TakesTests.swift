import Foundation
import Testing
@testable import TrackLabCore

/// Gravando um loop de 4 s (10 a 14) a 85 %, com 1 s de pré-rolo antes dele: cada volta vira um take recortado no loop.
@Test func cadaVoltaDoLoopViraUmTake() {
    let plan = PlaybackPlan(start: 9, loop: 10...14, duration: 200)
    let rate = 0.85
    let sampleRate = 48_000.0
    // 1 s de pré-rolo, três voltas inteiras e 0,4 s da quarta (curta demais: fica de fora).
    let song = 1 + 4 * 3 + 0.4
    let frames = Int(song / rate * sampleRate)
    let passes = TakeCut.passes(plan: plan, elapsed: 0, frames: frames, sampleRate: sampleRate, rate: rate)
    #expect(passes.count == 3)
    for (index, pass) in passes.enumerated() {
        #expect(abs(pass.start - 10) < 1e-9)
        #expect(abs(pass.length - 4) < 1e-9)
        #expect(abs(Double(pass.frames) - 4 / rate * sampleRate) <= 1)
        let expected = (1 + 4 * Double(index)) / rate * sampleRate
        #expect(abs(Double(pass.frame) - expected) <= 1)
    }
}

/// Entrando no meio do loop (gravar com a música tocando), a primeira volta começa onde a gravação começou.
@Test func gravarNoMeioDoLoopComecaOndeEntrou() {
    let plan = PlaybackPlan(start: 10, loop: 10...14, duration: 200)
    let passes = TakeCut.passes(plan: plan, elapsed: 2.5, frames: 44_100 * 6, sampleRate: 44_100, rate: 1)
    #expect(passes.map(\.start) == [12.5, 10])
    #expect(passes.map(\.length) == [1.5, 4])
    #expect(passes[1].frame == Int(1.5 * 44_100))
}

/// Sem loop, um take só, do ponto em que a gravação começou, e nada além do fim da música.
@Test func semLoopUmTakeSo() {
    let plan = PlaybackPlan(start: 30, loop: nil, duration: 40)
    let passes = TakeCut.passes(plan: plan, elapsed: 1, frames: 48_000 * 20, sampleRate: 48_000, rate: 1)
    #expect(passes.count == 1)
    #expect(passes[0].start == 31)
    #expect(abs(passes[0].length - 9) < 1e-9)
    #expect(passes[0].frames == 48_000 * 9)
}

/// O take agendado no plano: silêncio até ele, o áudio, e o silêncio do resto de cada volta; a 85 %, em quadros do
/// arquivo como foi gravado. Volta a volta, o total não escorrega.
@Test func takeAgendadoNoTempoDaMusica() {
    let rate = 0.85
    let sampleRate = 48_000.0
    let segments: [ClosedRange<Double>] = [9...14] + Array(repeating: 10...14, count: 300)
    let pieces = TakeSchedule.pieces(start: 11, length: 2, rate: rate, sampleRate: sampleRate, fileFrames: 200_000,
                                     segments: segments)
    func total(_ list: [TakeSchedule.Piece]) -> Int {
        list.reduce(0) { sum, piece in
            switch piece {
            case let .silence(frames), let .audio(_, frames): sum + frames
            }
        }
    }
    #expect(pieces.first == .silence(frames: Int((2 / rate * sampleRate).rounded())))
    #expect(pieces[1] == .audio(frame: 0, frames: Int((2 / rate * sampleRate).rounded())))
    // Até o fim do último áudio agendado: 5 s do primeiro trecho, 299 voltas inteiras e 3 s da última.
    let song = 5 + 299 * 4.0 + 3
    #expect(abs(total(pieces) - Int((song / rate * sampleRate).rounded())) <= 1)
}

/// Um arquivo mais curto que o take (o fim cortado) agenda o que tem e silêncio no resto, para a volta seguinte cair
/// no lugar.
@Test func takeQueAcabaAntesDoTrecho() {
    let pieces = TakeSchedule.pieces(start: 0, length: 3, rate: 1, sampleRate: 100, fileFrames: 250,
                                     segments: [0...10, 0...10])
    #expect(pieces == [.audio(frame: 0, frames: 250), .silence(frames: 750), .audio(frame: 0, frames: 250)])
}

@Test func escolherUmTakeCalaOsQueSeSobrepoem() {
    var takes = [
        Take(id: "a", lane: 1, start: 10, length: 4, name: "Take 1"),
        Take(id: "b", lane: 1, start: 10, length: 4, name: "Take 2"),
        Take(id: "c", lane: 1, start: 40, length: 4, name: "Take 3"),
        Take(id: "d", lane: 2, start: 10, length: 4, name: "Base"),
    ]
    takes = TakeLanes.choose("b", in: takes)
    #expect(takes.map(\.active) == [false, true, true, true])
    #expect(TakeLanes.alternate(around: 11...12, lane: 1, in: takes) == "a")
    takes = TakeLanes.choose("a", in: takes)
    #expect(TakeLanes.alternate(around: 11...12, lane: 1, in: takes) == "b")
    #expect(TakeLanes.alternate(around: 41...42, lane: 1, in: takes) == nil)
}

@Test func afinadorAchaAAlturaDeUmaCordaDeGuitarra() {
    let sampleRate = 48_000.0
    for frequency in [82.41, 110, 196, 329.63, 659.26] {
        // Um som com harmônicos, como uma corda (e um pouco de ruído).
        var generator = SystemRandomNumberGenerator()
        let samples = (0..<4096).map { i -> Float in
            let t = Double(i) / sampleRate
            let tone = sin(2 * .pi * frequency * t) + 0.6 * sin(4 * .pi * frequency * t) + 0.3 * sin(6 * .pi * frequency * t)
            return Float(0.3 * tone) + Float.random(in: -0.01...0.01, using: &generator)
        }
        let found = Tuner.frequency(samples, sampleRate: sampleRate)
        #expect(found != nil)
        if let found {
            let cents = 1200 * log2(found / frequency)
            #expect(abs(cents) < 5, "\(frequency) Hz deu \(found) Hz")
        }
    }
    #expect(Tuner.frequency([Float](repeating: 0, count: 4096), sampleRate: sampleRate) == nil)
    // O zumbido da rede com a guitarra parada (60 Hz a −57 dB) não é nota.
    let hum = (0..<4096).map { i in Float(0.002 * sin(2 * .pi * 60 * Double(i) / sampleRate)) }
    #expect(Tuner.frequency(hum, sampleRate: sampleRate) == nil)
    #expect(abs(Tuner.pitch(440) - 69) < 1e-9)
}
