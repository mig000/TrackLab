import Foundation

/// O que a curva do som diz de uma nota, como `fitCurve` da Lente do TabLab (`web/lens-core.js`): a altura presa no
/// traste (`base`, o grave do começo da nota), o bend em quartos de tom com os pontos do Guitar Pro (deslocamento de 0
/// a 60 ao longo da nota, até quatro), se há vibrato (oscilação de 3,5 a 9 Hz, ≥ 1,5 ciclo, ≥ 0,12 semitom em volta
/// da tendência) e se é trinado (ligados rápidos entre duas casas).
public struct CurveFit: Hashable, Sendable {
    public struct Trill: Hashable, Sendable {
        public let low: Int
        public let high: Int
        /// Segundos entre os saltos (a mediana).
        public let gap: Double

        /// A figura de cada troca no Guitar Pro (8, 16, 32 ou 64: colcheia a semifusa), com a semínima de
        /// `beatSeconds`: a mais perto de quantas trocas cabem na semínima.
        public func speed(beatSeconds: Double) -> Int {
            guard gap > 0, beatSeconds > 0 else { return 16 }
            let value = 4 * beatSeconds / gap
            return [8, 16, 32, 64].min { abs(log2(Double($0) / value)) < abs(log2(Double($1) / value)) } ?? 16
        }
    }

    public let base: Int
    public let low: Double
    /// O alto do bend em semitons acima da casa (`base`), sem a meia oscilação do vibrato.
    public let rise: Double
    /// A altura mais alta do bend (o pré ou até onde sobe), em quartos de tom; 0 sem bend.
    public let quarterTones: Int
    /// O bend que o som faz, num tipo do editor (`BendForm`: pré-bend, sobe, volta, com as alturas e o tempo); nil
    /// sem bend.
    public let form: BendForm?
    public let vibrato: Bool
    public let trill: Trill?
    public let depth: Double
    /// O movimento do bend foi visto deslizando (quadros entre a partida e a chegada); sem eles, com quadros vazios no
    /// meio, pode ser um bend rápido que o rastreador perdeu ou um ligado: o F escreve, as suspeitas não acusam sozinhas.
    public let certain: Bool

    public init(base: Int, low: Double, rise: Double, quarterTones: Int, form: BendForm?, vibrato: Bool, trill: Trill?,
                depth: Double, certain: Bool = true) {
        self.certain = certain
        self.base = base
        self.low = low
        self.rise = rise
        self.quarterTones = quarterTones
        self.form = form
        self.vibrato = vibrato
        self.trill = trill
        self.depth = depth
    }

    /// Os pontos do bend (deslocamento 0–60, quartos de tom), no formato que o Guitar Pro 7 guarda.
    public var points: [ScoreNote.BendPoint]? {
        form.map { $0.points.map { ScoreNote.BendPoint(offset: $0[0], value: $0[1]) } }
    }

    public var guitarPro: [ScoreNote.BendPoint]? { points }
}

/// A curva de uma nota pronta para a Fita: a do motor (já sem os pontos soltos), as tendências de 200 ms (sem o
/// vibrato) e de 40 ms, e o encaixe. `offset` é a forma da faixa (`shapeAt` da Lente): ela segue o som, não só a
/// escrita.
public struct SoundNote: Sendable {
    public let curve: PitchCurve
    public let level: [Double?]
    public let quick: [Double?]
    public let fit: CurveFit?
    /// Nota de acorde: a curva pula entre as cordas que soam juntas, então a faixa fica na escrita e não há trinado.
    public let chord: Bool
    private let topLevel: Double
    private let topQuick: Double

    /// `next`: a altura da nota seguinte da corda, se ela começa onde esta acaba (uma subida no fim que chega a ela é a
    /// passagem, não um bend). `written`: os pontos do bend escrito (o som que fica entre a casa e o alto escrito é o
    /// bend da casa escrita, também quando o rastreador perde o começo de um bend rápido ou é um pré-bend).
    /// `approached`, `slidesOut`: a nota chega de outra casa (ligado, slide) ou sai por slide (`ScoreNote`).
    public init(curve: PitchCurve, start: Double, end: Double, pitch: Double, chord: Bool = false, next: Int? = nil,
                written: [ScoreNote.BendPoint] = [], approached: Bool = false, slidesOut: Bool = false) {
        self.curve = curve
        self.chord = chord
        level = SoundNote.trend(curve.values, width: Int((0.2 / curve.hop).rounded()))
        quick = SoundNote.trend(curve.values, width: max(3, Int((0.04 / curve.hop).rounded())))
        fit = SoundNote.fit(curve, start: start, end: end, pitch: pitch, trills: !chord, next: next, written: written,
                            approached: approached, slidesOut: slidesOut)
        func top(_ series: [Double?]) -> Double {
            var best = -Double.infinity
            for (k, value) in series.enumerated() {
                let t = curve.from + Double(k) * curve.hop
                if let value, t >= start + 0.02, t <= end { best = max(best, value) }
            }
            return best
        }
        topLevel = top(level)
        topQuick = top(quick)
    }

