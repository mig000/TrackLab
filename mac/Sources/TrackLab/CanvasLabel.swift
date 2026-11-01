import AppKit
import SwiftUI

/// Os rótulos dos Canvas que se redesenham a cada quadro tocando (os números dos compassos, os nomes das teclas e das
/// partes, os ms do Ajuste): cada texto vira uma imagem uma vez e daí em diante é só carimbado. Um `Text` desenhado no
/// Canvas é composto de novo a cada quadro, e medido no iMac tocando isso era quase metade da linha principal do app (a
/// pauta da TAB, que anda no ritmo dela, engasgava junto).
@MainActor
enum CanvasLabel {
    private static var cache: [String: Image] = [:]

    /// `color` é resolvida na aparência pedida (`dark`), não na de quem desenha.
    static func image(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, monospaced: Bool = false,
                      color: NSColor, dark: Bool) -> Image {
        let key = "\(text)|\(size)|\(weight.rawValue)|\(monospaced)|\(dark)|\(color)"
        if let image = cache[key] { return image }
        if cache.count > 4000 { cache.removeAll() }
        let image = render(text, size: size, weight: weight, monospaced: monospaced, color: color, dark: dark)
        cache[key] = image
        return image
    }

    private static func render(_ text: String, size: CGFloat, weight: NSFont.Weight, monospaced: Bool, color: NSColor,
                               dark: Bool) -> Image {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var result = Image(nsImage: NSImage())
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                                  : NSFont.systemFont(ofSize: size, weight: weight)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let bounds = string.size()
            let width = max(1, Int((bounds.width * scale).rounded(.up)))
            let height = max(1, Int((bounds.height * scale).rounded(.up)))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            bitmap.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            string.draw(at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            if let made = bitmap.makeImage() { result = Image(decorative: made, scale: scale) }
        }
        return result
    }
}
