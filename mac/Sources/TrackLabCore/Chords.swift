import Foundation

/// Uma correção da barra de acordes, guardada no pacote (`chordEdits` no manifesto): o trecho, em tiques, com o nome
/// que vale ali. Nome vazio é "sem acorde" (N.C.).
public struct ChordEdit: Codable, Hashable, Sendable {
    public var from: Double
    public var to: Double
    public var name: String

    public init(from: Double, to: Double, name: String) {
        self.from = from
        self.to = to
        self.name = name
    }
}

/// Um acorde na barra: de onde a onde (tiques), o nome ("" = sem acorde), de onde veio e os outros nomes que as notas
/// também aceitam (os mais perto primeiro).
public struct ChordSpan: Hashable, Sendable {
    public enum Source: String, Sendable {
        /// Lido nas notas das pistas.
        case score
        /// Escrito no Guitar Pro (o nome no alto da batida).
        case written
        /// Corrigido na barra.
        case edited
    }

    public var from: Double
    public var to: Double
    public var name: String
    public var source: Source
    public var alternatives: [String]
    /// O que o som diz no trecho (o Chord-CNN-LSTM do motor), na grafia da música; nil sem a leitura pelo som.
    public var heard: String?
    /// O som e as notas discordam com segurança (outra fundamental, ou a terça trocada, na maior parte do trecho): a
    /// barra marca para conferir.
    public var disputed: Bool

    public init(from: Double, to: Double, name: String, source: Source, alternatives: [String] = [],
                heard: String? = nil, disputed: Bool = false) {
        self.from = from
        self.to = to
        self.name = name
        self.source = source
        self.alternatives = alternatives
        self.heard = heard
        self.disputed = disputed
    }
}

/// O papel de uma pista na harmonia, pelo nome dela (os do Songsterr dizem "Rhythm Guitar", "Lead Guitar", "Bass",
/// "Lead Vocals"…): quanto as notas dela pesam no acorde.
public enum HarmonyRole: Sendable, Equatable {
    case rhythm, guitar, lead, keys, bass, vocal, drums, other

    public static func of(name: String) -> HarmonyRole {
        let text = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("drum", "bateria", "percus", "kit") { return .drums }
        if has("vocal", "voice", "voz", "vox", "choir", "coro", "sing") { return .vocal }
        if has("bass", "baixo") { return .bass }
        if has("rhythm", "ritmo", "ritmica", "base", "acoustic", "violao", "chord", "acord", "comp") { return .rhythm }
        if has("lead", "solo", "slide", "harmon", "melod", "fill") { return .lead }
        if has("key", "piano", "organ", "orgao", "synth", "teclado", "rhodes", "clav", "wurl") { return .keys }
        if has("guitar", "guitarra", "gtr") { return .guitar }
        return .other
    }

    /// O peso de uma nota desta pista; na lead, a nota de um acorde (outra começa junto) pesa como na base. Na base, na
    /// guitarra e no teclado, uma nota sozinha curta (uma frase, uma passagem) pesa menos que a de um acorde.
    func weight(chordal: Bool, short: Bool = false) -> Double {
        let alone = !chordal && short ? 0.4 : 1
        switch self {
        case .rhythm: return alone
        case .guitar, .keys: return 0.8 * alone
        case .lead: return chordal ? 0.9 : 0.12
        case .bass: return 0.35
        case .vocal: return 0.08
        case .other: return 0.3
        case .drums: return 0
        }
    }
}

/// O nome de um acorde a partir das notas que soam: a base e o teclado dizem a harmonia, a lead quando toca acorde, o
/// baixo dá a fundamental, e o que fica entre uma troca e outra se decide pelo caminho mais provável (uma troca custa,
/// e custa menos no 1 do compasso que fora do tempo). Por cima, os escritos no Guitar Pro e as correções.
public enum ChordReader {
    public struct Track: Sendable {
        public let name: String
        public let notes: [ScoreNote]

        public init(name: String, notes: [ScoreNote]) {
            self.name = name
            self.notes = notes
        }

        /// A mesma pista com as notas `shift` semitons acima.
        func shifted(by shift: Int) -> Track {
            Track(name: name, notes: notes.map { note in
                ScoreNote(tick: note.tick, duration: note.duration, pitch: note.pitch + shift, string: note.string,
                          fret: note.fret, vibrato: note.vibrato, bend: note.bend, trill: note.trill.map { $0 + shift },
                          approached: note.approached, slidesOut: note.slidesOut, slideIn: note.slideIn, slideOut: note.slideOut)
            })
        }
    }

    /// Os passos da leitura: uma colcheia.
    static let step = TempoGrid.ticksPerQuarter / 2

    public static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    /// As qualidades, os intervalos (a fundamental primeiro, e o que passa do acorde de três notas, a sétima, a sexta,
    /// a nona, por último) e quanto o nome mais raro custa.
    struct Quality {
        let suffix: String
        let tones: [Int]
        let cost: Double
        /// Quantos intervalos do começo são o acorde; os de depois são a cor (só valem se pesam de verdade).
        var core: Int { tones.count > 3 ? 3 : tones.count }
    }

    static let qualities: [Quality] = [
        Quality(suffix: "", tones: [0, 4, 7], cost: 0),
        Quality(suffix: "m", tones: [0, 3, 7], cost: 0),
        Quality(suffix: "5", tones: [0, 7], cost: 0.04),
        Quality(suffix: "7", tones: [0, 4, 7, 10], cost: 0.08),
        Quality(suffix: "m7", tones: [0, 3, 7, 10], cost: 0.08),
        Quality(suffix: "maj7", tones: [0, 4, 7, 11], cost: 0.12),
        Quality(suffix: "sus4", tones: [0, 5, 7], cost: 0.1),
        Quality(suffix: "sus2", tones: [0, 2, 7], cost: 0.12),
        Quality(suffix: "add9", tones: [0, 4, 7, 2], cost: 0.18),
        Quality(suffix: "9", tones: [0, 4, 7, 10, 2], cost: 0.22),
        Quality(suffix: "dim", tones: [0, 3, 6], cost: 0.2),
        Quality(suffix: "m7b5", tones: [0, 3, 6, 10], cost: 0.22),
        Quality(suffix: "aug", tones: [0, 4, 8], cost: 0.24),
    ]