    /// Quantos semitons acima da altura escrita a faixa passa no instante `t`: o trinado em dentes entre as duas
    /// casas; o bend pelo som quando ele também dobra (senão pelos pontos escritos); o vibrato copiado do som quando
    /// ele tem vibrato (senão a onda escrita).
    public func offset(_ note: ScoreNote, at t: Double, start: Double, end: Double) -> Double {
        if chord { return note.shape(fraction: (t - start) / max(1e-3, end - start), elapsed: t - start) }
        if let trill = fit?.trill, Double(note.pitch) >= Double(trill.low) - 0.5, Double(note.pitch) <= Double(trill.high) + 0.5 {
            guard let value = value(curve.values, at: t) else { return 0 }
            let level = abs(value - Double(trill.high)) < abs(value - Double(trill.low)) ? trill.high : trill.low
            return Double(level - note.pitch)
        }
        let length = max(1e-3, end - start)
        let vibrato = note.vibrato > 0
        var offset = bendFromSound(note, at: t, start: start, vibrato: vibrato) ?? note.bendOffset(fraction: (t - start) / length)
        if vibrato {
            let k = Int(((t - curve.from) / curve.hop).rounded())
            if let fit, fit.vibrato, curve.values.indices.contains(k), let value = curve.values[k], let trend = level[k] {
                offset += note.bend.isEmpty ? value - fit.low : value - trend
            } else {
                offset += note.vibratoOffset(elapsed: t - start)
            }
        }
        return offset
    }

    /// O bend escrito que o som também faz: a faixa sobe e desce com o som, até a altura escrita. Nil quando o som não
    /// dobra (vale a escrita).
    private func bendFromSound(_ note: ScoreNote, at t: Double, start: Double, vibrato: Bool) -> Double? {
        guard let fit, !note.bend.isEmpty, fit.quarterTones > 0, fit.trill == nil else { return nil }
        let useLevel = vibrato && fit.vibrato
        let top = useLevel ? topLevel : topQuick
        let base = Double(fit.base)
        guard top > base + 0.15 else { return nil }
        let reading = t < start + 0.02 ? base : value(useLevel ? level : quick, at: t)
        guard let reading else { return nil }
        let written = (note.bend.map(\.value).max() ?? 0) / 2
        return written * max(0, min(1, (reading - base) / (top - base)))
    }

    /// O valor da série no instante: o do quadro, ou o válido mais perto até 3 quadros; antes do primeiro válido,
    /// nil; depois do último, o último.
    public func value(_ series: [Double?], at t: Double) -> Double? {
        let k = Int(((t - curve.from) / curve.hop).rounded())
        for d in 0...3 {
            if series.indices.contains(k - d), let v = series[k - d] { return v }
            if series.indices.contains(k + d), let v = series[k + d] { return v }
        }
        var i = min(series.count - 1, k)
        while i >= 0 {
            if let v = series[i] { return v }
            i -= 1
        }
        return nil
    }

    // MARK: - As contas da Lente

    static func percentile(_ list: [Double], _ q: Double) -> Double {
        guard !list.isEmpty else { return .nan }
        let sorted = list.sorted()
        let at = max(0, min(Double(sorted.count - 1), q * Double(sorted.count - 1)))
        let i = Int(at)
        return sorted[i] + (sorted[min(sorted.count - 1, i + 1)] - sorted[i]) * (at - Double(i))
    }

    /// Média móvel de `width` pontos só entre os válidos: a tendência (200 ms anulam o vibrato de 4 a 7 Hz).
    public static func trend(_ values: [Double?], width: Int) -> [Double?] {
        let half = width / 2
        return values.indices.map { i in
            guard values[i] != nil else { return nil }
            var sum = 0.0
            var count = 0
            for j in max(0, i - half)...min(values.count - 1, i + half) {
                if let v = values[j] {
                    sum += v
                    count += 1
                }
            }
            return sum / Double(count)
        }
    }

    /// Uma altura em semitons em quartos de tom, como a TAB escreve: abaixo de 0,3 semitom, 0; até 0,85, o ¼ de tom do
    /// blues (o limite da Lente do TabLab); depois o semitom inteiro mais perto (½, 1, 1½ tom…), e ¾, 1¼ … só quando o
    /// som está a 0,1 semitom deles (um bend de 1 tom que chega a 1,7 semitom é "1", como se escreve). Até 3 tons.
    /// Antes eram só ¼, ½, 1, 1½ e 2 tons, em faixas largas (um ¾ de tom saía de 1).
    public static func quarterTones(rise: Double) -> Int {
        guard rise >= 0.3 else { return 0 }
        guard rise >= 0.85 else { return 1 }
        let quarters = 2 * rise
        let odd = Int(quarters.rounded())
        if odd % 2 == 1, abs(quarters - Double(odd)) <= 0.2 { return min(BendForm.maxHeight, odd) }
        return min(BendForm.maxHeight, max(2, 2 * Int(rise.rounded())))
    }

