import Foundation

/// As alturas das camadas da tela da música, pelo modo e pela altura que há (2/11: na tela grande do iMac o que tinha
/// altura fixa ficava estreito, o braço e os takes, e a Onda, que levava todo o resto, ficava esticada).
///
/// Cada modo dá a sua parte a quem trabalha nele: a TAB na altura da pauta (até metade), o braço e os takes numa fração
/// do resto, e a Onda até um teto (um terço da altura) quando é só uma referência. O que ainda sobra se reparte: metade
/// para a TAB (a altura escolhida no divisor vale como mínimo), metade para as camadas que crescem bem (o braço, até a
/// proporção de um braço de verdade na largura que há; as faixas dos takes), e o resto para a TAB: a Onda não passa do
/// teto. Com a Lente embaixo, ela fica com o resto (o espectro ganha com altura) e a Onda com a do divisor; no Ajustar,
/// a música inteira em cima e a Fita, que é onde o tempo se ajusta, com o resto.
public struct LaneLayout: Equatable, Sendable {
    public enum Mode: Sendable { case study, edit, adjust, record }

    public var tab = 0.0
    public var overview = 0.0
    public var fretboard = 0.0
    /// A altura de cada pista de takes e a da pista do disco em cima delas.
    public var takeRow = 0.0
    public var takeRecord = 0.0
    public var wave = 0.0
    public var lens = 0.0

    public static let tabMinimum = 120.0
    public static let waveMinimum = 60.0
    public static let lensMinimum = 160.0
    public static let fretboardRange = 110.0...300.0
    public static let rowRange = 46.0...190.0
    /// O que a camada dos takes ocupa além das pistas (as bordas).
    public static let takesMargin = 4.0

    public init() {}

    /// A camada dos takes inteira com `lanes` pistas.
    public func takes(lanes: Int) -> Double {
        lanes > 0 ? takeRecord + Double(lanes) * takeRow + Self.takesMargin : 0
    }

    /// `height`: o que sobra para as camadas depois das partes fixas (a barra de acordes, os divisores, as margens).
    /// `tabNatural`: a altura da pauta desenhada (nil em páginas); `tabChosen`: a que o divisor escolheu.
    public static func make(height: Double, mode: Mode, tabNatural: Double?, tabChosen: Double?, wave: Bool,
                            lens: Bool, waveChosen: Double, fretboard: Bool, takeLanes: Int,
                            fretboardMax: Double = fretboardRange.upperBound) -> LaneLayout {
        var layout = LaneLayout()
        let total = max(0, height)
        if mode == .adjust {
            layout.overview = min(max(total * 0.16, 92), 170)
            layout.wave = max(waveMinimum, total - layout.overview)
            return layout
        }
        guard wave || lens || fretboard || takeLanes > 0 else {
            layout.tab = total
            return layout
        }
        let natural = tabNatural.map { max(tabMinimum, $0) } ?? total * 0.5
        layout.tab = tabChosen ?? min(natural, total * 0.5)
        layout.tab = max(min(layout.tab, total - waveMinimum), min(tabMinimum, total))
        let rest = total - layout.tab
        if fretboard {
            layout.fretboard = min(max(rest * 0.32, fretboardRange.lowerBound), min(220, fretboardMax))
        }
        if takeLanes > 0 {
            let row = rest * 0.38 / (Double(takeLanes) + 0.45)
            layout.takeRow = min(max(row, rowRange.lowerBound), 140)
            layout.takeRecord = recordHeight(row: layout.takeRow)
        }
        var left = rest - layout.fretboard - layout.takes(lanes: takeLanes)
        if lens {
            if wave { layout.wave = max(waveMinimum, min(waveChosen, left - lensMinimum)) }
            layout.lens = left - layout.wave
            if layout.lens < lensMinimum {
                layout.shrink(by: lensMinimum - layout.lens, chosenTab: tabChosen != nil, lanes: takeLanes)
                layout.lens = lensMinimum
            }
            return layout
        }
        if wave {
            layout.wave = max(waveMinimum, min(left, max(140, total * 0.32)))
            left -= layout.wave
        }
        if left < 0 {
            layout.shrink(by: -left, chosenTab: tabChosen != nil, lanes: takeLanes)
            return layout
        }
        // O que sobra: metade para a TAB (a pauta com folga embaixo; a altura escolhida no divisor vale como mínimo),
        // metade para quem cresce bem.
        var spare = left
        let toTab = (fretboard || takeLanes > 0 || wave) ? spare / 2 : spare
        layout.tab += toTab
        spare -= toTab
        if fretboard, spare > 0 {
            let add = min(spare, max(0, min(fretboardRange.upperBound, fretboardMax) - layout.fretboard))
            layout.fretboard += add
            spare -= add
        }
        if takeLanes > 0, spare > 0 {
            // A pista do disco cresce junto (perto de metade de uma pista): o que entra é o total da camada.
            let before = layout.takes(lanes: takeLanes)
            let room = (rowRange.upperBound - layout.takeRow) * Double(takeLanes)
            layout.takeRow += min(spare * 0.7, room) / Double(takeLanes)
            layout.takeRecord = recordHeight(row: layout.takeRow)
            spare -= layout.takes(lanes: takeLanes) - before
        }
        // O resto vai à TAB: a Onda passou do teto e esticava (1/11, na tela do iMac).
        if spare > 0 { layout.tab += spare }
        return layout
    }

    /// A pista do disco, em cima dos takes: perto de metade de uma pista.
    public static func recordHeight(row: Double) -> Double { min(max(row * 0.42, 24), 64) }

    /// Falta altura (uma janela baixa): a TAB cede até o mínimo, depois o braço e as pistas dos takes.
    private mutating func shrink(by deficit: Double, chosenTab: Bool, lanes: Int) {
        var need = deficit
        let tabCut = min(need, max(0, tab - Self.tabMinimum))
        tab -= tabCut
        need -= tabCut
        if fretboard > 0 {
            let cut = min(need, max(0, fretboard - 80))
            fretboard -= cut
            need -= cut
        }
        if lanes > 0, need > 0 {
            let cut = min(need, max(0, (takeRow - 34) * Double(lanes)))
            takeRow -= cut / Double(lanes)
            takeRecord = Self.recordHeight(row: takeRow)
            need -= cut
        }
        if wave > 0, need > 0 { wave = max(Self.waveMinimum, wave - need) }
    }
}