    struct Chord: Hashable {
        let root: Int
        let quality: Int
        var name: String { name(ChordReader.names) }
        func name(_ spelling: [String]) -> String { spelling[root] + ChordReader.qualities[quality].suffix }
    }

    /// O que soa num passo: o peso de cada uma das 12 notas e o baixo (a nota mais grave, com o peso dela).
    struct Window {
        var weights = [Double](repeating: 0, count: 12)
        var bass: [Double] = [Double](repeating: 0, count: 12)
        /// A nota grave que começa neste passo (o baixo que abre um acorde), se alguma começa.
        var onset: Int?
        var total: Double { weights.reduce(0, +) }
    }

    /// A barra inteira: lida nas notas e no som, com os escritos e as correções por cima. `barTicks` vai do primeiro
    /// compasso ao fim do último; `written` traz o tique, a pista e o nome; `sound`, os acordes pelo som em tiques, com o
    /// nome como o Chord-CNN-LSTM escreve ("A:min7", "C:maj/5", "N").
    public static func read(tracks: [Track], barTicks: [Double], written: [(tick: Double, track: Int, name: String)] = [],
                            sound: [(from: Double, to: Double, name: String)] = [], edits: [ChordEdit] = []) -> [ChordSpan] {
        guard let start = barTicks.first, let end = barTicks.last, end > start else { return [] }
        let count = Int(((end - start) / step).rounded(.up))
        guard count > 0 else { return [] }
        let heard = hear(sound, start: start, count: count)
        // Uma pista deslocada do disco (as formas de um capo que o Guitar Pro não guarda, uma afinação abaixo que ele
        // não diz): as notas dela entram já no que soa. Pista por pista: no Here Comes the Sun as guitarras estão 7
        // semitons abaixo e o baixo na altura certa (deslocando tudo, o baixo virava a barra errada: "A/E", "D/A").
        let shifts = trackShifts(tracks, heard: heard, start: start, count: count)
        let windows = listen(tracks: zip(tracks, shifts).map { $1 == 0 ? $0 : $0.shifted(by: $1) }, start: start, count: count)
        let spelling = spelling(for: windows)
        var spans = decide(windows, start: start, end: end, barTicks: barTicks, spelling: spelling, heard: heard)
        spans = applyWritten(spans, written: written, tracks: tracks, end: end, spelling: spelling)
        spans = judge(spans, heard: heard, start: start, spelling: spelling)
        return apply(edits, to: spans)
    }

    // MARK: - O som

    /// O deslocamento da guitarra de base (a primeira pista de base, de guitarra ou lead com notas): o nome da forma no
    /// braço para os diagramas.
    public static func tabShift(tracks: [Track], barTicks: [Double], sound: [(from: Double, to: Double, name: String)]) -> Int {
        guard let start = barTicks.first, let end = barTicks.last, end > start, !sound.isEmpty else { return 0 }
        let count = Int(((end - start) / step).rounded(.up))
        let heard = hear(sound, start: start, count: count)
        for role in [HarmonyRole.rhythm, .guitar, .lead] {
            if let track = tracks.first(where: { HarmonyRole.of(name: $0.name) == role && !$0.notes.isEmpty }) {
                return shift(of: track, heard: heard, start: start, count: count)
            }
        }
        return 0
    }

    /// O deslocamento de cada pista até o disco (0 na que já soa no lugar), para o app propor o capo ou a afinação.
    public static func trackShifts(tracks: [Track], barTicks: [Double], sound: [(from: Double, to: Double, name: String)]) -> [Int] {
        guard let start = barTicks.first, let end = barTicks.last, end > start, !sound.isEmpty else {
            return Array(repeating: 0, count: tracks.count)
        }
        let count = Int(((end - start) / step).rounded(.up))
        return trackShifts(tracks, heard: hear(sound, start: start, count: count), start: start, count: count)
    }

    static func trackShifts(_ tracks: [Track], heard: [Chord?], start: Double, count: Int) -> [Int] {
        tracks.map { shift(of: $0, heard: heard, start: start, count: count) }
    }

    /// Quantos semitons somar às notas de uma pista para elas caírem nas notas do acorde que o som ouve: o deslocamento
    /// com mais tempo de nota dentro do acorde, quando ele põe a metade dentro e ao menos 15 % mais que sem deslocar
    /// (com ao menos 16 tempos de nota comparados). A voz e a bateria não mudam.
    static func shift(of track: Track, heard: [Chord?], start: Double, count: Int) -> Int {
        let role = HarmonyRole.of(name: track.name)
        guard !heard.isEmpty, role != .drums, role != .vocal else { return 0 }
        var scores = [Double](repeating: 0, count: 12)
        var total = 0.0
        for note in track.notes where note.duration > 0 {
            let first = max(0, Int(((note.tick - start) / step).rounded(.down)))
            let last = min(count - 1, Int(((note.tick + note.duration - start) / step).rounded(.up)) - 1)
            guard first <= last else { continue }
            let pc = ((note.pitch % 12) + 12) % 12
            for index in first...last where index < heard.count {
                guard let chord = heard[index] else { continue }
                let a = start + Double(index) * step
                let weight = (min(a + step, note.tick + note.duration) - max(a, note.tick)) / step
                guard weight > 0 else { continue }
                total += weight
                for interval in qualities[chord.quality].tones {
                    scores[((chord.root + interval - pc) % 12 + 12) % 12] += weight
                }
            }
        }
        guard total >= 32, let best = scores.indices.max(by: { scores[$0] < scores[$1] }), best != 0,
              scores[best] >= 0.5 * total, scores[best] >= scores[0] + 0.15 * total else { return 0 }
        return best
    }