    public static func fit(_ curve: PitchCurve, start: Double, end: Double, pitch: Double?,
                           trills: Bool = true, next: Int? = nil, written: [ScoreNote.BendPoint] = [],
                           approached: Bool = false, slidesOut: Bool = false) -> CurveFit? {
        let length = end - start
        guard length > 0.04 else { return nil }
        var times: [Double] = []
        var values: [Double?] = []
        for (k, value) in curve.values.enumerated() {
            let t = curve.from + Double(k) * curve.hop
            guard t >= start + 0.02, t <= end else { continue }
            times.append(t)
            values.append(value)
        }
        // A nota que vem de outra casa (ligado, slide da anterior, slide de fora): o som entra subindo ou descendo até
        // ela, e esse caminho não é bend nem outra altura; fica fora da medida até o primeiro quadro na altura escrita
        // (no pré-bend, se escrito), quando ele chega nos primeiros 250 ms (ou três quartos de uma nota curta). A que sai
        // por slide, sem bend escrito: fora depois do último quadro a um quarto de semitom da altura, nos últimos 250 ms
        // (o começo da subida até meio semitom já seria um bend de ¼). No reference.gp, 6 das 11 notas acusadas de
        // "outra altura e bend" eram slide ou ligado de uma ou duas casas abaixo.
        if let pitch, approached || slidesOut {
            let target = pitch + (written.first?.value ?? 0) / 2
            let near = { (i: Int, within: Double) -> Bool in values[i].map { abs($0 - target) <= within } ?? false }
            let enough = { (range: Range<Int>) -> Bool in values[range].compactMap { $0 }.count >= 6 }
            let reach = min(0.25, 0.75 * length)
            if slidesOut, written.isEmpty, let last = values.indices.last(where: { near($0, 0.25) }), times[last] >= end - reach,
               enough(0..<last + 1) {
                times.removeSubrange((last + 1)...)
                values.removeSubrange((last + 1)...)
            }
            if approached, let first = values.indices.first(where: { near($0, 0.5) }), times[first] <= start + reach,
               enough(first..<values.count) {
                times.removeSubrange(..<first)
                values.removeSubrange(..<first)
            }
        }
        let valid = values.compactMap { $0 }
        guard valid.count >= 6, Double(valid.count) >= 0.4 * Double(values.count) else { return nil }
        var head: [Double] = []
        for (i, value) in values.enumerated() where times[i] <= start + max(0.08, 0.4 * length) {
            if let value { head.append(value) }
        }
        let low = percentile(head.count >= 3 ? head : valid, 0.2)
        let fallback = Int(low.rounded())
        let trill = trills ? trillOf(times: times, values: values, base: fallback, pitch: pitch) : nil
        // Um salto no último quarto da nota (¾ de semitom ou mais entre dois quadros com altura, seguidos ou com até 7
        // vazios no meio): dali em diante já é a nota seguinte (um ligado, o rastreador ouvindo a próxima) e fica fora da
        // medida do bend. Antes o salto entrava no alto (no Highway Star, c. 171, um bend de 1 tom saía 1½ ou 2).
        if trill == nil {
            var previous: Int?
            var cut: Int?
            for i in values.indices {
                guard let value = values[i] else { continue }
                if let p = previous, let before = values[p], times[i] >= start + 0.75 * length, i - p <= 8,
                   abs(value - before) >= 0.75 {
                    cut = p + 1
                    break
                }
                previous = i
            }
            if let cut, values[..<cut].compactMap({ $0 }).count >= 6 {
                times.removeSubrange(cut...)
                values.removeSubrange(cut...)
            }
        }
        let level = trend(values, width: max(3, Int((0.2 / curve.hop).rounded())))
        let quick = trend(values, width: max(3, Int((0.04 / curve.hop).rounded())))
        // O vibrato: o que sobra em volta da tendência, em meias voltas que passam de 0,12 semitom.
        var swings = 0
        var sign = 0
        var top = 0.0
        var firstSwing: Double?
        var lastSwing: Double?
        var sizes: [Double] = []
        for i in values.indices {
            guard let value = values[i], let trend = level[i] else { continue }
            let rest = value - trend
            let s = rest > 0 ? 1 : -1
            if s != sign {
                if sign != 0, top >= 0.12 {
                    swings += 1
                    sizes.append(top)
                    if firstSwing == nil { firstSwing = times[i] }
                    lastSwing = times[i]
                }
                sign = s
                top = 0
            }
            top = max(top, abs(rest))
        }
        let cycles = Double(swings) / 2
        let span = firstSwing.flatMap { first in lastSwing.map { $0 - first } } ?? 0
        let frequency = span > 0 ? Double(swings - 1) / 2 / span : 0
        let vibrato = trill == nil && cycles >= 1.5 && frequency >= 3.5 && frequency <= 9 && percentile(sizes, 0.5) >= 0.12
        let depth = sizes.isEmpty ? 0 : percentile(sizes, 0.5)
        // A casa: a escrita, quando o som passa perto dela em algum momento da nota (antes o grave do começo virava a
        // casa: um bend rápido, ou o fim dobrado da nota anterior ainda nos primeiros quadros, a punha um ou dois
        // semitons acima, e a nota virava "outra altura"), ou, numa nota com bend escrito, quando o som fica entre a casa
        // e o alto escrito (o rastreador perdeu o começo de um bend rápido, ou é um pré-bend: nos licks do Buddy Guy e do
        // BB King o bend de 1 tom saía "½ a partir da casa de cima"); senão o grave do começo (a escrita está noutra
        // casa: pelo som, um pré-bend parado é igual a uma nota mais alta).
        let bottom = percentile(valid, 0.1)
        let writtenTop = (written.map(\.value).max() ?? 0) / 2
        let nearFret = pitch.map { pitch in
            abs(bottom - pitch) <= 0.5 || Double(valid.filter { abs($0 - pitch) <= 0.5 }.count) >= 0.4 * Double(valid.count)
        } ?? false
        let inWritten = pitch.map { writtenTop > 0 && bottom >= $0 - 0.5 && bottom <= $0 + writtenTop + 0.5 } ?? false
        var base = fallback
        if let pitch, trill == nil, nearFret || inWritten { base = Int(pitch.rounded()) }
        // O som nunca passa pela casa e o bend escrito sai dela: o rastreador perdeu o começo da subida (ou ouve o fim da
        // nota anterior), e o que ele ouve no começo não é um pré-bend (nas músicas, a dica fazia 30 bends escritos
        // virarem "pré e bend").
        let missedStart = !nearFret && inWritten && (written.first?.value ?? 0) == 0
        let ref = Double(base)
        guard trill == nil else {
            return CurveFit(base: base, low: low, rise: 0, quarterTones: 0, form: nil, vibrato: false, trill: trill,
                            depth: depth)
        }
        // As três alturas do bend, acima da casa: no ataque (o pré-bend), no alto (sem a meia oscilação do vibrato, que
        // na guitarra só sobe) e no fim (até onde volta).
        func median(from: Double, to: Double, _ series: [Double?]) -> Double? {
            let list = series.indices.compactMap { times[$0] >= from && times[$0] <= to ? series[$0] : nil }
            return list.count >= 2 ? percentile(list, 0.5) : list.first
        }
        // O ataque: o grave do começo (100 ms ou um quinto da nota). Num pré-bend o começo inteiro fica no alto; num
        // bend rápido a corda passa pela casa; e os primeiros quadros, que ainda ouvem o fim da nota anterior (dobrada,
        // num solo de bends), não contam sozinhos.
        let opening = values.indices.compactMap { times[$0] <= start + 0.02 + max(0.1, 0.2 * length) ? values[$0] : nil }
        let attack = (opening.count >= 2 ? percentile(opening, 0.1) : low) - ref
        // O alto: com vibrato, pela curva de 200 ms (que tira a oscilação) menos a meia oscilação; sem ele, pela de 40 ms,
        // que alcança o bend que só chega no fim da nota (no Highway Star, c. 250, um bend de 1 tom que chega a 1,9
        // semitom no fim saía ¾ pela de 200 ms). Sem os primeiros 50 ms, que ainda ouvem a nota anterior.
        var peak = -Double.infinity
        var peakAt = 0
        let series = vibrato ? level : quick
        for (i, value) in series.enumerated() where vibrato || times[i] >= start + 0.07 {
            if let value, value > peak {
                peak = value
                peakAt = i
            }
        }
        if peak == -.infinity, let first = level.indices.first(where: { level[$0] != nil }), let value = level[first] {
            (peak, peakAt) = (value, first)
        }
        let rise = peak - ref - (vibrato ? depth : 0)
        // O fim pela curva de 40 ms (a de 200 ms apagava uma volta curta), nos últimos quadros medidos.
        let last = times.last ?? end
        let final = (median(from: last - max(0.05, 0.15 * length), to: last, quick) ?? peak) - ref
        // Um pré-bend de ao menos meio tom: abaixo disso é o ataque agudo da corda (palhetada forte) ou a afinação.
        let pre = !missedStart && quarterTones(rise: attack) >= 2 ? quarterTones(rise: attack) : 0
        let high = max(pre, quarterTones(rise: rise))
        // O instante (0–60) de `t`, e o tempo do movimento de `from` a `to` (semitons acima da casa) a partir do índice
        // `index`: de 20 % a 80 % pela curva de 40 ms, estendido até 0 % e 100 % (a de 200 ms começa 100 ms antes).
        func offset(_ t: Double) -> Double { max(0, min(60, ((t - start) / length * 60).rounded())) }
        // Se o movimento desliza ou é um degrau (ligado, pull-off, o rastreador trocando de som), na curva crua: a
        // de 40 ms transforma o degrau numa rampa. Desliza com dois quadros ou mais entre 20 % e 80 %, ou com quadros
        // sem altura no meio (o rastreador perde a corda que desliza depressa); um salto direto entre dois quadros
        // seguidos, de um lado ao outro, é degrau. No Highway Star, no White Room e no Sunshine (31/10), os bends não
        // escritos caíram de 342 para ~115 com isso.
        var certain = true
        func glides(from: Double, to: Double, leave: Int, reach: Int) -> Bool {
            let low = ref + min(from, to) + 0.2 * abs(to - from)
            let high = ref + max(from, to) - 0.2 * abs(to - from)
            let first = max(0, leave - 3)
            let last = min(values.count - 1, reach + 3)
            guard first < last else { return false }
            if (first...last).filter({ values[$0].map { $0 > low && $0 < high } ?? false }).count >= 2 { return true }
            for i in first..<last {
                if let a = values[i], let b = values[i + 1], (a <= low && b >= high) || (a >= high && b <= low) { return false }
            }
            certain = false
            return true
        }
        // O ponto mais grave antes de `index` (de onde a subida sai: os primeiros quadros podem ainda ouvir a nota
        // anterior, dobrada).
        func lowest(before index: Int) -> Int {
            var best = 0
            var least = Double.infinity
            for i in 0...max(0, index) where i < quick.count {
                if let value = quick[i], value < least {
                    least = value
                    best = i
                }
            }
            return best
        }
        func move(from: Double, to: Double, after index: Int) -> (leave: Int, reach: Int, times: (Double, Double)) {
            let up = to > from
            func past(_ value: Double?, _ fraction: Double) -> Bool {
                guard let value else { return false }
                let mark = ref + from + (to - from) * fraction
                return up ? value >= mark : value <= mark
            }
            var leave = index
            while leave < values.count - 1, !past(quick[leave], 0.2) { leave += 1 }
            var reach = leave
            while reach < values.count - 1, !past(quick[reach], 0.8) { reach += 1 }
            let pace = (times[reach] - times[leave]) / 3
            return (leave, reach, (max(start, times[leave] - pace), min(end, times[reach] + pace)))
        }
        var form: BendForm?
        if high > 0 {
            let topQ = max(high, 1)
            if pre == 0 {
                // Sobe; volta se cai ao menos meio semitom e 40 % da subida depois do alto. Um degrau não é bend.
                let target = min(Double(topQ) / 2, rise)
                let rising = move(from: 0, to: target, after: lowest(before: peakAt))
                if glides(from: 0, to: target, leave: rising.leave, reach: rising.reach) {
                    var bend = BendForm(kind: .bend, top: topQ, start: offset(rising.times.0), arrive: offset(rising.times.1))
                    if rise - final >= max(0.5, 0.4 * rise), peakAt < values.count - 1 {
                        let falling = move(from: rise, to: max(0, final), after: max(peakAt, rising.reach))
                        if glides(from: rise, to: max(0, final), leave: falling.leave, reach: falling.reach) {
                            bend.kind = .bendRelease
                            bend.end = quarterTones(rise: max(0, final))
                            (bend.hold, bend.back) = (offset(falling.times.0), offset(falling.times.1))
                        }
                    }
                    form = bend
                }
            } else if rise - attack >= 0.5 {
                // Começa dobrada e sobe mais (num degrau, fica o pré-bend).
                let rising = move(from: attack, to: rise, after: 0)
                form = glides(from: attack, to: rise, leave: rising.leave, reach: rising.reach)
                    ? BendForm(kind: .prebendBend, pre: pre, top: max(quarterTones(rise: rise), pre + 1),
                               start: offset(rising.times.0), arrive: offset(rising.times.1))
                    : BendForm(kind: .prebend, pre: pre)
            } else if attack - final >= max(0.5, 0.4 * attack) {
                // Começa dobrada e volta; um degrau até a casa é outra nota (um ligado), não um pré-bend.
                let falling = move(from: attack, to: max(0, final), after: 0)
                if glides(from: attack, to: max(0, final), leave: falling.leave, reach: falling.reach) {
                    form = BendForm(kind: .prebendRelease, pre: pre, end: quarterTones(rise: max(0, final)),
                                    start: offset(falling.times.0), arrive: offset(falling.times.1))
                }
            } else {
                form = BendForm(kind: .prebend, pre: pre)
            }
            form = form?.valid()
            // A passagem para a nota seguinte (ligado, slide), não um bend: a subida que só sai no último quarto da nota,
            // ou que sai depois da metade e chega à altura da seguinte; a volta no último quarto que cai na altura da
            // seguinte (outra casa).
            if let current = form {
                let late = current.start >= 45
                // Pelo alto da curva de 40 ms: a de 200 ms não alcança o salto no fim de uma nota curta.
                let quickTop = (quick.compactMap { $0 }.max() ?? peak) - ref
                let reachesNext = next.map { abs(Double($0) - ref - quickTop) <= 0.5 } ?? false
                switch current.kind {
                case .bend where late || (current.start >= 30 && reachesNext):
                    form = nil
                case .prebendBend where late || (current.start >= 30 && reachesNext):
                    form = BendForm(kind: .prebend, pre: current.pre).valid()
                case .bendRelease where current.hold >= 45
                    && (next.map { abs(Double($0) - ref) >= 1 && abs(Double($0) - ref - final) <= 0.5 } ?? false):
                    var kept = current
                    kept.kind = .bend
                    form = kept.valid()
                default:
                    break
                }
            }
        }
        let quarters = form.map { max($0.kind.usesPre ? $0.pre : 0, $0.kind.usesTop ? $0.top : 0) } ?? 0
        return CurveFit(base: base, low: form?.kind.usesPre == true ? ref : low, rise: form == nil ? 0 : max(0, rise),
                        quarterTones: quarters, form: form, vibrato: vibrato, trill: nil, depth: depth,
                        certain: form == nil || certain)
    }

