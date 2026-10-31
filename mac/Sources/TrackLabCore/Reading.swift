import Foundation

/// Uma leitura de uma nota: a altura, o bend, o vibrato e o trinado que se escreveriam nela. O corretor ("Corrigir pelo
/// som") escreve a do som onde ela discorda da escrita com segurança; num clique, a coluna mostra as leituras perto do
/// som (`SoundNote.readings`) como cartões desenhados (a TAB e a forma sobre os pontos do som), e um clique escolhe.
public struct NoteReading: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// O que o som faz (o F).
        case sound
        /// O que está escrito agora.
        case written
        /// O que estava antes do corretor (o Songsterr, ou a sua edição).
        case original
        /// Uma variação perto do som: ¼ de tom a mais ou a menos, sem a volta, sem bend, a casa de cima, o vibrato.
        case variant
    }

    public var pitch: Int
    /// Os pontos do bend como o Guitar Pro 7 guarda: [deslocamento 0–60, quartos de tom]; vazio sem bend.
    public var bend: [[Double]]
    public var vibrato: Bool
    /// A altura MIDI de cima do trinado (a nota fica na de baixo); nil sem trinado.
    public var trill: Int?
    public var kind: Kind
    public var name: String

    public init(pitch: Int, bend: [[Double]] = [], vibrato: Bool = false, trill: Int? = nil, kind: Kind, name: String) {
        self.pitch = pitch
        self.bend = bend
        self.vibrato = vibrato
        self.trill = trill
        self.kind = kind
        self.name = name
    }

    /// A leitura do que a nota tem escrito.
    public init(note: ScoreNote, kind: Kind = .written, name: String = "Como está") {
        self.init(pitch: note.pitch, bend: note.bend.map { [$0.offset, $0.value] }, vibrato: note.vibrato > 0,
                  trill: note.trill, kind: kind, name: name)
    }

    /// A leitura do som (o que o F escreve): o trinado na nota de baixo, ou a casa, o bend e o vibrato medidos.
    public init(fit: CurveFit, name: String = "Pelo som") {
        if let trill = fit.trill {
            self.init(pitch: trill.low, trill: trill.high, kind: .sound, name: name)
        } else {
            self.init(pitch: fit.base, bend: fit.form?.points ?? [], vibrato: fit.vibrato, kind: .sound, name: name)
        }
    }

    /// O bend num tipo do editor (nil sem bend, ou num bend de dois movimentos de outro editor).
    public var form: BendForm? { BendForm(points: bend) }

    /// Escreve o mesmo que `other` (a altura, o bend, o vibrato e o trinado; o nome e a origem não contam).
    public func writesSame(as other: NoteReading) -> Bool {
        pitch == other.pitch && vibrato == other.vibrato && trill == other.trill && bend == other.bend
    }

    /// A forma na fração 0–1 da nota, em semitons acima da casa: o bend em linha reta entre os pontos.
    public func offset(at fraction: Double) -> Double {
        guard let first = bend.first, first.count >= 2 else { return 0 }
        let x = max(0, min(60, fraction * 60))
        if x <= first[0] { return first[1] / 2 }
        for (a, b) in zip(bend, bend.dropFirst()) where x <= b[0] {
            return (b[0] > a[0] ? a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0]) : b[1]) / 2
        }
        return (bend.last?[1] ?? 0) / 2
    }

    /// O que a leitura muda em relação a `other`, em palavras ("Ré♯ 4, sobe ½, vibrato"); vazio se escreve o mesmo.
    public func changes(from other: NoteReading) -> [String] {
        var parts: [String] = []
        if pitch != other.pitch { parts.append(TabSelection.name(pitch)) }
        if bend != other.bend { parts.append(form?.spoken ?? (bend.isEmpty ? "sem bend" : "outro bend")) }
        if vibrato != other.vibrato { parts.append(vibrato ? "vibrato" : "sem vibrato") }
        if trill != other.trill { parts.append(trill.map { "trinado até \(TabSelection.name($0))" } ?? "sem trinado") }
        return parts
    }
}

