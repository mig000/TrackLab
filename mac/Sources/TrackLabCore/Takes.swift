import Foundation

/// Um take gravado (Fase 5): a guitarra do Miguel por cima da música, numa das quatro pistas ("Guitarra 1" a 4). O
/// áudio fica no pacote (`takes/<id>.caf`) como foi tocado: gravado a 85 %, ele tem 1/0,85 do tempo da música, e é
/// tocado de volta no tempo dela (`rate`, `cents`: a velocidade e o tom do estudo na hora da gravação).
public struct Take: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var file: String
    public var lane: Int
    /// Onde começa na música e quanto dura, em segundos da música.
    public var start: Double
    public var length: Double
    public var rate: Double
    public var cents: Int
    public var name: String
    public var created: String
    public var favorite: Bool
    /// Soa no estudo: numa pista, entre os takes que se sobrepõem, só um (o escolhido).
    public var active: Bool
    public var input: String?
    public var chain: String?

    public init(id: String, lane: Int, start: Double, length: Double, rate: Double = 1, cents: Int = 0,
                name: String, created: String = "", favorite: Bool = false, active: Bool = true, input: String? = nil,
                chain: String? = nil) {
        self.id = id
        file = "takes/\(id).caf"
        self.lane = lane
        self.start = start
        self.length = length
        self.rate = rate
        self.cents = cents
        self.name = name
        self.created = created
        self.favorite = favorite
        self.active = active
        self.input = input
        self.chain = chain
    }

    public var end: Double { start + length }
    public var range: ClosedRange<Double> { start...end }

    public func overlaps(_ other: ClosedRange<Double>) -> Bool {
        start < other.upperBound && end > other.lowerBound
    }

    public static let lanes = 1...4
}

/// Como uma gravação vira takes: com loop, cada volta é um take recortado no loop (o pré-rolo antes dele fica de
/// fora); sem loop, um só, da música que tocou enquanto gravava.
public enum TakeCut {
    public struct Pass: Equatable, Sendable {
        /// O primeiro quadro do arquivo gravado e quantos quadros.
        public let frame: Int
        public let frames: Int
        /// Onde o take começa na música, em segundos.
        public let start: Double
        public let length: Double
    }

    /// Uma volta mais curta que isso (gravar parou logo depois de o loop voltar) não vira take.
    public static func minimum(loop: ClosedRange<Double>?) -> Double {
        guard let loop else { return 1 }
        return min(1, (loop.upperBound - loop.lowerBound) / 2)
    }

    /// `elapsed`: a música tocada no plano até o primeiro quadro (o que se ouvia quando ele foi tocado; negativo quando
    /// a entrada já mandava som antes de a música soar, e esse começo fica de fora); `frames` do arquivo a
    /// `sampleRate`, gravados com a música a `rate`.
    public static func passes(plan: PlaybackPlan, elapsed: Double, frames: Int, sampleRate: Double,
                              rate: Double) -> [Pass] {
        guard frames > 0, sampleRate > 0, rate > 0 else { return [] }
        let rawStart = plan.start + elapsed
        let rawEnd = rawStart + Double(frames) / sampleRate * rate
        func frame(_ raw: Double) -> Int {
            min(frames, max(0, Int(((raw - rawStart) / rate * sampleRate).rounded())))
        }
        var pieces: [(raw: ClosedRange<Double>, song: Double)] = []
        if let loop = plan.loop {
            let length = loop.upperBound - loop.lowerBound
            // A primeira passada vai do play ao fim do loop; as seguintes, uma volta inteira cada uma.
            let first = max(rawStart, loop.lowerBound)
            if first < loop.upperBound { pieces.append((first...loop.upperBound, first)) }
            var lap = 0
            while true {
                let from = loop.upperBound + Double(lap) * length
                guard from < rawEnd, lap < PlaybackPlan.maxRepeats else { break }
                pieces.append((from...(from + length), loop.lowerBound))
                lap += 1
            }
        } else {
            // O que entrou antes de a música começar a soar (o play com a entrada já ligada) fica de fora.
            let first = max(rawStart, plan.start)
            if first < min(rawEnd, plan.duration) { pieces.append((first...min(rawEnd, plan.duration), first)) }
        }
        let shortest = minimum(loop: plan.loop)
        return pieces.compactMap { piece in
            let low = max(piece.raw.lowerBound, rawStart)
            let high = min(piece.raw.upperBound, rawEnd)
            guard high - low >= shortest else { return nil }
            let first = frame(low)
            let last = frame(high)
            guard last > first else { return nil }
            return Pass(frame: first, frames: last - first, start: piece.song + (low - piece.raw.lowerBound),
                        length: high - low)
        }
    }
}

/// Um take no plano de tocar: o que o player dele agenda em cada trecho do plano. O player toca o arquivo como foi
/// gravado (a `rate` da gravação), e um time-pitch dele o leva ao tempo da música; o silêncio fora do take e o áudio
/// dentro são contados juntos, em quadros do arquivo, sem acumular arredondamento volta a volta.
public enum TakeSchedule {
    public enum Piece: Equatable, Sendable {
        case silence(frames: Int)
        case audio(frame: Int, frames: Int)
    }

