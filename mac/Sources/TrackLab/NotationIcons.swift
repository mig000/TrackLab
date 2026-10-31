import CoreText
import SwiftUI

/// Os símbolos da notação na coluna de edição, como a paleta do Guitar Pro: as figuras, os acentos, os vibratos e a
/// palhetada na fonte Bravura (SMuFL, a mesma da partitura, que o alphaTab traz com licença OFL), e os bends, os
/// slides e a ligadura desenhados como a TAB os mostra.
enum Bravura {
    /// A fonte do alphaTab registrada no processo, uma vez (o CoreText lê o woff2 dele).
    static let available: Bool = {
        guard let url = Bundle.main.url(forResource: "Bravura", withExtension: "woff2",
                                        subdirectory: "web/vendor/alphatab") else { return false }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        // Já registrada (outra janela) também serve.
        return NSFont(name: "Bravura", size: 12) != nil
    }()

    static func font(_ size: CGFloat) -> Font {
        available ? .custom("Bravura", fixedSize: size) : .system(size: size * 0.6)
    }

    // Os pontos de código SMuFL.
    static let whole = "\u{E1D2}", half = "\u{E1D3}", quarter = "\u{E1D5}", eighth = "\u{E1D7}"
    static let sixteenth = "\u{E1D9}", thirtySecond = "\u{E1DB}", dot = "\u{E1E7}", quarterRest = "\u{E4E5}"
    static let accent = "\u{E4A0}", marcato = "\u{E4AC}", staccato = "\u{E4A2}"
    static let vibrato = "\u{EAB2}", wideVibrato = "\u{EAB3}"
    static let deadNote = "\u{E0A9}", ghost = "\u{E0F5}\u{E0A4}\u{E0F6}"
    static let diamond = "\u{E0D9}", blackDiamond = "\u{E0DB}"
    static let downBow = "\u{E610}", upBow = "\u{E612}"

    /// A figura de uma duração em tiques (a semibreve tem 3840).
    static func figure(_ ticks: Int) -> String {
        [3840: whole, 1920: half, 960: quarter, 480: eighth, 240: sixteenth, 120: thirtySecond][ticks] ?? quarter
    }
}

/// Um símbolo da paleta.
enum NotationIcon: Hashable {
    /// Texto na Bravura (com um deslocamento vertical, em frações do tamanho, porque os glifos do SMuFL ficam na
    /// linha da pauta).
    case glyph(String, size: CGFloat = 18, lift: CGFloat = 0)
    /// Texto comum, como o Guitar Pro escreve (P.M., let ring, H/P, T).
    case text(String, italic: Bool = false)
    /// Os bends como a TAB os desenha: a curva que sobe até a seta, com o tamanho em cima.
    case bend(BendShape, String)
    case slide(SlideShape)
    case tie

    enum BendShape: Hashable { case bend, release, prebend, prebendRelease }
    enum SlideShape: Hashable { case legato, shift, inBelow, inAbove, outUp, outDown }
}

struct NotationIconView: View {
    let icon: NotationIcon

    var body: some View {
        switch icon {
        case let .glyph(text, size, lift):
            Text(text).font(Bravura.font(size)).baselineOffset(lift * size).frame(height: 20)
        case let .text(text, italic):
            Text(text).font(.system(size: 11, weight: .semibold, design: .serif)).italic(italic).frame(height: 18)
        case let .bend(shape, label):
            HStack(alignment: .top, spacing: 0) {
                BendPath(shape: shape).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                    .frame(width: shape == .prebend ? 8 : 18, height: 16)
                Text(label).font(.system(size: 9, weight: .semibold)).offset(y: -3)
            }
            .frame(height: 18)
        case let .slide(shape):
            SlidePath(shape: shape).stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(width: 26, height: 14).frame(height: 18)
        case .tie:
            TiePath().stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round)).frame(width: 24, height: 12)
                .frame(height: 18)
        }
    }
}

/// O bend da TAB: a subida curva até a ponta da seta; o que volta desce até outra seta; o pré-bend sobe reto.
private struct BendPath: Shape {
    let shape: NotationIcon.BendShape

