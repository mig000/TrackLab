import Foundation

/// O bend de uma nota como o Guitar Pro 7 guarda: uma origem, um patamar e um destino, no máximo quatro pontos, e o
/// tipo sai da forma. As alturas em quartos de tom (de ¼ de tom a 3 tons) e os instantes de 0 a 60 ao longo da nota,
/// como o alphaTab. Cada tipo tem um movimento só (sobe, volta, ou sobe e volta): dois movimentos na mesma nota não
/// cabem no formato (o Guitar Pro e o alphaTab guardam um patamar só) e se escrevem em duas notas ligadas (Dividir,
/// Ligada). Medido nos bends das músicas do Miguel (31/10): ¼ e ¾ de tom, a volta sozinha numa ligada e a subida ao
/// longo da nota inteira (como o Songsterr importa) aparecem, e a paleta de antes não os escrevia.
public struct BendForm: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case bend, bendRelease, release, prebend, prebendBend, prebendRelease

        public var label: String {
            switch self {
            case .bend: "Bend"
            case .bendRelease: "Bend e volta"
            case .release: "Volta"
            case .prebend: "Pré-bend"
            case .prebendBend: "Pré e bend"
            case .prebendRelease: "Pré e volta"
            }
        }

        /// As alturas que o tipo usa: o pré-bend (na Volta, a altura que vem da nota ligada de antes), até onde sobe e
        /// até onde volta.
        public var usesPre: Bool { [.release, .prebend, .prebendBend, .prebendRelease].contains(self) }
        public var usesTop: Bool { [.bend, .bendRelease, .prebendBend].contains(self) }
        public var usesEnd: Bool { [.bendRelease, .release, .prebendRelease].contains(self) }
    }

    /// O tempo do movimento: rápido (chega a um quarto da nota, como o Guitar Pro 8 grava), ao longo da nota (como o
    /// Songsterr importa) e atrasado (começa na metade).
    public enum Timing: String, CaseIterable, Sendable {
        case quick, along, late

        public var label: String {
            switch self {
            case .quick: "Rápido"
            case .along: "Ao longo"
            case .late: "Atrasado"
            }
        }
    }

    /// 3 tons, o mais alto (o alphaTab e o Guitar Pro).
    public static let maxHeight = 12
    /// A grade do tempo no gráfico: 1/12 da nota.
    public static let step = 5.0

    public var kind: Kind
    public var pre: Int
    public var top: Int
    public var end: Int
    /// Quando o movimento começa e quando chega (0–60); no bend e volta, `hold` e `back`: quando começa a voltar e
    /// quando acaba.
    public var start: Double
    public var arrive: Double
    public var hold: Double
    public var back: Double

    public init(kind: Kind, pre: Int = 0, top: Int = 0, end: Int = 0, start: Double = 0, arrive: Double = 15,
                hold: Double = 45, back: Double = 60) {
        self.kind = kind
        self.pre = pre
        self.top = top
        self.end = end
        self.start = start
        self.arrive = arrive
        self.hold = hold
        self.back = back
    }

    /// Um tipo novo, rápido, com as alturas que dá para aproveitar do bend de antes. `carried`: a altura que a nota
    /// ligada traz da anterior (a Volta parte dela).
    public static func make(_ kind: Kind, from old: BendForm? = nil, carried: Int = 0) -> BendForm {
        let high = old.map { $0.kind.usesTop ? $0.top : $0.pre } ?? 4
        var form = BendForm(kind: kind)
        switch kind {
        case .bend, .bendRelease:
            form.top = high
        case .release:
            form.pre = carried > 0 ? carried : high
        case .prebend, .prebendRelease:
            form.pre = high
        case .prebendBend:
            form.pre = old?.kind.usesPre == true ? old?.pre ?? 2 : 2
            form.top = max(form.pre + 2, old?.kind.usesTop == true ? old?.top ?? 4 : 4)
        }
        return form.timed(.quick)
    }

    /// O mesmo bend com o tempo de um atalho.
    public func timed(_ timing: Timing) -> BendForm {
        var form = self
        if kind == .bendRelease {
            (form.start, form.arrive, form.hold, form.back) = switch timing {
            case .quick: (0, 15, 45, 60)
            case .along: (0, 30, 30, 60)
            case .late: (30, 40, 50, 60)
            }
        } else {
            (form.start, form.arrive) = switch timing {
            case .quick: (0, 15)
            case .along: (0, 60)
            case .late: (30, 45)
            }
        }
        return form.valid()
    }

    /// O atalho de tempo que o bend é, se for um (o pré-bend não tem movimento).
    public var timing: Timing? {
        guard kind != .prebend else { return nil }
        return Timing.allCases.first { timed($0).points == points }
    }

    /// Os pontos do bend (deslocamento 0–60, quartos de tom), como o Guitar Pro 7 guarda.
    public var points: [[Double]] {
        switch kind {
        case .bend: [[start, 0], [arrive, Double(top)]]
        case .bendRelease: [[start, 0], [arrive, Double(top)], [hold, Double(top)], [back, Double(end)]]
        case .release, .prebendRelease: [[start, Double(pre)], [arrive, Double(end)]]
        case .prebend: [[0, Double(pre)], [60, Double(pre)]]
        case .prebendBend: [[start, Double(pre)], [arrive, Double(top)]]
        }
    }

    /// A altura (quartos de tom) no instante `x` (0–60), em linha reta entre os pontos.
    public func value(at x: Double) -> Double {
        let list = points
        guard let first = list.first else { return 0 }
        if x <= first[0] { return first[1] }
        for (a, b) in zip(list, list.dropFirst()) where x <= b[0] {
            return b[0] > a[0] ? a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0]) : b[1]
        }
        return list[list.count - 1][1]
    }

    /// O bend dentro do que o formato aceita: alturas de ¼ de tom a 3 tons (a volta abaixo de onde estava, o bend
    /// depois do pré acima dele), os instantes em ordem dentro da nota, com o movimento de ao menos um ponto do
    /// alphaTab. O que o tipo não usa fica zerado (dois bends iguais são iguais).
    public func valid() -> BendForm {
        var form = self
        let most = Self.maxHeight
        form.pre = kind.usesPre ? min(max(pre, 1), most) : 0
        form.top = kind.usesTop ? min(max(top, 1), most) : 0
        switch kind {
        case .prebendBend:
            form.pre = min(form.pre, most - 1)
            form.top = max(form.top, form.pre + 1)
        case .bendRelease:
            form.end = min(max(end, 0), form.top - 1)
        case .release, .prebendRelease:
            form.end = min(max(end, 0), form.pre - 1)
        default:
            form.end = 0
        }
        let gap = 1.0
        switch kind {
        case .prebend:
            (form.start, form.arrive, form.hold, form.back) = (0, 60, 45, 60)
        case .bendRelease:
            form.start = min(max(start, 0), 60 - 2 * gap)
            form.arrive = min(max(arrive, form.start + gap), 60 - gap)
            form.hold = min(max(hold, form.arrive), 60 - gap)
            form.back = min(max(back, form.hold + gap), 60)
        default:
            form.start = min(max(start, 0), 60 - gap)
            form.arrive = min(max(arrive, form.start + gap), 60)
            (form.hold, form.back) = (45, 60)
        }
        return form
    }

    /// O bend escrito de uma nota (os pontos dela, como a página manda: [deslocamento, quartos de tom]), ou nil sem
    /// bend próprio (uma ligada que só segura o alto de antes) ou numa forma que não é de um tipo só (dois movimentos,
    /// de outro editor). `continued`: a nota continua um bend ligado (a que só desce é a Volta).
    public init?(points raw: [[Double]], continued: Bool = false) {
        let list = raw.compactMap { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite ? ($0[0], Int($0[1].rounded())) : nil }
        guard list.count >= 2, let peak = list.map(\.1).max() else { return nil }
        let values = list.map(\.1)
        let first = values[0]
        let last = values[values.count - 1]
        func rising(_ part: ArraySlice<Int>) -> Bool { zip(part, part.dropFirst()).allSatisfy { $0 <= $1 } }
        func falling(_ part: ArraySlice<Int>) -> Bool { zip(part, part.dropFirst()).allSatisfy { $0 >= $1 } }
        // Onde o movimento começa (o último ponto ainda na altura de partida) e onde chega (o primeiro na de chegada).
        func leaves(_ from: Int, before limit: Int) -> Double { list[..<limit].last { $0.1 == from }?.0 ?? list[0].0 }
        func reaches(_ value: Int, from index: Int) -> Double { list[index...].first { $0.1 == value }?.0 ?? list[index].0 }
        if values.allSatisfy({ $0 == first }) {
            guard !continued, first > 0 else { return nil }
            self.init(kind: .prebend, pre: first, start: 0, arrive: 60)
        } else if first == 0, last < peak {
            let rise = values.firstIndex(of: peak)!
            let fall = values.lastIndex(of: peak)!
            guard rising(values[...rise]), falling(values[fall...]), values[rise...fall].allSatisfy({ $0 == peak }) else {
                return nil
            }
            self.init(kind: .bendRelease, top: peak, end: last, start: leaves(0, before: rise), arrive: list[rise].0,
                      hold: list[fall].0, back: reaches(last, from: fall))
        } else if rising(values[...]) {
            let up = values.firstIndex(of: last)!
            self.init(kind: first == 0 ? .bend : .prebendBend, pre: first, top: last, start: leaves(first, before: up),
                      arrive: list[up].0)
        } else if falling(values[...]) {
            let down = values.firstIndex(of: last)!
            self.init(kind: continued ? .release : .prebendRelease, pre: first, end: last,
                      start: leaves(first, before: down), arrive: list[down].0)
        } else {
            return nil
        }
        self = valid()
    }

    /// O mesmo bend com a altura principal em `height` (até onde sobe; no pré-bend, na volta e no pré e volta, a de
    /// partida), dentro do que o formato aceita.
    public func with(height: Int) -> BendForm {
        var form = self
        if kind.usesTop { form.top = height } else { form.pre = height }
        return form.valid()
    }

    /// O bend em palavras, para a linha do som e as mensagens: "sobe 1", "pré ½ → 1", "sobe 1 e volta a ½".
    public var spoken: String {
        let name = Self.name
        return switch kind {
        case .bend: "sobe \(name(top))"
        case .bendRelease: "sobe \(name(top)) e volta" + (end > 0 ? " a \(name(end))" : "")
        case .release: "volta de \(name(pre))" + (end > 0 ? " a \(name(end))" : "")
        case .prebend: "pré-bend \(name(pre))"
        case .prebendBend: "pré \(name(pre)) → \(name(top))"
        case .prebendRelease: "pré \(name(pre)) e volta" + (end > 0 ? " a \(name(end))" : "")
        }
    }

    /// O nome de uma altura em quartos de tom, como a TAB escreve: ¼, ½, ¾, 1, 1¼ … 3.
    public static func name(_ quarterTones: Int) -> String {
        guard quarterTones > 0 else { return "0" }
        let whole = quarterTones / 4
        let part = ["", "¼", "½", "¾"][quarterTones % 4]
        return whole == 0 ? part : "\(whole)\(part)"
    }
}
