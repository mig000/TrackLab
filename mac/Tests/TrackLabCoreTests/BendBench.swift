import Foundation
import Testing
@testable import TrackLabCore

/// A medição da detecção de bend sobre as curvas das músicas (`node web/tools/bend-curves.cjs <motor> <arquivo>`
/// extrai do motor as curvas das notas das guitarras do repertório): só roda com `TRACKLAB_BEND_BENCH` apontando o
/// arquivo (`TRACKLAB_BEND_BENCH=… ./test.sh --filter medicaoDosBends`); escreve o resumo e cada nota com bend (escrito
/// ou ouvido) em `<arquivo>.txt`, com "!" nas suspeitas.
@Test func medicaoDosBends() throws {
    guard let path = ProcessInfo.processInfo.environment["TRACKLAB_BEND_BENCH"] else { return }
    struct Curve: Decodable { let from: Double; let hop: Double; let values: [Double?]; let attack: Double? }
    struct Next: Decodable { let pitch: Int; let gap: Double }
    struct Note: Decodable {
        let tick: Double, duration: Double, pitch: Int, string: Int, fret: Int, vibrato: Int, trill: Int?
        let bend: [Double], start: Double, end: Double, others: [Int], next: Next?, curve: Curve
        let approached: Bool?, slidesOut: Bool?
    }
    struct Track: Decodable { let index: Int; let name: String; let notes: [Note] }
    struct Song: Decodable { let name: String; let tracks: [Track] }
    struct File: Decodable { let songs: [Song] }
    let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var lines: [String] = []
    var table: [String: Int] = [:]
    func count(_ key: String) { table[key, default: 0] += 1 }
    func label(_ form: BendForm?) -> String {
        guard let form else { return "sem" }
        let heights = [form.kind.usesPre ? "pré \(BendForm.name(form.pre))" : nil, form.kind.usesTop ? BendForm.name(form.top) : nil,
                       form.kind.usesEnd ? "→\(BendForm.name(form.end))" : nil].compactMap { $0 }
        return "\(form.kind.rawValue) " + heights.joined(separator: " ")
    }
    for song in file.songs {
        for track in song.tracks {
            func curve(_ note: Note) -> PitchCurve {
                PitchCurve(from: note.curve.from, hop: note.curve.hop, values: note.curve.values, attack: note.curve.attack)
            }
            let samples = track.notes.map { note in
                RecordingTuning.Sample(curve: curve(note), start: note.start, end: note.end, pitch: note.pitch,
                                       plain: note.bend.isEmpty && note.others.isEmpty)
            }
            let tuning = RecordingTuning.estimate(samples) ?? 0
            lines.append("== \(song.name) · \(track.name) · afinação \(Int((tuning * 100).rounded())) cents")
            for note in track.notes where note.others.isEmpty {
                let pairs = stride(from: 0, to: note.bend.count - 1, by: 2).map {
                    ScoreNote.BendPoint(offset: note.bend[$0], value: note.bend[$0 + 1])
                }
                let written = ScoreNote(tick: note.tick, duration: note.duration, pitch: note.pitch, string: note.string,
                                        fret: note.fret, vibrato: note.vibrato, bend: pairs, trill: note.trill,
                                        approached: note.approached ?? false, slidesOut: note.slidesOut ?? false)
                let shifted = curve(note).shifted(by: -tuning)
                let sound = SoundNote(curve: shifted, start: note.start, end: note.end, pitch: Double(note.pitch),
                                      next: note.next.flatMap { $0.gap < 1 ? $0.pitch : nil }, written: pairs,
                                      approached: note.approached ?? false, slidesOut: note.slidesOut ?? false)
                guard let fit = sound.fit, fit.trill == nil else { continue }
                let wrote = BendForm(points: pairs.map { [$0.offset, $0.value] })
                let heard = fit.form
                let checks = sound.disagreements(with: written).map { check -> String in
                    let name = "\(check)"
                    return name.hasPrefix("pitch") ? "altura" : String(name.prefix { $0 != "(" })
                }
                count("notas")
                if wrote != nil {
                    count("escrito com bend")
                    if heard?.kind == wrote?.kind { count("escrito: o som tem o mesmo tipo") }
                    if label(heard) == label(wrote) { count("escrito: mesmo tipo e alturas") }
                    if heard == nil { count("escrito: o som não dobra") }
                    if checks.contains("altura") { count("escrito: suspeita de altura") }
                } else if let heard {
                    count("não escrito: o som dobra")
                    if (heard.kind.usesTop ? heard.top : heard.pre) >= 2, fit.certain {
                        count("não escrito: o som dobra ½ tom ou mais, confirmado")
                    }
                }
                for check in Set(checks) { count("suspeita: \(check)") }
                if !checks.isEmpty { count("suspeitas (notas)") }
                if wrote != nil || heard != nil {
                    lines.append("\(checks.isEmpty ? " " : "!") c.\(Int(note.tick / 3840) + 1) \(String(format: "%.2f", note.start))s"
                                 + " corda \(note.string) casa \(note.fret) · escrito: \(label(wrote))"
                                 + " · som: \(label(heard))\(fit.certain ? "" : " (sem confirmar)") base \(fit.base - note.pitch)"
                                 + (checks.isEmpty ? "" : " · \(checks.joined(separator: ","))"))
                }
            }
        }
    }
    let summary = table.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    try (summary + [""] + lines).joined(separator: "\n").write(toFile: path + ".txt", atomically: true, encoding: .utf8)
    print(summary.joined(separator: "\n"))
}