    /// `start` e `length` do take em segundos da música (o começo já descontado do atraso do time-pitch dele).
    public static func pieces(start: Double, length: Double, rate: Double, sampleRate: Double, fileFrames: Int,
                              segments: [ClosedRange<Double>]) -> [Piece] {
        var list: [Piece] = []
        var song = 0.0       // música agendada até aqui, em segundos
        var done = 0         // quadros do arquivo agendados até aqui
        func frames(through seconds: Double) -> Int { Int((seconds / rate * sampleRate).rounded()) }
        func add(_ seconds: Double, audio from: Double?) {
            guard seconds > 0 else { return }
            song += seconds
            let count = frames(through: song) - done
            guard count > 0 else { return }
            done += count
            if let from {
                let first = min(fileFrames, max(0, Int((from / rate * sampleRate).rounded())))
                let usable = min(count, fileFrames - first)
                if usable > 0 { list.append(.audio(frame: first, frames: usable)) }
                if count > usable { list.append(.silence(frames: count - usable)) }
            } else if case let .silence(previous)? = list.last {
                list[list.count - 1] = .silence(frames: previous + count)
            } else {
                list.append(.silence(frames: count))
            }
        }
        let end = start + length
        for segment in segments {
            let low = segment.lowerBound
            let high = segment.upperBound
            let audioLow = min(max(low, start), high)
            let audioHigh = max(min(high, end), audioLow)
            add(audioLow - low, audio: nil)
            add(audioHigh - audioLow, audio: audioLow - start)
            add(high - audioHigh, audio: nil)
        }
        // O silêncio do fim não precisa ser agendado: o player só para de tocar.
        while case .silence? = list.last { list.removeLast() }
        return list
    }
}

/// As regras das pistas: numa pista, entre os takes que se sobrepõem, só um soa.
public enum TakeLanes {
    /// Onde o take fica na partitura, pelos compassos das pontas (nil antes do primeiro ou depois do último): "c. 3 · ",
    /// "c. 3–5 · ", "até o c. 2 · " num take que começa na introdução, ou nada fora da partitura.
    public static func place(first: Int?, last: Int?) -> String {
        switch (first, last) {
        case let (first?, last?): first == last ? "c. \(first) · " : "c. \(first)–\(last) · "
        case let (first?, nil): "do c. \(first) em diante · "
        case let (nil, last?): "até o c. \(last) · "
        case (nil, nil): ""
        }
    }

    /// `id` passa a soar; os da mesma pista que se sobrepõem a ele deixam de soar.
    public static func choose(_ id: String, in takes: [Take]) -> [Take] {
        guard let chosen = takes.first(where: { $0.id == id }) else { return takes }
        return takes.map { take in
            var take = take
            if take.id == id {
                take.active = true
            } else if take.lane == chosen.lane, take.overlaps(chosen.range) {
                take.active = false
            }
            return take
        }
    }

    /// Os takes da pista que passam por `range`, do mais velho ao mais novo (a ordem em que foram gravados).
    public static func around(_ range: ClosedRange<Double>, lane: Int, in takes: [Take]) -> [Take] {
        takes.filter { $0.lane == lane && $0.overlaps(range) }
    }

    /// O A/B: o escolhido em `range` passa ao anterior a ele (o mais novo, se ele é o primeiro). Nil sem dois takes.
    public static func alternate(around range: ClosedRange<Double>, lane: Int, in takes: [Take]) -> String? {
        let list = around(range, lane: lane, in: takes)
        guard list.count > 1 else { return nil }
        guard let current = list.lastIndex(where: \.active) else { return list.last?.id }
        return list[current == 0 ? list.count - 1 : current - 1].id
    }
}

/// O afinador: a frequência de um trecho de som pela YIN (a diferença cumulativa normalizada), de 60 a 1.400 Hz.
public enum Tuner {
    public static let range = 60.0...1400.0

    public static func frequency(_ samples: [Float], sampleRate: Double, threshold: Float = 0.15) -> Double? {
        let minLag = Int(sampleRate / range.upperBound)
        let maxLag = min(Int(sampleRate / range.lowerBound), samples.count / 2)
        guard maxLag > minLag + 2 else { return nil }
        // Silêncio e ruído de fundo não têm altura: abaixo de −48 dBFS (RMS) não lê. O Helix parado dá −57 dB de
        // zumbido da rede, que o afinador lia como "Si 1, 60 Hz"; uma nota tocada passa de −35.
        var energy: Float = 0
        for sample in samples { energy += sample * sample }
        guard energy / Float(samples.count) > 1.6e-5 else { return nil }
        let window = samples.count - maxLag
        var difference = [Float](repeating: 0, count: maxLag + 1)
        samples.withUnsafeBufferPointer { x in
            for lag in 1...maxLag {
                var sum: Float = 0
                for i in 0..<window {
                    let d = x[i] - x[i + lag]
                    sum += d * d
                }
                difference[lag] = sum
            }
        }
        var running: Float = 0
        var normalized = [Float](repeating: 1, count: maxLag + 1)
        for lag in 1...maxLag {
            running += difference[lag]
            normalized[lag] = running > 0 ? difference[lag] * Float(lag) / running : 1
        }
        var lag = minLag
        var found: Int?
        while lag <= maxLag {
            if normalized[lag] < threshold {
                while lag + 1 <= maxLag, normalized[lag + 1] < normalized[lag] { lag += 1 }
                found = lag
                break
            }
            lag += 1
        }
        guard let tau = found else { return nil }
        // A parábola pelos três pontos em volta do mínimo afina o período.
        var period = Double(tau)
        if tau > 1, tau < maxLag {
            let (a, b, c) = (Double(normalized[tau - 1]), Double(normalized[tau]), Double(normalized[tau + 1]))
            let denominator = a - 2 * b + c
            if denominator != 0 { period += 0.5 * (a - c) / denominator }
        }
        let frequency = sampleRate / period
        return range.contains(frequency) ? frequency : nil
    }

    /// A nota (MIDI, com fração) de uma frequência, com o Lá em `a4`.
    public static func pitch(_ frequency: Double, a4: Double = 440) -> Double {
        69 + 12 * log2(frequency / a4)
    }
}
