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
                                        fret: note.fret, vibrato: note.vibrato, bend: pairs, trill: note.trill)
                let shifted = curve(note).shifted(by: -tuning)
                let sound = SoundNote(curve: shifted, start: note.start, end: note.end, pitch: Double(note.pitch),
                                      next: note.next.flatMap { $0.gap < 1 ? $0.pitch : nil }, written: pairs)
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
