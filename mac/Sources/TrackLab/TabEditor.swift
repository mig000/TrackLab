import AppKit
import SwiftUI
import TrackLabCore

/// A edição da TAB (⌘E), como a do TabLab (`EditorKeys`, `ArticulationTabs`): uma coluna à direita das faixas (a TAB,
/// a Onda e a Lente perdem largura, não altura, e seguem alinhadas) com tudo à vista e a tecla de cada comando, e as
/// teclas, que valem só com a edição ligada e quando não se está digitando num campo.
///
///     0–9           casa (dois dígitos em 0,6 s: 10–24)      ↑ ↓   outra corda, mesma altura
///     ⌥↑ ⌥↓         meio tom                                  ← →   nota anterior / seguinte
///     ⌥← ⌥→         a nota um passo da grade mais cedo / mais tarde   D   as barras de duração
///     ⌫             apaga                                     Esc   tira a escolha (de novo: sai da edição)
///     − =           a figura da metade / do dobro             .  T  ponto / tercina          ⇧⌫  vira pausa
///     ⇧← ⇧→         escolhe mais uma nota para trás / para a frente (⇧ clique: até ali; ⌘ clique: põe ou tira)
///     O, ⌥Espaço    ouvir: o trecho escolhido vira o loop e toca (o ⌥Espaço é o atalho global do ChatGPT)
///     H ligado   S slide   B bend   V vibrato   M palm mute   X nota morta   N harmônico   G fantasma
///     A acento   R let ring   P palhetada   F encaixa no som (a altura, o bend e o vibrato da curva)
///     Tab ⇧Tab      a nota suspeita seguinte / anterior (o som discorda da escrita; vale também fora da edição)
struct TabEditPanel: View {
    let model: SongModel
    static let width = 252.0
    /// A casa da nota nova no cursor de inserção (com o mouse: − + e Pôr nota; o teclado digita direto).
    @Local private var newFret = 0
    /// A fórmula escolhida para o compasso (começa na dele).
    @Local private var numerator = 4
    @Local private var denominator = 4

    struct Item: Identifiable {
        let key: String
        let label: String
        let help: String
        /// A tecla, mostrada no botão (a segunda do mesmo grupo é a mesma tecla de novo, sem mostrar).
        var shortcut: String? = nil
        var id: String { key }
    }

    static let groups: [(name: String, items: [Item])] = [
        ("Ligados e slides", [
            Item(key: "hammer", label: "H/P", help: "Hammer-on ou pull-off até a nota seguinte da corda (H)", shortcut: "H"),
            Item(key: "slide-legato", label: "Legato", help: "Slide ligado até a nota seguinte (S)", shortcut: "S"),
            Item(key: "slide-shift", label: "Shift", help: "Slide atacando a nota seguinte (S de novo)"),
            Item(key: "slide-in-below", label: "↗ Entra", help: "Entra deslizando de baixo"),
            Item(key: "slide-in-above", label: "↘ Entra", help: "Entra deslizando de cima"),
            Item(key: "slide-out-up", label: "Sai ↗", help: "Sai deslizando para cima"),
            Item(key: "slide-out-down", label: "Sai ↘", help: "Sai deslizando para baixo"),
        ]),
        ("Bend", [
            Item(key: "bend-half", label: "½", help: "Bend de meio tom (B; de novo, os seguintes)", shortcut: "B"),
            Item(key: "bend-full", label: "1", help: "Bend de um tom (B de novo)"),
            Item(key: "bend-1.5", label: "1½", help: "Bend de um tom e meio"),
            Item(key: "bend-2", label: "2", help: "Bend de dois tons"),
            Item(key: "bend-release", label: "↑↓", help: "Bend e volta"),
            Item(key: "prebend", label: "Pré", help: "Pré-bend (a corda já sobe antes de tocar)"),
            Item(key: "prebend-release", label: "Pré↓", help: "Pré-bend e volta"),
        ]),
        ("Vibrato e mão direita", [
            Item(key: "vibrato", label: "∿", help: "Vibrato (V)", shortcut: "V"),
            Item(key: "wide-vibrato", label: "≋", help: "Vibrato largo (V de novo)"),
            Item(key: "palm-mute", label: "P.M.", help: "Palm mute (M)", shortcut: "M"),
            Item(key: "dead", label: "✕", help: "Nota morta (X)", shortcut: "X"),
            Item(key: "let-ring", label: "Ring", help: "Deixar soar, let ring (R)", shortcut: "R"),
            Item(key: "pick-down", label: "⊓", help: "Palhetada para baixo (P)", shortcut: "P"),
            Item(key: "pick-up", label: "V", help: "Palhetada para cima (P de novo)"),
            Item(key: "tap", label: "Tap", help: "Tapping"),
        ]),
        ("Acentos e harmônicos", [
            Item(key: "accent", label: ">", help: "Acento (A)", shortcut: "A"),
            Item(key: "heavy-accent", label: "^", help: "Acento forte (A de novo)"),
            Item(key: "staccato", label: "·", help: "Staccato"),
            Item(key: "ghost", label: "( )", help: "Nota fantasma (G)", shortcut: "G"),
            Item(key: "harmonic-natural", label: "N.H.", help: "Harmônico natural (N)", shortcut: "N"),
            Item(key: "harmonic-artificial", label: "A.H.", help: "Harmônico artificial"),
            Item(key: "harmonic-pinch", label: "P.H.", help: "Harmônico de palheta"),
            Item(key: "harmonic-tap", label: "T.H.", help: "Harmônico de tapping"),
        ]),
    ]

