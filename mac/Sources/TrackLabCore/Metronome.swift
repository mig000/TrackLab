import Foundation

/// O metrônomo da música: um clique em cada batida do mapa de tempo (o 1 de cada compasso mais agudo e mais forte),
/// numa faixa do tamanho do áudio que toca junto com as outras (segue o loop, a velocidade e o tom como elas).
public enum Metronome {
    public static let rate = 22_050.0
    static let length = 0.03

    /// As amostras (mono, `rate`) de `duration` segundos; `beats` e `bars` em segundos (os compassos ganham o clique
    /// forte). Cada clique é um seno que decai em 30 ms: 1 500 Hz no 1, 1 000 Hz nas outras batidas.
    public static func samples(beats: [Double], bars: [Double], duration: Double) -> [Float] {
        let count = max(0, Int((duration * rate).rounded()))
        var out = [Float](repeating: 0, count: count)
        let size = Int(length * rate)
        let downbeats = bars.sorted()
        func isDownbeat(_ t: Double) -> Bool {
            var low = 0
            var high = downbeats.count
            while low < high {
                let middle = (low + high) / 2
                if downbeats[middle] < t - 0.002 { low = middle + 1 } else { high = middle }
            }
            return low < downbeats.count && abs(downbeats[low] - t) <= 0.002
        }
        for beat in beats where beat >= 0 && beat < duration {
            let strong = isDownbeat(beat)
            let frequency = strong ? 1500.0 : 1000.0
            let gain = strong ? 0.8 : 0.5
            let first = Int((beat * rate).rounded())
            for i in 0..<size where first + i < count {
                let t = Double(i) / rate
                out[first + i] += Float(gain * sin(2 * .pi * frequency * t) * exp(-t / 0.008))
            }
        }
        return out
    }
}