    /// O trinado: a curva alterna entre dois níveis a ao menos 0,7 semitom, cruzando o meio a cada 35 a 200 ms, em
    /// degraus (metade dos saltos em até dois quadros: o ligado pula de casa, o vibrato desliza).
    static func trillOf(times: [Double], values: [Double?], base: Int, pitch: Double?) -> CurveFit.Trill? {
        let valid = values.compactMap { $0 }
        let bottom = percentile(valid, 0.1)
        let top = percentile(valid, 0.9)
        let span = top - bottom
        guard span >= 0.7 else { return nil }
        let middle = (bottom + top) / 2
        var changes: [Double] = []
        var side = 0
        for (i, value) in values.enumerated() {
            guard let value else { continue }
            let now = value > middle ? 1 : -1
            if side != 0, now != side { changes.append(times[i]) }
            side = now
        }
        guard changes.count >= 2 else { return nil }
        let gap = percentile(zip(changes, changes.dropFirst()).map { $1 - $0 }, 0.5)
        guard gap >= 0.035, gap <= 0.2 else { return nil }
        var steps = 0
        var last = -1
        for (i, value) in values.enumerated() {
            guard let value else { continue }
            if last >= 0, i - last <= 2, let previous = values[last], abs(value - previous) >= 0.5 * span { steps += 1 }
            last = i
        }
        guard steps >= (changes.count + 1) / 2 else { return nil }
        return CurveFit.Trill(low: Int(bottom.rounded()), high: Int(top.rounded()), gap: gap)
    }
}

