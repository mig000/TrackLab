import AVFoundation
import Foundation

/// A nota sintetizada (o botão direito na TAB, a nota recém-digitada): o SoundFont da TAB sintetizada num
/// AVAudioUnitSampler, num motor de áudio só dele (não mexe no do estudo), com o bend e o vibrato da escrita pelo pitch
/// bend (±12 semitons, para os bends de até dois tons e o tom do estudo).
@MainActor
final class NoteSynth {
    static let shared = NoteSynth()

    enum Failure: LocalizedError {
        case noSoundFont

        var errorDescription: String? {
            "Sem SoundFont para tocar a nota: ponha um .sf2 em ~/TrackLab/Sons."
        }
    }

    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private var loaded: (url: URL, program: Int, percussion: Bool)?
    private var sounding: UInt8?
    private var task: Task<Void, Never>?

    private init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
    }

    /// O SoundFont na ordem do motor (`media/synth.py`, `soundfont`): `TRACKLAB_SOUNDFONT`, o `soundfont` do
    /// config.json da biblioteca ou o primeiro de Sons, na biblioteca de `TRACKLAB_HOME` (a do motor, que herda o
    /// ambiente do app) ou ~/TrackLab; o escolhido que não existe é nenhum, como no motor.
    static func soundFont() -> URL? {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        func expanded(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        let home = environment["TRACKLAB_HOME"].flatMap { $0.isEmpty ? nil : expanded($0) }
            ?? fm.homeDirectoryForCurrentUser.appending(path: "TrackLab")
        var chosen = environment["TRACKLAB_SOUNDFONT"].flatMap { $0.isEmpty ? nil : $0 }
        if chosen == nil, let data = try? Data(contentsOf: home.appending(path: "config.json")),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let path = config["soundfont"] as? String, !path.isEmpty {
            chosen = path
        }
        if let chosen {
            let url = expanded(chosen)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        let folder = home.appending(path: "Sons")
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["sf2", "sf3"].contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// Toca `pitch` (MIDI) por `seconds`, no programa General MIDI `program` (ou na bateria), `transpose` semitons
    /// acima (o tom e os cents do estudo) e com `shape(fração, segundos)` semitons a mais a cada instante (o bend e o
    /// vibrato escritos). Uma nota nova corta a anterior.
    func play(pitch: Int, seconds: Double, program: Int, percussion: Bool, transpose: Double,
              shape: ((Double, Double) -> Double)?) throws {
        guard let url = Self.soundFont() else { throw Failure.noSoundFont }
        if !engine.isRunning { try engine.start() }
        if loaded?.url != url || loaded?.program != program || loaded?.percussion != percussion {
            let bank = percussion ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB
            try sampler.loadSoundBankInstrument(at: url, program: UInt8(clamping: percussion ? 0 : program),
                                                bankMSB: UInt8(bank), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            loaded = (url, program, percussion)
            // A faixa do pitch bend em ±12 semitons (RPN 0).
            sampler.sendController(101, withValue: 0, onChannel: 0)
            sampler.sendController(100, withValue: 0, onChannel: 0)
            sampler.sendController(6, withValue: 12, onChannel: 0)
            sampler.sendController(38, withValue: 0, onChannel: 0)
        }
        task?.cancel()
        if let sounding { sampler.stopNote(sounding, onChannel: 0) }
        // Os semitons inteiros do tom vão na própria nota; os cents, o bend e o vibrato, no pitch bend.
        let whole = Int(transpose.rounded())
        let fine = transpose - Double(whole)
        let note = UInt8(clamping: pitch + (percussion ? 0 : whole))
        bend(percussion ? 0 : fine)
        sampler.startNote(note, withVelocity: 100, onChannel: 0)
        sounding = note
        let start = CACurrentMediaTime()
        let length = max(0.08, seconds)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let elapsed = CACurrentMediaTime() - start
                if elapsed >= length { break }
                if let shape, !percussion { self?.bend(fine + shape(elapsed / length, elapsed)) }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let self, !Task.isCancelled else { return }
            self.sampler.stopNote(note, onChannel: 0)
            self.sounding = nil
        }
    }

    private func bend(_ semitones: Double) {
        let value = 8192 + semitones / 12 * 8191
        sampler.sendPitchBend(UInt16(min(16383, max(0, value.rounded()))), onChannel: 0)
    }
}
