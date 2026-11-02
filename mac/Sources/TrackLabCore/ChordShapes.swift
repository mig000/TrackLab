import Foundation

/// Uma digitação de acorde no violão em afinação padrão: a casa de cada corda, da mais grave (Mi) à mais aguda (−1
/// abafada, 0 solta), os dedos (0 sem dedo) e as pestanas, em casas do braço.
public struct ChordShape: Hashable, Sendable {
    public var frets: [Int]
    public var fingers: [Int]
    public var barres: [Int]
    /// Tirada da TAB (o que o guitarrista toca ali), e não da base de digitações.
    public var fromTab: Bool
    /// O acorde que a digitação é de fato, quando a base não tem o pedido (o "C7" de um "C7/G", o "Cm" de um
    /// "Cmadd11"): o cartão diz o que desenha e toca. nil quando é o pedido.
    public var drawn: String?

    public init(frets: [Int], fingers: [Int] = [], barres: [Int] = [], fromTab: Bool = false) {
        self.frets = frets
        self.fingers = fingers.count == frets.count ? fingers : Array(repeating: 0, count: frets.count)
        self.barres = barres
        self.fromTab = fromTab
    }

    /// A primeira casa do desenho (quatro casas por vez): 1 quando tudo cabe no começo do braço.
    public var baseFret: Int {
        let pressed = frets.filter { $0 > 0 }
        guard let low = pressed.min(), let high = pressed.max() else { return 1 }
        return high <= 4 ? 1 : low
    }

    /// Onde a mão está: a média das casas apertadas (0 só com cordas soltas).
    public var position: Double {
        let pressed = frets.filter { $0 > 0 }
        return pressed.isEmpty ? 0 : Double(pressed.reduce(0, +)) / Double(pressed.count)
    }
}

/// As digitações do chords-db (tombatossals, MIT; `mac/Resources/chords-db`), procuradas pelos nomes da barra de
/// acordes.
public struct ChordLibrary: Sendable {
    let table: [String: [ChordShape]]

    struct Database: Decodable {
        struct Entry: Decodable {
            let key: String
            let suffix: String
            let positions: [Position]
        }
        struct Position: Decodable {
            let frets: [Int]
            let fingers: [Int]?
            let baseFret: Int
            let barres: [Int]?
        }
        let chords: [String: [Entry]]
    }

    public init(json: Data) throws {
        let database = try JSONDecoder().decode(Database.self, from: json)
        var table: [String: [ChordShape]] = [:]
        for entries in database.chords.values {
            for entry in entries {
                guard let (root, _) = ChordReader.rootOf(entry.key) else { continue }
                // As casas da base são contadas a partir da primeira do desenho.
                let shapes = entry.positions.map { position in
                    ChordShape(frets: position.frets.map { $0 > 0 ? $0 + position.baseFret - 1 : $0 },
                               fingers: position.fingers ?? [],
                               barres: (position.barres ?? []).map { $0 + position.baseFret - 1 })
                }
                table["\(root)|\(entry.suffix)"] = shapes
            }
        }
        self.table = table
    }

    /// As digitações de um nome da barra ("C", "Am7", "Bb/D", "C(add9)", "F#m7b5"), as mais simples primeiro; vazio num
    /// nome que a base não tem.
    public func shapes(for name: String) -> [ChordShape] {
        let plain = name.replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
            .replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        let parts = plain.split(separator: "/", maxSplits: 1).map(String.init)
        guard let head = parts.first, let (root, rest) = ChordReader.rootOf(head) else { return [] }
        let suffix = Self.suffix(rest)
        // Com baixo: a inversão que a base tem ("C/G", "Am/G"), que só existe para as tríades maior e menor (um "C7/G"
        // ou "Csus4/G" pegava o C/G maior, sem a sétima ou com a terça no lugar da quarta); senão o acorde sem o baixo.
        if parts.count > 1, suffix == "major" || suffix == "minor", let (bass, _) = ChordReader.rootOf(parts[1]) {
            let minor = suffix == "minor"
            let name = ChordReader.flats[bass].replacingOccurrences(of: "Gb", with: "F#")
            for candidate in [(minor ? "m/" : "/") + name, (minor ? "m/" : "/") + ChordReader.sharps[bass]] {
                if let found = table["\(root)|\(candidate)"], !found.isEmpty { return found }
            }
        }
        let rootName = String(head.dropLast(rest.count))
        for (index, candidate) in [suffix, Self.simpler(suffix)].enumerated() {
            guard let found = table["\(root)|\(candidate)"], !found.isEmpty else { continue }
            guard index > 0 || parts.count > 1 else { return found }
            let drawn = rootName + Self.display(candidate)
            return found.map { shape in
                var shape = shape
                shape.drawn = drawn
                return shape
            }
        }
        return []
    }