extension SoundNote {
    /// Quão perto do som a leitura fica, de 0 a 1: a raiz da média dos quadrados da diferença, em semitons, entre a forma
    /// da leitura e a curva do som (de 40 ms; com vibrato no som, a de 200 ms menos a meia oscilação, como o alto do
    /// bend), na janela que o encaixe mediu; um semitom de diferença média é 0. O vibrato que discorda do som tira 0,1;
    /// num trinado, cada quadro vale pela mais perto das duas notas. Nil sem encaixe ou com menos de três quadros.
    public func closeness(_ reading: NoteReading, start: Double, end: Double) -> Double? {
        guard let fit, end > start else { return nil }
        let window = fit.window ?? (start + 0.02)...end
        let series = fit.vibrato ? level : quick
        var sum = 0.0
        var count = 0
        for k in curve.values.indices {
            let t = curve.from + Double(k) * curve.hop
            guard window.contains(t), let raw = curve.values[k], let smooth = series[k] else { continue }
            let measured: Double
            let target: Double
            if let high = reading.trill {
                measured = raw
                target = abs(raw - Double(high)) < abs(raw - Double(reading.pitch)) ? Double(high) : Double(reading.pitch)
            } else {
                measured = fit.vibrato ? smooth - fit.depth : smooth
                target = Double(reading.pitch) + reading.offset(at: (t - start) / (end - start))
            }
            sum += min(16, (measured - target) * (measured - target))
            count += 1
        }
        guard count >= 3 else { return nil }
        var score = 1 - (sum / Double(count)).squareRoot()
        if reading.trill == nil, reading.vibrato != fit.vibrato { score -= 0.1 }
        if reading.trill == nil, fit.trill != nil { score -= 0.2 }
        return max(0, min(1, score))
    }

    /// As leituras da nota para escolher, das mais perto do som para as mais longe: a do som, a escrita, a de antes
    /// do corretor (`original`, se outra) e variações da do som (¼ de tom a mais ou a menos, sem a volta, sem bend, a
    /// casa de cima sem bend, o vibrato trocado). Iguais saem (fica a primeira desta ordem: som, escrita, original);
    /// no máximo `limit`, sempre com a escrita e a original.
    public func readings(for note: ScoreNote, start: Double, end: Double, original: NoteReading? = nil,
                         limit: Int = 4) -> [(reading: NoteReading, closeness: Double)] {
        guard let fit else { return [] }
        let written = NoteReading(note: note)
        var list: [NoteReading] = []
        let sound = NoteReading(fit: fit)
        list.append(sound)
        list.append(written)
        if var original {
            original.kind = .original
            original.name = "Original"
            list.append(original)
        }
        if sound.trill == nil {
            func variant(_ name: String, _ change: (inout NoteReading) -> Void) {
                var reading = sound
                change(&reading)
                reading.kind = .variant
                reading.name = name
                list.append(reading)
            }
            if let form = sound.form {
                let height = form.kind.usesTop ? form.top : form.pre
                if height > 1 { variant("¼ a menos") { $0.bend = form.with(height: height - 1).points } }
                if height < BendForm.maxHeight { variant("¼ a mais") { $0.bend = form.with(height: height + 1).points } }
                if form.kind == .bendRelease {
                    var held = form
                    held.kind = .bend
                    variant("Sem a volta") { $0.bend = held.valid().points }
                }
                if form.kind == .bend, form.top % 2 == 0 {
                    variant("Casa de cima") {
                        $0.pitch += form.top / 2
                        $0.bend = []
                    }
                }
                variant("Sem bend") { $0.bend = [] }
            }
            variant(sound.vibrato ? "Sem vibrato" : "Com vibrato") { $0.vibrato.toggle() }
        }
        var unique: [NoteReading] = []
        for reading in list where !unique.contains(where: { $0.writesSame(as: reading) }) {
            unique.append(reading)
        }
        // A do som igual à escrita fica com o nome da escrita (é o que está na TAB).
        if sound.writesSame(as: written), let index = unique.firstIndex(where: { $0.kind == .sound }) {
            unique[index].name = "Como está"
        }
        let sorted = unique.compactMap { reading in closeness(reading, start: start, end: end).map { (reading, $0) } }
            .sorted { $0.1 > $1.1 }
        // Sempre à vista: a escrita e a de antes do corretor, mesmo longe do som (no lugar da variação mais longe).
        var shown = Array(sorted.prefix(limit))
        for kept in [NoteReading.Kind.written, .original] {
            guard !shown.contains(where: { $0.0.kind == kept }), let item = sorted.first(where: { $0.0.kind == kept }),
                  let index = shown.lastIndex(where: { $0.0.kind == .variant }) else { continue }
            shown[index] = item
        }
        return shown.sorted { $0.1 > $1.1 }.map { (reading: $0.0, closeness: $0.1) }
    }