    /// O peso do som no caminho: pouco onde a TAB tem um acorde claro (a TAB está no tempo da partitura e vê as
    /// notas), muito onde ela é um riff ou uma frase (o verso da White Room, o fim do Ramblin' Man), pelo quanto o
    /// melhor acorde das notas as explica.
    static func soundWeight(clarity: Double) -> Double {
        let doubt = 1 - min(1, max(0, clarity))
        return 0.1 + 0.9 * doubt * doubt
    }
    static let soundWeight = 0.6

    /// Um nome do Chord-CNN-LSTM ("A:min7", "C:maj/5", "Bb:sus4(b7)") num dos nossos acordes; nil sem acorde.
    static func chord(heard name: String) -> Chord? {
        guard name != "N", name != "X", let colon = name.firstIndex(of: ":") else { return nil }
        guard let (root, _) = rootOf(String(name[..<colon])) else { return nil }
        var kind = String(name[name.index(after: colon)...])
        if let cut = kind.firstIndex(where: { $0 == "/" || $0 == "(" }) { kind = String(kind[..<cut]) }
        let suffix: String
        switch kind {
        case "maj", "maj6", "": suffix = ""
        case "min", "min6", "minmaj7": suffix = "m"
        case "7", "11", "13": suffix = "7"
        case "maj7", "maj9", "maj13": suffix = "maj7"
        case "min7", "min9", "min11", "min13": suffix = "m7"
        case "9": suffix = "9"
        case "dim", "dim7": suffix = "dim"
        case "hdim7": suffix = "m7b5"
        case "aug": suffix = "aug"
        case "sus4": suffix = "sus4"
        case "sus2": suffix = "sus2"
        case "5", "1": suffix = "5"
        default: return nil
        }
        guard let quality = qualities.firstIndex(where: { $0.suffix == suffix }) else { return nil }
        return Chord(root: root, quality: quality)
    }

    /// O acorde que o som ouve em cada passo (pelo meio dele); nil sem acorde ou sem a leitura.
    static func hear(_ sound: [(from: Double, to: Double, name: String)], start: Double, count: Int) -> [Chord?] {
        guard !sound.isEmpty else { return [] }
        let sorted = sound.sorted { $0.from < $1.from }
        var result = [Chord?](repeating: nil, count: count)
        var cursor = 0
        for index in 0..<count {
            let middle = start + (Double(index) + 0.5) * step
            while cursor < sorted.count, sorted[cursor].to <= middle { cursor += 1 }
            if cursor < sorted.count, sorted[cursor].from <= middle { result[index] = chord(heard: sorted[cursor].name) }
        }
        return result
    }

    /// Quanto dois acordes concordam: o mesmo, 1; a mesma fundamental e a mesma terça (ou um deles sem terça), 0,7; só
    /// a mesma fundamental, 0,3; outra, 0.
    static func agreement(_ a: Chord, _ b: Chord) -> Double {
        if a == b { return 1 }
        guard a.root == b.root else { return 0 }
        func third(_ chord: Chord) -> Int? {
            let tones = qualities[chord.quality].tones
            return tones.contains(3) ? 3 : tones.contains(4) ? 4 : nil
        }
        let x = third(a)
        let y = third(b)
        return x == nil || y == nil || x == y ? 0.7 : 0.3
    }

    /// Cada trecho com o que o som disse nele (o acorde que ele mais ouviu) e, se o som e o nome discordam na maior
    /// parte do trecho (outra fundamental, ou a terça trocada), a marca para conferir.
    static func judge(_ spans: [ChordSpan], heard: [Chord?], start: Double, spelling: [String]) -> [ChordSpan] {
        guard !heard.isEmpty else { return spans }
        return spans.map { span in
            var copy = span
            let first = max(0, Int(((span.from - start) / step).rounded()))
            let last = min(heard.count, Int(((span.to - start) / step).rounded()))
            guard first < last else { return copy }
            var counts: [Chord: Int] = [:]
            for chord in heard[first..<last].compactMap({ $0 }) { counts[chord, default: 0] += 1 }
            guard let (top, _) = counts.max(by: { $0.value < $1.value }) else { return copy }
            copy.heard = top.name(spelling)
            // As notas sem terça (um power chord, um sus de riff) e o som com ela na mesma fundamental: o nome do som
            // (o verso da White Room saía D5 e Csus2; o disco é Ré e Dó).
            func third(_ chord: Chord) -> Bool { qualities[chord.quality].tones.contains { $0 == 3 || $0 == 4 } }
            if span.source == .score, !span.name.contains("/"), let mine = chordOf(name: span.name), mine.root == top.root,
               !third(mine), third(top), Double(counts[top] ?? 0) >= 0.5 * Double(last - first) {
                copy.alternatives = Array(([span.name] + span.alternatives.filter { $0 != copy.heard }).prefix(4))
                copy.name = top.name(spelling)
            }
            // Ao menos dois tempos.
            if let mine = chordOf(name: span.name), last - first >= 4 {
                let against = heard[first..<last].filter { other in other.map { agreement($0, mine) < 0.5 } ?? false }.count
                copy.disputed = Double(against) >= 0.6 * Double(last - first)
            }
            return copy
        }
    }

    /// Um nome nosso ("Bbm7", "C/G", "A♭") num acorde, para comparar com o som.
    static func chordOf(name: String) -> Chord? {
        let plain = name.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
        let head = String(plain.split(separator: "/").first ?? "")
        guard let (root, rest) = rootOf(head) else { return nil }
        let suffix = rest.hasPrefix("min") ? "m" + rest.dropFirst(3) : rest
        if let quality = qualities.firstIndex(where: { $0.suffix == suffix }) { return Chord(root: root, quality: quality) }
        // Um nome que a leitura não tem (C(add9), Cmadd11): a tríade dele.
        let minor = suffix.hasPrefix("m") && !suffix.hasPrefix("maj")
        return Chord(root: root, quality: minor ? 1 : 0)
    }