    /// A casa mais alta (a mesma da página, `MAX_FRET`).
    static let maxFret = 24

    var body: some View {
        let selection = model.tabSelection
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    noteSection(selection)
                    Divider()
                    durationSection(selection)
                    Divider()
                    articulations(selection)
                    Divider()
                    soundSection(selection)
                    Divider()
                    timeSection(selection)
                    Divider()
                    barSection
                    Divider()
                    suspectsSection
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: Self.width)
        .controlSize(.small)
    }

    // MARK: - Partes

    private func title(_ text: String, keys: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let keys { KeyHint(keys) }
        }
    }

    /// A nota: onde está, a figura, a casa, a altura, a corda (a mesma altura em outra corda) e andar de nota em nota.
    private func noteSection(_ selection: TabSelection?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title((selection?.count ?? 1) > 1 ? "\(selection?.count ?? 0) notas escolhidas" : "Nota", keys: "Esc solta")
            VStack(alignment: .leading, spacing: 1) {
                if let selection, selection.count > 1 {
                    // Com várias: de onde a onde, e a principal (a última clicada), cujos valores a coluna mostra.
                    Text(selection.span ?? "")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .lineLimit(2, reservesSpace: true)
                    Text("Principal: " + [selection.place, selection.pitchName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if selection == nil, let caret = model.tabCaret {
                    // O cursor de inserção: a casa digitada põe a nota ali.
                    Text("Nota nova · corda \(caret.string)")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .lineLimit(2, reservesSpace: true)
                    Text(caret.place + (caret.inside ? (caret.rest ? " · no meio da pausa" : " · no meio da nota, que se divide")
                                        : (caret.rest ? " · na pausa" : " · no acorde"))
                         + " — digite a casa (0–9; 10–24 em dois dígitos)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(selection?.place ?? "Clique numa nota da TAB")
                        .font(.callout.weight(.medium).monospacedDigit())
                        .lineLimit(2, reservesSpace: true)
                    Text(selection.map { [$0.pitchName, $0.figure, $0.voice > 1 ? "voz \($0.voice)" : nil].compactMap { $0 }
                        .joined(separator: " · ") }
                         ?? "Clique numa linha vazia para pôr uma nota; ⇧ clique ou ⇧← → escolhem várias; ⌘ clique põe ou tira uma; o botão direito toca sintetizada")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if selection == nil, model.tabCaret != nil {
                // O cursor de inserção, com o mouse: a casa e Pôr nota.
                HStack(spacing: 4) {
                    Text("Casa").font(.caption).foregroundStyle(.secondary)
                    Button { newFret = max(0, newFret - 1) } label: { Image(systemName: "minus") }
                        .disabled(newFret <= 0)
                    Text("\(newFret)").font(.title3.weight(.semibold).monospacedDigit()).frame(minWidth: 28)
                    Button { newFret = min(Self.maxFret, newFret + 1) } label: { Image(systemName: "plus") }
                        .disabled(newFret >= Self.maxFret)
                    Spacer(minLength: 4)
                    Button("Pôr nota") { model.tabEdit("fret", newFret) }
                        .help("Põe a nota nova nessa corda, na casa escolhida (ou digite a casa: 0–9, dois dígitos para 10–24)")
                }
                // Em que voz a nota nova entra: a 2 tem as batidas dela (uma linha de baixo sob uma melodia, por exemplo).
                Picker("Voz", selection: Binding(get: { model.tabCaret?.voice ?? 1 }, set: { model.tabEdit("voice", $0) })) {
                    Text("Voz 1").tag(1)
                    Text("Voz 2").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("A voz da nota nova; na voz 2 ela entra no tempo do clique, com as pausas da voz 2 em volta")
            }
            // Com o cursor de inserção, a casa é a da nota nova (acima); a da nota escolhida some.
            if !(selection == nil && model.tabCaret != nil) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Casa").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        // Uma casa abaixo ou acima na mesma corda é meio tom: com várias notas, vale para todas.
                        Button { model.tabEdit("transpose", -1) } label: { Image(systemName: "minus") }
                            .disabled((selection?.fret ?? 0) <= 0)
                        Text(selection.map { "\($0.fret)" } ?? "–")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .frame(minWidth: 28)
                        Button { model.tabEdit("transpose", 1) } label: { Image(systemName: "plus") }
                            .disabled((selection?.fret ?? Self.maxFret) >= Self.maxFret)
                    }
                    .help("A casa na mesma corda; as teclas 0–9 digitam a casa (dois dígitos em 0,6 s: 10–24)")
                    KeyHint("0–9")
                }
                GridRow {
                    Text("Altura").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Button("−½") { model.tabEdit("transpose", -1) }
                        Text(selection?.pitchName ?? "–").font(.callout.monospacedDigit()).frame(minWidth: 44)
                        Button("+½") { model.tabEdit("transpose", 1) }
                    }
                    .help("Meio tom abaixo ou acima, na mesma corda")
                    KeyHint("⌥↑↓")
                }
            }
            .disabled(selection == nil)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Corda (a mesma altura)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    KeyHint("↑↓")
                }
                stringButtons(selection)
            }
            HStack(spacing: 4) {
                Button { model.tabEdit("nav", -1) } label: { Label("Anterior", systemImage: "chevron.left") }
                    .help("A nota anterior (←)")
                Button { model.tabEdit("nav", 1) } label: { Label("Seguinte", systemImage: "chevron.right") }
                    .help("A nota seguinte (→)")
                Spacer()
                Button { model.listenSelection() } label: { Image(systemName: "ear") }
                    .help("Ouvir: o trecho das notas escolhidas vira o loop e toca (O, ou ⌥Espaço)")
                    .accessibilityLabel("Ouvir")
                Button(role: .destructive) { model.tabEdit("delete") } label: { Image(systemName: "trash") }
                    .help("Apagar a nota, ou as escolhidas (⌫)")
                    .accessibilityLabel("Apagar")
            }
            .labelStyle(.titleAndIcon)
            .disabled(selection == nil && model.tabCaret == nil)
            // Copiar e colar: as batidas inteiras das notas escolhidas; colar a partir da nota ou da linha escolhida,
            // por cima do que estava (também noutra música).
            HStack(spacing: 4) {
                Button { model.copyTab(cut: false) } label: { Label("Copiar", systemImage: "doc.on.doc") }
                    .disabled(selection == nil)
                    .help("⌘C: copia as batidas das notas escolhidas (o acorde inteiro, as articulações)")
                Button { model.copyTab(cut: true) } label: { Label("Recortar", systemImage: "scissors") }
                    .disabled(selection == nil)
                    .help("⌘X: copia e deixa pausa no lugar")
                Button { model.pasteTab() } label: { Label("Colar", systemImage: "doc.on.clipboard") }
                    .disabled(selection == nil && model.tabCaret == nil)
                    .help("⌘V: cola a partir da nota escolhida ou da linha vazia, por cima do que estava")
            }
            .labelStyle(.titleAndIcon)
        }
    }

    /// Uma corda por botão (1, a mais aguda, à esquerda), com a casa em que a mesma altura cai nela; a da nota marcada.
    private func stringButtons(_ selection: TabSelection?) -> some View {
        let frets = selection?.strings ?? []
        let count = frets.isEmpty ? 6 : frets.count
        return HStack(spacing: 3) {
            ForEach(1...count, id: \.self) { string in
                let fret = string <= frets.count ? frets[string - 1] : nil
                let label = VStack(spacing: 0) {
                    Text("\(string)").font(.caption.weight(.semibold))
                    Text(fret.map { "\($0)" } ?? "·").font(.caption2.monospacedDigit())
                }
                .frame(maxWidth: .infinity)
                // A corda da nota fica marcada (e não faz nada); as outras levam a nota para ela, na mesma altura.
                if selection?.string == string {
                    Button {} label: { label }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .help("Corda \(string), casa \(fret ?? 0): a da nota")
                } else {
                    Button {
                        if let selection { model.tabEdit("string", selection.string - string) }
                    } label: { label }
                        .buttonStyle(.bordered)
                        .disabled(selection == nil || fret == nil)
                        .help(fret.map { "Corda \(string), casa \($0)" } ?? "Corda \(string): a nota não cabe nela")
                }
            }
        }
    }

    /// A figura da nota (com as ligadas): a base, o ponto, a tercina e a pausa. O começo fica; mais curta sobra pausa,
    /// mais longa não passa da nota seguinte.
    private func durationSection(_ selection: TabSelection?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Duração", keys: "− =  .  T")
            HStack(spacing: 3) {
                ForEach(SongModel.figures, id: \.ticks) { figure in
                    let label = Text(figure.label).font(.callout.monospacedDigit()).frame(maxWidth: .infinity)
                    if selection?.base == figure.ticks {
                        Button {} label: { label }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .help("A nota é \(figure.name)\(selection?.dotted == true ? " pontuada" : "")"
                                  + "\(selection?.triplet == true ? " em tercina" : "")")
                    } else {
                        Button { model.setFigure(base: figure.ticks) } label: { label }
                            .buttonStyle(.bordered)
                            .help("\(figure.name.prefix(1).uppercased() + figure.name.dropFirst()) (− e = passam à metade e ao dobro)")
                    }
                }
            }
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { selection?.dotted ?? false }, set: { model.setFigure(dotted: $0) })) {
                    HStack(spacing: 3) { Text("Pontuada"); KeyHint(".") }
                }
                .toggleStyle(.button)
                .help("Ponto: a figura e mais a metade dela (.)")
                Toggle(isOn: Binding(get: { selection?.triplet ?? false }, set: { model.setFigure(triplet: $0) })) {
                    HStack(spacing: 3) { Text("Tercina"); KeyHint("T") }
                }
                .toggleStyle(.button)
                .help("Tercina: três no tempo de duas (T)")
                Spacer(minLength: 0)
                Button { model.tabEdit("rest") } label: {
                    HStack(spacing: 3) { Text("Pausa"); KeyHint("⇧⌫") }
                }
                .help("A batida da nota (o acorde, as ligadas) vira pausa; as outras notas ficam no lugar (⇧⌫)")
            }
        }
        .disabled(selection == nil)
    }

    /// Todas as articulações à vista, com a tecla de cada uma; as ligadas da nota escolhida ficam marcadas.
    private func articulations(_ selection: TabSelection?) -> some View {
        let on = Set(selection?.techniques ?? [])
        return VStack(alignment: .leading, spacing: 8) {
            title("Articulações")
            ForEach(Self.groups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name).font(.caption2).foregroundStyle(.tertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 3)], alignment: .leading, spacing: 3) {
                        ForEach(group.items) { item in
                            Toggle(isOn: Binding(get: { on.contains(item.key) },
                                                 set: { _ in model.toggleTechnique(item.key) })) {
                                HStack(spacing: 3) {
                                    Text(item.label)
                                    if let shortcut = item.shortcut {
                                        Text(shortcut).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .toggleStyle(.button)
                            .help(item.help)
                        }
                    }
                }
            }
        }
        .disabled(selection == nil)
    }

    /// O que o som fez na nota (com a Lente, que mede as curvas) e o encaixe.
    private func soundSection(_ selection: TabSelection?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Som", keys: "F")
            let sound = model.soundSummary
            Text(sound ?? (selection == nil ? " " : "Sem medida: a Lente à vista mede o som das notas."))
                .font(.caption.monospacedDigit())
                .foregroundStyle(sound == nil ? Color.secondary : Color(red: 1, green: 138 / 255, blue: 61 / 255))
                .lineLimit(3, reservesSpace: true)
                .help(sound ?? "")
            Button("Encaixar no som") { model.fitToSound() }
                .disabled(selection == nil)
                .help("F: a altura, o bend e o vibrato que o som da nota tem (pela curva do espectro)")
        }
    }

    /// O tempo das notas: as barras de duração embaixo delas (D), a grade e um passo para os lados.
    private func timeSection(_ selection: TabSelection?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Tempo da nota", keys: "D")
            Toggle(isOn: Binding(get: { model.showDurations }, set: { model.showDurations = $0 })) {
                Label("Barras de duração", systemImage: "ruler")
            }
            .toggleStyle(.button)
            .help("D: uma barra embaixo de cada nota, do tamanho do som; arraste o meio para mover no tempo, as pontas "
                  + "para mudar o começo ou o fim (passa da barra de compasso com ligadura). Com ⌥, na grade de 1/32.")
            HStack(spacing: 6) {
                Text("Grade").font(.caption).foregroundStyle(.secondary)
                Picker("Grade", selection: Binding(get: { model.gridTicks }, set: { model.gridTicks = $0 })) {
                    ForEach(SongModel.grids, id: \.ticks) { grid in Text(grid.name).tag(grid.ticks) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Onde as notas podem cair ao mudar de tempo: arrastar o número da nota na TAB, as barras de duração, ⌥← ⌥→ "
                      + "e o arrasto lateral na Lente param nas posições desta grade, contadas do começo do compasso "
                      + "(1/16: a cada semicolcheia; tercina de 1/8: a cada terço de tempo). Com ⌥, 1/32.")
            }
            HStack(spacing: 4) {
                Button { model.shiftSelected(-1) } label: { Label("Mais cedo", systemImage: "arrow.left") }
                Button { model.shiftSelected(1) } label: { Label("Mais tarde", systemImage: "arrow.right") }
                Spacer()
                KeyHint("⌥←→")
            }
            .labelStyle(.titleAndIcon)
            .disabled(selection == nil)
            .help("A nota um passo da grade mais cedo ou mais tarde, com a mesma duração")
        }
    }

    /// O compasso da escolha, em todas as pistas: pôr um antes ou depois, apagá-lo, mudar a fórmula. O mapa de tempo
    /// acompanha (o resto da música fica no mesmo lugar do áudio); os trechos e os compassos conferidos andam junto.
    private var barSection: some View {
        let bar = model.tabBar
        return VStack(alignment: .leading, spacing: 6) {
            title(bar.map { "Compasso \($0.index + 1) · \($0.numerator)/\($0.denominator)" } ?? "Compasso")
            HStack(spacing: 4) {
                Button { model.editBar("insert-before") } label: { Label("Antes", systemImage: "plus") }
                    .help("Põe um compasso vazio antes deste (em todas as pistas, com a mesma fórmula)")
                Button { model.editBar("insert-after") } label: { Label("Depois", systemImage: "plus") }
                    .help("Põe um compasso vazio depois deste")
                Spacer(minLength: 0)
                Button(role: .destructive) { model.editBar("delete") } label: { Label("Apagar", systemImage: "minus") }
                    .help("Apaga este compasso de todas as pistas; o tempo dele fica com o de antes no mapa (⌘Z desfaz)")
            }
            .labelStyle(.titleAndIcon)
            HStack(spacing: 4) {
                Text("Fórmula").font(.caption).foregroundStyle(.secondary)
                Button { numerator = max(1, numerator - 1) } label: { Image(systemName: "minus") }
                Text("\(numerator)").font(.callout.weight(.semibold).monospacedDigit()).frame(minWidth: 18)
                Button { numerator = min(32, numerator + 1) } label: { Image(systemName: "plus") }
                Text("/").foregroundStyle(.secondary)
                Picker("Unidade", selection: $denominator) {
                    ForEach([2, 4, 8, 16], id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                Button("Aplicar") { model.editBar("signature", numerator: numerator, denominator: denominator) }
                    .disabled(bar == nil || (bar?.numerator == numerator && bar?.denominator == denominator))
                    .help("Só este compasso: o que passar do fim novo sai, o que faltar vira pausa")
            }
        }
        .disabled(bar == nil)
        .onChange(of: bar, initial: true) {
            if let bar {
                numerator = bar.numerator
                denominator = bar.denominator
            }
        }
    }

    /// As notas em que o som discorda da escrita (altura, bend, trinado), de uma em uma.
    private var suspectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            title("Suspeitas", keys: "Tab ⇧Tab")
            HStack(spacing: 4) {
                Button { model.nextSuspect(-1) } label: { Image(systemName: "chevron.left") }
                    .help("⇧Tab: a nota suspeita anterior")
                Text("\(model.suspects(track: model.scoreTrack).count) notas")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity)
                Button { model.nextSuspect(1) } label: { Image(systemName: "chevron.right") }
                    .help("Tab: a nota suspeita seguinte (o som discorda da escrita: altura, bend, trinado)")
            }
        }
    }

    /// O aviso da página (por que a nota não andou), desfazer, refazer e concluir: sempre no mesmo lugar.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.tabMessage ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .help(model.tabMessage ?? "")
            HStack(spacing: 4) {
                Button { model.tabEdit("undo") } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!model.canUndoTab)
                    .help("Desfazer a última mudança na TAB (⌘Z)")
                    .accessibilityLabel("Desfazer")
                Button { model.tabEdit("redo") } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!model.canRedoTab)
                    .help("Refazer (⇧⌘Z)")
                    .accessibilityLabel("Refazer")
                Spacer()
                Button("Concluir") { model.editingTab = false }
                    .help("Sai da edição (⌘E; Esc sem nota escolhida)")
            }
        }
        .padding(12)
    }
}