    /// A largura (meia oscilação, semitons) a partir da qual o corretor escreve sozinho o vibrato que o som tem: a
    /// detecção vê a partir de 0,1 (a Lente, os cartões), mas no GOAT o corretor passava a pôr 50 vibratos a mais com
    /// ela, quase todos sutis.
    public static let writtenVibrato = 0.12

    /// O vibrato de uma corda dupla (duas notas na mesma batida): a mão vibra as duas juntas, então as duas ganham o
    /// vibrato quando as duas o mostram, ao menos uma com largura para o corretor e nenhuma acima de meio semitom (a
    /// curva de acorde, pelos harmônicos, dá saltos que parecem um vibrato largo: no Sultans of Swing, c. 42, a corda
    /// dupla 8/9 "vibrava" 0,59 semitom na de baixo e nada na de cima, e ganhava o vibrato). Acordes de três notas ou mais
    /// ficam de fora. No c. 42, a última, a de cima vibra 0,11 e a de baixo 0,36.
    public static func doubleStopVibrato(_ sounds: [SoundNote]) -> Bool {
        let fits = sounds.compactMap(\.fit)
        return sounds.count == 2 && fits.count == 2
            && fits.allSatisfy { $0.vibrato && $0.trill == nil && $0.depth <= 0.5 }
            && fits.contains { $0.depth >= writtenVibrato }
    }

    /// A correção do corretor: a escrita com as partes em que o som discorda dela com segurança (a altura, o bend, o
    /// vibrato que o som tem e a escrita não), ou nil se nada muda; o trinado fica para o clique. Notas de acorde não mudam (a curva pula
    /// entre as cordas); a altura só muda até um semitom (mais longe, o rastreador provavelmente pegou outra coisa, como
    /// o F recusa). O tempo de um bend escrito do mesmo tipo e alturas do som fica como está. A correção tem de chegar
    /// perto do som (`closeness`): a altura, o bend e o trinado só mudam se a nota fica ao menos 15 pontos mais perto e
    /// em 50 % ou mais; o vibrato sozinho, se a nota com ele fica em 75 % ou mais (medido em 31/10: sem isso, mudanças
    /// que não aproximavam a nota do som, e vibratos num som pouco claro).
    public func correction(for note: ScoreNote, start: Double, end: Double) -> NoteReading? {
        guard !chord, let fit else { return nil }
        let written = NoteReading(note: note)
        let sound = NoteReading(fit: fit)
        var out = written
        out.kind = .sound
        out.name = "Pelo som"
        for reason in disagreements(with: note) {
            switch reason {
            case .pitch:
                guard abs(fit.base - note.pitch) <= 1 else { return nil }
                out.pitch = sound.pitch
                out.bend = sound.bend
                out.vibrato = sound.vibrato
            case .bend, .prebend, .noPrebend, .release, .noRelease:
                out.bend = sound.bend
            case .trill, .noTrill:
                // O trinado não muda sozinho (nas músicas, 40 trinados não escritos, muitos repetidos no mesmo riff do
                // White Room: o rastreador alternando com outra coisa); ele aparece entre as leituras do clique.
                return nil
            case .attack, .silent, .vibrato:
                break
            }
        }
        if fit.trill == nil, fit.vibrato, fit.depth >= SoundNote.writtenVibrato, note.vibrato == 0, out.pitch == note.pitch {
            out.vibrato = true
        }
        guard !out.writesSame(as: written), let before = closeness(written, start: start, end: end) else { return nil }
        let reshaped = out.pitch != written.pitch || out.bend != written.bend || out.trill != written.trill
        if reshaped, let after = closeness(out, start: start, end: end), after - before >= 0.15, after >= 0.5 {
            return out
        }
        // Sem a mudança de forma (ou ela não aproxima), fica o vibrato, se ele sozinho vale.
        var vibrato = written
        vibrato.kind = .sound
        vibrato.name = "Pelo som"
        vibrato.vibrato = out.vibrato
        guard vibrato.vibrato != written.vibrato, out.pitch == written.pitch,
              let after = closeness(vibrato, start: start, end: end), after >= 0.75 else { return nil }
        return vibrato
    }
}
