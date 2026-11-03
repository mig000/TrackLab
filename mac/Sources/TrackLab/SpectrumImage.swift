import CoreGraphics
import Foundation
import SwiftUI
import TrackLabCore

/// A imagem do espectro, pela receita da Lente do TabLab (`web/lens.js`, `buildPalette` e `paintSpectrum`): um pixel
/// por quadro na largura; na altura, `rowScale` pixels por linha (1/3 de semitom), interpolados entre as linhas. O topo
/// da escala acompanha o trecho: o mais alto dos arredores (±2 s), não o da música inteira, que deixava os trechos
/// baixos apagados; a base fica 150 passos (~53 dB) abaixo dele.
///
/// A Tinta (3/11, a proposta "A Lente clara", como o RipX): o espectro em violeta e, onde a TAB tem nota, a energia
/// acesa em âmbar. São duas imagens do mesmo espectro, a violeta e a âmbar (`Images`); a âmbar só aparece pela máscara
/// das notas (`SpectrumLayerView`). No papel, do quase branco ao índigo; no escuro, do quase preto ao lilás claro.
/// O terço de baixo da escala é o fundo, sem a névoa do ruído e do vazamento dos outros instrumentos.
enum SpectrumPalette {
    typealias Stops = [(at: Double, rgb: (Double, Double, Double))]

    static let paperGround = (251.0, 251.0, 253.0)
    static let darkGround = (14.0, 14.0, 20.0)

    static let paperInk: Stops = [
        (0.0, paperGround), (0.38, paperGround), (0.58, (233, 230, 246)), (0.75, (196, 186, 236)),
        (0.88, (139, 122, 214)), (1.0, (82, 64, 168)),
    ]
    static let paperWarm: Stops = [
        (0.0, paperGround), (0.38, paperGround), (0.58, (253, 236, 206)), (0.75, (248, 200, 128)),
        (0.88, (236, 150, 46)), (1.0, (178, 92, 8)),
    ]
    static let darkInk: Stops = [
        (0.0, darkGround), (0.38, darkGround), (0.58, (34, 30, 60)), (0.75, (70, 58, 136)),
        (0.88, (124, 106, 206)), (1.0, (190, 178, 246)),
    ]
    static let darkWarm: Stops = [
        (0.0, darkGround), (0.38, darkGround), (0.58, (66, 40, 12)), (0.75, (148, 90, 22)),
        (0.88, (232, 152, 52)), (1.0, (255, 214, 142)),
    ]

    /// O fundo da Lente: a base da paleta, para a imagem e a borda se emendarem.
    static func ground(paper: Bool) -> Color {
        let g = paper ? paperGround : darkGround
        return Color(red: g.0 / 255, green: g.1 / 255, blue: g.2 / 255)
    }

    struct Images {
        let ink: CGImage
        let warm: CGImage
    }

    static let gamma = 1.35
    static let range = 150.0
    static let minimumHigh = 120.0
    /// Pixels por linha na altura (cada linha é 1/3 de semitom).
    static let rowScale = 2
    static let chunk = 32
    static let around = 2.0

    /// Feitas fora da thread principal: numa música de 5 min, são uns 10 milhões de pixels cada.
    static func images(_ spectrum: Spectrum, paper: Bool) async -> Images? {
        await Task.detached(priority: .userInitiated) { build(spectrum, paper: paper) }.value
    }

    /// As duas imagens numa passada só (o índice da cor de cada pixel é o mesmo nas duas).
    static func build(_ spectrum: Spectrum, paper: Bool) -> Images? {
        let frames = spectrum.frames
        let rows = spectrum.rows
        let height = rows * rowScale
        let inkColors = table(paper ? paperInk : darkInk)
        let warmColors = table(paper ? paperWarm : darkWarm)
        let highs = localHighs(spectrum)
        var ink = [UInt32](repeating: 0, count: frames * height)
        var warm = [UInt32](repeating: 0, count: frames * height)
        spectrum.data.withUnsafeBufferPointer { data in
            ink.withUnsafeMutableBufferPointer { inkOut in
                warm.withUnsafeMutableBufferPointer { warmOut in
                    for frame in 0..<frames {
                        let high = highs[frame]
                        let low = high - range
                        let scale = Double(inkColors.count - 1) / (high - low)
                        let base = frame * rows
                        for y in 0..<height {
                            // A linha (fracionária) deste pixel: o topo é a mais aguda.
                            let r = Double(height - 1 - y) / Double(rowScale)
                            let r0 = min(rows - 1, Int(r))
                            let r1 = min(rows - 1, r0 + 1)
                            let f = r - Double(r0)
                            let v = Double(data[base + r0]) * (1 - f) + Double(data[base + r1]) * f
                            let index = Int(min(Double(inkColors.count - 1), max(0, (v - low) * scale)))
                            inkOut[y * frames + frame] = inkColors[index]
                            warmOut[y * frames + frame] = warmColors[index]
                        }
                    }
                }
            }
        }
        guard let inkImage = cgImage(ink, width: frames, height: height),
              let warmImage = cgImage(warm, width: frames, height: height) else { return nil }
        return Images(ink: inkImage, warm: warmImage)
    }

    private static func cgImage(_ pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let provider = CGDataProvider(data: Data(bytes: pixels, count: pixels.count * 4) as CFData)
        return provider.flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
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
    static func table(_ stops: Stops) -> [UInt32] {
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
