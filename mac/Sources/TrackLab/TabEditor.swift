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
///     H ligado   S slide   B bend (a altura; ⇧B o tipo)   V vibrato   M palm mute   X nota morta   N harmônico
///     G fantasma
///     A acento   R let ring   P palhetada   F encaixa no som (a altura, o bend e o vibrato da curva)
///     Tab ⇧Tab      a nota suspeita seguinte / anterior (o som discorda da escrita; vale também fora da edição)
struct TabEditPanel: View {
    let model: SongModel
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
        /// O símbolo, como na paleta do Guitar Pro (o rótulo fica para a ajuda e a acessibilidade).
        var icon: NotationIcon? = nil
        var id: String { key }
    }

    static let groups: [(name: String, items: [Item])] = [
        ("Ligados e slides", [
            Item(key: "tie", label: "Ligada", help: "Ligada à nota anterior da corda: continua o som dela, sem atacar, e pode ter "
                 + "articulação própria, como o vibrato depois de um bend (L; de novo, solta)", shortcut: "L", icon: .tie),
            Item(key: "hammer", label: "H/P", help: "Hammer-on ou pull-off até a nota seguinte da corda (H)", shortcut: "H",
                 icon: .text("H/P")),
            Item(key: "slide-legato", label: "Legato", help: "Slide ligado até a nota seguinte (S)", shortcut: "S",
                 icon: .slide(.legato)),
            Item(key: "slide-shift", label: "Shift", help: "Slide atacando a nota seguinte (S de novo)", icon: .slide(.shift)),
            Item(key: "slide-in-below", label: "↗ Entra", help: "Entra deslizando de baixo", icon: .slide(.inBelow)),
            Item(key: "slide-in-above", label: "↘ Entra", help: "Entra deslizando de cima", icon: .slide(.inAbove)),
            Item(key: "slide-out-up", label: "Sai ↗", help: "Sai deslizando para cima", icon: .slide(.outUp)),
            Item(key: "slide-out-down", label: "Sai ↘", help: "Sai deslizando para baixo", icon: .slide(.outDown)),
        ]),
        ("Vibrato e mão direita", [
            Item(key: "vibrato", label: "∿", help: "Vibrato (V)", shortcut: "V",
                 icon: .glyph(String(repeating: Bravura.vibrato, count: 3), size: 36, lift: -0.08)),
            Item(key: "wide-vibrato", label: "≋", help: "Vibrato largo (V de novo)",
                 icon: .glyph(String(repeating: Bravura.wideVibrato, count: 2), size: 36, lift: -0.08)),
            Item(key: "palm-mute", label: "P.M.", help: "Palm mute (M)", shortcut: "M", icon: .text("P.M.")),
            Item(key: "dead", label: "✕", help: "Nota morta (X)", shortcut: "X", icon: .glyph(Bravura.deadNote, size: 26, lift: -0.18)),
            Item(key: "let-ring", label: "Ring", help: "Deixar soar, let ring (R)", shortcut: "R",
                 icon: .text("let ring", italic: true)),
            Item(key: "pick-down", label: "⊓", help: "Palhetada para baixo (P)", shortcut: "P",
                 icon: .glyph(Bravura.downBow, size: 28, lift: -0.2)),
            Item(key: "pick-up", label: "V", help: "Palhetada para cima (P de novo)", icon: .glyph(Bravura.upBow, size: 28, lift: -0.2)),
            Item(key: "tap", label: "Tap", help: "Tapping", icon: .text("T")),
        ]),
        ("Acentos e harmônicos", [
            Item(key: "accent", label: ">", help: "Acento (A)", shortcut: "A", icon: .glyph(Bravura.accent, size: 30, lift: -0.15)),
            Item(key: "heavy-accent", label: "^", help: "Acento forte (A de novo)", icon: .glyph(Bravura.marcato, size: 30, lift: -0.2)),
            Item(key: "staccato", label: "·", help: "Staccato", icon: .glyph(Bravura.staccato, size: 34, lift: -0.15)),
            Item(key: "ghost", label: "( )", help: "Nota fantasma (G)", shortcut: "G", icon: .glyph(Bravura.ghost, size: 22, lift: -0.15)),
            Item(key: "harmonic-natural", label: "N.H.", help: "Harmônico natural (N)", shortcut: "N",
                 icon: .glyph(Bravura.diamond, size: 24, lift: -0.15)),
            Item(key: "harmonic-artificial", label: "A.H.", help: "Harmônico artificial", icon: .glyph(Bravura.blackDiamond, size: 24, lift: -0.15)),
            Item(key: "harmonic-pinch", label: "P.H.", help: "Harmônico de palheta", icon: .text("P.H.")),
            Item(key: "harmonic-tap", label: "T.H.", help: "Harmônico de tapping", icon: .text("T.H.")),
        ]),
    ]

    /// A casa mais alta (a mesma da página, `MAX_FRET`).
    static let maxFret = 24

    var body: some View {
        let selection = model.tabSelection
        VStack(spacing: 0) {
            InspectorHead(title: selection.map { $0.count > 1 ? "\($0.count) notas" : "Nota" } ?? (model.tabCaret != nil ? "Nota nova" : "Nota")) {
                Button { model.showKeys = true } label: { Image(systemName: "keyboard") }
                    .buttonStyle(.borderless)
                    .help("As teclas da edição (⌘/)")
                    .accessibilityLabel("Teclas")
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    noteCard(selection)
                    ReadingCards(model: model)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    BendEditor(model: model, selection: selection)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    InspectorGroup("Articulações", summary: techniqueSummary(selection), key: "articulacoes", open: false) {
                        articulations(selection)
                    }
                    InspectorGroup("Duração e tempo", summary: [selection?.figure, SongModel.grids.first { $0.ticks == model.gridTicks }.map { "grade \($0.name)" }]
                        .compactMap { $0 }.joined(separator: " · "), key: "duracao", open: false) {
                        durationSection(selection)
                        Divider()
                        timeSection(selection)
                    }
                    InspectorGroup(model.tabBar.map { "Compasso \($0.index + 1)" } ?? "Compasso",
                                   summary: model.tabBar.map { "\($0.numerator)/\($0.denominator)" }, key: "compasso", open: false) {
                        barSection
                    }
                    InspectorGroup("Suspeitas", summary: "\(model.suspects(track: model.scoreTrack).count)", key: "suspeitas", open: false) {
                        suspectsSection
                    }
                }
                .padding(10)
            }
            Divider()
            footer
        }
        .controlSize(.small)
    }

    // MARK: - Partes

    private func techniqueSummary(_ selection: TabSelection?) -> String {
        let on = Set(selection?.techniques ?? [])
        let names = Self.groups.flatMap(\.items).filter { on.contains($0.key) }.map(\.label)
        return names.isEmpty ? "nenhuma" : names.joined(separator: ", ")
    }

    /// O cartão da nota: a altura, onde está e a figura; a casa (− +), a corda (a mesma altura em cada corda); e o que
    /// o som fez, com o Encaixar. Com o cursor de inserção: a nota nova, a casa e a voz.
    private func noteCard(_ selection: TabSelection?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection, selection.count > 1 {
                // Com várias: de onde a onde, e a principal (a última clicada), cujos valores a coluna mostra.
                Text(selection.span ?? "").font(.callout.weight(.semibold).monospacedDigit()).lineLimit(2)
                Text("Principal: " + [selection.place, selection.pitchName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            } else if selection == nil, let caret = model.tabCaret {
                Text("Nota nova · corda \(caret.string)").font(.callout.weight(.semibold).monospacedDigit())
                Text(caret.place + (caret.inside ? (caret.rest ? " · no meio da pausa" : " · no meio da nota, que se divide")
                                    : (caret.rest ? " · na pausa" : " · no acorde")))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                .onChange(of: model.tabCaret, initial: true) {
                    if let fret = model.tabCaret?.fret { newFret = fret }
                }
                Picker("Voz", selection: Binding(get: { model.tabCaret?.voice ?? 1 }, set: { model.tabEdit("voice", $0) })) {
                    Text("Voz 1").tag(1)
                    Text("Voz 2").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("A voz da nota nova; na voz 2 ela entra no tempo do clique, com as pausas da voz 2 em volta")
            } else if let selection {
                HStack(alignment: .firstTextBaseline) {
                    Text(selection.pitchName).font(.title3.weight(.semibold))
                    Spacer()
                    Text([selection.place, selection.figure, selection.voice > 1 ? "voz \(selection.voice)" : nil].compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text("Casa").font(.caption).foregroundStyle(.secondary)
                    Button { model.tabEdit("transpose", -1) } label: { Image(systemName: "minus") }
                        .disabled(selection.fret <= 0)
                    Text("\(selection.fret)").font(.title3.weight(.semibold).monospacedDigit()).frame(minWidth: 28)
                    Button { model.tabEdit("transpose", 1) } label: { Image(systemName: "plus") }
                        .disabled(selection.fret >= Self.maxFret)
                    Text("corda \(selection.string)").font(.caption).foregroundStyle(.secondary).padding(.leading, 6)
                    Spacer()
                }
                .help("A casa na mesma corda (meio tom por casa); as teclas 0–9 digitam a casa")
                stringButtons(selection)
            } else {
                Text("Clique numa nota da TAB").font(.callout.weight(.medium))
                Text("Numa linha vazia, põe uma nota; ⇧ clique ou ⇧← → escolhem várias; o botão direito tem a edição rápida.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if selection != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let sound = model.soundSummary
                    Text(sound ?? "Sem medida: a Lente à vista mede o som das notas.")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(sound == nil ? Color.secondary : Color(red: 1, green: 138 / 255, blue: 61 / 255))
                        .lineLimit(2)
                        .help(sound ?? "")
                    Spacer(minLength: 4)
                    Button { model.fitToSound() } label: { HStack(spacing: 3) { Text("Encaixar"); KeyHint("F") } }
                        .disabled(sound == nil)
                        .help("F: a altura, o bend e o vibrato que o som da nota tem (pela curva do espectro)")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
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
                        .help(fret.map { "Corda \(string), casa \($0) (↑↓)" } ?? "Corda \(string): a nota não cabe nela")
                }
            }
        }
    }

    /// A figura da nota (com as ligadas): a base, o ponto, a tercina e a pausa. O começo fica; mais curta sobra pausa,
    /// mais longa não passa da nota seguinte.
    private func durationSection(_ selection: TabSelection?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // As seis figuras numa linha, do mesmo tamanho, como na paleta do Guitar Pro.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 6), spacing: 3) {
                ForEach(SongModel.figures, id: \.ticks) { figure in
                    let label = NotationIconView(icon: .glyph(Bravura.figure(figure.ticks), size: 17, lift: -0.42))
                        .frame(maxWidth: .infinity).accessibilityLabel(figure.name)
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
            .disabled(selection == nil)
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { selection?.dotted ?? false }, set: { model.setFigure(dotted: $0) })) {
                    NotationIconView(icon: .glyph(Bravura.quarter + Bravura.dot, size: 17, lift: -0.42)).accessibilityLabel("Pontuada")
                }
                .toggleStyle(.button)
                .help("Ponto: a figura e mais a metade dela (.)")
                Toggle(isOn: Binding(get: { selection?.triplet ?? false }, set: { model.setFigure(triplet: $0) })) {
                    Text("⌐3¬").font(.system(size: 12, weight: .semibold, design: .serif)).accessibilityLabel("Tercina")
                }
                .toggleStyle(.button)
                .help("Tercina: três no tempo de duas (T)")
                Button { model.tabEdit("rest") } label: {
                    NotationIconView(icon: .glyph(Bravura.quarterRest, size: 17, lift: -0.25)).accessibilityLabel("Pausa")
                }
                .help("A batida da nota (o acorde, as ligadas) vira pausa; as outras notas ficam no lugar (⇧⌫)")
                Spacer(minLength: 0)
                Button { model.splitNote() } label: { HStack(spacing: 3) { Text("Dividir"); KeyHint("/") } }
                    .disabled(selection == nil && model.tabCaret == nil)
                    .help("A nota vira duas ligadas com o mesmo som, para a segunda ter articulação dela: no cursor, se ele "
                          + "está dentro da nota, na agulha, se ela está dentro da escolhida, ou no meio; na grade (/)")
            }
            .disabled(selection == nil && model.tabCaret == nil)
        }
    }

    /// Todas as articulações, em três grupos; as ligadas da nota escolhida ficam marcadas.
    private func articulations(_ selection: TabSelection?) -> some View {
        let on = Set(selection?.techniques ?? [])
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.groups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name).font(.caption2).foregroundStyle(.tertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 3)], alignment: .leading, spacing: 3) {
                        ForEach(group.items) { item in
                            Toggle(isOn: Binding(get: { on.contains(item.key) },
                                                 set: { _ in model.toggleTechnique(item.key) })) {
                                Group {
                                    if let icon = item.icon {
                                        NotationIconView(icon: icon).accessibilityLabel(item.label)
                                    } else {
                                        Text(item.label)
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

    /// O tempo das notas: um passo da grade para os lados (as barras de duração e a grade ficam no canto da TAB).
    private func timeSection(_ selection: TabSelection?) -> some View {
        HStack(spacing: 4) {
            Button { model.shiftSelected(-1) } label: { Label("Mais cedo", systemImage: "arrow.left") }
            Button { model.shiftSelected(1) } label: { Label("Mais tarde", systemImage: "arrow.right") }
            Spacer()
            KeyHint("⌥←→")
        }
        .labelStyle(.titleAndIcon)
        .disabled(selection == nil)
        .help("A nota um passo da grade mais cedo ou mais tarde, com a mesma duração (a grade está no canto da TAB)")
    }

    /// O compasso da escolha, em todas as pistas: pôr um antes ou depois, apagá-lo, mudar a fórmula. O mapa de tempo
    /// acompanha (o resto da música fica no mesmo lugar do áudio); os trechos e os compassos conferidos andam junto.
    private var barSection: some View {
        let bar = model.tabBar
        return VStack(alignment: .leading, spacing: 6) {
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

    /// O que o som tem de diferente da TAB, de uma suspeita em uma (Tab, ⇧Tab), com o filtro por tipo e quantas há de
    /// cada um na pista (o mesmo filtro do selo no canto da Lente).
    private var suspectsSection: some View { SuspectFilter(model: model) }

    static let suspectHelp: [SuspectKind: String] = [
        .pitch: "O som da nota está noutra altura (a medida perto da escrita: de 2 semitons abaixo a 4 acima)",
        .bend: "O som dobra diferente do escrito (meio tom ou mais), ou não dobra",
        .trill: "Ligados rápidos que a TAB não tem, ou o trinado escrito que o som não faz",
        .unwritten: "Um ataque forte no espectro, numa altura que nenhuma nota escrita tem ali (Tab põe o cursor nele, com a casa)",
        .silent: "A nota escrita quase não tem altura no som (não soa, ou soa muito fraco)",
        .attack: "O ataque medido a mais de 60 ms do começo escrito (o ritmo da TAB, ou o mapa de tempo ali)",
        .vibrato: "O som tem vibrato e a TAB não escreve (muita TAB omite: vem desligado)",
    ]

    /// O aviso da página (por que a nota não andou) e Concluir: sempre no mesmo lugar.
    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.tabMessage ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(model.tabMessage ?? "")
            Spacer()
            Button("Concluir") { model.editingTab = false }
                .help("Volta a Estudar (⌘E; Esc sem nota escolhida)")
        }
        .padding(10)
    }
}

/// O filtro das suspeitas: a anterior e a seguinte (⇧Tab, Tab) e os tipos ligados, com quantas há de cada um.
struct SuspectFilter: View {
    let model: SongModel

    var body: some View {
        let counts = model.suspectCounts(track: model.scoreTrack)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { model.nextSuspect(-1) } label: { Image(systemName: "chevron.left") }
                    .help("⇧Tab: a suspeita anterior")
                Text("\(model.suspects(track: model.scoreTrack).count) suspeitas")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity)
                Button { model.nextSuspect(1) } label: { Image(systemName: "chevron.right") }
                    .help("Tab: a suspeita seguinte")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 2), spacing: 3) {
                ForEach(SuspectKind.allCases, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { model.suspectKinds.contains(kind) },
                                         set: { on in
                                             if on { model.suspectKinds.insert(kind) } else { model.suspectKinds.remove(kind) }
                                         })) {
                        HStack(spacing: 2) {
                            Text(kind.label)
                            Spacer(minLength: 2)
                            Text("\(counts[kind] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .toggleStyle(.button)
                    .help(TabEditPanel.suspectHelp[kind] ?? "")
                }
            }
        }
    }
}

/// A tecla de um comando, pequena, ao lado dele.
struct KeyHint: View {
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
            // Esc cancela a seleção no espectro (a marcar, ou os cartões dela) antes de qualquer outra coisa.
            if event.keyCode == 53, model.selectingRegion || model.regionReading != nil {
                model.selectingRegion = false
                model.dismissRegion()
                return true
            }
            if event.keyCode == 48, model.editingTab || model.lensVisible {
                model.nextSuspect(flags.contains(.shift) ? -1 : 1)
                return true
            }
            // No modo Gravar: R grava e para; B compara os takes do loop.
            if model.mode == .record, !flags.contains(.option) {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "r": model.toggleRecording(); return true
                case "b": model.alternateTake(); return true
                default: break
                }
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
                // ⌥1–⌥4: a leitura do cartão (ou a posição, com várias notas).
                if option, (1...4).contains(digit) {
                    if let positions = model.selectedPositions() {
                        if positions.indices.contains(digit - 1) { model.choosePosition(positions[digit - 1].id) }
                    } else {
                        model.chooseReading(digit - 1)
                    }
                    return true
                }
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
            case "l": model.toggleTechnique("tie")
            case "s": model.cycleTechnique(["slide-legato", "slide-shift"])
            case "b": flags.contains(.shift) ? model.cycleBendKind() : model.cycleBendHeight()
            case "v": model.cycleTechnique(["vibrato", "wide-vibrato"])
            case "m": model.toggleTechnique("palm-mute")
            case "x": model.toggleTechnique("dead")
            case "n": model.toggleTechnique("harmonic-natural")
            case "g": model.toggleTechnique("ghost")
            case "a": model.cycleTechnique(["accent", "heavy-accent"])
            case "r": model.toggleTechnique("let-ring")
            case "p": model.cycleTechnique(["pick-down", "pick-up"])
            case "f": flags.contains(.shift) ? model.correctBySound() : model.fitToSound()
            case "o": model.listenSelection()
            case "t": model.setFigure(triplet: !(model.tabSelection?.triplet ?? false))
            // O − = e . pelo caractere também (outros teclados, e o que chega sem a tecla física).
            case "-": model.stepFigure(-1)
            case "=", "+": model.stepFigure(1)
            case ".": model.setFigure(dotted: !(model.tabSelection?.dotted ?? false))
            case "d": model.showDurations.toggle()
            case "/": model.splitNote()
            default: return false
            }
            return true
        }
    }
}