/// A medição do corretor (`SoundNote.correction`) sobre um arquivo da medição de bend: o que ele mudaria em cada nota
/// fora de acorde (altura, bend, vibrato, trinado) e, nas notas que trazem `original` (a TAB do Songsterr de antes da
/// edição do Miguel, que o `web/tools/bend-curves.cjs` grava), se ele faz no original as correções que o Miguel fez e
/// quantas faz que o Miguel não fez. Só roda com `TRACKLAB_CORRECTOR_BENCH`; escreve `<arquivo>.corretor.txt`.
@Test func medicaoDoCorretor() throws {
    guard let path = ProcessInfo.processInfo.environment["TRACKLAB_CORRECTOR_BENCH"] else { return }
    struct Curve: Decodable { let from: Double; let hop: Double; let values: [Double?]; let attack: Double? }
    struct Next: Decodable { let pitch: Int; let gap: Double }
    struct Original: Decodable { let pitch: Int; let vibrato: Int; let trill: Int?; let bend: [Double] }
    struct Note: Decodable {
        let tick: Double, duration: Double, pitch: Int, string: Int, fret: Int, vibrato: Int, trill: Int?
        let bend: [Double], start: Double, end: Double, others: [Int], next: Next?, curve: Curve
        let approached: Bool?, slidesOut: Bool?, original: Original?
    }
    struct Track: Decodable { let index: Int; let name: String; let notes: [Note] }
    struct Song: Decodable { let name: String; let tracks: [Track] }
    struct File: Decodable { let songs: [Song] }
    let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var lines: [String] = []
    var table: [String: Int] = [:]
    func count(_ key: String) { table[key, default: 0] += 1 }
    func points(_ raw: [Double]) -> [ScoreNote.BendPoint] {
        stride(from: 0, to: raw.count - 1, by: 2).map { ScoreNote.BendPoint(offset: raw[$0], value: raw[$0 + 1]) }
    }
    // O mesmo para o músico: a altura, o vibrato, o trinado e o bend pelo tipo e alturas (o tempo não conta).
    func same(_ a: NoteReading, _ b: NoteReading) -> Bool {
        a.pitch == b.pitch && a.vibrato == b.vibrato && a.trill == b.trill
            && (a.bend.isEmpty && b.bend.isEmpty || a.form.map { $0.kind.rawValue + $0.spoken } == b.form.map { $0.kind.rawValue + $0.spoken }
                && a.form != nil)
    }
    for song in file.songs {
        for track in song.tracks {
            func curve(_ note: Note) -> PitchCurve {
                PitchCurve(from: note.curve.from, hop: note.curve.hop, values: note.curve.values, attack: note.curve.attack)
            }
            let tuning = RecordingTuning.estimate(track.notes.map { note in
                RecordingTuning.Sample(curve: curve(note), start: note.start, end: note.end, pitch: note.pitch,
                                       plain: note.bend.isEmpty && note.others.isEmpty)
            }) ?? 0
            lines.append("== \(song.name) · \(track.name)")
            for note in track.notes where note.others.isEmpty {
                // A nota como estava antes da edição (se o arquivo traz), senão como está.
                let source = note.original
                let written = ScoreNote(tick: note.tick, duration: note.duration, pitch: source?.pitch ?? note.pitch,
                                        string: note.string, fret: note.fret, vibrato: source?.vibrato ?? note.vibrato,
                                        bend: points(source?.bend ?? note.bend), trill: source?.trill ?? note.trill,
                                        approached: note.approached ?? false, slidesOut: note.slidesOut ?? false)
                let sound = SoundNote(curve: curve(note).shifted(by: -tuning), start: note.start, end: note.end,
                                      pitch: Double(written.pitch), next: note.next.flatMap { $0.gap < 1 ? $0.pitch : nil },
                                      written: written.bend, approached: written.approached, slidesOut: written.slidesOut)
                count("notas")
                let before = NoteReading(note: written)
                let fixed = sound.correction(for: written, start: note.start, end: note.end)
                if let fixed {
                    count("corrigidas")
                    if fixed.pitch != before.pitch { count("corrigidas: altura") }
                    if fixed.bend != before.bend { count("corrigidas: bend") }
                    if fixed.vibrato != before.vibrato { count(fixed.vibrato ? "corrigidas: vibrato posto" : "corrigidas: vibrato tirado") }
                    if fixed.trill != before.trill { count("corrigidas: trinado") }
                }
                var verdict = ""
                if source != nil {
                    let edited = NoteReading(pitch: note.pitch, bend: note.bend.chunked(), vibrato: note.vibrato > 0,
                                             trill: note.trill, kind: .written, name: "")
                    let miguel = !same(before, edited)
                    switch (miguel, fixed) {
                    case (true, let fixed?) where same(fixed, edited): count("Miguel mudou: o corretor fez igual"); verdict = "igual ao Miguel"
                    case (true, _?): count("Miguel mudou: o corretor mudou diferente"); verdict = "diferente do Miguel"
                    case (true, nil): count("Miguel mudou: o corretor não mudou"); verdict = "Miguel mudou, o corretor não"
                    case (false, _?): count("Miguel não mudou: o corretor mudou"); verdict = "o Miguel não mudou"
                    case (false, nil): count("Miguel não mudou: o corretor também não")
                    }
                }
                if fixed != nil || verdict.contains("Miguel mudou") {
                    let change = fixed.map { $0.changes(from: before).joined(separator: ", ") } ?? "nada"
                    let closeness = fixed.flatMap { sound.closeness($0, start: note.start, end: note.end) }
                    let was = sound.closeness(before, start: note.start, end: note.end)
                    lines.append(String(format: "c.%d %.2fs corda %d casa %d · muda: %@ · perto do som %@ → %@%@",
                                        Int(note.tick / 3840) + 1, note.start, note.string, note.fret, change,
                                        was.map { "\(Int(($0 * 100).rounded()))%" } ?? "?",
                                        closeness.map { "\(Int(($0 * 100).rounded()))%" } ?? "?",
                                        verdict.isEmpty ? "" : " · \(verdict)"))
                }
            }
        }
    }
    let summary = table.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    try (summary + [""] + lines).joined(separator: "\n").write(toFile: path + ".corretor.txt", atomically: true, encoding: .utf8)
}

private extension Array where Element == Double {
    /// [deslocamento, valor, deslocamento, valor…] em pares.
    func chunked() -> [[Double]] { stride(from: 0, to: count - 1, by: 2).map { [self[$0], self[$0 + 1]] } }
}
