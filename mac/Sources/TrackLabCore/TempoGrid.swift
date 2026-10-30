import Foundation

/// O mapa de tempo como a Fita e o loop o usam: segundos ↔ tiques por trechos lineares, as batidas (os pontos do
/// mapa) e os compassos (os inícios que a partitura dá). As mesmas contas de `web/score-core.js`.
public struct TempoGrid: Sendable, Equatable {
    public static let ticksPerQuarter = 960.0

    /// Pontos em ordem, estritamente crescentes em tique e em segundos.
    public let points: [TempoPoint]
    /// Início de cada compasso em tiques, mais o fim do último; vazio enquanto a partitura não disse.
    public let barTicks: [Double]

    /// Os tiques e os segundos de cada ponto, e os compassos em segundos: guardados uma vez. A Fita pergunta
    /// `seconds(at:)` por nota a cada quadro; montar a lista a cada pergunta deixava o espectro a 4 quadros/s.
    private let ticks: [Double]
    /// Cada batida do mapa, em segundos.
    public let beats: [Double]
    /// O início de cada compasso em segundos (com o fim do último); sem a partitura, os pontos `detected`.
    public let bars: [Double]

    public init(points: [TempoPoint], barTicks: [Double] = []) {
        var clean: [TempoPoint] = []
        for point in points.filter({ $0.tick.isFinite && $0.seconds.isFinite }).sorted(by: { $0.tick < $1.tick }) {
            if let last = clean.last, point.tick <= last.tick || point.seconds <= last.seconds { continue }
            clean.append(point)
        }
        self.points = clean
        self.barTicks = barTicks.filter(\.isFinite).sorted()
        let ticks = clean.map(\.tick)
        let beats = clean.map(\.seconds)
        self.ticks = ticks
        self.beats = beats
        if self.barTicks.count >= 2 {
            bars = self.barTicks.map { Self.interpolate(ticks, beats, $0) }
        } else {
            bars = clean.filter { $0.kind == "detected" || $0.kind == "anchor" }.map(\.seconds)
        }
    }

    public var isEmpty: Bool { points.count < 2 }

    public func tick(at seconds: Double) -> Double {
        Self.interpolate(beats, ticks, seconds)
    }

    public func seconds(at tick: Double) -> Double {
        Self.interpolate(ticks, beats, tick)
    }

    /// O número (1…) do compasso que toca em `seconds`; nil fora da partitura.
    public func bar(at seconds: Double) -> Int? {
        let starts = bars
        guard starts.count >= 2, seconds >= starts[0], seconds < starts[starts.count - 1] else { return nil }
        return Self.floorIndex(starts, seconds) + 1
    }

    /// A batida mais perto de `seconds`; sem mapa, o próprio tempo.
    public func nearestBeat(_ seconds: Double) -> Double {
        let list = beats
        guard !list.isEmpty else { return seconds }
        let index = Self.floorIndex(list, seconds)
        var best = list[Swift.max(0, index)]
        if index + 1 < list.count, abs(list[index + 1] - seconds) < abs(best - seconds) { best = list[index + 1] }
        return best
    }

    /// A batida do mapa mais perto de `seconds`, se estiver a até `tolerance` segundos: o que um arrasto do Ajuste
    /// pega. Nil longe de todas.
    public func beat(near seconds: Double, within tolerance: Double) -> TempoPoint? {
        guard !points.isEmpty else { return nil }
        let index = Self.floorIndex(beats, seconds)
        let candidates = [index, index + 1].filter { $0 >= 0 && $0 < points.count }.map { points[$0] }
        guard let best = candidates.min(by: { abs($0.seconds - seconds) < abs($1.seconds - seconds) }),
              abs(best.seconds - seconds) <= tolerance else { return nil }
        return best
    }

    /// A batida do mapa mais perto do tique (o que o ⇧ + arrastar deixou sob o cursor).
    public func point(nearTick tick: Double) -> TempoPoint? {
        points.min { abs($0.tick - tick) < abs($1.tick - tick) }
    }

    /// O início de compasso mais perto de `seconds`, em tiques: o 1 que a tecla U leva até o toque.
    public func nearestBarTick(_ seconds: Double) -> Double? {
        let ticks = barTicks.count >= 2 ? Array(barTicks.dropLast()) : points.filter { $0.kind != "interpolated" }.map(\.tick)
        return ticks.min { abs(self.seconds(at: $0) - seconds) < abs(self.seconds(at: $1) - seconds) }
    }

    /// Batidas por minuto em `seconds` (semínimas), pelo trecho do mapa que o contém.
    public func bpm(at seconds: Double) -> Double? {
        guard points.count >= 2 else { return nil }
        let index = Swift.min(Swift.max(Self.floorIndex(beats, seconds), 0), points.count - 2)
        let a = points[index]
        let b = points[index + 1]
        let quarters = (b.tick - a.tick) / Self.ticksPerQuarter
        return quarters > 0 ? quarters / (b.seconds - a.seconds) * 60 : nil
    }

