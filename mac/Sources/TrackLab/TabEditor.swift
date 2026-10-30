import AppKit
import SwiftUI
import TrackLabCore

/// A edição da TAB (⌘E), como a do TabLab (`EditorKeys`, `ArticulationTabs`): a paleta de articulações embaixo da
/// partitura e as teclas, que valem só com a edição ligada e quando não se está digitando num campo.
///
///     0–9           casa (dois dígitos em 0,6 s: 10–24)      ↑ ↓   outra corda, mesma altura
///     ⌥↑ ⌥↓         meio tom                                  ← →   nota anterior / seguinte
///     ⌫             apaga                                     Esc   tira a escolha (de novo: sai da edição)
///     H ligado   S slide   B bend   V vibrato   M palm mute   X nota morta   N harmônico   G fantasma
///     A acento   R let ring   P palhetada   F encaixa no som (a altura, o bend e o vibrato da curva)
///     Tab ⇧Tab      a nota suspeita seguinte / anterior (o som discorda da escrita; vale também fora da edição)
struct TabEditBar: View {
    let model: SongModel

    struct Item: Identifiable {
        let key: String
        let label: String
        let help: String
        var id: String { key }
    }

    static let groups: [(name: String, items: [Item])] = [
        ("Ligados", [Item(key: "hammer", label: "H/P", help: "Hammer-on ou pull-off até a nota seguinte da corda (H)")]),
        ("Slides", [
            Item(key: "slide-legato", label: "Legato", help: "Slide ligado até a nota seguinte (S)"),
            Item(key: "slide-shift", label: "Shift", help: "Slide atacando a nota seguinte (S de novo)"),
            Item(key: "slide-in-below", label: "↗ Entra", help: "Entra deslizando de baixo"),
            Item(key: "slide-in-above", label: "↘ Entra", help: "Entra deslizando de cima"),
            Item(key: "slide-out-up", label: "Sai ↗", help: "Sai deslizando para cima"),
            Item(key: "slide-out-down", label: "Sai ↘", help: "Sai deslizando para baixo"),
        ]),
        ("Bend", [
            Item(key: "bend-half", label: "½", help: "Bend de meio tom (B)"),
            Item(key: "bend-full", label: "1", help: "Bend de um tom (B de novo)"),
            Item(key: "bend-1.5", label: "1½", help: "Bend de um tom e meio"),
            Item(key: "bend-2", label: "2", help: "Bend de dois tons"),
            Item(key: "bend-release", label: "↑↓", help: "Bend e volta"),
            Item(key: "prebend", label: "Pré", help: "Pré-bend (a corda já sobe antes de tocar)"),
            Item(key: "prebend-release", label: "Pré↓", help: "Pré-bend e volta"),
        ]),
        ("Vibrato", [
            Item(key: "vibrato", label: "∿", help: "Vibrato (V)"),
            Item(key: "wide-vibrato", label: "≋", help: "Vibrato largo (V de novo)"),
        ]),
        ("Mão direita", [
            Item(key: "palm-mute", label: "P.M.", help: "Palm mute (M)"),
            Item(key: "dead", label: "✕", help: "Nota morta (X)"),
            Item(key: "let-ring", label: "Let ring", help: "Deixar soar (R)"),
            Item(key: "pick-down", label: "⊓", help: "Palhetada para baixo (P)"),
            Item(key: "pick-up", label: "V", help: "Palhetada para cima (P de novo)"),
            Item(key: "tap", label: "T", help: "Tapping"),
        ]),
        ("Acentos", [
            Item(key: "accent", label: ">", help: "Acento (A)"),
            Item(key: "heavy-accent", label: "^", help: "Acento forte (A de novo)"),
            Item(key: "staccato", label: "·", help: "Staccato"),
            Item(key: "ghost", label: "( )", help: "Nota fantasma (G)"),
        ]),
        ("Harmônicos", [
            Item(key: "harmonic-natural", label: "N.H.", help: "Harmônico natural (N)"),
            Item(key: "harmonic-artificial", label: "A.H.", help: "Harmônico artificial"),
            Item(key: "harmonic-pinch", label: "P.H.", help: "Harmônico de palheta"),
            Item(key: "harmonic-tap", label: "T.H.", help: "Harmônico de tapping"),
        ]),
    ]

