import Foundation

/// O mapa de tempo como a Fita e o loop o usam: segundos ↔ tiques por trechos lineares, as batidas (os pontos do
/// mapa) e os compassos (os inícios que a partitura dá). As mesmas contas de `web/score-core.js`.
public struct TempoGrid: Sendable, Equatable {
    public static let ticksPerQuarter = 960.0

    /// Pontos em ordem, estritamente crescentes em tique e em segundos.
    public let points: [TempoPoint]
    /// Início de cada compasso em tiques, mais o fim do último; vazio enquanto a partitura não disse.
    public let barTicks: [Double]

    public init(points: [TempoPoint], barTicks: [Double] = []) {
        var clean: [TempoPoint] = []
        for point in points.filter({ $0.tick.isFinite && $0.seconds.isFinite }).sorted(by: { $0.tick < $1.tick }) {
            if let last = clean.last, point.tick <= last.tick || point.seconds <= last.seconds { continue }
            clean.append(point)
        }
        self.points = clean
        self.barTicks = barTicks.filter(\.isFinite).sorted()
    }

    public var isEmpty: Bool { points.count < 2 }

    public func tick(at seconds: Double) -> Double {
        Self.piecewise(points, seconds, \.seconds, \.tick)
    }

    public func seconds(at tick: Double) -> Double {
        Self.piecewise(points, tick, \.tick, \.seconds)
    }

    /// Cada batida do mapa, em segundos.
    public var beats: [Double] { points.map(\.seconds) }

    /// O início de cada compasso em segundos (com o fim do último); sem a partitura, os pontos `detected`.
    public var bars: [Double] {
        if barTicks.count >= 2 { return barTicks.map { seconds(at: $0) } }
        return points.filter { $0.kind == "detected" || $0.kind == "anchor" }.map(\.seconds)
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

    /// O início de compasso mais perto de `seconds`, em tiques: o 1 que a tecla U leva até o toque.
    public func nearestBarTick(_ seconds: Double) -> Double? {
        let ticks = barTicks.count >= 2 ? Array(barTicks.dropLast()) : points.filter { $0.kind != "interpolated" }.map(\.tick)
        return ticks.min { abs(self.seconds(at: $0) - seconds) < abs(self.seconds(at: $1) - seconds) }
    }

    /// Batidas por minuto em `seconds` (semínimas), pelo trecho do mapa que o contém.
    public func bpm(at seconds: Double) -> Double? {
        guard points.count >= 2 else { return nil }
        let index = Swift.min(Swift.max(Self.floorIndex(points.map(\.seconds), seconds), 0), points.count - 2)
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

    static func piecewise(_ list: [TempoPoint], _ x: Double, _ ka: KeyPath<TempoPoint, Double>,
                          _ kb: KeyPath<TempoPoint, Double>) -> Double {
        guard let first = list.first else { return x }
        guard list.count >= 2 else { return first[keyPath: kb] }
        let index = Swift.min(Swift.max(floorIndex(list.map { $0[keyPath: ka] }, x), 0), list.count - 2)
        let a = list[index]
        let b = list[index + 1]
        let span = b[keyPath: ka] - a[keyPath: ka]
        guard span > 0 else { return a[keyPath: kb] }
        return a[keyPath: kb] + (x - a[keyPath: ka]) / span * (b[keyPath: kb] - a[keyPath: kb])
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
