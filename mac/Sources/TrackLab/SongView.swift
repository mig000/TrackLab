import SwiftUI
import TrackLabCore

/// A tela de estudo: a partitura em cima, a Fita, o transporte (play, voltar, loop, velocidade, tom) e o mixer.
struct SongView: View {
    let model: SongModel
    @Local private var span = 10.0

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
            .background(ScrollCatcher(onScroll: scrub))
            // A mesma margem da Fita: as duas têm a mesma largura, a mesma escala e a agulha no mesmo x.
            .padding(.horizontal, 12)
            .frame(minHeight: 180, maxHeight: model.scoreHeight.map { max(180, $0 + 16) } ?? .infinity)
            .onChange(of: span, initial: true) { model.bridge.setSpan(span) }
            Divider()
            if model.adjusting {
                AdjustBar(model: model)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            FitaView(model: model, span: $span)
                .background(ScrollCatcher(onScroll: scrub))
                .frame(minHeight: 120, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            TransportBar(model: model, span: $span)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            MixerBar(model: model)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
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
            if model.scoreTracks.count > 1 {
                Picker("Pista", selection: Binding(get: { model.scoreTrack }, set: { model.scoreTrack = $0 })) {
                    ForEach(model.scoreTracks, id: \.index) { track in
                        Text(track.name).tag(track.index)
                    }
                }
                .frame(maxWidth: 260)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Os trechos de estudo da música, acima da TAB: um clique liga o loop do trecho na velocidade do recorde; o menu
/// renomeia, muda a meta ou apaga. "+ Trecho do loop" guarda o loop de agora; sem trechos, as seções do Guitar Pro.
struct SectionsBar: View {
    let model: SongModel
    @Local private var renaming: StudySection?
    @Local private var newName = ""

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
            Button { model.addSectionFromLoop() } label: { Label("Trecho do loop", systemImage: "plus") }
                .disabled(model.engine.loop == nil)
                .help("Guarda o loop de agora como um trecho de estudo (marque o loop arrastando na Fita ou com L)")
        }
        .buttonStyle(.borderless)
        .alert("Renomear trecho", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Renomear") { if let renaming { model.rename(renaming, to: newName) } }
            Button("Cancelar", role: .cancel) {}
        }
    }

    private func chip(_ section: StudySection) -> some View {
        let active = model.activeSectionID == section.id
        return Button {
            if active { model.deactivateSection() } else { model.activate(section) }
        } label: {
            HStack(spacing: 6) {
                Text(section.name).fontWeight(.semibold)
                Text("\(section.best.map(String.init) ?? "–") → \(section.goal) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(active ? Color.accentColor : Color.clear))
        }
        .help("Clique: loop do trecho a \(section.startRate) %. Menu: renomear, meta, apagar.")
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
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                Text(clock(engine.currentTime, engine.duration))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    // Largura fixa: o loop ao lado não pula quando aparece o compasso.
                    .frame(minWidth: 200, alignment: .leading)
            }
            Divider().frame(height: 18)
            Button { model.toggleBarLoop() } label: {
                Label(engine.loop == nil ? "Loop no compasso" : "Soltar loop", systemImage: "repeat")
            }
            .keyboardShortcut("l", modifiers: [])
            .help("L: repete o compasso que está tocando; arraste na Fita para marcar outro trecho")
            if let loop = engine.loop {
                Text("\(clock(loop.lowerBound)) – \(clock(loop.upperBound))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
            if let section = model.activeSection {
                Divider().frame(height: 18)
                Button { model.markClean() } label: { Label("Limpo!", systemImage: "checkmark.seal") }
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
            }
            Spacer()
            Stepper(value: Binding(get: { Double(engine.rate) }, set: { engine.rate = Float($0) }),
                    in: Double(StemEngine.rates.lowerBound)...Double(StemEngine.rates.upperBound),
                    step: Double(StemEngine.rateStep)) {
                Text("Velocidade \(Int((engine.rate * 100).rounded())) %").monospacedDigit().fixedSize()
            }
            Stepper(value: Binding(get: { engine.semitones }, set: { engine.semitones = $0 }), in: StemEngine.semitones) {
                Text("Tom \(engine.semitones > 0 ? "+" : "")\(engine.semitones)").monospacedDigit().fixedSize()
            }
            Stepper(value: $span, in: FitaView.spans, step: 2) {
                Image(systemName: "waveform").help("Quantos segundos a Fita mostra")
            }
            .labelsHidden()
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

struct MixerBar: View {
    let model: SongModel

    var body: some View {
        let engine = model.engine
        HStack(alignment: .center, spacing: 16) {
            if engine.stemIDs.isEmpty {
                Text("Só o áudio original.").foregroundStyle(.secondary)
                if model.stemJob != nil {
                    StemJobView(model: model)
                } else if model.detail?.audio != nil {
                    Button("Separar as faixas (Demucs 6s)") { Task { await model.separate() } }
                    if model.multitrack != nil {
                        Button("Faixas da multitrack") { Task { await model.improve(.multitrack) } }
                    }
                }
                Spacer()
            } else {
                // Duas linhas: as escolhas em cima e as seis faixas embaixo, repartindo a largura (numa linha só,
                // Teclado e Outros ficavam fora da janela).
                VStack(alignment: .leading, spacing: 8) {
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
                        if model.stemJob != nil {
                            StemJobView(model: model)
                        } else {
                            ImproveMenu(model: model)
                        }
                    }
                    HStack(spacing: 14) {
                        ForEach(Stem.allCases.filter { engine.stemIDs.contains($0.rawValue) }) { stem in
                            StemStrip(model: model, stem: stem)
                        }
                    }
                    .disabled(!engine.useStems)
                }
            }
        }
    }
}

private struct StemStrip: View {
    let model: SongModel
    let stem: Stem

    var body: some View {
        let entry = model.engine.mix[stem.rawValue] ?? StemMix()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(stem.label).font(.caption.weight(.medium))
                Spacer(minLength: 4)
                Toggle("M", isOn: Binding(get: { entry.muted }, set: { _ in model.toggleMute(stem.rawValue) }))
                    .toggleStyle(.button).controlSize(.mini).help("Mudo")
                Toggle("S", isOn: Binding(get: { entry.solo }, set: { _ in model.toggleSolo(stem.rawValue) }))
                    .toggleStyle(.button).controlSize(.mini).help("Solo")
            }
            Slider(value: Binding(get: { Double(entry.volume) }, set: { model.setVolume(stem.rawValue, Float($0)) }), in: 0...1.5)
                .controlSize(.mini)
        }
        .frame(minWidth: 90, maxWidth: 180)
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