/// O que o som diz contra a nota escrita: as notas suspeitas da Fita (contorno vermelho) e o Tab do editor, que vai de
/// uma a outra. É o que o Encaixar (F) mudaria no que se toca, com folga para não acusar à toa: a altura, o bend com
/// meio tom de diferença e o trinado. O vibrato fica de fora (no Sunshine eram 22 das 75, quase sempre um vibrato que a
/// TAB não escreve; o F ainda o põe). Sem curva clara ou numa nota de acorde (a curva pula entre as cordas) não há o
/// que dizer.
public enum SoundDisagreement: Hashable, Sendable {
    /// Soa noutra altura (a medida, presa no semitom).
    case pitch(Int)
    /// O bend que soa, em quartos de tom (0: o som não dobra), longe do escrito.
    case bend(Int)
    /// O som já começa dobrado (o pré-bend, em quartos de tom) e a escrita não; ou o pré-bend escrito não soa (o som
    /// parte da casa).
    case prebend(Int)
    case noPrebend
    /// O som volta (até a altura dita, em quartos de tom) e a escrita não; ou a volta escrita não soa.
    case release(Int)
    case noRelease

    /// Ligados rápidos entre duas casas, que a TAB não tem (ou tem entre outras).
    case trill(low: Int, high: Int)
    /// O trinado escrito que o som não faz.
    case noTrill
    /// O ataque medido longe do começo escrito (milissegundos; negativo: antes).
    case attack(Int)
    /// A nota escrita não soa (a curva quase não tem altura no corpo dela).
    case silent
    /// O som tem vibrato e a escrita não.
    case vibrato

