import SwiftUI
import TrackLabCore

/// A tela de estudo: a partitura em cima, a Fita, o transporte (play, voltar, loop, velocidade, tom) e o mixer.
struct SongView: View {
    let model: SongModel
    @Local private var span = 10.0
    /// A altura da TAB (0: a da pauta desenhada) e a da Onda quando a Lente está embaixo dela; o divisor de cada uma
    /// arrasta, o duplo clique volta ao automático.
    @AppStorage("tabHeight") private var tabHeight = 0.0
    @AppStorage("waveHeight") private var waveHeight = 150.0
    @Local private var tabMeasured = 0.0

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

    /// Alguma camada embaixo da TAB (sem nenhuma, a TAB fica com a altura toda).
    private var lanes: Bool { model.waveVisible || model.lensVisible }

    private var study: some View {
        VStack(spacing: 0) {
            header
            SongMapView(model: model)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            // O inspetor à direita (o que ele mostra segue o modo): a TAB, a Onda e a Lente perdem largura juntas (a mesma
            // escala e a agulha no mesmo x nas três), sem perder altura.
            HStack(spacing: 0) {
                lanesColumn
                if model.showInspector {
                    Divider()
                    InspectorPanel(model: model)
                }
            }
            Divider()
            StatusLine(model: model)
            Divider()
            TransportBar(model: model, span: $span)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .background(TabEditKeys(model: model))
        .sheet(isPresented: Binding(get: { model.showKeys }, set: { model.showKeys = $0 })) { KeysSheet() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleWave)) { _ in model.waveVisible.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePage)) { _ in model.scorePage.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleLens)) { _ in model.lensVisible.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleChords)) { _ in model.chordsVisible.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleEdit)) { _ in model.mode = model.mode == .edit ? .study : .edit }
        .onReceive(NotificationCenter.default.publisher(for: .toggleAdjust)) { _ in model.mode = model.mode == .adjust ? .study : .adjust }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRecord)) { _ in model.mode = model.mode == .record ? .study : .record }
        .onReceive(NotificationCenter.default.publisher(for: .showKeys)) { _ in model.showKeys.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .syncBySound)) { _ in
            if !model.adjusting { model.adjusting = true }
            model.syncAllToSound()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectRegion)) { _ in model.armRegionSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .correctBySound)) { _ in
            if !model.editingTab { model.editingTab = true }
            model.correctBySound()
        }
        // ⌥⌘I (Visualizar): esconde o inspetor e as camadas ganham a largura.
        .onReceive(NotificationCenter.default.publisher(for: .toggleMixer)) { _ in model.showInspector.toggle() }
        // ⌘+ e ⌘− (Visualizar): o mesmo zoom do controle, um terço da escala por vez.
        .onReceive(NotificationCenter.default.publisher(for: .zoomIn)) { _ in span = FitaView.clampSpan(span / 1.33) }
        .onReceive(NotificationCenter.default.publisher(for: .zoomOut)) { _ in span = FitaView.clampSpan(span * 1.33) }
    }

    /// A TAB e as camadas embaixo dela (a Onda e a Lente), uma sobre a outra; cada uma com os controles dela no canto.
    private var lanesColumn: some View {
        VStack(spacing: 0) {
            ZStack {
                ScoreView(bridge: model.bridge)
                if let message = model.scoreMessage {
                    Text(message).foregroundStyle(.secondary).padding().background(.background)
                }
            }
            .overlay(alignment: .topTrailing) { tabCorner }
            .background(ScrollCatcher(onScroll: scrub, onMagnify: pinch))
            // A mesma margem da Fita: as duas têm a mesma largura, a mesma escala e a agulha no mesmo x.
            .padding(.horizontal, 12)
            // Em páginas, sem altura escolhida, a TAB divide o espaço com as camadas (a música toda não cabe).
            .frame(minHeight: tabHeight > 0 ? min(tabHeight, 160) : 120,
                   maxHeight: tabHeight > 0 ? tabHeight
                       : lanes && !model.scorePage ? model.scoreHeight.map { max(120, $0 + 16) } ?? .infinity : .infinity)
            .background(GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { tabMeasured = proxy.size.height }
            })
            .onChange(of: span, initial: true) {
                model.span = span
                model.bridge.setSpan(span)
            }
            if lanes {
                ResizeHandle(help: "Arraste para mudar a altura da TAB; duplo clique volta à altura da pauta") { delta, start in
                    tabHeight = min(max(80, (start ?? tabMeasured) + delta), 900)
                } begin: { tabMeasured } reset: { tabHeight = 0 }
            }
            // Os acordes da música, na escala da Fita (fora das páginas, que não têm a escala).
            if model.chordsVisible, !model.scorePage, !model.chordSpans.isEmpty {
                ChordLane(model: model, span: span)
                    .background(ScrollCatcher(onScroll: scrub, onMagnify: pinch))
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            }
            // No modo Gravar, os takes de cada pista de guitarra, na escala da Fita.
            if model.mode == .record {
                TakesLane(model: model, span: span)
                    .background(ScrollCatcher(onScroll: scrub, onMagnify: pinch))
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            if !lanes { Divider() }
            // A Onda e a Lente: com as duas, a Onda tem a altura do divisor e a Lente o resto.
            if model.waveVisible {
                FitaView(model: model, span: $span)
                    .background(ScrollCatcher(onScroll: scrub, onMagnify: pinch))
                    // Com a Lente embaixo, a altura do divisor, mas encolhe se a janela não comporta tudo (a soma das
                    // mínimas passava da janela e empurrava o cabeçalho para fora).
                    .frame(minHeight: 60, maxHeight: model.lensVisible ? waveHeight : .infinity)
                    .layoutPriority(model.lensVisible ? 1 : 0)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
            if model.waveVisible, model.lensVisible {
                ResizeHandle(help: "Arraste para dividir a altura entre a Onda e a Lente") { delta, start in
                    waveHeight = min(max(60, (start ?? waveHeight) + delta), 600)
                } begin: { waveHeight } reset: { waveHeight = 150 }
            }
            if model.lensVisible {
                FitaView(model: model, span: $span, lens: true, strip: !model.waveVisible)
                    .background(ScrollCatcher(onScroll: scrub, onMagnify: pinch))
                    .frame(minHeight: 90, maxHeight: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
    }

    /// O canto da TAB: faixa ou página, as outras pistas e, na edição, a grade e as barras de duração.
    private var tabCorner: some View {
        HStack(spacing: 6) {
            Picker("TAB", selection: Binding(get: { model.scorePage }, set: { model.scorePage = $0 })) {
                Text("Faixa").tag(false)
                Text("Página").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("⌥⌘P: a TAB na faixa que corre com a Fita, ou em páginas, de cima para baixo, com o cursor na batida que toca")
            if model.scoreTracks.count > 1 {
                Menu(model.scoreOthers.isEmpty ? "Com: nenhuma" : "Com: \(model.scoreOthers.count) pista\(model.scoreOthers.count == 1 ? "" : "s")") {
                    ForEach(model.scoreTracks.filter { $0.index != model.scoreTrack }, id: \.index) { track in
                        Toggle(track.name, isOn: Binding(get: { model.scoreOthers.contains(track.index) }, set: { on in
                            if on { model.scoreOthers.append(track.index) } else { model.scoreOthers.removeAll { $0 == track.index } }
                        }))
                    }
                    if !model.scoreOthers.isEmpty {
                        Divider()
                        Button("Só a principal") { model.scoreOthers = [] }
                    }
                }
                .fixedSize()
                .help("Outras pistas embaixo da principal, nos mesmos compassos (a bateria aparece em partitura); na "
                      + "Lente, cada uma na sua cor")
            }
            if model.editingTab {
                Picker("Grade", selection: Binding(get: { model.gridTicks }, set: { model.gridTicks = $0 })) {
                    ForEach(SongModel.grids, id: \.ticks) { grid in Text("Grade \(grid.name)").tag(grid.ticks) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Onde as notas podem cair ao mudar de tempo: arrastar o número da nota, as barras de duração, ⌥← ⌥→ e "
                      + "o arrasto lateral na Lente param nesta grade. Com ⌥, 1/32.")
                Toggle(isOn: Binding(get: { model.showDurations }, set: { model.showDurations = $0 })) {
                    HStack(spacing: 3) { Image(systemName: "ruler"); KeyHint("D") }
                }
                .toggleStyle(.button)
                .help("D: uma barra embaixo de cada nota, do tamanho do som; arraste o meio para mover no tempo, as pontas "
                      + "para mudar o começo ou o fim")
            }
        }
        .controlSize(.mini)
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .padding(.top, 6)
        .padding(.trailing, 18)
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

    /// A barra: o título com o estado, o seletor de modo no centro (parado, por mais que os lados mudem) e, à direita,
    /// o que o modo pede.
    private var header: some View {
        ZStack {
            Picker("Modo", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                ForEach(SongModel.StudioMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.detail?.score == nil)
            .help("Estudar: tocar e treinar. Editar (⌘E): a TAB, nota a nota. Ajustar (⌘J): a sincronização, batida a "
                  + "batida. Gravar (⌘R): a guitarra por cima da música, em takes.")
            headerSides
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var headerSides: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.detail?.title ?? "").font(.headline).lineLimit(1)
                HStack(spacing: 8) {
                    Text(model.detail?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Menu {
                        ForEach(StudyStatus.flow) { status in
                            Button { model.setStatus(status) } label: {
                                if status == model.status { Label(status.label, systemImage: "checkmark") } else { Text(status.label) }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle().fill(.orange).frame(width: 6, height: 6)
                            Text(model.status.label).font(.caption.weight(.semibold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("O estado de estudo da música: a barra lateral e o Para hoje se organizam por ele")
                }
            }
            .frame(minWidth: 180, alignment: .leading)
            Spacer()
            HStack(spacing: 6) {
                modeControls
                Toggle(isOn: Binding(get: { model.showInspector }, set: { model.showInspector = $0 })) {
                    Image(systemName: "sidebar.trailing")
                }
                .toggleStyle(.button)
                .help(model.showInspector ? "Esconde o inspetor: as camadas ganham a largura (⌥⌘I)" : "Mostra o inspetor (⌥⌘I)")
                .accessibilityLabel("Inspetor")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lineLimit(1)
        }
    }

    /// O lado direito da barra em cada modo: Estudar tem a pista e a visão; Editar, desfazer, refazer e o corretor;
    /// Ajustar, as ferramentas do mapa e o Conferido.
    @ViewBuilder private var modeControls: some View {
        switch model.mode {
        case .study:
            trackMenu
            viewMenu
        case .edit:
            Button { model.tabEdit("undo") } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndoTab)
                .help("Desfazer a última mudança na TAB (⌘Z)")
                .accessibilityLabel("Desfazer")
            Button { model.tabEdit("redo") } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedoTab)
                .help("Refazer (⇧⌘Z)")
                .accessibilityLabel("Refazer")
            Button { model.correctBySound() } label: { HStack(spacing: 3) { Text("Corrigir pelo som"); KeyHint("⇧F") } }
                .help("⇧F: escreve o que o som faz onde ele discorda da TAB com segurança (a altura, o bend, o vibrato), "
                      + "na pista inteira ou só no loop; ⌘Z desfaz")
            trackMenu
            viewMenu
        case .adjust:
            Button { model.downbeatHere() } label: { HStack(spacing: 3) { Text("O 1 é aqui"); KeyHint("U") } }
                .keyboardShortcut("u", modifiers: [])
                .help("U: tocando, aperte no tempo forte; o começo de compasso mais perto vem até o toque")
            Button { model.tap() } label: { HStack(spacing: 3) { Text("Bater junto"); KeyHint("T") } }
                .keyboardShortcut("t", modifiers: [])
                .help("T: com a música tocando, aperte em cada batida de um trecho; quando parar, as batidas dele viram os seus toques")
            Divider().frame(height: 16)
            Button { model.syncBarToSound() } label: { HStack(spacing: 3) { Text("Pelo som"); KeyHint("A") } }
                .keyboardShortcut("a", modifiers: [])
                .help("A: o 1 do compasso que toca vai para onde as notas dele soam (os ataques medidos no espectro)")
            Button { model.syncAllToSound() } label: { HStack(spacing: 3) { Text("Tudo"); KeyHint("⇧A") } }
                .keyboardShortcut("a", modifiers: [.shift])
                .help("⇧A: a música toda de uma vez: cada compasso vai para onde as notas dele soam, suavizado pelos vizinhos")
            Divider().frame(height: 16)
            Button("Metade") { model.halveBeats() }
                .help("Metade das batidas no mapa (o tempo não muda)")
            Button("Dobro") { model.doubleBeats() }
                .help("O dobro de batidas no mapa (o tempo não muda)")
            Button("−10 ms") { model.shiftAll(by: -0.01) }
                .help("Atraso do vídeo: a TAB e a grade inteiras 10 ms antes do som")
            Button("+10 ms") { model.shiftAll(by: 0.01) }
                .help("A TAB e a grade inteiras 10 ms depois do som")
            Divider().frame(height: 16)
            let current = model.currentBars
            let done = !current.isEmpty && current.allSatisfy(model.checkedBars.contains)
            Button { model.toggleChecked() } label: {
                HStack(spacing: 3) {
                    Image(systemName: done ? "checkmark.circle.fill" : "checkmark.circle")
                    Text("Conferido")
                    KeyHint("C")
                }
            }
            .keyboardShortcut("c", modifiers: [])
            .tint(done ? .green : nil)
            .help("C: marca como conferidos os compassos do loop (ou o que está tocando); de novo, desmarca")
        case .record:
            RecordControls(model: model)
        }
    }

    /// A pista principal e as outras, num menu só.
    private var trackMenu: some View {
        Menu {
            Picker("Principal", selection: Binding(get: { model.scoreTrack }, set: { model.scoreTrack = $0 })) {
                ForEach(model.scoreTracks, id: \.index) { track in Text(track.name).tag(track.index) }
            }
            .pickerStyle(.inline)
        } label: {
            Text("Pista · " + (model.scoreTracks.first { $0.index == model.scoreTrack }?.name ?? "").prefix(28))
        }
        .fixedSize()
        .disabled(model.scoreTracks.count < 2)
        .help("A pista principal da TAB e da Lente (as outras pistas no canto da TAB)")
    }

    /// A visão: as camadas à vista, a TAB em páginas, o inspetor.
    private var viewMenu: some View {
        Menu {
            Toggle("Onda", isOn: Binding(get: { model.waveVisible }, set: { model.waveVisible = $0 }))
                .keyboardShortcut("1", modifiers: [.option, .command])
            Toggle("Lente (o espectro)", isOn: Binding(get: { model.lensVisible }, set: { model.lensVisible = $0 }))
                .keyboardShortcut("2", modifiers: [.option, .command])
            Toggle("Acordes", isOn: Binding(get: { model.chordsVisible }, set: { model.chordsVisible = $0 }))
                .keyboardShortcut("3", modifiers: [.option, .command])
            Divider()
            Toggle("TAB em páginas", isOn: Binding(get: { model.scorePage }, set: { model.scorePage = $0 }))
            Toggle("Inspetor", isOn: Binding(get: { model.showInspector }, set: { model.showInspector = $0 }))
            Divider()
            Button("Teclas…") { model.showKeys = true }
        } label: {
            Image(systemName: "rectangle.3.group")
        }
        .fixedSize()
        .help("O que está à vista: a Onda, a Lente, os acordes, a TAB em páginas, o inspetor; e as teclas (⌘/)")
        .accessibilityLabel("Visão")
    }
}

/// A linha de estado, entre as camadas e o transporte: a última ação ou aviso (e o ⌘Z), e à direita a parte da
/// música que toca, os conferidos e as suspeitas.
struct StatusLine: View {
    let model: SongModel

    var body: some View {
        HStack(spacing: 10) {
            let taps = model.taps.isEmpty ? nil : "\(model.taps.count) toques: continue batendo; ao parar, o trecho é regravado."
            let text = model.statusText ?? taps
            Text(text ?? " ")
                .font(.caption)
                .foregroundStyle(model.adjustMessage != nil || model.notice != nil ? Color.orange : Color.secondary)
                .lineLimit(1)
                .help(text ?? "")
            if text != nil, model.canUndoAny { KeyHint("⌘Z desfaz") }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let part = model.partName(atTick: model.grid.tick(at: model.engine.currentTime))
                let suspects = model.suspects(track: model.scoreTrack).count
                Text([part, "\(model.checkedBars.count) de \(model.barCount) conferidos",
                      suspects > 0 ? "\(suspects) suspeita\(suspects == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if model.saving { ProgressView().controlSize(.mini) }
        }
        .frame(height: 20)
        .padding(.horizontal, 12)
    }
}

/// O transporte: só o que é de tocar. Tocar, o relógio, o loop, o metrônomo, a velocidade, o tom, o que ouvir, o zoom
/// e, com um trecho ativo, o Limpo!.
struct TransportBar: View {
    let model: SongModel
    @Binding var span: Double

    var body: some View {
        let engine = model.engine
        HStack(spacing: 12) {
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
            if model.mode == .record {
                Button { model.toggleRecording() } label: {
                    Image(systemName: model.studio.recording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(.red)
                        .frame(width: 22)
                }
                .accessibilityLabel(model.studio.recording ? "Parar a gravação" : "Gravar")
                .help(model.studio.recording ? "R: para e guarda os takes" : "R: grava na Guitarra \(model.studio.armed)")
            }
            Button { engine.skip(5) } label: { Image(systemName: "goforward.5") }
                .help("Avançar 5 segundos")
                .accessibilityLabel("Avançar 5 segundos")
                .keyboardShortcut(.rightArrow, modifiers: [])
            // Largura fixa: o loop ao lado não pula quando aparece o compasso.
            ClockLabel { clock(engine.currentTime, engine.duration) }
                .frame(width: 196, height: 20)
            Divider().frame(height: 18)
            Button { model.toggleBarLoop() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "repeat")
                    if let loop = engine.loop {
                        Text("\(clock(loop.lowerBound)) – \(clock(loop.upperBound))").font(.caption.monospacedDigit())
                    } else {
                        Text("Loop")
                    }
                    KeyHint("L")
                }
            }
            .fixedSize()
            .foregroundStyle(engine.loop == nil ? Color.primary : Color.orange)
            .keyboardShortcut("l", modifiers: [])
            .help("L: repete o compasso que está tocando (de novo, solta); arraste no mapa ou na Fita para marcar outro trecho")
            Toggle(isOn: Binding(get: { model.metronome }, set: { model.metronome = $0 })) {
                Image(systemName: "metronome")
            }
            .toggleStyle(.button)
            .keyboardShortcut("k", modifiers: [])
            .help("K: metrônomo nas batidas do mapa de tempo (o 1 de cada compasso mais forte); segue o loop e a velocidade")
            .accessibilityLabel("Metrônomo")
            Divider().frame(height: 18)
            Stepper(value: Binding(get: { Double(engine.rate) }, set: { engine.rate = Float($0) }),
                    in: Double(StemEngine.rates.lowerBound)...Double(StemEngine.rates.upperBound),
                    step: Double(StemEngine.rateStep)) {
                Label("\(Int((engine.rate * 100).rounded())) %", systemImage: "speedometer").monospacedDigit().fixedSize()
                    .help("Velocidade")
            }
            TuningButton(model: model)
            CompactMix(model: model, swap: !(model.showInspector && [.study, .record].contains(model.mode)))
            Spacer()
            // O zoom: − + (a pinça no trackpad e ⌘+ ⌘− também), na escala do logaritmo.
            HStack(spacing: 2) {
                Button { span = FitaView.clampSpan(span * 1.33) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Afastar")
                Text("\(Int(span.rounded())) s").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28)
                Button { span = FitaView.clampSpan(span / 1.33) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Aproximar")
            }
            .help("Zoom da TAB e da Fita juntas (\(Int(span.rounded())) s na largura); pinça no trackpad e ⌘+ ⌘− também")
            if model.activeSection != nil {
                Button { model.markClean() } label: { HStack(spacing: 4) { Label("Limpo!", systemImage: "checkmark.seal"); KeyHint("⏎") } }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .fixedSize()
                    .keyboardShortcut(.return, modifiers: [])
                    .help("⏎: tocou o trecho sem errar nesta velocidade. Três seguidos sobem 5 %, até a meta.")
            }
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
        let bar = model.grid.bar(at: seconds).map { "  ·  c. \($0)" } ?? ""
        return "\(format(seconds)) / \(format(total))\(bar)"
    }
}

/// O que ouvir, no transporte: o original ou um atalho de mixagem das faixas, num menu; e o X (áudio ↔ TAB) quando o
/// mixer do inspetor não está à vista (é lá que ele mora).
private struct CompactMix: View {
    let model: SongModel
    let swap: Bool

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
            .help("O que soa: o original ou as faixas separadas (o resto da mixagem fica no inspetor)")
        }
        if swap, !engine.synthIDs.isEmpty {
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

/// O tom da música: os semitons e, no popover, o ajuste fino em cents (−50 a +50) e o Lá 440, que desconta a afinação
/// medida da gravação (com o espectro). O rótulo mostra os dois: "Tom +1 −17 c".
private struct TuningButton: View {
    let model: SongModel
    @Local private var open = false

    var body: some View {
        let engine = model.engine
        Button { open.toggle() } label: {
            Text(label(engine.semitones, engine.cents)).monospacedDigit().fixedSize()
        }
        .help("Tom e ajuste fino (cents)")
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Stepper(value: Binding(get: { engine.semitones }, set: { engine.semitones = $0 }), in: StemEngine.semitones) {
                    Text("Tom: \(signed(engine.semitones)) semiton\(abs(engine.semitones) == 1 ? "" : "s")").monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ajuste fino: \(signed(engine.cents)) cents").monospacedDigit()
                    Slider(value: Binding(get: { Double(engine.cents) }, set: { engine.cents = Int($0.rounded()) }),
                           in: Double(StemEngine.cents.lowerBound)...Double(StemEngine.cents.upperBound), step: 1)
                        .frame(width: 220)
                }
                HStack {
                    let cents = Int((model.tuning * 100).rounded())
                    Button("Lá 440") { model.tuneTo440() }
                        .disabled(cents == 0)
                        .help(cents == 0 ? "A afinação da gravação aparece com o espectro aberto (as notas medidas)"
                              : "A gravação está \(signed(cents)) cents do Lá 440: o ajuste fino desconta")
                    Button("Zerar") {
                        engine.semitones = 0
                        engine.cents = 0
                    }
                }
            }
            .padding(14)
        }
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : value < 0 ? "−\(abs(value))" : "0" }

    private func label(_ semitones: Int, _ cents: Int) -> String {
        "Tom \(signed(semitones))" + (cents != 0 ? " \(signed(cents)) c" : "")
    }
}

/// O divisor entre duas camadas: uma linha que se arrasta para cima ou para baixo (o cursor de redimensionar em cima
/// dela) e volta ao automático com duplo clique. `change` recebe o deslocamento desde o começo do arrasto e o valor que
/// `begin` deu nesse começo.
private struct ResizeHandle: View {
    let help: String
    let change: (_ delta: Double, _ start: Double?) -> Void
    let begin: () -> Double
    let reset: () -> Void
    @Local private var start: Double?

    init(help: String, change: @escaping (_ delta: Double, _ start: Double?) -> Void,
         begin: @escaping () -> Double, reset: @escaping () -> Void) {
        self.help = help
        self.change = change
        self.begin = begin
        self.reset = reset
    }

    var body: some View {
        ZStack {
            Color.clear
            Divider()
            Capsule().fill(.secondary.opacity(0.45)).frame(width: 36, height: 3)
        }
        .frame(height: 9)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if start == nil { start = begin() }
                change(value.translation.height, start)
            }
            .onEnded { _ in start = nil })
        .onTapGesture(count: 2) { reset() }
        .help(help)
    }
}