    // MARK: - A grafia pelo tom

    public static let sharps = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    public static let flats = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]

    /// O tom da música pelas notas de tudo (os perfis de Krumhansl, maior e menor): a fundamental e se é menor.
    static func key(of windows: [Window]) -> (tonic: Int, minor: Bool)? {
        var total = [Double](repeating: 0, count: 12)
        for window in windows { for pc in 0..<12 { total[pc] += window.weights[pc] } }
        guard total.reduce(0, +) > 0 else { return nil }
        let major = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        func correlation(_ profile: [Double], _ tonic: Int) -> Double {
            let shifted = (0..<12).map { profile[($0 - tonic + 12) % 12] }
            let mx = total.reduce(0, +) / 12
            let my = shifted.reduce(0, +) / 12
            var num = 0.0, dx = 0.0, dy = 0.0
            for i in 0..<12 {
                num += (total[i] - mx) * (shifted[i] - my)
                dx += (total[i] - mx) * (total[i] - mx)
                dy += (shifted[i] - my) * (shifted[i] - my)
            }
            return num / max(1e-9, (dx * dy).squareRoot())
        }
        var best = (tonic: 0, minor: false, value: -2.0)
        for tonic in 0..<12 {
            for (isMinor, profile) in [(false, major), (true, minor)] {
                let value = correlation(profile, tonic)
                if value > best.value { best = (tonic, isMinor, value) }
            }
        }
        return (best.tonic, best.minor)
    }

    /// Os nomes das notas pela armadura do tom: tudo em bemóis em Fá, Si♭, Mi♭, Lá♭, Ré♭ e Sol♭ maior (e nas relativas
    /// menores); nos tons de sustenidos, as notas da escala em sustenidos e as de fora na grafia de costume; em Dó maior e
    /// Lá menor, a de costume (Bb, Eb, Ab, mas C# e F#).
    static func spelling(for windows: [Window]) -> [String] {
        guard let key = key(of: windows) else { return names }
        let major = key.minor ? (key.tonic + 3) % 12 : key.tonic
        if [5, 10, 3, 8, 1, 6].contains(major) { return flats }
        guard [7, 2, 9, 4, 11].contains(major) else { return names }
        let scale = Set([0, 2, 4, 5, 7, 9, 11].map { (major + $0) % 12 })
        return (0..<12).map { scale.contains($0) ? sharps[$0] : names[$0] }
    }

    /// Um nome escrito na grafia da música ("A♭" vira "Ab", "C#" vira "Db" numa música em bemóis, "C5 \\G" vira "C5/G").
    static func respell(_ name: String, _ spelling: [String]) -> String {
        let plain = name.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: " \\", with: "/").replacingOccurrences(of: "\\", with: "/")
        let parts = plain.split(separator: "/", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let head = parts.first, let (root, rest) = rootOf(head) else { return plain }
        var result = spelling[root] + rest
        if parts.count > 1 {
            if let (bass, after) = rootOf(parts[1]), after.isEmpty { result += "/" + spelling[bass] } else { result += "/" + parts[1] }
        }
        return result
    }

    // MARK: - O que soa em cada passo

    static func listen(tracks: [Track], start: Double, count: Int) -> [Window] {
        var windows = [Window](repeating: Window(), count: count)
        // A nota mais grave de cada passo, e a mais grave das que começam nele.
        var lowestPitch: [Int: Int] = [:]
        var lowestOnset: [Int: Int] = [:]
        let hasBass = tracks.contains { HarmonyRole.of(name: $0.name) == .bass && !$0.notes.isEmpty }
        for track in tracks {
            let role = HarmonyRole.of(name: track.name)
            guard role != .drums, !track.notes.isEmpty else { continue }
            // Quantas notas começam em cada tique: duas ou mais juntas são acorde.
            var together: [Double: Int] = [:]
            for note in track.notes { together[note.tick, default: 0] += 1 }
            for note in track.notes where note.duration > 0 {
                let weight = role.weight(chordal: (together[note.tick] ?? 0) >= 2,
                                         short: note.duration < TempoGrid.ticksPerQuarter)
                guard weight > 0 else { continue }
                let first = max(0, Int(((note.tick - start) / step).rounded(.down)))
                let last = min(count - 1, Int(((note.tick + note.duration - start) / step).rounded(.up)) - 1)
                guard first <= last else { continue }
                let pc = ((note.pitch % 12) + 12) % 12
                for index in first...last {
                    let a = start + Double(index) * step
                    let overlap = min(a + step, note.tick + note.duration) - max(a, note.tick)
                    guard overlap > 0 else { continue }
                    // A nota segurada perde peso com o tempo (o que foi atacado agora diz mais que o que ainda soa).
                    let age = max(0, a - note.tick)
                    let fade = max(0.35, exp(-age / (TempoGrid.ticksPerQuarter * 4)))
                    windows[index].weights[pc] += weight * fade * overlap / step
                }
            }
            // O baixo: a nota mais grave de cada passo, da pista de baixo; sem ela, das pistas de harmonia.
            let bassSource = hasBass ? role == .bass : [.rhythm, .guitar, .keys].contains(role)
            if bassSource {
                for note in track.notes where note.duration > 0 {
                    let first = max(0, Int(((note.tick - start) / step).rounded(.down)))
                    let last = min(count - 1, Int(((note.tick + note.duration - start) / step).rounded(.up)) - 1)
                    guard first <= last else { continue }
                    if abs(start + Double(first) * step - note.tick) < step / 2 || first == 0,
                       lowestOnset[first].map({ note.pitch < $0 }) ?? true {
                        lowestOnset[first] = note.pitch
                    }
                    for index in first...last {
                        if let lowest = lowestPitch[index], lowest <= note.pitch { continue }
                        lowestPitch[index] = note.pitch
                    }
                }
            }
        }
        for (index, pitch) in lowestPitch {
            windows[index].bass[((pitch % 12) + 12) % 12] = 1
        }
        for (index, pitch) in lowestOnset {
            windows[index].onset = ((pitch % 12) + 12) % 12
        }
        return windows
    }

    // MARK: - O acorde de cada passo e o caminho

    /// Quanto as notas do passo concordam com o acorde (perto de 1: só as notas dele, todas presentes, com o baixo na
    /// fundamental).
    static func score(_ chord: Chord, _ window: Window) -> Double {
        score(chord, window, total: window.total)
    }

    static func score(_ chord: Chord, _ window: Window, total: Double) -> Double {
        guard total > 0 else { return 0 }
        let quality = qualities[chord.quality]
        var inside = 0.0
        var missing = 0.0
        var bassOnTone = false
        for (index, interval) in quality.tones.enumerated() {
            let pc = (chord.root + interval) % 12
            let weight = window.weights[pc]
            inside += weight
            // A quinta falta muitas vezes; a fundamental e a terça, não; a sétima, a sexta e a nona precisam pesar de
            // verdade (uma passagem do baixo ou da voz pela sexta fazia do Eb um Cm7).
            let needed = index < quality.core ? 0.06 : 0.14
            if weight / total < needed { missing += interval == 7 && index < quality.core ? 0.12 : 0.4 }
            if interval != 0, window.bass[pc] > 0 { bassOnTone = true }
        }
        inside /= total
        // O baixo: a parte do tempo em que ele está na fundamental (ou noutra nota do acorde).
        let bassTotal = window.bass.reduce(0, +)
        var bass = 0.0
        if bassTotal > 0 {
            let onRoot = window.bass[chord.root] / bassTotal
            bass = 0.18 * onRoot + (bassOnTone ? 0.04 * (1 - onRoot) : 0)
        }
        return inside - (1 - inside) - missing - quality.cost + bass
    }

    static func candidates(_ window: Window, limit: Int) -> [Chord] {
        let total = window.total
        guard total > 0 else { return [] }
        var best: [(Chord, Double)] = []
        for root in 0..<12 {
            // Um acorde sem a fundamental soando não entra (corta as contas sem mudar a resposta).
            guard window.weights[root] > 0 || window.bass[root] > 0 else { continue }
            for quality in qualities.indices {
                let chord = Chord(root: root, quality: quality)
                let value = score(chord, window, total: total)
                if best.count < limit || value > best[best.count - 1].1 {
                    best.append((chord, value))
                    best.sort { $0.1 > $1.1 }
                    if best.count > limit { best.removeLast() }
                }
            }
        }
        return best.map(\.0)
    }

    /// O que soa em volta de cada passo, um tempo para cada lado (pesos 1, 2, 3, 2, 1): o acorde se decide pelo tempo
    /// inteiro, e uma nota de passagem ou um pedaço do acorde não muda a conta sozinho.
    static func context(_ windows: [Window]) -> [Window] {
        let kernel: [Double] = [1, 2, 3, 2, 1]
        return windows.indices.map { index in
            var sum = Window()
            for (offset, factor) in kernel.enumerated() {
                let other = index + offset - 2
                guard windows.indices.contains(other) else { continue }
                for pc in 0..<12 {
                    sum.weights[pc] += windows[other].weights[pc] * factor / 3
                    sum.bass[pc] += windows[other].bass[pc] * factor
                }
            }
            return sum
        }
    }

    /// Quanto custa trocar de acorde em cada passo: pouco no 1 do compasso, mais no meio dele, mais num tempo e muito
    /// fora do tempo.
    static func changeCosts(count: Int, start: Double, barTicks: [Double]) -> [Double] {
        let quarter = TempoGrid.ticksPerQuarter
        return (0..<count).map { index in
            let tick = start + Double(index) * step
            guard let bar = barTicks.lastIndex(where: { $0 <= tick + 0.5 }), bar + 1 < barTicks.count else { return 1.6 }
            let offset = tick - barTicks[bar]
            let length = barTicks[bar + 1] - barTicks[bar]
            if abs(offset) < 0.5 { return 0.4 }
            if abs(offset - length / 2) < 0.5 { return 0.7 }
            if abs(offset.truncatingRemainder(dividingBy: quarter)) < 0.5 { return 1.1 }
            return 1.6
        }
    }

    static func decide(_ raw: [Window], start: Double, end: Double, barTicks: [Double], spelling: [String] = names,
                       heard: [Chord?] = []) -> [ChordSpan] {
        let windows = context(raw)
        let count = windows.count
        // Quanto um passo pesa: um passo com pouca nota (uma pausa entre batidas) segue o acorde de antes.
        let totals = windows.map(\.total)
        let sounding = totals.filter { $0 > 0 }.sorted()
        let typical = max(0.001, sounding.isEmpty ? 1 : sounding[sounding.count / 2])
        let tops = windows.map { candidates($0, limit: 3) }
        let costs = changeCosts(count: count, start: start, barTicks: barTicks)
        // Os estados de cada passo: os melhores dos passos em volta, mais "sem acorde" (nil).
        var states: [[Chord?]] = []
        for index in 0..<count {
            var pool: [Chord?] = [nil]
            var seen = Set<Chord>()
            for other in max(0, index - 4)...min(count - 1, index + 4) {
                for chord in tops[other] where seen.insert(chord).inserted { pool.append(chord) }
                // O que o som ouve em volta também é candidato (a TAB pode não ter a harmonia ali).
                if other < heard.count, let chord = heard[other], seen.insert(chord).inserted { pool.append(chord) }
            }
            states.append(pool)
        }
        // Quão clara é a harmonia nas notas de cada passo (o melhor acorde delas, pela parte do passo que soa).
        let clarity = windows.indices.map { index -> Double in
            guard let top = tops[index].first, totals[index] > 0 else { return 0 }
            return score(top, windows[index], total: totals[index]) * min(1, totals[index] / typical)
        }
        func emission(_ chord: Chord?, _ index: Int) -> Double {
            let confidence = min(1, totals[index] / typical)
            let sound = index < heard.count ? heard[index] : nil
            let soundWeight = soundWeight(clarity: clarity[index])
            guard let chord else {
                // Sem acorde: o som também não ouve nenhum, ou a TAB está quase vazia e o som não diz nada.
                if index < heard.count, sound != nil { return -0.6 }
                return totals[index] < typical * 0.05 ? 0.3 : -0.6 * confidence
            }
            let notes = totals[index] > 0 ? score(chord, windows[index], total: totals[index]) * confidence : 0
            return notes + (sound.map { soundWeight * agreement(chord, $0) } ?? 0)
        }
        // Viterbi.
        var best = states[0].map { emission($0, 0) }
        var back: [[Int]] = [Array(repeating: 0, count: states[0].count)]
        for index in 1..<max(count, 1) {
            let cost = costs[index]
            var row: [Double] = []
            var from: [Int] = []
            let previous = states[index - 1]
            let bestPrevious = best.indices.max { best[$0] < best[$1] } ?? 0
            for state in states[index] {
                var value = best[bestPrevious] - cost
                var origin = bestPrevious
                if let same = previous.firstIndex(where: { $0 == state }), best[same] > value {
                    value = best[same]
                    origin = same
                }
                row.append(value + emission(state, index))
                from.append(origin)
            }
            best = row
            back.append(from)
        }
        var path = [Int](repeating: 0, count: count)
        path[count - 1] = best.indices.max { best[$0] < best[$1] } ?? 0
        if count > 1 {
            for index in stride(from: count - 1, to: 0, by: -1) { path[index - 1] = back[index][path[index]] }
        }
        // Os trechos: passos seguidos com o mesmo acorde.
        var runs: [Run] = []
        var runStart = 0
        for index in 1...count {
            let current = states[runStart][path[runStart]]
            if index < count, states[index][path[index]] == current { continue }
            runs.append(Run(chord: current, first: runStart, end: index))
            runStart = index
        }
        runs = absorb(runs, raw: raw, barTicks: barTicks, start: start, heard: heard)
        return runs.map { run in
            span(run.chord, windows: Array(raw[run.first..<run.end]), from: start + Double(run.first) * step,
                 to: min(end, start + Double(run.end) * step), spelling: spelling)
        }
    }

    struct Run {
        var chord: Chord?
        var first: Int
        var end: Int
    }

    /// Um trecho curto (menos de meio compasso) que o acorde vizinho explica quase tão bem vira parte dele: o
    /// guitarrista que troca pedaços do acorde, ou faz uma passagem, sem sair dele. E dois vizinhos com a mesma
    /// fundamental, um sendo variação do outro (sus, add9, 6, 7), viram um, com o nome que pesa mais no todo.
    static func absorb(_ input: [Run], raw: [Window], barTicks: [Double], start: Double, heard: [Chord?] = []) -> [Run] {
        var runs = input
        func sum(_ run: Run) -> Window {
            var total = Window()
            for window in raw[run.first..<run.end] {
                for pc in 0..<12 {
                    total.weights[pc] += window.weights[pc]
                    total.bass[pc] += window.bass[pc]
                }
            }
            return total
        }
        func value(_ chord: Chord?, _ window: Window, _ run: Run? = nil) -> Double {
            guard let chord else { return window.total < 0.05 ? 0.3 : -1 }
            var value = window.total > 0 ? score(chord, window) : 0
            // O som no trecho: a parte dele que concorda com o acorde.
            if let run, run.end <= heard.count {
                let said = heard[run.first..<run.end].compactMap { $0 }
                if !said.isEmpty { value += soundWeight * said.map { agreement(chord, $0) }.reduce(0, +) / Double(run.end - run.first) }
            }
            return value
        }
        let bar = barTicks.count >= 2 ? (barTicks.last! - barTicks.first!) / Double(barTicks.count - 1) : 4 * TempoGrid.ticksPerQuarter
        let short = Int((bar / 2 / step).rounded())
        var changed = true
        while changed, runs.count > 1 {
            changed = false
            // O mais curto primeiro.
            for index in runs.indices.sorted(by: { runs[$0].end - runs[$0].first < runs[$1].end - runs[$1].first }) {
                let run = runs[index]
                guard run.end - run.first < short else { break }
                let here = sum(run)
                let own = value(run.chord, here, run)
                // O baixo na fundamental do trecho quase todo (e não na do vizinho): é uma troca de verdade.
                let bassTotal = here.bass.reduce(0, +)
                let bassAgrees = run.chord.map { bassTotal > 0 && here.bass[$0.root] / bassTotal >= 0.6 } ?? false
                var best: (index: Int, value: Double)?
                for other in [index - 1, index + 1] where runs.indices.contains(other) {
                    if bassAgrees, runs[other].chord?.root != run.chord?.root { continue }
                    let candidate = value(runs[other].chord, here, run)
                    if candidate >= own - 0.3, best == nil || candidate > best!.value { best = (other, candidate) }
                }
                guard let best else { continue }
                runs[best.index].first = min(runs[best.index].first, run.first)
                runs[best.index].end = max(runs[best.index].end, run.end)
                runs.remove(at: index)
                changed = true
                break
            }
        }
        // As variações da mesma fundamental.
        let variants: Set<String> = ["", "5", "sus2", "sus4", "add9", "6", "7", "maj7", "9"]
        let minorVariants: Set<String> = ["m", "5", "sus2", "sus4", "m7", "m6"]
        func related(_ a: Chord, _ b: Chord) -> Bool {
            guard a.root == b.root else { return false }
            let x = qualities[a.quality].suffix
            let y = qualities[b.quality].suffix
            return (variants.contains(x) && variants.contains(y)) || (minorVariants.contains(x) && minorVariants.contains(y))
        }
        var merged: [Run] = []
        for run in runs {
            if let last = merged.last, let a = last.chord, let b = run.chord, related(a, b) {
                let whole = Run(chord: a, first: last.first, end: run.end)
                let total = sum(whole)
                let chord = value(a, total, whole) >= value(b, total, whole) ? a : b
                merged[merged.count - 1] = Run(chord: chord, first: last.first, end: run.end)
            } else if let last = merged.last, last.chord == run.chord {
                merged[merged.count - 1].end = run.end
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    /// O trecho com o nome (e o baixo, quando ele fica noutra nota do acorde quase o trecho todo: "C/G") e os outros
    /// nomes que as notas também aceitam.
    static func span(_ found: Chord?, windows: [Window], from: Double, to: Double, spelling: [String] = names) -> ChordSpan {
        guard var chord = found else { return ChordSpan(from: from, to: to, name: "", source: .score) }
        var sum = Window()
        for window in windows {
            for pc in 0..<12 {
                sum.weights[pc] += window.weights[pc]
                sum.bass[pc] += window.bass[pc]
            }
        }
        // As mesmas notas, dois nomes (Cm7 e Eb6, Fm7 e Ab6): vale o do baixo que abre o trecho, se ele é a fundamental
        // de uma leitura quase tão boa (o baixo que anda pela sexta não faz o acorde menor).
        if let opening = windows.first(where: { $0.onset != nil })?.onset, opening != chord.root {
            let own = score(chord, sum)
            let tones = Set(qualities[chord.quality].tones.map { (chord.root + $0) % 12 })
            // Só as leituras do baixo cujas notas o acorde achado já tem (o Eb dentro do Cm7; um pedal embaixo de
            // outro acorde não muda o nome).
            let rival = qualities.indices.map { Chord(root: opening, quality: $0) }
                .filter { rival in qualities[rival.quality].tones.prefix(qualities[rival.quality].core)
                    .allSatisfy { tones.contains((rival.root + $0) % 12) } }
                .max { score($0, sum) < score($1, sum) }
            if let rival, score(rival, sum) >= own - 0.35 { chord = rival }
        }
        var name = chord.name(spelling)
        let bassTotal = sum.bass.reduce(0, +)
        if bassTotal > 0, let low = sum.bass.indices.max(by: { sum.bass[$0] < sum.bass[$1] }), low != chord.root,
           sum.bass[low] / bassTotal >= 0.7, sum.bass[low] >= 2,
           qualities[chord.quality].tones.map({ (chord.root + $0) % 12 }).contains(low) {
            name += "/" + spelling[low]
        }
        let others = candidates(sum, limit: 5).filter { $0 != chord }.map { $0.name(spelling) }
        return ChordSpan(from: from, to: to, name: name, source: .score, alternatives: Array(others.prefix(3)))
    }

    // MARK: - Os escritos e as correções por cima

    /// Um acorde escrito vale do tique dele até o próximo escrito ou até a troca lida que vem depois (a primeira a mais
    /// de uma semínima dele). Repetido em várias pistas no mesmo tique, vale o da pista de base.
    static func applyWritten(_ spans: [ChordSpan], written: [(tick: Double, track: Int, name: String)], tracks: [Track],
                             end: Double, spelling: [String] = names) -> [ChordSpan] {
        guard !written.isEmpty else { return spans }
        func rank(_ track: Int) -> Int {
            guard tracks.indices.contains(track) else { return 9 }
            switch HarmonyRole.of(name: tracks[track].name) {
            case .rhythm: return 0
            case .guitar, .keys: return 1
            case .lead: return 2
            default: return 3
            }
        }
        var byTick: [Double: (rank: Int, name: String)] = [:]
        for chord in written {
            let r = rank(chord.track)
            if let have = byTick[chord.tick], have.rank <= r { continue }
            byTick[chord.tick] = (r, respell(chord.name, spelling))
        }
        // Escritos pelas formas do violão numa guitarra afinada abaixo (o Yesterday, um tom abaixo: o Songsterr escreve
        // G, F#m, B7, e soa F, Em, A7): todos deslocados do que as notas soam pelo mesmo intervalo. A barra mostra o
        // que soa, com a forma entre os outros nomes.
        var shapes: [Double: String] = [:]
        let shift = shapeShift(byTick.mapValues(\.name), spans: spans)
        if shift != 0 {
            for (tick, entry) in byTick {
                shapes[tick] = entry.name
                byTick[tick] = (entry.rank, transpose(entry.name, by: shift, spelling))
            }
        }
        func root(_ name: String) -> Int? { rootOf(name).map(\.0) }
        let ticks = byTick.keys.sorted()
        var edits: [ChordSpan] = []
        for (index, tick) in ticks.enumerated() {
            let name = byTick[tick]!.name
            let previous = index > 0 ? ticks[index - 1] : -Double.infinity
            let next = index + 1 < ticks.count ? ticks[index + 1] : end
            // O lido que já tem esse acorde um pouco antes (o escrito caiu no 2, o acorde soa desde o 1): o escrito vale
            // desde ali, sem um pedaço do lido com outro nome na frente.
            var from = tick
            if let under = spans.first(where: { $0.from <= tick && tick < $0.to }), under.from > previous,
               root(under.name) == root(name) {
                from = under.from
            }
            let change = spans.first { $0.from > tick + TempoGrid.ticksPerQuarter - 1 }?.from ?? end
            let to = min(next, change)
            guard to > from else { continue }
            edits.append(ChordSpan(from: from, to: to, name: name, source: .written,
                                   alternatives: shapes[tick].map { [$0] } ?? []))
        }
        return overlay(edits, on: spans)
    }

    /// Quanto os escritos estão deslocados do que as notas soam (0 quando batem): o deslocamento que acerta a
    /// fundamental de ao menos 60 % deles e o dobro dos que batem sem deslocar, com ao menos quatro escritos.
    static func shapeShift(_ written: [Double: String], spans: [ChordSpan]) -> Int {
        var pairs: [(Int, Int)] = []
        for (tick, name) in written {
            guard let (mine, _) = rootOf(name),
                  let under = spans.first(where: { $0.from <= tick + 1 && tick + 1 < $0.to }),
                  let heard = chordOf(name: under.name) else { continue }
            pairs.append((mine, heard.root))
        }
        guard pairs.count >= 4 else { return 0 }
        let counts = (0..<12).map { shift in pairs.filter { ($0.0 + shift) % 12 == $0.1 }.count }
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] }), best != 0,
              Double(counts[best]) >= 0.6 * Double(pairs.count), counts[best] >= 2 * counts[0] else { return 0 }
        return best
    }

    /// Um nome deslocado `by` semitons (a fundamental e o baixo), na grafia da música.
    public static func transpose(_ name: String, by shift: Int, _ spelling: [String]) -> String {
        let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
        guard let head = parts.first, let (root, rest) = rootOf(head) else { return name }
        var result = spelling[(root + shift) % 12] + rest
        if parts.count > 1 {
            if let (bass, after) = rootOf(parts[1]), after.isEmpty { result += "/" + spelling[(bass + shift) % 12] } else { result += "/" + parts[1] }
        }
        return result
    }

    /// As correções por cima de tudo.
    public static func apply(_ edits: [ChordEdit], to spans: [ChordSpan]) -> [ChordSpan] {
        overlay(edits.filter { $0.to > $0.from }.map { ChordSpan(from: $0.from, to: $0.to, name: $0.name, source: .edited) },
                on: spans)
    }

    /// Os trechos de `top` no lugar do que estava embaixo (o de baixo cortado nas pontas).
    static func overlay(_ top: [ChordSpan], on spans: [ChordSpan]) -> [ChordSpan] {
        var result = spans
        for piece in top.sorted(by: { $0.from < $1.from }) {
            var next: [ChordSpan] = []
            for span in result {
                if span.to <= piece.from || span.from >= piece.to {
                    next.append(span)
                    continue
                }
                if span.from < piece.from {
                    var left = span
                    left.to = piece.from
                    next.append(left)
                }
                if span.to > piece.to {
                    var right = span
                    right.from = piece.to
                    next.append(right)
                }
            }
            var placed = piece
            // As alternativas do que estava embaixo continuam valendo para o menu (depois das que já vêm, a forma de um
            // escrito).
            do {
                let under = result.filter { $0.from < piece.to && $0.to > piece.from }
                var names = placed.alternatives
                for span in under {
                    for name in [span.name] + span.alternatives where !name.isEmpty && name != piece.name && !names.contains(name) {
                        names.append(name)
                    }
                }
                placed.alternatives = Array(names.prefix(4))
            }
            next.append(placed)
            result = next.sorted { $0.from < $1.from }
        }
        // Dois trechos lidos seguidos com o mesmo nome viram um.
        var merged: [ChordSpan] = []
        for span in result {
            if var last = merged.last, last.name == span.name, last.source == span.source, span.source != .edited,
               abs(last.to - span.from) < 0.5 {
                last.to = span.to
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    // MARK: - Correções

    /// As correções com um trecho novo no lugar do que ele cobre (as de antes cortadas nas pontas).
    public static func editing(_ edits: [ChordEdit], with edit: ChordEdit) -> [ChordEdit] {
        var result: [ChordEdit] = []
        for old in edits {
            if old.to <= edit.from || old.from >= edit.to {
                result.append(old)
                continue
            }
            if old.from < edit.from { result.append(ChordEdit(from: old.from, to: edit.from, name: old.name)) }
            if old.to > edit.to { result.append(ChordEdit(from: edit.to, to: old.to, name: old.name)) }
        }
        if edit.to > edit.from { result.append(edit) }
        return result.sorted { $0.from < $1.from }
    }

    /// As correções sem nada entre `from` e `to` (o trecho volta ao que as notas dizem).
    public static func clearing(_ edits: [ChordEdit], from: Double, to: Double) -> [ChordEdit] {
        var result: [ChordEdit] = []
        for old in edits {
            if old.to <= from || old.from >= to {
                result.append(old)
                continue
            }
            if old.from < from { result.append(ChordEdit(from: old.from, to: from, name: old.name)) }
            if old.to > to { result.append(ChordEdit(from: to, to: old.to, name: old.name)) }
        }
        return result
    }

    /// As notas MIDI de um acorde pelo nome (para ouvir), numa posição perto do Dó central; nil num nome que não lê.
    public static func pitches(of name: String) -> [Int]? {
        let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
        guard let head = parts.first, let (root, rest) = rootOf(head) else { return nil }
        let suffix = rest.replacingOccurrences(of: "min", with: "m").replacingOccurrences(of: "M7", with: "maj7")
        guard let quality = qualities.first(where: { $0.suffix == suffix }) else { return nil }
        var notes = quality.tones.map { 48 + root + $0 }
        if parts.count > 1, let (bass, _) = rootOf(parts[1]) { notes.insert(36 + bass, at: 0) } else { notes.insert(36 + root, at: 0) }
        return notes
    }

    public static func rootOf(_ text: String) -> (Int, String)? {
        let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let first = text.first, let base = letters[first] else { return nil }
        var rest = text.dropFirst()
        var root = base
        while let mark = rest.first, mark == "#" || mark == "b" || mark == "♯" || mark == "♭" {
            root += mark == "#" || mark == "♯" ? 1 : -1
            rest = rest.dropFirst()
        }
        return ((root % 12 + 12) % 12, String(rest))
    }
}