    /// O sufixo do chords-db como a barra o escreve ("major" → "", "minor" → "m").
    static func display(_ suffix: String) -> String {
        switch suffix {
        case "major": ""
        case "minor": "m"
        default: suffix
        }
    }

    /// O sufixo da barra no nome do chords-db.
    static func suffix(_ rest: String) -> String {
        switch rest {
        case "", "maj", "M": return "major"
        case "m", "min", "-": return "minor"
        case "m7", "min7", "-7": return "m7"
        case "maj7", "M7": return "maj7"
        case "mmaj7", "mMaj7", "minmaj7": return "mmaj7"
        case "+", "aug": return "aug"
        case "°", "dim": return "dim"
        case "ø", "m7b5": return "m7b5"
        default: return rest
        }
    }

    /// O mais perto que a base costuma ter, para um nome que ela não tem ("Cmadd11" → "minor", "C7sus2" → "7").
    static func simpler(_ suffix: String) -> String {
        if suffix.hasPrefix("m") && !suffix.hasPrefix("maj") { return suffix.contains("7") ? "m7" : "minor" }
        if suffix.hasPrefix("maj") { return "maj7" }
        if suffix.hasPrefix("sus") { return "sus4" }
        if suffix.hasPrefix("7") || suffix.hasPrefix("9") || suffix.hasPrefix("13") || suffix.hasPrefix("11") { return "7" }
        return "major"
    }

    /// As digitações para mostrar: a que a TAB toca (se toca uma) primeiro, e as da base pela distância até onde a mão
    /// está na TAB (sem TAB, como a base as ordena: as do começo do braço primeiro).
    public func shapes(for name: String, played: ChordShape?, hand: Double?) -> [ChordShape] {
        var result = shapes(for: name)
        if let hand, hand > 0 {
            result.sort { abs($0.position - hand) < abs($1.position - hand) }
        }
        if let played {
            result.removeAll { $0.frets == played.frets }
            result.insert(played, at: 0)
        }
        return result
    }
}

extension ChordShape {
    /// A digitação que a TAB toca no trecho: a batida com mais cordas de uma vez (ao menos três) numa guitarra de seis
    /// cordas; as cordas que ela não toca ficam abafadas. `notes` são as da pista, com a corda como a página manda (1 é
    /// a mais aguda).
    public static func played(_ notes: [ScoreNote], from: Double, to: Double, strings: Int = 6) -> ChordShape? {
        var beats: [Double: [ScoreNote]] = [:]
        for note in notes where note.tick >= from - 0.5 && note.tick < to - 0.5 && note.string >= 1 && note.string <= strings {
            beats[note.tick, default: []].append(note)
        }
        let full = beats.values.filter { Set($0.map(\.string)).count >= 3 }
        guard let best = full.max(by: { a, b in
            Set(a.map(\.string)).count == Set(b.map(\.string)).count ? a[0].tick > b[0].tick
                : Set(a.map(\.string)).count < Set(b.map(\.string)).count
        }) else { return nil }
        var frets = [Int](repeating: -1, count: strings)
        for note in best { frets[strings - note.string] = note.fret }
        return ChordShape(frets: frets, fromTab: true)
    }

    /// Onde a mão está nas notas do trecho (a média das casas apertadas), para escolher entre as digitações da base.
    public static func hand(_ notes: [ScoreNote], from: Double, to: Double) -> Double? {
        let pressed = notes.filter { $0.tick >= from - 0.5 && $0.tick < to - 0.5 && $0.fret > 0 }.map(\.fret)
        return pressed.isEmpty ? nil : Double(pressed.reduce(0, +)) / Double(pressed.count)
    }
}