    /// Último índice com valor <= x; -1 antes do primeiro.
    static func floorIndex(_ list: [Double], _ x: Double) -> Int {
        var low = 0
        var high = list.count - 1
        var found = -1
        while low <= high {
            let mid = (low + high) / 2
            if list[mid] <= x {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// `x` (na escala de `xs`) levado à de `ys` pela reta do trecho que o contém; fora do mapa, a dos dois pontos
    /// da ponta.
    static func interpolate(_ xs: [Double], _ ys: [Double], _ x: Double) -> Double {
        guard let first = ys.first else { return x }
        guard xs.count >= 2 else { return first }
        let index = Swift.min(Swift.max(floorIndex(xs, x), 0), xs.count - 2)
        let span = xs[index + 1] - xs[index]
        guard span > 0 else { return ys[index] }
        return ys[index] + (x - xs[index]) / span * (ys[index + 1] - ys[index])
    }
}

/// O trecho que se repete: preso em batidas, com um tamanho mínimo, dentro da música.
public enum LoopRegion {
    /// Um loop mais curto que isto não se ouve como trecho.
    public static let minimum = 0.25

    /// O trecho entre dois pontos de um arrasto (em qualquer ordem), cada ponta na batida mais perto; nil se curto.
    public static func snapped(_ a: Double, _ b: Double, grid: TempoGrid, duration: Double) -> ClosedRange<Double>? {
        var low = grid.nearestBeat(Swift.min(a, b))
        var high = grid.nearestBeat(Swift.max(a, b))
        low = Swift.max(0, low)
        if duration > 0 { high = Swift.min(high, duration) }
        guard high - low >= minimum else { return nil }
        return low...high
    }

    /// O compasso inteiro que contém `seconds`.
    public static func bar(containing seconds: Double, grid: TempoGrid) -> ClosedRange<Double>? {
        let starts = grid.bars
        guard starts.count >= 2 else { return nil }
        let index = TempoGrid.floorIndex(starts, seconds)
        guard index >= 0, index + 1 < starts.count else { return nil }
        return starts[index]...starts[index + 1]
    }
}

/// Uma nota da partitura para as barras sobre o espectro: tique, duração em tiques, altura MIDI, corda (1 é a mais
/// aguda), casa, vibrato (0, 1 leve, 2 largo) e os pontos do bend (deslocamento de 0 a 60 ao longo da nota, valor em
/// quartos de tom), como a página da partitura manda (`trackNotes` em score-core.js).
public struct ScoreNote: Hashable, Sendable {
    public struct BendPoint: Hashable, Sendable {
        public let offset: Double
        public let value: Double

        public init(offset: Double, value: Double) {
            self.offset = offset
            self.value = value
        }
    }

    public let tick: Double
    public let duration: Double
    public let pitch: Int
    public let string: Int
    public let fret: Int
    public let vibrato: Int
    public let bend: [BendPoint]

    public init(tick: Double, duration: Double, pitch: Int, string: Int, fret: Int, vibrato: Int = 0,
                bend: [BendPoint] = []) {
        self.tick = tick
        self.duration = duration
        self.pitch = pitch
        self.string = string
        self.fret = fret
        self.vibrato = vibrato
        self.bend = bend
    }

    /// A lista da página: [[tique, duração, altura, corda, casa, vibrato?, deslocamento, valor, …], …]; o que não
    /// tiver os cinco primeiros números fica de fora.
    public static func list(_ raw: [[Double]]) -> [ScoreNote] {
        raw.compactMap { item in
            guard item.count >= 5, item.allSatisfy(\.isFinite), item[1] > 0 else { return nil }
            let pairs = item.count > 6 ? Array(item[6...]) : []
            let bend = stride(from: 0, to: pairs.count - 1, by: 2).map { BendPoint(offset: pairs[$0], value: pairs[$0 + 1]) }
            return ScoreNote(tick: item[0], duration: item[1], pitch: Int(item[2]), string: Int(item[3]),
                             fret: Int(item[4]), vibrato: item.count > 5 ? Int(item[5]) : 0, bend: bend)
        }
    }

    /// Quantos semitons acima da altura a nota está num instante, pela escrita (como `shapeAt` da Lente do
    /// TabLab, sem a curva do som; com ela, `SoundNote.offset`): o bend mais o vibrato. `fraction`: de 0 a 1 ao longo
    /// da nota; `elapsed`: segundos desde o começo.
    public func shape(fraction: Double, elapsed: Double) -> Double {
        bendOffset(fraction: fraction) + vibratoOffset(elapsed: elapsed)
    }

    /// O bend escrito pelos pontos (quartos de tom, deslocamento 0–60), com a subida suavizada; sem bend, 0.
    public func bendOffset(fraction: Double) -> Double {
        guard let first = bend.first else { return 0 }
        let at = Swift.max(0, Swift.min(60, fraction * 60))
        if at <= first.offset { return first.value / 2 }
        for (a, b) in zip(bend, bend.dropFirst()) where at <= b.offset {
            let u = b.offset > a.offset ? (at - a.offset) / (b.offset - a.offset) : 1
            let eased = u * u * (3 - 2 * u)
            return (a.value + (b.value - a.value) * eased) / 2
        }
        return (bend.last?.value ?? 0) / 2
    }

    /// O vibrato escrito: uma onda de 5,5 Hz que só sobe (0,22 semitom; o largo, o dobro).
    public func vibratoOffset(elapsed: Double) -> Double {
        vibrato > 0 ? Double(vibrato) * 0.22 * (1 - cos(2 * Double.pi * 5.5 * elapsed)) : 0
    }
}

/// O espectro da Fita (o motor calcula: `GET songs/{id}/spectrum`): `frames` quadros de `rows` linhas, um byte por
/// célula (−90 a 0 dB), a linha 0 na altura `low` e `perSemitone` linhas por semitom, um quadro a cada `hop` segundos.
public struct Spectrum: Sendable {
    public let frames: Int
    public let rows: Int
    public let hop: Double
    public let low: Double
    public let perSemitone: Double
    public let data: [UInt8]

    public init?(frames: Int, rows: Int, hop: Double, low: Double, perSemitone: Double, data: [UInt8]) {
        guard frames > 0, rows > 0, hop > 0, perSemitone > 0, data.count == frames * rows else { return nil }
        self.frames = frames
        self.rows = rows
        self.hop = hop
        self.low = low
        self.perSemitone = perSemitone
        self.data = data
    }

    /// A altura (MIDI, fracionária) de uma linha e a linha de uma altura.
    public func pitch(row: Double) -> Double { low + row / perSemitone }
    public func row(pitch: Double) -> Double { (pitch - low) * perSemitone }

    /// O byte que fica no topo da escala de cor: o percentil 99,5 das células com som (o resto satura menos).
    public var ceiling: UInt8 {
        var counts = [Int](repeating: 0, count: 256)
        for value in data { counts[Int(value)] += 1 }
        let total = data.count - counts[0]
        guard total > 0 else { return 255 }
        var seen = 0
        for value in stride(from: 255, through: 1, by: -1) {
            seen += counts[value]
            if Double(seen) >= Double(total) * 0.005 { return UInt8(value) }
        }
        return 255
    }
}

/// A nota escolhida na edição da TAB, como a página descreve (`describe` em score-edit.js): a pista, a corda (1 é a
/// mais aguda), a casa, a altura MIDI e as articulações ligadas (as chaves da paleta).
public struct TabSelection: Hashable, Sendable {
    public let track: Int
    public let string: Int
    public let fret: Int
    public let pitch: Int
    /// O tique em que a nota começa (para achar a faixa dela na Fita).
    public let tick: Double?
    public let techniques: [String]

    public init(track: Int, string: Int, fret: Int, pitch: Int, tick: Double? = nil, techniques: [String]) {
        self.track = track
        self.string = string
        self.fret = fret
        self.pitch = pitch
        self.tick = tick
        self.techniques = techniques
    }

    /// Se é esta nota da pista (a mesma batida e a mesma corda).
    public func matches(_ note: ScoreNote, track: Int) -> Bool {
        guard let tick else { return false }
        return self.track == track && string == note.string && abs(tick - note.tick) < 1
    }

    public init?(page: [String: Any]) {
        func int(_ key: String) -> Int? { (page[key] as? NSNumber)?.intValue }
        guard let track = int("track"), let string = int("string"), let fret = int("fret"), let pitch = int("pitch") else {
            return nil
        }
        self.init(track: track, string: string, fret: fret, pitch: pitch,
                  tick: (page["tick"] as? NSNumber)?.doubleValue, techniques: page["techniques"] as? [String] ?? [])
    }

    /// O nome da altura (Dó 4 = MIDI 60), para o rótulo da paleta.
    public var pitchName: String {
        let names = ["Dó", "Dó♯", "Ré", "Mi♭", "Mi", "Fá", "Fá♯", "Sol", "Lá♭", "Lá", "Si♭", "Si"]
        return "\(names[((pitch % 12) + 12) % 12]) \(pitch / 12 - 1)"
    }
}

/// A curva de altura do som numa nota (o motor calcula: `POST songs/{id}/pitch`): um valor MIDI a cada `hop`
/// segundos desde `from`, nil onde o som não diz (silêncio, ruído).
public struct PitchCurve: Codable, Hashable, Sendable {
    public let from: Double
    public let hop: Double
    public let values: [Double?]

    public init(from: Double, hop: Double, values: [Double?]) {
        self.from = from
        self.hop = hop
        self.values = values
    }
}