    public var kind: SuspectKind {
        switch self {
        case .pitch: .pitch
        case .bend, .prebend, .noPrebend, .release, .noRelease: .bend
        case .trill, .noTrill: .trill
        case .attack: .attack
        case .silent: .silent
        case .vibrato: .vibrato
        }
    }
}

/// Os tipos de suspeita, para o filtro da coluna: as que comparam o som com a nota escrita (altura, bend, trinado,
/// ataque fora do tempo, nota que não soa, vibrato não escrito) e o som sem nota escrita.
public enum SuspectKind: String, CaseIterable, Codable, Hashable, Sendable {
    case pitch, bend, trill, unwritten, silent, attack, vibrato

    public var label: String {
        switch self {
        case .pitch: "Altura"
        case .bend: "Bend"
        case .trill: "Trinado"
        case .unwritten: "Sem nota"
        case .silent: "Não soa"
        case .attack: "Ataque"
        case .vibrato: "Vibrato"
        }
    }

    /// Os que vêm ligados: o vibrato fica de fora (muita TAB não o escreve, e ele encheria a lista).
    public static let standard: Set<SuspectKind> = Set(allCases).subtracting([.vibrato])
}

/// Um som que a faixa tem (o motor acha os ataques e a altura de cada um, `GET songs/{id}/sounds`): o segundo, a
/// altura MIDI, a intensidade em dB e quanto ela está abaixo do mais forte em ±2 s.
public struct HeardSound: Hashable, Sendable {
    public let seconds: Double
    public let pitch: Int
    public let level: Double
    public let relative: Double

    public init(seconds: Double, pitch: Int, level: Double, relative: Double) {
        self.seconds = seconds
        self.pitch = pitch
        self.level = level
        self.relative = relative
    }

