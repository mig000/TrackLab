import CoreGraphics
import Foundation
import TrackLabCore

/// A imagem do espectro, pela receita da Lente do TabLab (`web/lens.js`, `buildPalette` e `paintSpectrum`): um pixel
/// por quadro na largura; na altura, `rowScale` pixels por linha (1/3 de semitom), interpolados entre as linhas. A cor
/// vai de um azul quase preto a branco (as paradas da Lente, gama 1,35) e o topo da escala acompanha o trecho: o mais
/// alto dos arredores (±2 s), não o da música inteira, que deixava os trechos baixos apagados; a base fica 150 passos
/// (~53 dB) abaixo dele.
enum SpectrumPalette {
    static let stops: [(at: Double, rgb: (Double, Double, Double))] = [
        (0.0, (11, 13, 18)), (0.3, (26, 30, 42)), (0.55, (56, 61, 84)), (0.75, (118, 124, 150)),
        (0.9, (192, 196, 210)), (1.0, (246, 247, 250)),
    ]
    /// No papel (a aparência clara): do quase branco ao quase preto, a mesma escala de tinta.
    static let paperStops: [(at: Double, rgb: (Double, Double, Double))] = [
        (0.0, (250, 248, 243)), (0.3, (233, 229, 220)), (0.55, (196, 190, 177)), (0.75, (128, 122, 112)),
        (0.9, (64, 60, 56)), (1.0, (18, 17, 16)),
    ]
    static let gamma = 1.35
    static let range = 150.0
    static let minimumHigh = 120.0
    /// Pixels por linha na altura (cada linha é 1/3 de semitom).
    static let rowScale = 2
    static let chunk = 32
    static let around = 2.0

    /// Feita fora da thread principal: numa música de 5 min, são uns 10 milhões de pixels.
    static func image(_ spectrum: Spectrum, paper: Bool = false) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { build(spectrum, paper: paper) }.value
    }

    static func build(_ spectrum: Spectrum, paper: Bool = false) -> CGImage? {
        let frames = spectrum.frames
        let rows = spectrum.rows
        let height = rows * rowScale
        let colors = table(paper ? paperStops : stops)
        let highs = localHighs(spectrum)
        var pixels = [UInt32](repeating: 0, count: frames * height)
        spectrum.data.withUnsafeBufferPointer { data in
            pixels.withUnsafeMutableBufferPointer { out in
                for frame in 0..<frames {
                    let high = highs[frame]
                    let low = high - range
                    let scale = Double(colors.count - 1) / (high - low)
                    let base = frame * rows
                    for y in 0..<height {
                        // A linha (fracionária) deste pixel: o topo é a mais aguda.
                        let r = Double(height - 1 - y) / Double(rowScale)
                        let r0 = min(rows - 1, Int(r))
                        let r1 = min(rows - 1, r0 + 1)
                        let f = r - Double(r0)
                        let v = Double(data[base + r0]) * (1 - f) + Double(data[base + r1]) * f
                        let index = Int(min(Double(colors.count - 1), max(0, (v - low) * scale)))
                        out[y * frames + frame] = colors[index]
                    }
                }
            }
        }
        let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 4) as CFData)
        return provider.flatMap {
            CGImage(width: frames, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frames * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: $0,
                    decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
    }

    /// O topo da escala de cada quadro: o maior byte de cada bloco de `chunk` quadros, o maior dos blocos a até
    /// `around` segundos, e uma reta entre os blocos (a cor não salta de um bloco para o outro).
    static func localHighs(_ spectrum: Spectrum) -> [Double] {
        let frames = spectrum.frames
        let rows = spectrum.rows
        let count = (frames + chunk - 1) / chunk
        var peaks = [Double](repeating: 0, count: count)
        spectrum.data.withUnsafeBufferPointer { data in
            for c in 0..<count {
                var best: UInt8 = 0
                for i in (c * chunk * rows)..<min(data.count, (c + 1) * chunk * rows) where data[i] > best { best = data[i] }
                peaks[c] = Double(best)
            }
        }
        let reach = max(1, Int((around / (spectrum.hop * Double(chunk))).rounded()))
        let smoothed = (0..<count).map { c in
            max(minimumHigh, peaks[max(0, c - reach)...min(count - 1, c + reach)].max() ?? minimumHigh)
        }
        return (0..<frames).map { frame in
            let position = (Double(frame) + 0.5) / Double(chunk) - 0.5
            let c0 = max(0, min(count - 1, Int(position.rounded(.down))))
            let c1 = min(count - 1, c0 + 1)
            let f = max(0, min(1, position - Double(c0)))
            return smoothed[c0] * (1 - f) + smoothed[c1] * f
        }
    }

    /// As cores de 0 (a base) a 1 (o topo), em 1024 degraus.
    static func table(_ stops: [(at: Double, rgb: (Double, Double, Double))] = stops) -> [UInt32] {
        (0..<1024).map { step in
            let t = pow(Double(step) / 1023, gamma)
            let upper = stops.firstIndex { $0.at >= t } ?? stops.count - 1
            let lower = max(0, upper - 1)
            let a = stops[lower], b = stops[upper]
            let f = b.at > a.at ? (t - a.at) / (b.at - a.at) : 0
            func mix(_ x: Double, _ y: Double) -> UInt32 { UInt32(max(0, min(255, (x + (y - x) * f).rounded()))) }
            // RGBA na memória (little-endian: A B G R no inteiro).
            return UInt32(255) << 24 | mix(a.rgb.2, b.rgb.2) << 16 | mix(a.rgb.1, b.rgb.1) << 8 | mix(a.rgb.0, b.rgb.0)
        }
    }
}