/// A tecla de um comando, pequena, ao lado dele.
private struct KeyHint: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption2.monospaced()).foregroundStyle(.tertiary)
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
            // ⌘C ⌘X ⌘V na edição: as notas da TAB (num campo de texto, o monitor já deixou passar).
            if model.editingTab, flags.intersection([.command, .shift, .option, .control]) == .command {
                switch event.keyCode {
                case 8: model.copyTab(cut: false); return true      // C
                case 7: model.copyTab(cut: true); return true       // X
                case 9: model.pasteTab(); return true                // V
                default: break
                }
            }
            if flags.contains(.command) || flags.contains(.control) { return false }
            // Tab: a suspeita seguinte; com o espectro à vista vale também fora da edição (ela liga a edição).
            if event.keyCode == 48, model.editingTab || model.lensVisible {
                model.nextSuspect(flags.contains(.shift) ? -1 : 1)
                return true
            }
            guard model.editingTab else { return false }
            let option = flags.contains(.option)
            switch event.keyCode {
            case 126: model.tabEdit(option ? "transpose" : "string", 1); return true      // ↑
            case 125: model.tabEdit(option ? "transpose" : "string", -1); return true     // ↓
            case 123, 124:                                                                // ← →, ⌥← ⌥→, ⇧← ⇧→
                let step = event.keyCode == 123 ? -1 : 1
                if option {
                    model.shiftSelected(step)
                } else if flags.contains(.shift) {
                    model.tabEdit("extend", step)
                } else {
                    model.tabEdit("nav", step)
                }
                return true
            case 49 where option:                                                         // ⌥Espaço: ouvir
                model.listenSelection()
                return true
            case 51, 117: model.tabEdit(flags.contains(.shift) ? "rest" : "delete"); return true  // ⌫, ⇧⌫ pausa
            case 27, 78: model.stepFigure(-1); return true                                 // −, − do teclado numérico
            case 24, 69: model.stepFigure(1); return true                                  // = (+), + do numérico
            case 47: model.setFigure(dotted: !(model.tabSelection?.dotted ?? false)); return true  // .
            case 53:                                                                      // Esc
                if model.tabSelection == nil, model.tabCaret == nil {
                    model.editingTab = false
                } else {
                    model.tabEdit((model.tabSelection?.count ?? 1) > 1 ? "single" : "clear")
                }
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
            case "o": model.listenSelection()
            case "t": model.setFigure(triplet: !(model.tabSelection?.triplet ?? false))
            // O − = e . pelo caractere também (outros teclados, e o que chega sem a tecla física).
            case "-": model.stepFigure(-1)
            case "=", "+": model.stepFigure(1)
            case ".": model.setFigure(dotted: !(model.tabSelection?.dotted ?? false))
            case "d": model.showDurations.toggle()
            default: return false
            }
            return true
        }
    }
}