    /// Os sons fortes (até `strong` dB abaixo do mais forte em volta) sem nota escrita: nenhuma nota de nenhuma pista
    /// começa perto (`tolerance` segundos) na mesma altura (um semitom de folga, ou a oitava), nem uma nota dessa altura
    /// está soando ali (um ligado, um bend ou o vibrato também dão ataque no espectro).
    public static func unwritten(_ sounds: [HeardSound], notes: [(start: Double, end: Double, pitch: Int)],
                                 tolerance: Double = 0.12, strong: Double = -18) -> [HeardSound] {
        let sorted = notes.sorted { $0.start < $1.start }
        let longest = sorted.map { $0.end - $0.start }.max() ?? 0
        func same(_ a: Int, _ b: Int) -> Bool { abs(a - b) <= 1 || abs(abs(a - b) - 12) <= 1 }
        return sounds.filter { sound in
            guard sound.relative >= strong else { return false }
            // As notas que podem cobrir o som: as que começam até `longest` antes dele.
            var low = 0, high = sorted.count
            let from = sound.seconds - max(tolerance, longest) - 0.05
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid].start < from { low = mid + 1 } else { high = mid }
            }
            var i = low
            while i < sorted.count, sorted[i].start <= sound.seconds + tolerance {
                let note = sorted[i]
                if same(note.pitch, sound.pitch) {
                    if abs(note.start - sound.seconds) <= tolerance { return false }
                    if note.start < sound.seconds, sound.seconds < note.end + 0.05 { return false }
                }
                i += 1
            }
            return true
        }
    }
}

extension SoundNote {
    /// Tudo o que o som discorda da nota escrita que começa em `start` e acaba em `end` (segundos): a altura, o bend, o
    /// trinado (`disagreements`), a nota que não soa (no corpo dela, sem as pontas, menos de um quinto dos pontos têm
    /// altura), o ataque a mais de 60 ms do começo escrito e o vibrato que a escrita não tem.
    public func checks(with note: ScoreNote, start: Double, end: Double) -> [SoundDisagreement] {
        let length = end - start
        var body = 0, heard = 0
        for (k, value) in curve.values.enumerated() {
            let t = curve.from + Double(k) * curve.hop
            if t >= start + 0.15 * length, t <= end - 0.15 * length {
                body += 1
                if value != nil { heard += 1 }
            }
        }
        if !chord, body >= 5, Double(heard) < 0.2 * Double(body) { return [.silent] }
        var list = disagreements(with: note)
        if let attack = curve.attack, abs(attack - start) >= 0.06 { list.append(.attack(Int(((attack - start) * 1000).rounded()))) }
        if !chord, fit?.vibrato == true, note.vibrato == 0, fit?.trill == nil, !list.contains(where: { $0.kind == .pitch }) {
            list.append(.vibrato)
        }
        return list
    }

    public func disagreements(with note: ScoreNote) -> [SoundDisagreement] {
        guard !chord, let fit else { return [] }
        if let trill = fit.trill {
            // O trinado escrito entre as mesmas duas notas (de qualquer uma para a outra) está certo.
            let written = note.trill.map { Set([note.pitch, $0]) }
            return written == Set([trill.low, trill.high]) ? [] : [.trill(low: trill.low, high: trill.high)]
        }
        if note.trill != nil { return [.noTrill] }
        let written = BendForm(points: note.bend.map { [$0.offset, $0.value] })
        // Noutra altura, o bend e o vibrato foram medidos em volta da nota errada: só a altura. O pré-bend escrito que
        // fica parado soa como a nota mais alta: está certo.
        if fit.base != note.pitch {
            if let written, written.kind == .prebend, fit.form == nil,
               abs(Double(fit.base - note.pitch) - Double(written.pre) / 2) <= 0.5 {
                return []
            }
            return [.pitch(fit.base)]
        }
        // Um bend não confirmado (sem quadros no meio do movimento) não acusa sozinho uma nota sem bend escrito.
        let heard = fit.certain || written != nil ? fit.form : nil
        let heardHeight = heard == nil ? 0 : fit.quarterTones
        var list: [SoundDisagreement] = []
        let writtenHeight = Int(note.bend.map(\.value).max() ?? 0)
        if abs(heardHeight - writtenHeight) >= 2 { list.append(.bend(heardHeight)) }
        // O tipo, com meio tom de folga: o pré-bend e a volta. Sem bend no som, o `.bend(0)` já diz.
        func pre(_ form: BendForm?) -> Int { form.map { $0.kind.usesPre ? $0.pre : 0 } ?? 0 }
        func drop(_ form: BendForm?) -> Int {
            guard let form, form.kind.usesEnd else { return 0 }
            return (form.kind == .bendRelease ? form.top : form.pre) - form.end
        }
        if pre(heard) >= 2, pre(written) == 0 {
            list.append(.prebend(pre(heard)))
        } else if pre(written) >= 2, heard != nil, pre(heard) == 0 {
            list.append(.noPrebend)
        }
        if drop(heard) >= 2, drop(written) == 0 {
            list.append(.release(heard?.end ?? 0))
        } else if drop(written) >= 2, heard != nil, drop(heard) == 0 {
            list.append(.noRelease)
        }
        return list
    }
}

extension PitchCurve {
    /// A mesma curva `semitones` acima (abaixo, se negativo): a afinação da gravação descontada.
    public func shifted(by semitones: Double) -> PitchCurve {
        semitones == 0 ? self
            : PitchCurve(from: from, hop: hop, values: values.map { $0.map { $0 + semitones } }, attack: attack)
    }
}