    var body: some View {
        let selection = model.tabSelection
        let on = Set(selection?.techniques ?? [])
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Editar TAB").font(.caption.weight(.semibold))
                Text(selection.map { "Corda \($0.string) · casa \($0.fret) · \($0.pitchName)" }
                     ?? "Clique numa nota da TAB")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 150, alignment: .leading)
                // O que o som fez nela (com o espectro, que mede as curvas).
                if let sound = model.soundSummary {
                    Text(sound)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color(red: 1, green: 138 / 255, blue: 61 / 255))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Self.groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name).font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 3) {
                                ForEach(group.items) { item in
                                    Toggle(item.label, isOn: Binding(get: { on.contains(item.key) },
                                                                     set: { _ in model.toggleTechnique(item.key) }))
                                        .toggleStyle(.button)
                                        .controlSize(.small)
                                        .help(item.help)
                                }
                            }
                        }
                    }
                }
            }
            .disabled(selection == nil)
            Spacer(minLength: 0)
            if let message = model.tabMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 2) {
                Button { model.nextSuspect(-1) } label: { Image(systemName: "chevron.left") }
                    .help("⇧Tab: a nota suspeita anterior")
                Text("\(model.suspects(track: model.scoreTrack).count) suspeitas")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { model.nextSuspect(1) } label: { Image(systemName: "chevron.right") }
                    .help("Tab: a nota suspeita seguinte (o som discorda da escrita: altura, bend, trinado)")
            }
            .fixedSize()
            Button("Encaixar no som") { model.fitToSound() }
                .disabled(selection == nil)
                .help("F: a altura, o bend e o vibrato que o som da nota tem (pela curva do espectro)")
            Button("Concluir") { model.editingTab = false }
        }
    }
}

/// As teclas da edição: um monitor local de teclado, na tela da música (`SongView`), que só age com a edição ligada
/// (e no Tab com o espectro à vista), pega as teclas antes dos atalhos do transporte (setas, letras) e deixa passar o
/// espaço (tocar) e o que tem ⌘ (os menus).
struct TabEditKeys: NSViewRepresentable {
    let model: SongModel

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.model = model
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.model = model
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.stop()
    }

    final class KeyView: NSView {
        weak var model: SongModel?
        private var monitor: Any?
        private var lastDigit: (value: Int, at: TimeInterval)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let model = self.model, event.window === self.window else { return event }
                // Digitando num campo (renomear trecho, busca), as teclas são do campo.
                if self.window?.firstResponder is NSText { return event }
                return MainActor.assumeIsolated { self.handle(event, model) } ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        @MainActor
        private func handle(_ event: NSEvent, _ model: SongModel) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) || flags.contains(.control) { return false }
            // Tab: a suspeita seguinte; com o espectro à vista vale também fora da edição (ela liga a edição).
            if event.keyCode == 48, model.editingTab || model.fitaMode == .spectrum {
                model.nextSuspect(flags.contains(.shift) ? -1 : 1)
                return true
            }
            guard model.editingTab else { return false }
            let option = flags.contains(.option)
            switch event.keyCode {
            case 126: model.tabEdit(option ? "transpose" : "string", 1); return true      // ↑
            case 125: model.tabEdit(option ? "transpose" : "string", -1); return true     // ↓
            case 123: model.tabEdit("nav", -1); return true                               // ←
            case 124: model.tabEdit("nav", 1); return true                                // →
            case 51, 117: model.tabEdit("delete"); return true                            // ⌫, Delete
            case 53:                                                                      // Esc
                if model.tabSelection == nil { model.editingTab = false } else { model.tabEdit("clear") }
                return true
            default: break
            }
            guard let character = event.charactersIgnoringModifiers?.lowercased().first else { return false }
            if let digit = character.wholeNumberValue {
                let now = event.timestamp
                if let last = lastDigit, now - last.at < 0.6, last.value * 10 + digit <= 24 {
                    model.tabEdit("fret", last.value * 10 + digit)
                    lastDigit = nil
                } else {
                    model.tabEdit("fret", digit)
                    lastDigit = (digit, now)
                }
                return true
            }
            switch character {
            case "h": model.toggleTechnique("hammer")
            case "s": model.cycleTechnique(["slide-legato", "slide-shift"])
            case "b": model.cycleTechnique(["bend-half", "bend-full", "bend-1.5", "bend-2", "bend-release"])
            case "v": model.cycleTechnique(["vibrato", "wide-vibrato"])
            case "m": model.toggleTechnique("palm-mute")
            case "x": model.toggleTechnique("dead")
            case "n": model.toggleTechnique("harmonic-natural")
            case "g": model.toggleTechnique("ghost")
            case "a": model.cycleTechnique(["accent", "heavy-accent"])
            case "r": model.toggleTechnique("let-ring")
            case "p": model.cycleTechnique(["pick-down", "pick-up"])
            case "f": model.fitToSound()
            default: return false
            }
            return true
        }
    }
}
