import SwiftUI
import TrackLabCore

/// A tela de estudo: a partitura em cima, a Fita, o transporte (play, voltar, loop, velocidade, tom) e o mixer.
struct SongView: View {
    let model: SongModel
    @Local private var span = 10.0
    @AppStorage("showMixer") private var showMixer = true

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Abrindo a música…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle").multilineTextAlignment(.center)
                Button("Tentar de novo") { Task { await model.load() } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            study
        }
    }

    private var study: some View {
        VStack(spacing: 0) {
            header
            SectionsBar(model: model)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            ZStack {
                ScoreView(bridge: model.bridge)
                if let message = model.scoreMessage {
                    Text(message).foregroundStyle(.secondary).padding().background(.background)
                }
            }
            .background(ScrollCatcher(onScroll: scrub, onMagnify: pinch))
            // A mesma margem da Fita: as duas têm a mesma largura, a mesma escala e a agulha no mesmo x.
            .padding(.horizontal, 12)
            .frame(minHeight: 180, maxHeight: model.scoreHeight.map { max(180, $0 + 16) } ?? .infinity)
            .onChange(of: span, initial: true) { model.bridge.setSpan(span) }
            if model.editingTab {
                Divider()
                TabEditBar(model: model)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            Divider()
            if model.adjusting {
                AdjustBar(model: model)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            FitaView(model: model, span: $span)
                .background(ScrollCatcher(onScroll: scrub, onMagnify: pinch))
                .frame(minHeight: 120, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            TransportBar(model: model, span: $span)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if showMixer {
                Divider()
                MixerBar(model: model)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(TabEditKeys(model: model))
        // ⌥⌘M (Visualizar): esconde o mixer e a Fita (com o espectro) ganha a altura.
        .onReceive(NotificationCenter.default.publisher(for: .toggleMixer)) { _ in showMixer.toggle() }
        // ⌘+ e ⌘− (Visualizar): o mesmo zoom do controle deslizante, um terço da escala por vez.
        .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in span = FitaView.clampSpan(span / 1.33) }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in span = FitaView.clampSpan(span * 1.33) }
    }

    /// A pinça no trackpad, sobre a TAB ou a Fita: abrir aproxima (menos segundos na largura), fechar afasta. As duas
    /// mudam juntas: a Fita na hora e a TAB esticada até o desenho novo chegar.
    private func pinch(_ amount: Double) {
        span = FitaView.clampSpan(span / (1 + amount))
    }

    private func scrub(dx: Double, dy: Double, width: Double) -> Bool {
        model.scrub(dx: dx, dy: dy, width: width, span: span)
        return true
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.detail?.title ?? "").font(.title2.weight(.semibold))
                Text(model.detail?.artist ?? "").foregroundStyle(.secondary)
                let notes = (model.detail?.warnings ?? []) + [model.notice].compactMap { $0 }
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(notes.joined(separator: "\n"))
                }
            }
            Spacer()
            Picker("Estado", selection: Binding(get: { model.status }, set: { model.setStatus($0) })) {
                ForEach(StudyStatus.flow) { status in Text(status.label).tag(status) }
            }
            .labelsHidden()
            .fixedSize()
            .help("O estado de estudo da música: a barra lateral e o Para hoje se organizam por ele")
            Button {
                model.adjusting.toggle()
            } label: {
                Label("Ajustar sincronização", systemImage: "slider.horizontal.below.rectangle")
            }
            .keyboardShortcut("j")
            .help("⌘J: mostra as batidas na Fita para levar cada uma até onde ela soa")
            Toggle(isOn: Binding(get: { model.editingTab }, set: { model.editingTab = $0 })) {
                Label("Editar TAB", systemImage: "pencil.and.list.clipboard")
            }
            .toggleStyle(.button)
            .keyboardShortcut("e")
            .disabled(model.detail?.score == nil)
            .help("⌘E: clique numa nota da TAB e mude casa, corda e articulações (teclas ou a paleta); o Guitar Pro "
                  + "editado fica guardado na música, e o original do Songsterr também")
            if model.scoreTracks.count > 1 {
                Picker("Pista", selection: Binding(get: { model.scoreTrack }, set: { model.scoreTrack = $0 })) {
                    ForEach(model.scoreTracks, id: \.index) { track in
                        Text(track.name).tag(track.index)
                    }
                }
                .frame(maxWidth: 260)
                Picker("Com", selection: Binding(get: { model.scoreSecond }, set: { model.scoreSecond = $0 })) {
                    Text("Nenhuma").tag(Int?.none)
                    ForEach(model.scoreTracks.filter { $0.index != model.scoreTrack }, id: \.index) { track in
                        Text(track.name).tag(Int?.some(track.index))
                    }
                }
                .frame(maxWidth: 220)
                .help("Uma segunda pista embaixo da principal, nos mesmos compassos (a bateria aparece em partitura)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Os trechos de estudo da música, acima da TAB: um clique liga o loop do trecho na velocidade do recorde; o menu
/// renomeia, muda a meta, o tipo, as etiquetas e o favorito, ou apaga. "+ Do loop" guarda o loop de agora como lick,
/// solo, riff…; sem trechos, as seções do Guitar Pro.
struct SectionsBar: View {
    let model: SongModel
    @Local private var renaming: StudySection?
    @Local private var newName = ""
    @Local private var tagging: StudySection?
    @Local private var tagText = ""

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sections, id: \.id) { section in chip(section) }
                }
            }
            if model.sections.isEmpty && !model.markers.isEmpty {
                Button("Trechos das seções da TAB") { model.addSectionsFromMarkers() }
                    .help(model.markers.map(\.name).joined(separator: " · "))
            }
            Menu {
                ForEach(SectionKind.allCases) { kind in
                    Button { model.addSectionFromLoop(kind: kind) } label: { Label(kind.label, systemImage: kind.symbol) }
                }
            } label: {
                Label("Do loop", systemImage: "plus")
            } primaryAction: {
                model.addSectionFromLoop()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.engine.loop == nil)
            .help("Guarda o loop de agora como trecho (clique) ou como lick, solo, riff… (seta); marque o loop "
                  + "arrastando na Fita ou com L")
        }
        .buttonStyle(.borderless)
        .alert("Renomear trecho", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Renomear") { if let renaming { model.rename(renaming, to: newName) } }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Etiquetas", isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            TextField("blues, bend, pentatônica", text: $tagText)
            Button("Guardar") { if let tagging { model.setTags(tagging, tagText) } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            let known = model.knownTags
            Text(known.isEmpty ? "Separadas por vírgula." : "Separadas por vírgula. Já usadas: \(known.joined(separator: ", "))")
        }
    }

    private func chip(_ section: StudySection) -> some View {
        let active = model.activeSectionID == section.id
        return Button {
            if active { model.deactivateSection() } else { model.activate(section) }
        } label: {
            HStack(spacing: 6) {
                if section.kind != .trecho {
                    Image(systemName: section.kind.symbol).font(.caption).foregroundStyle(.secondary)
                }
                Text(section.name).fontWeight(.semibold)
                if section.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                Text("\(section.best.map(String.init) ?? "–") → \(section.goal) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentColor : Color.clear))
        }
        .help("\(section.kind.label)\(section.tags.isEmpty ? "" : " · " + section.tags.joined(separator: ", ")). "
              + "Clique: loop do trecho a \(section.startRate) %. Menu: renomear, meta, tipo, etiquetas, favorito.")
        .contextMenu {
            Button("Renomear…") {
                newName = section.name
                renaming = section
            }
            Menu("Meta") {
                ForEach([80, 90, 100, 110, 120], id: \.self) { goal in
                    Button("\(goal) %\(goal == section.goal ? " ✓" : "")") { model.setGoal(section, goal) }
                }
            }
            Menu("Tipo") {
                ForEach(SectionKind.allCases) { kind in
                    Button("\(kind.label)\(kind == section.kind ? " ✓" : "")") { model.setKind(section, kind) }
                }
            }
            Button("Etiquetas…") {
                tagText = section.tags.joined(separator: ", ")
                tagging = section
            }
            Button(section.favorite ? "Tirar dos favoritos" : "Favorito") { model.toggleFavorite(section) }
            Divider()
            Button("Apagar", role: .destructive) { model.delete(section) }
        }
    }
}

/// A barra do Ajuste, sobre a Fita: o 1 no toque (U), Desfazer e Refazer, quantas âncoras há e o que o motor disse.
struct AdjustBar: View {
    let model: SongModel

    static let guide = "Arraste uma batida na Fita até onde ela soa: ela vira âncora e as vizinhas acompanham. "
        + "⇧ + arraste na TAB: só a onda anda com o mouse, sob as linhas e a TAB paradas; ponha o ataque da nota do "
        + "cursor sob a linha e solte: a batida mais perto do cursor vai para esse som. Duplo clique numa batida prende "
        + "ou solta. Dois dedos ou a roda do mouse andam pela música."

    var body: some View {
        HStack(spacing: 12) {
            Text("Ajuste")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.orange.opacity(0.15)))
                .help(Self.guide)
            Button { model.downbeatHere() } label: { Label("O 1 é aqui", systemImage: "metronome") }
                .keyboardShortcut("u", modifiers: [])
                .help("U: tocando, aperte no tempo forte; o começo de compasso mais perto vem até o toque")
            Button { model.syncBarToSound() } label: { Label("Pelo som", systemImage: "waveform.badge.magnifyingglass") }
                .keyboardShortcut("a", modifiers: [])
                .help("A: o 1 do compasso que toca vai para onde as notas dele soam (os ataques medidos no espectro; "
                      + "a Fita mostra no alto de cada compasso quanto o som vem antes ou depois)")
            Button { model.tap() } label: { Label("Bater junto", systemImage: "hand.tap") }
                .keyboardShortcut("t", modifiers: [])
                .help("T: com a música tocando, aperte em cada batida de um trecho; quando parar, as batidas dele viram os seus toques")
            Button("Metade") { model.halveBeats() }
                .help("Metade das batidas no mapa (o tempo não muda): o arrasto e o Bater junto vão de duas em duas")
            Button("Dobro") { model.doubleBeats() }
                .help("O dobro de batidas no mapa (o tempo não muda): uma no meio de cada uma")
            HStack(spacing: 4) {
                Button("−10 ms") { model.shiftAll(by: -0.01) }
                Button("+10 ms") { model.shiftAll(by: 0.01) }
            }
            .help("Atraso do vídeo: a TAB e a grade inteiras 10 ms antes ou depois do som")
            Button { model.undo() } label: { Label("Desfazer", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("⌘Z")
            Button { model.redo() } label: { Label("Refazer", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("⇧⌘Z")
            // Só o que pede atenção: um aviso do motor ou os toques do Bater junto em curso; o guia fica no "Ajuste".
            if let message = model.adjustMessage {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1).help(message)
            } else if !model.taps.isEmpty {
                Text("\(model.taps.count) toques: continue batendo; ao parar, o trecho é regravado.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.saving { ProgressView().controlSize(.small) }
            Text(model.anchorCount == 1 ? "1 âncora" : "\(model.anchorCount) âncoras")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            let current = model.currentBars
            let done = !current.isEmpty && current.allSatisfy(model.checkedBars.contains)
            Button { model.toggleChecked() } label: {
                Label("Conferido \(model.checkedBars.count)/\(model.barCount)",
                      systemImage: done ? "checkmark.circle.fill" : "checkmark.circle")
                    .monospacedDigit()
            }
            .foregroundStyle(done ? Color.green : Color.primary)
            .help("Marca como conferidos os compassos do loop (ou o que está tocando); de novo, desmarca")
            Button { model.restartFromSongsterr() } label: { Label("Recomeçar", systemImage: "arrow.counterclockwise") }
                .disabled(model.saving)
                .help("Recomeçar do Songsterr: volta ao mapa como veio de lá; o atual fica no histórico da música e no Desfazer")
            Button("Concluir") { model.adjusting = false }
        }
        .buttonStyle(.borderless)
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TransportBar: View {
    let model: SongModel
    @Binding var span: Double
    @AppStorage("showMixer") private var showMixer = true

    var body: some View {
        let engine = model.engine
        HStack(spacing: 14) {
            Button { engine.toStart() } label: { Image(systemName: "backward.end.fill") }
                .help("Voltar ao começo (do loop)")
                .accessibilityLabel("Voltar ao começo")
                .keyboardShortcut(.home, modifiers: [])
            Button { engine.skip(-5) } label: { Image(systemName: "gobackward.5") }
                .help("Voltar 5 segundos")
                .accessibilityLabel("Voltar 5 segundos")
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button { engine.toggle() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
            }
            .accessibilityLabel(engine.isPlaying ? "Pausar" : "Tocar")
            .keyboardShortcut(.space, modifiers: [])
            Button { engine.skip(5) } label: { Image(systemName: "goforward.5") }
                .help("Avançar 5 segundos")
                .accessibilityLabel("Avançar 5 segundos")
                .keyboardShortcut(.rightArrow, modifiers: [])
            // Largura fixa: o loop ao lado não pula quando aparece o compasso.
            ClockLabel { clock(engine.currentTime, engine.duration) }
                .frame(width: 196, height: 20)
            Divider().frame(height: 18)
            // Com um trecho ativo (Limpo!, a sequência e o recorde ao lado), o botão do loop fica só no ícone: tudo cabe
            // numa linha.
            Button { model.toggleBarLoop() } label: {
                if model.activeSection == nil {
                    Label(engine.loop == nil ? "Loop no compasso" : "Soltar loop", systemImage: "repeat")
                } else {
                    Image(systemName: "repeat")
                }
            }
            .fixedSize()
            .keyboardShortcut("l", modifiers: [])
            .help("L: repete o compasso que está tocando; arraste na Fita para marcar outro trecho")
            if let loop = engine.loop {
                Text("\(clock(loop.lowerBound)) – \(clock(loop.upperBound))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
                    .fixedSize()
            }
            if let section = model.activeSection {
                Divider().frame(height: 18)
                Button { model.markClean() } label: { Label("Limpo!", systemImage: "checkmark.seal") }
                    .fixedSize()
                    .keyboardShortcut(.return, modifiers: [])
                    .help("⏎: tocou o trecho sem errar nesta velocidade. Três seguidos sobem 5 %, até a meta.")
                HStack(spacing: 3) {
                    ForEach(0..<SpeedTrainer.streakToRise, id: \.self) { index in
                        Circle().fill(index < model.streak ? Color.green : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Text(model.trainingMessage ?? "recorde \(section.best.map { "\($0) %" } ?? "–") · meta \(section.goal) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.trainingMessage == nil ? Color.secondary : Color.green)
                    .lineLimit(1)
                    .frame(minWidth: 150, alignment: .leading)
                    .layoutPriority(-1)
            }
            Spacer()
            Stepper(value: Binding(get: { Double(engine.rate) }, set: { engine.rate = Float($0) }),
                    in: Double(StemEngine.rates.lowerBound)...Double(StemEngine.rates.upperBound),
                    step: Double(StemEngine.rateStep)) {
                Label("\(Int((engine.rate * 100).rounded())) %", systemImage: "speedometer").monospacedDigit().fixedSize()
                    .help("Velocidade")
            }
            Stepper(value: Binding(get: { engine.semitones }, set: { engine.semitones = $0 }), in: StemEngine.semitones) {
                Text("Tom \(engine.semitones > 0 ? "+" : "")\(engine.semitones)").monospacedDigit().fixedSize()
            }
            Picker("Fita", selection: Binding(get: { model.fitaMode }, set: { model.fitaMode = $0 })) {
                Image(systemName: "waveform").help("Onda: o original e a guitarra separada").tag(SongModel.FitaMode.wave)
                Image(systemName: "chart.bar.xaxis").help("Espectro da guitarra, com as notas da TAB por cima")
                    .tag(SongModel.FitaMode.spectrum)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("A Fita: onda ou espectro com as notas da TAB por cima (âmbar a pista, azul a segunda)")
            if model.fitaMode == .spectrum {
                Toggle(isOn: Binding(get: { model.pitchZoom }, set: { model.pitchZoom = $0 })) {
                    Image(systemName: "arrow.up.and.down.square")
                }
                .toggleStyle(.button)
                .keyboardShortcut("z", modifiers: [])
                .help("Z: amplia a altura em volta da nota que toca (para conferir um bend); Z de novo volta")
            }
            // O zoom: para a direita aproxima. Na escala do logaritmo, para os passos valerem o mesmo de 3 s a 40 s.
            HStack(spacing: 4) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { -log(span) }, set: { span = FitaView.clampSpan(exp(-$0)) }),
                       in: -log(FitaView.spans.upperBound)...(-log(FitaView.spans.lowerBound)))
                    .frame(width: 90)
                    .controlSize(.small)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }
            .help("Zoom da TAB e da Fita juntas (\(Int(span.rounded())) s na largura); pinça no trackpad também")
            // Com o mixer fechado, o que mais se troca tocando fica aqui: o que ouvir e o X.
            if !showMixer {
                CompactMix(model: model)
            }
            // Só o ícone: com o nome, a barra passava da largura de uma janela de 1300 pontos e empurrava a tela.
            Toggle(isOn: $showMixer) { Image(systemName: "slider.vertical.3") }
                .toggleStyle(.button)
                .accessibilityLabel("Mixer")
                .help(showMixer ? "Esconde o mixer: a Fita ganha a altura (⌥⌘M)" : "Mostra o mixer (⌥⌘M)")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private func clock(_ seconds: Double, _ total: Double? = nil) -> String {
        func format(_ value: Double) -> String {
            let whole = Int(max(0, value))
            return String(format: "%d:%02d", whole / 60, whole % 60)
        }
        guard let total else { return format(seconds) }
        let bar = model.grid.bar(at: seconds).map { "  ·  compasso \($0)" } ?? ""
        return "\(format(seconds)) / \(format(total))\(bar)"
    }
}

/// O mixer fechado, no transporte: o original ou um atalho de mixagem das faixas, num menu, e o X (áudio ↔ TAB), que
/// mora na linha TAB do mixer e sem isto sumiria com ele.
private struct CompactMix: View {
    let model: SongModel

    var body: some View {
        let engine = model.engine
        if !engine.stemIDs.isEmpty {
            Picker("Ouvir", selection: Binding(get: { selection }, set: choose)) {
                Text("Original").tag("original")
                Divider()
                ForEach(MixPreset.allCases) { preset in Text(preset.label).tag(preset.rawValue) }
                if engine.useStems, model.preset == nil {
                    Text("Mixagem própria").tag("custom")
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("O que soa: o original ou as faixas separadas (o resto da mixagem fica no mixer)")
        }
        if !engine.synthIDs.isEmpty {
            Button { model.swapAudioAndTab() } label: { Image(systemName: "arrow.left.arrow.right") }
                .keyboardShortcut("x", modifiers: [])
                .help("X: troca o áudio pela TAB sintetizada, ou a TAB pelo áudio")
        }
    }

    private var selection: String {
        guard model.engine.useStems else { return "original" }
        return model.preset?.rawValue ?? "custom"
    }

    private func choose(_ tag: String) {
        if tag == "original" {
            model.engine.useStems = false
        } else if let preset = MixPreset(rawValue: tag) {
            model.engine.useStems = true
            model.apply(preset)
        }
    }
}

struct MixerBar: View {
    let model: SongModel

    var body: some View {
        let engine = model.engine
        VStack(alignment: .leading, spacing: 8) {
            if engine.stemIDs.isEmpty {
                HStack(spacing: 16) {
                    Text("Só o áudio original.").foregroundStyle(.secondary)
                    if model.stemJob != nil, model.stemJob?.request != .synth {
                        StemJobView(model: model)
                    } else if model.detail?.audio != nil {
                        Button("Separar as faixas (Demucs 6s)") { Task { await model.separate() } }
                        if model.multitrack != nil {
                            Button("Faixas da multitrack") { Task { await model.improve(.multitrack) } }
                        }
                    }
                    Spacer()
                }
            } else {
                // As escolhas em cima e as faixas embaixo, repartindo a largura (numa linha só, Teclado e Outros
                // ficavam fora da janela).
                HStack(spacing: 16) {
                    Picker("Ouvir", selection: Binding(get: { engine.useStems }, set: { engine.useStems = $0 })) {
                        Text("Original").tag(false)
                        Text("Faixas").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    Picker("Mix", selection: Binding(get: { model.preset }, set: { if let p = $0 { model.apply(p) } })) {
                        ForEach(MixPreset.allCases) { preset in Text(preset.label).tag(Optional(preset)) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 330)
                    .disabled(!engine.useStems)
                    StemSourcePicker(model: model)
                    Spacer()
                    // A síntese da TAB mostra o progresso na linha dela.
                    if model.stemJob != nil, model.stemJob?.request != .synth {
                        StemJobView(model: model)
                    } else {
                        ImproveMenu(model: model)
                    }
                }
                HStack(spacing: 14) {
                    ForEach(Stem.allCases.filter { engine.stemIDs.contains($0.rawValue) }) { stem in
                        StemStrip(model: model, id: stem.rawValue, label: stem.label)
                    }
                }
                .disabled(!engine.useStems)
            }
            SynthRow(model: model)
        }
    }
}

/// A TAB sintetizada: uma faixa por pista do Guitar Pro, por cima do original ou das faixas, cada uma com volume,
/// mudo e solo. Sem ela (ou com o mapa de tempo mudado depois), o botão de sintetizar.
private struct SynthRow: View {
    let model: SongModel

    var body: some View {
        let synth = model.detail?.synth
        let tracks = synth?.ids.filter { model.engine.synthIDs.contains($0.id) } ?? []
        let engine = model.engine
        HStack(spacing: 14) {
            // As chaves gerais: todo o áudio, toda a TAB, e trocar um pelo outro.
            HStack(spacing: 4) {
                Toggle(isOn: Binding(get: { engine.audioOn }, set: { engine.audioOn = $0 })) {
                    Label("Áudio", systemImage: engine.audioOn ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .help("Liga ou cala todo o áudio (o original ou as faixas), sem mexer na mixagem de cada faixa")
                Toggle(isOn: Binding(get: { engine.tabOn }, set: { engine.tabOn = $0 })) {
                    Label("TAB", systemImage: engine.tabOn ? "pianokeys" : "pianokeys.inverse")
                }
                .disabled(tracks.isEmpty)
                .help(synth.map { "Liga ou cala toda a TAB sintetizada (\($0.soundfont ?? "SoundFont"), no mapa de tempo)" }
                      ?? "A TAB sintetizada ainda não existe")
                Button { model.swapAudioAndTab() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .keyboardShortcut("x", modifiers: [])
                    .disabled(tracks.isEmpty)
                    .help("X: troca o áudio pela TAB, ou a TAB pelo áudio")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .fixedSize()
            ForEach(tracks, id: \.id) { item in
                StemStrip(model: model, id: item.id, label: item.track.shortName)
                    .help(item.track.name ?? "")
                    .opacity(engine.tabOn ? 1 : 0.5)
            }
            if tracks.isEmpty { Spacer() }
            if case .synth = model.stemJob?.request {
                // Com sete pistas na linha, o progresso não pode encolher até sumir.
                StemJobView(model: model)
                    .frame(minWidth: 200)
                    .layoutPriority(1)
            } else if model.detail?.score != nil, model.detail?.tempoMap != nil {
                if let message = model.synthMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(message)
                }
                if synth == nil {
                    Button("Sintetizar a TAB") { Task { await model.synthesize() } }
                        .help("Toca cada pista do Guitar Pro com um SoundFont, no tempo da gravação, para misturar com o "
                              + "áudio (FluidSynth)")
                } else if model.synthOutdated {
                    Button("Atualizar a TAB (o mapa mudou)") { Task { await model.synthesize() } }
                }
            }
        }
    }
}

private struct StemStrip: View {
    let model: SongModel
    let id: String
    let label: String

    var body: some View {
        let entry = model.engine.mix[id] ?? StemMix()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Toggle("M", isOn: Binding(get: { entry.muted }, set: { _ in model.toggleMute(id) }))
                    .toggleStyle(.button).controlSize(.mini).help("Mudo")
                Toggle("S", isOn: Binding(get: { entry.solo }, set: { _ in model.toggleSolo(id) }))
                    .toggleStyle(.button).controlSize(.mini).help("Solo")
            }
            Slider(value: Binding(get: { Double(entry.volume) }, set: { model.setVolume(id, Float($0)) }), in: 0...1.5)
                .controlSize(.mini)
        }
        // Mínimo pequeno: com as seis faixas e as sete pistas da TAB, as linhas do mixer cabem na janela.
        .frame(minWidth: 64, maxWidth: 180)
        .opacity(entry.muted && !entry.solo ? 0.55 : 1)
    }
}

/// A separação que toca (Demucs, multitrack, MVSEP) e o A/B entre a atual e a anterior (ou a recém-chegada).
private struct StemSourcePicker: View {
    let model: SongModel

    var body: some View {
        if let detail = model.detail, detail.stems.count > 1 {
            HStack(spacing: 6) {
                Picker("Faixas", selection: Binding(get: { detail.activeStems ?? "" },
                                                    set: { key in Task { await model.useStems(key) } })) {
                    ForEach(detail.stemKeys, id: \.self) { key in
                        Text(detail.stems[key]?.label ?? key).tag(key)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help(detail.active.map { "\($0.label): \($0.detail)" } ?? "")
                Button {
                    model.toggleAB()
                } label: {
                    Text("A/B")
                }
                .keyboardShortcut("b", modifiers: [])
                .disabled(model.compareKey == nil)
                .help(model.compareKey.flatMap { detail.stems[$0]?.label }.map {
                    "B: troca para \($0) no mesmo ponto, tocando, com a mesma mixagem"
                } ?? "Escolha outra separação para comparar")
            }
        }
    }
}

/// Faixas melhores: a multitrack da biblioteca (quando a música está lá) e a guitarra do MVSEP, com a cota do dia.
private struct ImproveMenu: View {
    let model: SongModel

    var body: some View {
        let detail = model.detail
        let has = { (provider: String, model: String?) in
            detail?.stems.values.contains { $0.provider == provider && (model == nil || $0.model == model) } ?? false
        }
        let left = model.mvsepUsage?.left
        Menu("Melhorar as faixas") {
            if let multitrack = model.multitrack {
                Button("Faixas da multitrack · \(multitrack.formatLabel)") { Task { await model.improve(.multitrack) } }
                    .disabled(has("multitrack", nil) || multitrack.format == "mogg")
            } else {
                Text("Esta música não está na biblioteca de multitracks")
            }
            Divider()
            Button("Seis faixas do MVSEP (BS-RoFormer SW)") { Task { await model.improve(.mvsep(63)) } }
                .disabled(has("mvsep", "mvsep63") || left == 0)
            Button("Guitarra do MVSEP") { Task { await model.improve(.mvsep(31)) } }
                .disabled(has("mvsep", "mvsep31") || left == 0)
            Button("Guitarra solo e base do MVSEP") { Task { await model.improve(.mvsep(101)) } }
                .disabled(has("mvsep", "mvsep101") || left == 0)
            if let usage = model.mvsepUsage {
                Text("MVSEP: \(usage.left) de \(usage.limit) conversões hoje")
            }
            if !has("demucs", nil) {
                Divider()
                Button("Demucs 6s") { Task { await model.improve(.demucs) } }
            }
        }
        .fixedSize()
        .help("A multitrack é a gravação de verdade. No MVSEP (uma conversão do dia cada): as seis faixas do "
              + "BS-RoFormer SW; só a guitarra (o resto pelo Demucs local); ou guitarra solo e base. As faixas novas "
              + "chegam para o A/B, sem trocar as atuais.")
    }
}

/// A separação em curso, com o cancelar.
private struct StemJobView: View {
    let model: SongModel

    var body: some View {
        if let job = model.stemJob {
            HStack(spacing: 8) {
                if let progress = job.progress {
                    ProgressView(value: progress).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("\(job.request.label): \(job.message)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 360, alignment: .leading)
                Button("Cancelar") { model.cancelStemJob() }.controlSize(.small)
            }
        }
    }
}