    func path(in r: CGRect) -> Path {
        var p = Path()
        let head: (CGPoint, CGFloat) -> Void = { tip, dir in
            p.move(to: CGPoint(x: tip.x - 2.5, y: tip.y - 3.5 * dir))
            p.addLine(to: tip)
            p.addLine(to: CGPoint(x: tip.x + 2.5, y: tip.y - 3.5 * dir))
        }
        switch shape {
        case .bend:
            let top = CGPoint(x: r.maxX - 2, y: r.minY + 1)
            p.move(to: CGPoint(x: r.minX, y: r.maxY - 1))
            p.addQuadCurve(to: top, control: CGPoint(x: r.maxX - 2, y: r.maxY - 1))
            head(top, -1)
        case .release:
            let top = CGPoint(x: r.midX, y: r.minY + 1)
            let end = CGPoint(x: r.maxX - 1, y: r.maxY - 1)
            p.move(to: CGPoint(x: r.minX, y: r.maxY - 1))
            p.addQuadCurve(to: top, control: CGPoint(x: r.midX, y: r.maxY - 1))
            p.move(to: top)
            p.addQuadCurve(to: end, control: CGPoint(x: r.maxX - 1, y: r.minY + 1))
            head(end, 1)
        case .prebend:
            let top = CGPoint(x: r.midX, y: r.minY + 1)
            p.move(to: CGPoint(x: r.midX, y: r.maxY - 1))
            p.addLine(to: top)
            head(top, -1)
        case .prebendRelease:
            let top = CGPoint(x: r.minX + 3, y: r.minY + 1)
            let end = CGPoint(x: r.maxX - 1, y: r.maxY - 1)
            p.move(to: CGPoint(x: r.minX + 3, y: r.maxY - 1))
            p.addLine(to: top)
            head(top, -1)
            p.move(to: top)
            p.addQuadCurve(to: end, control: CGPoint(x: r.maxX - 1, y: r.minY + 1))
            head(end, 1)
        }
        return p
    }
}

/// Os slides como na TAB: a cabeça da nota (um ponto) e a linha que entra ou sai dela; entre duas notas, a linha de
/// uma à outra (com o arco, no legato).
private struct SlidePath: Shape {
    let shape: NotationIcon.SlideShape

    func path(in r: CGRect) -> Path {
        var p = Path()
        let dot: (CGPoint) -> Void = { c in p.addEllipse(in: CGRect(x: c.x - 2.2, y: c.y - 2.2, width: 4.4, height: 4.4)) }
        let mid = r.midY + 2
        switch shape {
        case .legato, .shift:
            dot(CGPoint(x: r.minX + 3, y: mid))
            dot(CGPoint(x: r.maxX - 3, y: mid))
            p.move(to: CGPoint(x: r.minX + 7, y: mid + 2))
            p.addLine(to: CGPoint(x: r.maxX - 7, y: mid - 2))
            if shape == .legato {
                p.move(to: CGPoint(x: r.minX + 3, y: mid - 4))
                p.addQuadCurve(to: CGPoint(x: r.maxX - 3, y: mid - 4), control: CGPoint(x: r.midX, y: r.minY - 3))
            }
        case .inBelow, .inAbove:
            dot(CGPoint(x: r.maxX - 5, y: mid))
            p.move(to: CGPoint(x: r.minX + 4, y: shape == .inBelow ? mid + 4 : mid - 4))
            p.addLine(to: CGPoint(x: r.maxX - 10, y: shape == .inBelow ? mid - 1 : mid + 1))
        case .outUp, .outDown:
            dot(CGPoint(x: r.minX + 5, y: mid))
            p.move(to: CGPoint(x: r.minX + 10, y: shape == .outUp ? mid + 1 : mid - 1))
            p.addLine(to: CGPoint(x: r.maxX - 4, y: shape == .outUp ? mid - 4 : mid + 4))
        }
        return p
    }
}

/// A ligadura: duas cabeças e o arco por baixo, como o Guitar Pro desenha na TAB.
private struct TiePath: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: r.minX, y: r.minY, width: 4.4, height: 4.4))
        p.addEllipse(in: CGRect(x: r.maxX - 4.4, y: r.minY, width: 4.4, height: 4.4))
        p.move(to: CGPoint(x: r.minX + 2, y: r.minY + 6))
        p.addQuadCurve(to: CGPoint(x: r.maxX - 2, y: r.minY + 6), control: CGPoint(x: r.midX, y: r.maxY + 3))
        return p
    }
}