/// A afinação da gravação: quanto as notas soam acima (ou abaixo) do Lá 440, em semitons (+0,35 = 35 cents). Muita
/// gravação antiga foi feita com a fita mais rápida ou a banda afinada entre si; sem descontar, os pontos ficam sempre
/// no alto da faixa, um bend parece maior e uma nota a meio caminho vira suspeita.
public enum RecordingTuning {
    public struct Sample: Sendable {
        public let curve: PitchCurve
        public let start: Double
        public let end: Double
        public let pitch: Int
        /// Sem bend escrito e fora de acorde: a altura parada diz a afinação.
        public let plain: Bool

        public init(curve: PitchCurve, start: Double, end: Double, pitch: Int, plain: Bool) {
            self.curve = curve
            self.start = start
            self.end = end
            self.pitch = pitch
            self.plain = plain
        }
    }

    /// A mediana do desvio das notas paradas (o meio de cada uma, sem o ataque e o fim; a mediana dos pontos), das
    /// que ficam a menos de 0,6 semitom da escrita; nil com menos de `minimum` notas.
    public static func estimate(_ samples: [Sample], minimum: Int = 20) -> Double? {
        var deviations: [Double] = []
        for sample in samples where sample.plain {
            let length = sample.end - sample.start
            let from = sample.start + 0.25 * length
            let to = sample.end - 0.25 * length
            var middle: [Double] = []
            for (k, value) in sample.curve.values.enumerated() {
                let t = sample.curve.from + Double(k) * sample.curve.hop
                if let value, t >= from, t <= to { middle.append(value) }
            }
            guard middle.count >= 5 else { continue }
            let deviation = SoundNote.percentile(middle, 0.5) - Double(sample.pitch)
            if abs(deviation) < 0.6 { deviations.append(deviation) }
        }
        guard deviations.count >= minimum else { return nil }
        return SoundNote.percentile(deviations, 0.5)
    }
}

/// O que o som fez numa nota, para a linha da nota escolhida: a altura (o semitom e os cents, no meio da nota), o bend
/// que soou (e quanto do escrito ele alcança), a largura do vibrato e o trinado.
public struct SoundReport: Hashable, Sendable {
    public let pitch: Int
    public let cents: Int
    /// O bend que soa, em quartos de tom (0: o som não dobra).
    public let bend: Int
    /// Quanto do bend escrito o som alcança, em %; nil sem bend escrito.
    public let reached: Int?
    /// A meia oscilação do vibrato, em cents; nil sem vibrato.
    public let vibrato: Int?
    public let trill: CurveFit.Trill?
    /// O bend que soa, no tipo do editor; nil sem bend.
    public let form: BendForm?
}

extension SoundNote {
    /// A mediana do meio da nota (sem o primeiro e o último quarto): a altura em que ela fica.
    public func middle(start: Double, end: Double) -> Double? {
        let length = end - start
        var values: [Double] = []
        for (k, value) in curve.values.enumerated() {
            let t = curve.from + Double(k) * curve.hop
            if let value, t >= start + 0.25 * length, t <= end - 0.25 * length { values.append(value) }
        }
        return values.count >= 3 ? SoundNote.percentile(values, 0.5) : nil
    }

    /// nil sem altura clara. Numa nota de acorde o motor mede entre as outras notas dele (sem trinado).
    public func report(for note: ScoreNote, start: Double, end: Double) -> SoundReport? {
        guard let fit else { return nil }
        let written = note.bend.map(\.value).max() ?? 0
        // Com bend, o meio da nota já subiu: a altura é a de partida.
        let held = fit.quarterTones > 0 ? fit.low : (middle(start: start, end: end) ?? fit.low)
        return SoundReport(pitch: fit.base, cents: Int(((held - Double(fit.base)) * 100).rounded()),
                           bend: fit.quarterTones,
                           reached: written > 0 ? Int((max(0, fit.rise) / (written / 2) * 100).rounded()) : nil,
                           vibrato: fit.vibrato ? Int((fit.depth * 100).rounded()) : nil, trill: fit.trill, form: fit.form)
    }
}

/// O mapa de tempo contra o som: em cada compasso, quanto os ataques das notas chegam depois (+) ou antes (−) do começo
/// escrito delas. A mediana, com ao menos `minimum` ataques no compasso: uma nota sozinha pode ser um atraso de
/// propósito; várias juntas dizem que a batida está no lugar errado.
public enum SoundSync {
    /// `bars`: o início de cada compasso em segundos (com o fim do último). A chave é o índice do compasso (0…).
    public static func barOffsets(_ notes: [(start: Double, attack: Double?)], bars: [Double],
                                  minimum: Int = 3) -> [Int: Double] {
        guard bars.count >= 2 else { return [:] }
        var lists: [Int: [Double]] = [:]
        for note in notes {
            guard let attack = note.attack, note.start >= bars[0], note.start < bars[bars.count - 1] else { continue }
            var low = 0
            var high = bars.count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                if bars[middle] <= note.start { low = middle } else { high = middle }
            }
            lists[low, default: []].append(attack - note.start)
        }
        return lists.compactMapValues { $0.count >= minimum ? SoundNote.percentile($0, 0.5) : nil }
    }
}
