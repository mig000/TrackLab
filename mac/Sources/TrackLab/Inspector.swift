import SwiftUI
import TrackLabCore

/// O inspetor, à direita das camadas (⌥⌘I): o que ele mostra segue o modo. Em Estudar, o trecho ativo (recorde, meta,
/// Limpo!), o mixer (o que ouvir, cada faixa, a TAB sintetizada) e as faixas (a separação, o A/B, melhorar); em
/// Editar, a nota (`TabEditPanel`); em Ajustar, a sincronização (os conferidos, os compassos fora pelo som, as versões).
/// O mixer de baixo da tela saiu daqui para cá: a Lente ganhou a altura dele.
struct InspectorPanel: View {
    let model: SongModel
    static let width = 300.0

    var body: some View {
        VStack(spacing: 0) {
            switch model.mode {
            case .study: StudyInspector(model: model)
            case .edit: TabEditPanel(model: model)
            case .adjust: SyncInspector(model: model)
            case .record: RecordInspector(model: model)
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// A cabeça do inspetor: o nome do que ele mostra e, à direita, o que couber.
struct InspectorHead<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.callout.weight(.semibold))
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Um grupo do inspetor que abre e fecha (a escolha fica guardada por `key`); fechado, só o título e um resumo.
struct InspectorGroup<Content: View>: View {
    let title: String
    var summary: String? = nil
    let key: String
    var open = true
    @ViewBuilder var content: Content
    @AppStorage private var expanded: Bool

    init(_ title: String, summary: String? = nil, key: String, open: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.summary = summary
        self.key = key
        self.open = open
        self.content = content()
        _expanded = AppStorage(wrappedValue: open, "group." + key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    if let summary, !expanded || !summary.isEmpty {
                        Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { content }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }
}

// MARK: - Estudar

struct StudyInspector: View {
    let model: SongModel

    var body: some View {
        InspectorHead(title: "Estudo") {
            if model.saving { ProgressView().controlSize(.small) }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TrechoGroup(model: model)
                ChordsGroup(model: model)
                GuitarGroup(model: model)
                MixerGroup(model: model)
                FaixasGroup(model: model)
            }
            .padding(10)
        }
        .controlSize(.small)
    }
}

/// O trecho ativo: o recorde, a meta, a sequência de limpos e o Limpo!; sem trecho, como marcar um.
private struct TrechoGroup: View {
    let model: SongModel

    var body: some View {
        let section = model.activeSection
        InspectorGroup("Trecho", summary: section.map { "\($0.name) · \($0.startRate) %" } ?? "nenhum", key: "trecho") {
            if let section {
                HStack(spacing: 6) {
                    if section.kind != .trecho { Image(systemName: section.kind.symbol).foregroundStyle(.secondary) }
                    Text(section.name).font(.callout.weight(.semibold))
                    if section.favorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    Spacer()
                    Text("c. \(model.grid.bar(at: model.grid.seconds(at: section.from)) ?? 0)–\(model.grid.bar(at: max(model.grid.seconds(at: section.from), model.grid.seconds(at: section.to) - 0.01)) ?? 0)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                HStack {
                    Text("recorde ").foregroundStyle(.secondary) + Text(section.best.map { "\($0) %" } ?? "–").fontWeight(.semibold)
                        + Text(" → meta ").foregroundStyle(.secondary) + Text("\(section.goal) %").fontWeight(.semibold)
                    Spacer()
                    HStack(spacing: 3) {
                        ForEach(0..<SpeedTrainer.streakToRise, id: \.self) { index in
                            Circle().fill(index < model.streak ? Color.green : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                        }
                    }
                    .help("Três limpos seguidos sobem 5 %")
                }
                .font(.caption.monospacedDigit())
                ProgressView(value: Double(min(section.best ?? 0, section.goal)), total: Double(max(section.goal, 1)))
                    .tint(.orange)
                Button { model.markClean() } label: {
                    HStack(spacing: 4) { Text("Limpo!"); KeyHint("⏎") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.regular)
                .help("⏎: tocou o trecho sem errar nesta velocidade. Três seguidos sobem 5 %, até a meta.")
                Text(model.trainingMessage ?? "Velocidade \(Int((model.engine.rate * 100).rounded())) %"
                     + (section.practiced.map { " · tocado \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(model.trainingMessage == nil ? Color.secondary : Color.green).lineLimit(2)
                Button("Soltar o trecho") { model.deactivateSection() }
            } else {
                Text("Clique numa chave do mapa, ou marque um loop (arraste na Fita, ou L) e guarde com “+ Trecho do loop”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// O mixer: o original ou as faixas, os atalhos de mixagem, cada faixa (volume, mudo, solo) e a TAB sintetizada.
struct MixerGroup: View {
    let model: SongModel
    @AppStorage("group.tabTracks") private var tabTracks = false

    var body: some View {
        let engine = model.engine
        InspectorGroup("Mixer", summary: engine.stemIDs.isEmpty ? "só o original" : engine.useStems ? (model.preset?.label ?? "mixagem própria") : "original",
                       key: "mixer") {
            if engine.stemIDs.isEmpty {
                Text("Só o áudio original.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Picker("Ouvir", selection: Binding(get: { engine.useStems }, set: { engine.useStems = $0 })) {
                        Text("Original").tag(false)
                        Text("Faixas").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Toggle(isOn: Binding(get: { engine.audioOn }, set: { engine.audioOn = $0 })) {
                        Image(systemName: engine.audioOn ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                    .toggleStyle(.button)
                    .help("Liga ou cala todo o áudio (o original ou as faixas), sem mexer na mixagem de cada faixa")
                }
                HStack(spacing: 4) {
                    ForEach(MixPreset.allCases) { preset in
                        Toggle(isOn: Binding(get: { model.preset == preset && engine.useStems }, set: { _ in
                            engine.useStems = true
                            model.apply(preset)
                        })) { Text(preset.label) }
                            .toggleStyle(.button)
                    }
                }
                .disabled(!engine.useStems)
                VStack(spacing: 6) {
                    ForEach(Stem.allCases.filter { engine.stemIDs.contains($0.rawValue) }) { stem in
                        StemStrip(model: model, id: stem.rawValue, label: stem.label)
                    }
                }
                .disabled(!engine.useStems)
                .opacity(engine.audioOn ? 1 : 0.5)
            }
            Divider()
            SynthRows(model: model, showTracks: $tabTracks)
            if !model.studio.takes.isEmpty {
                Divider()
                TakeRows(model: model)
            }
        }
    }
}

/// A TAB sintetizada: a chave geral, o X e, se quiser, uma faixa por pista; sem ela (ou desatualizada), o botão.
private struct SynthRows: View {
    let model: SongModel
    @Binding var showTracks: Bool

    var body: some View {
        let synth = model.detail?.synth
        let tracks = synth?.ids.filter { model.engine.synthIDs.contains($0.id) } ?? []
        let engine = model.engine
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { engine.tabOn }, set: { engine.tabOn = $0 })) {
                Label("TAB sintetizada", systemImage: engine.tabOn ? "pianokeys" : "pianokeys.inverse")
            }
            .toggleStyle(.button)
            .disabled(tracks.isEmpty)
            .help(synth.map { "Liga ou cala toda a TAB sintetizada (\($0.soundfont ?? "SoundFont"), no mapa de tempo)" }
                  ?? "A TAB sintetizada ainda não existe")
            Button { model.swapAudioAndTab() } label: { Image(systemName: "arrow.left.arrow.right") }
                .keyboardShortcut("x", modifiers: [])
                .disabled(tracks.isEmpty)
                .help("X: troca o áudio pela TAB, ou a TAB pelo áudio")
            Spacer()
            if !tracks.isEmpty {
                Button { showTracks.toggle() } label: {
                    Label("\(tracks.count) pistas", systemImage: showTracks ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }
        }
        if showTracks {
            VStack(spacing: 6) {
                ForEach(tracks, id: \.id) { item in
                    StemStrip(model: model, id: item.id, label: item.track.shortName)
                        .help(item.track.name ?? "")
                }
            }
            .opacity(engine.tabOn ? 1 : 0.5)
        }
        if case .synth = model.stemJob?.request {
            StemJobView(model: model)
        } else if model.detail?.score != nil, model.detail?.tempoMap != nil {
            if let message = model.synthMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(message)
            }
            if synth == nil {
                Button("Sintetizar a TAB") { Task { await model.synthesize() } }
                    .help("Toca cada pista do Guitar Pro com um SoundFont, no tempo da gravação, para misturar com o áudio")
            } else if model.synthOutdated {
                Button("Atualizar a TAB sintetizada") { Task { await model.synthesize() } }
                    .help("A partitura, o mapa de tempo ou o sintetizador do TrackLab mudou depois dela")
            }
        }
    }
}

/// As faixas: a separação que toca, o A/B com a outra e as melhores (a multitrack, o MVSEP com a cota do dia).
private struct FaixasGroup: View {
    let model: SongModel

    var body: some View {
        let detail = model.detail
        InspectorGroup("Faixas", summary: detail?.active?.label ?? "nenhuma", key: "faixas") {
            if model.stemJob != nil, model.stemJob?.request != .synth {
                StemJobView(model: model)
            } else if detail != nil, detail?.audio == nil {
                Text("Esta música entrou sem áudio: o vídeo do Songsterr não sincroniza todos os compassos.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = model.audioJob {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Button("Buscar o áudio de novo") { Task { await model.fetchAudio() } }
                        .help("Os poucos compassos do fim que o Songsterr não sincroniza seguem o andamento do anterior")
                }
            } else if (detail?.stems.isEmpty ?? true) {
                Text("Só o áudio original.").font(.caption).foregroundStyle(.secondary)
                if detail?.audio != nil {
                    HStack(spacing: 4) {
                        Button("Separar (Demucs 6s)") { Task { await model.separate() } }
                        if model.multitrack != nil {
                            Button("Faixas da multitrack") { Task { await model.improve(.multitrack) } }
                        }
                    }
                }
            } else {
                StemSourcePicker(model: model)
                HStack(spacing: 6) {
                    ImproveMenu(model: model)
                    Spacer()
                    if let usage = model.mvsepUsage {
                        Text("MVSEP \(usage.left) de \(usage.limit) hoje").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct StemStrip: View {
    let model: SongModel
    let id: String
    let label: String

    var body: some View {
        let entry = model.engine.mix[id] ?? StemMix()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int((entry.volume * 100).rounded())) %").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Toggle("M", isOn: Binding(get: { entry.muted }, set: { _ in model.toggleMute(id) }))
                    .toggleStyle(.button).controlSize(.mini).help("Mudo")
                Toggle("S", isOn: Binding(get: { entry.solo }, set: { _ in model.toggleSolo(id) }))
                    .toggleStyle(.button).controlSize(.mini).help("Solo")
            }
            Slider(value: Binding(get: { Double(entry.volume) }, set: { model.setVolume(id, Float($0)) }), in: 0...1.5)
                .controlSize(.mini)
        }
        .opacity(entry.muted && !entry.solo ? 0.55 : 1)
    }
}

/// A separação que toca (Demucs, multitrack, MVSEP) e o A/B entre a atual e a anterior (ou a recém-chegada).
struct StemSourcePicker: View {
    let model: SongModel

    var body: some View {
        if let detail = model.detail, !detail.stems.isEmpty {
            HStack(spacing: 6) {
                Picker("Faixas", selection: Binding(get: { detail.activeStems ?? "" },
                                                    set: { key in Task { await model.useStems(key) } })) {
                    ForEach(detail.stemKeys, id: \.self) { key in
                        Text(detail.stems[key]?.label ?? key).tag(key)
                    }
                }
                .labelsHidden()
                .disabled(detail.stems.count < 2)
                .help(detail.active.map { "\($0.label): \($0.detail)" } ?? "")
                Button { model.toggleAB() } label: { Text("A/B") }
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
struct ImproveMenu: View {
    let model: SongModel

    var body: some View {
        let detail = model.detail
        let has = { (provider: String, model: String?) in
            detail?.stems.values.contains { $0.provider == provider && (model == nil || $0.model == model) } ?? false
        }
        let left = model.mvsepUsage?.left
        Menu("Melhorar") {
            if let multitrack = model.multitrack {
                // Um .mogg tem os canais reconhecidos pelas faixas do Demucs: precisa delas antes.
                let demucs = detail?.stems.keys.contains { $0.hasPrefix("demucs") } ?? false
                Button("Faixas da multitrack · \(multitrack.formatLabel)") { Task { await model.improve(.multitrack) } }
                    .disabled(has("multitrack", nil) || (multitrack.format == "mogg" && !demucs))
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
struct StemJobView: View {
    let model: SongModel

    var body: some View {
        if let job = model.stemJob {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let progress = job.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Button("Cancelar") { model.cancelStemJob() }.controlSize(.small)
                }
                Text("\(job.request.label): \(job.message)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

// MARK: - Ajustar

/// A sincronização: os compassos conferidos, os que o som diz estarem fora, as versões do mapa.
struct SyncInspector: View {
    let model: SongModel

    var body: some View {
        InspectorHead(title: "Sincronização") {
            if model.saving { ProgressView().controlSize(.small) }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                InspectorGroup("Conferidos", summary: "\(model.checkedBars.count) de \(model.barCount)", key: "conferidos") {
                    ProgressView(value: Double(model.checkedBars.count), total: Double(max(1, model.barCount))).tint(.green)
                    let first = (1...max(1, model.barCount)).first { !model.checkedBars.contains($0) }
                    Text(first.map { "Falta conferir do c. \($0) em diante." } ?? "Tudo conferido.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { model.toggleChecked() } label: {
                        HStack(spacing: 4) { Text("Conferido: o loop ou o compasso que toca"); KeyHint("C") }.frame(maxWidth: .infinity)
                    }
                }
                bySound
                InspectorGroup("Versões do mapa", summary: "\(model.anchorCount) âncoras", key: "versoes") {
                    HStack(spacing: 4) {
                        Button { model.undo() } label: { Label("Desfazer", systemImage: "arrow.uturn.backward") }
                            .disabled(!model.canUndo)
                        Button { model.redo() } label: { Label("Refazer", systemImage: "arrow.uturn.forward") }
                            .disabled(!model.canRedo)
                    }
                    Text("Cada mudança vai para o histórico do pacote (as últimas 200 versões).")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { model.restartFromSongsterr() } label: { Label("Recomeçar do Songsterr", systemImage: "arrow.counterclockwise") }
                        .disabled(model.saving)
                        .help("Volta ao mapa como veio do Songsterr; o atual fica no histórico e no Desfazer")
                }
                Text(AdjustGuide.text).font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .controlSize(.small)
    }

    /// Onde as notas soam antes ou depois do mapa (a mediana dos ataques por compasso), de 25 ms para cima.
    private var bySound: some View {
        let offsets = model.lensVisible ? model.barOffsets().filter { abs($0.value) >= 0.025 }.sorted { $0.key < $1.key } : []
        return InspectorGroup("Pelo som", summary: model.lensVisible ? "\(offsets.count) compassos fora" : "abra a Lente", key: "pelosom") {
            if !model.lensVisible {
                Text("A Lente mede quando as notas soam: mostre-a (⌥⌘2).").font(.caption).foregroundStyle(.secondary)
            } else if model.measuring {
                Text("Medindo o som das notas…").font(.caption).foregroundStyle(.secondary)
            } else if offsets.isEmpty {
                Text("O som cai nas batidas (a menos de 25 ms).").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(offsets.prefix(12), id: \.key) { index, offset in
                    HStack {
                        Text("c. \(index + 1)").font(.caption.monospacedDigit())
                        Text("\(offset > 0 ? "+" : "−")\(Int((abs(offset) * 1000).rounded())) ms")
                            .font(.caption.monospacedDigit()).foregroundStyle(Color(red: 0.2, green: 0.5, blue: 0.9))
                        Spacer()
                        Button("Ir") { if let range = model.barRange(index + 1) { model.engine.seek(to: range.lowerBound) } }
                            .buttonStyle(.borderless)
                    }
                }
                if offsets.count > 12 { Text("… e mais \(offsets.count - 12)").font(.caption).foregroundStyle(.secondary) }
            }
            Button { model.syncAllToSound() } label: {
                HStack(spacing: 4) { Text("Tudo pelo som"); KeyHint("⇧A") }.frame(maxWidth: .infinity)
            }
            .help("A música toda de uma vez: cada compasso vai para onde as notas dele soam, suavizado pelos vizinhos; as âncoras ficam")
        }
    }
}

enum AdjustGuide {
    static let text = "Arraste uma batida na Fita até onde ela soa: ela vira âncora e as vizinhas acompanham. ⇧ + arraste na "
        + "TAB: só a onda anda com o mouse. Duplo clique numa batida prende ou solta."
}
