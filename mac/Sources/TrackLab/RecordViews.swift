import AVFoundation
import SwiftUI
import TrackLabCore

/// O inspetor do modo Gravar: a entrada (o dispositivo, os canais, o nível, o monitor, a latência), o afinador, os
/// efeitos AU, os takes do loop (escolher, comparar) e o mixer, para ouvir a banda sem a guitarra.
struct RecordInspector: View {
    let model: SongModel

    var body: some View {
        InspectorHead(title: "Gravação") {
            if model.studio.recording {
                Label("Gravando", systemImage: "record.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.red)
            }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TakeReviewGroup(model: model)
                InputGroup(model: model)
                TunerGroup(recording: model.studio.recording)
                EffectsGroup()
                TakesGroup(model: model)
                MixerGroup(model: model)
            }
            .padding(10)
        }
        .controlSize(.small)
    }
}

/// A entrada: o dispositivo, os canais, o nível, ouvir pelo Mac e o ajuste da posição dos takes.
private struct InputGroup: View {
    let model: SongModel

    var body: some View {
        let input = InputEngine.shared
        InspectorGroup("Entrada", summary: input.running ? input.label : "desligada", key: "rec.input") {
            InputPicker()
            LevelMeter(level: input.level).frame(height: 6)
            if let error = input.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Ouvir a entrada pelo Mac", isOn: Binding(get: { input.monitor }, set: { input.monitor = $0 }))
                .help("Com o Helix (ou a interface com monitor direto), você já se ouve nele, sem atraso. Ligue para "
                      + "ouvir os efeitos AU do Mac.")
            if input.monitor {
                Slider(value: Binding(get: { Double(input.monitorVolume) }, set: { input.monitorVolume = Float($0) }), in: 0...1.5) {
                    Text("Volume").font(.caption)
                }
            }
            HStack(spacing: 6) {
                Text("Latência").font(.caption)
                Spacer()
                Text("\(Int((input.inputLatency * 1000).rounded())) ms +").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Stepper(value: Binding(get: { input.offsetMS }, set: { input.offsetMS = $0 }), in: -150...150, step: 5) {
                    Text("\(Int(input.offsetMS)) ms").font(.caption.monospacedDigit())
                }
                .fixedSize()
                .help("Se os takes ficam adiantados (+) ou atrasados (−) em relação ao que você tocou: a latência medida "
                      + "já é descontada; isto corrige o resto. Vale para os próximos takes.")
            }
            HStack(spacing: 6) {
                Toggle("Pré-rolo de 1 compasso", isOn: Binding(get: { model.studio.preRoll }, set: { model.studio.preRoll = $0 }))
                    .help("Gravando com a música parada, ela começa um compasso antes do loop (ou da agulha)")
            }
        }
    }
}

/// O dispositivo e os canais, num menu cada.
struct InputPicker: View {
    var body: some View {
        let input = InputEngine.shared
        HStack(spacing: 6) {
            Menu {
                ForEach(input.devices) { device in
                    Button {
                        input.deviceUID = device.uid
                    } label: {
                        if device.uid == input.device?.uid { Label(device.name, systemImage: "checkmark") } else { Text(device.name) }
                    }
                }
                Divider()
                Button("Procurar dispositivos") { input.refreshDevices() }
            } label: {
                Text(input.device?.name ?? "Sem entrada").lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            if let device = input.device {
                Menu {
                    ForEach(InputChannels.choices(for: device.inputs), id: \.self) { choice in
                        Button {
                            input.channels = choice
                        } label: {
                            let name = (choice.stereo ? "Estéreo " : "Canal ") + choice.label
                            if choice == input.channels { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                } label: {
                    Text(input.channels.label)
                }
                .fixedSize()
                .help("Os canais da entrada: no Helix, 1/2 é o som processado e 7 o DI")
            }
            Toggle(isOn: Binding(get: { input.running }, set: { $0 ? input.start() : input.stop() })) {
                Image(systemName: input.running ? "mic.fill" : "mic.slash")
            }
            .toggleStyle(.button)
            .help(input.running ? "Desliga a entrada" : "Liga a entrada")
        }
    }
}

/// O medidor do nível da entrada: verde, âmbar perto do topo, vermelho no corte.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { proxy in
            let value = Double(min(1, max(0, level)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(value > 0.97 ? Color.red : value > 0.7 ? Color.orange : Color.green)
                    .frame(width: proxy.size.width * value)
            }
        }
        .accessibilityLabel("Nível da entrada")
        .accessibilityValue("\(Int(level * 100)) %")
    }
}

/// O afinador: a nota, a oitava, a frequência e os cents numa régua.
/// Gravando, ele fica apagado e sem nota: durante a volta, o ouvido na banda e não no ponteiro.
private struct TunerGroup: View {
    let recording: Bool

    var body: some View {
        let input = InputEngine.shared
        InspectorGroup("Afinador", summary: recording ? "gravando" : input.running ? "Lá 440" : "entrada desligada",
                       key: "rec.tuner") {
            TunerReadout(frequency: input.running && !recording ? input.frequency : nil, large: true)
                .opacity(recording ? 0.35 : 1)
        }
    }
}

struct TunerReadout: View {
    let frequency: Double?
    var large = false

    var body: some View {
        let pitch = frequency.map { Tuner.pitch($0) }
        let note = pitch.map { Int($0.rounded()) }
        let cents = pitch.flatMap { value in note.map { (value - Double($0)) * 100 } }
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(note.map { String(TabSelection.name($0).split(separator: " ").first ?? "") } ?? "–")
                    .font(large ? .system(size: 26, weight: .bold) : .title3.weight(.bold))
                if let note { Text("\(note / 12 - 1)").foregroundStyle(.secondary) }
                if let frequency { Text("\(Int(frequency.rounded())) Hz").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let cents {
                    Text("\(cents >= 0 ? "+" : "−")\(Int(abs(cents).rounded())) cents")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(abs(cents) <= 5 ? Color.green : abs(cents) <= 15 ? Color.orange : Color.red)
                }
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [.red.opacity(0.25), .green.opacity(0.25), .green.opacity(0.25), .red.opacity(0.25)],
                                                  startPoint: .leading, endPoint: .trailing))
                    Rectangle().fill(Color.secondary).frame(width: 1).offset(x: width / 2)
                    if let cents {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary)
                            .frame(width: 3, height: 16)
                            .offset(x: width / 2 + CGFloat(max(-50, min(50, cents))) / 50 * width / 2 - 1.5, y: -1)
                    }
                }
            }
            .frame(height: 14)
        }
    }
}

/// Os efeitos AU no caminho da guitarra: abrir a janela, ligar e desligar, mudar a ordem, tirar; e pôr um novo.
private struct EffectsGroup: View {
    @Local private var available: [AVAudioUnitComponent] = []

    var body: some View {
        let input = InputEngine.shared
        InspectorGroup("Efeitos", summary: input.effects.isEmpty ? "nenhum" : "\(input.effects.count) AU", key: "rec.effects",
                       open: false) {
            ForEach(Array(input.effects.enumerated()), id: \.element.id) { index, effect in
                HStack(spacing: 4) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(effect.name).font(.caption.weight(.medium)).lineLimit(1)
                        Text(effect.maker).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Button("Abrir") { input.openEditor(effect) }
                    Toggle(isOn: Binding(get: { !effect.bypass }, set: { input.setBypass(effect.id, !$0) })) {
                        Image(systemName: "power")
                    }
                    .toggleStyle(.button)
                    .help("Liga ou desliga o efeito")
                    Menu {
                        Button("Subir") { input.moveEffect(effect.id, by: -1) }.disabled(index == 0)
                        Button("Descer") { input.moveEffect(effect.id, by: 1) }.disabled(index == input.effects.count - 1)
                        Divider()
                        Button("Tirar") { input.removeEffect(effect.id) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            Menu {
                if available.isEmpty { Text("Nenhum efeito AU instalado") }
                let makers = Dictionary(grouping: available, by: \.manufacturerName)
                ForEach(makers.keys.sorted(), id: \.self) { maker in
                    Menu(maker) {
                        ForEach(makers[maker] ?? [], id: \.self) { component in
                            Button(component.name) { Task { await input.addEffect(component) } }
                        }
                    }
                }
            } label: {
                Label("Efeito", systemImage: "plus")
            }
            .onAppear { if available.isEmpty { available = InputEngine.availableEffects() } }
            Text("O timbre vai junto com cada take (botão direito no take › Usar o timbre dele).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Os takes da pista armada no loop (ou em volta da agulha): qual soa, os favoritos, comparar.
private struct TakesGroup: View {
    let model: SongModel
    @Local private var renaming: Take?
    @Local private var newName = ""

    var body: some View {
        let studio = model.studio
        let range = model.engine.loop ?? (model.engine.currentTime...(model.engine.currentTime + 0.01))
        let here = TakeLanes.around(range, lane: studio.armed, in: studio.takes).reversed()
        InspectorGroup("Takes", summary: "Guitarra \(studio.armed)", key: "rec.takes") {
            Picker("Gravar na", selection: Binding(get: { studio.armed }, set: { studio.armed = $0 })) {
                ForEach(Array(Take.lanes), id: \.self) { lane in Text("Guitarra \(lane)").tag(lane) }
            }
            .disabled(studio.recording)
            if studio.recording {
                Label("Gravando: cada volta do loop vira um take", systemImage: "record.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            if here.isEmpty {
                Text(model.engine.loop == nil ? "Nenhum take aqui. Marque um loop (L) e grave (R): cada volta vira um take."
                     : "Nenhum take neste loop ainda: R grava.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(here), id: \.id) { take in
                HStack(spacing: 6) {
                    Button { model.chooseTake(take.id) } label: {
                        Image(systemName: take.active ? "largecircle.fill.circle" : "circle")
                    }
                    .buttonStyle(.plain)
                    .help(take.active ? "Este é o que soa" : "Fazer este soar")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(take.name).font(.caption.weight(take.active ? .semibold : .regular))
                        Text(details(take)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 2)
                    Button { model.auditionTake(take.id) } label: { Image(systemName: "headphones") }
                        .help("Ouvir sozinho")
                    Button { model.toggleFavorite(take.id) } label: { Image(systemName: take.favorite ? "star.fill" : "star") }
                        .foregroundStyle(take.favorite ? Color.orange : Color.secondary)
                        .help("Favorito")
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(take.active ? Color.accentColor.opacity(0.12) : .clear))
                .contextMenu {
                    Button("Renomear…") {
                        newName = take.name
                        renaming = take
                    }
                    Button("Loop neste take") { model.loopOnTake(take.id) }
                    Button("Usar o timbre dele") { model.useChain(of: take.id) }.disabled(take.chain == nil)
                    Button("Exportar o take…") { model.exportTake(take.id) }
                    Button("Mostrar no Finder") { model.revealTake(take.id) }
                    Divider()
                    Button("Apagar") { model.deleteTake(take.id) }
                }
            }
            if here.count > 1 {
                Button { model.alternateTake() } label: {
                    HStack(spacing: 4) { Text("Comparar com o anterior"); KeyHint("B") }.frame(maxWidth: .infinity)
                }
            }
        }
        .alert("Renomear take", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Renomear") { if let renaming { model.renameTake(renaming.id, to: newName) } }
            Button("Cancelar", role: .cancel) {}
        }
    }

    private func details(_ take: Take) -> String {
        var parts = ["\(Int((take.rate * 100).rounded())) %"]
        if let date = ISO8601DateFormatter().date(from: take.created) {
            parts.insert(date.formatted(date: .omitted, time: .shortened), at: 0)
        }
        if take.chain != nil { parts.append("com efeitos") }
        if let score = model.takeScores[take.id] { parts.append("nota \(Int((score.share * 100).rounded())) %") }
        return parts.joined(separator: " · ")
    }
}

/// No mixer: a chave dos takes e uma faixa por pista de guitarra gravada.
struct TakeRows: View {
    let model: SongModel

    var body: some View {
        let studio = model.studio
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { studio.on }, set: { model.setTakesOn($0) })) {
                Label("Takes", systemImage: studio.on ? "waveform" : "waveform.slash")
            }
            .toggleStyle(.button)
            .help("Liga ou cala todos os takes gravados")
            Spacer()
        }
        ForEach(studio.lanes.filter { !studio.takes(in: $0).isEmpty }, id: \.self) { lane in
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Guitarra \(lane)").font(.caption.weight(.medium))
                    Text("\(studio.takes(in: lane).count) take\(studio.takes(in: lane).count == 1 ? "" : "s")")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text("\(Int((studio.volume(lane) * 100).rounded())) %").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    Toggle("M", isOn: Binding(get: { studio.muted.contains(lane) }, set: { _ in model.toggleLaneMute(lane) }))
                        .toggleStyle(.button).controlSize(.mini).help("Mudo")
                }
                Slider(value: Binding(get: { Double(studio.volume(lane)) }, set: { model.setLaneVolume(lane, Float($0)) }), in: 0...1.5)
                    .controlSize(.mini)
            }
            .opacity(studio.on && !studio.muted.contains(lane) ? 1 : 0.55)
        }
    }
}

/// No Estudar: a guitarra ligada para tocar junto sem gravar (o afinador e a nota ao vivo na Lente).
struct GuitarGroup: View {
    let model: SongModel

    var body: some View {
        let input = InputEngine.shared
        InspectorGroup("Guitarra", summary: input.running ? input.label : "desligada", key: "study.guitar", open: false) {
            InputPicker()
            if input.running {
                LevelMeter(level: input.level).frame(height: 6)
                TunerReadout(frequency: input.frequency)
            }
            Text("Tocar junto sem gravar: o afinador e a nota ao vivo na Lente. Gravar é o modo Gravar (⌘R).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// O lado direito da barra no modo Gravar: a entrada, o nível, o pré-rolo, ouvir pelo Mac e o botão de gravar.
struct RecordControls: View {
    let model: SongModel

    var body: some View {
        let input = InputEngine.shared
        let studio = model.studio
        Menu {
            ForEach(input.devices) { device in
                Button(device.name) { input.deviceUID = device.uid }
            }
        } label: {
            Text(input.running ? input.label : "Entrada desligada").lineLimit(1)
        }
        .fixedSize()
        .help("A entrada da guitarra (o dispositivo e os canais ficam no inspetor)")
        LevelMeter(level: input.level).frame(width: 46, height: 6)
        Toggle("Pré-rolo", isOn: Binding(get: { studio.preRoll }, set: { studio.preRoll = $0 }))
            .toggleStyle(.button)
            .help("Gravando com a música parada, ela começa um compasso antes")
        Toggle("Ouvir a entrada", isOn: Binding(get: { input.monitor }, set: { input.monitor = $0 }))
            .toggleStyle(.button)
            .help("Ouvir a guitarra pelo Mac (com os efeitos AU). Com o Helix, deixe desligado: ele já devolve o som.")
        if studio.recording, model.engine.loop != nil {
            Text("Volta \(model.recordPass + 1)").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.red)
                .help("Cada volta do loop vira um take; ao parar, cada uma ganha a nota e a melhor passa a soar")
        }
        Button { model.toggleRecording() } label: {
            HStack(spacing: 4) {
                Image(systemName: studio.recording ? "stop.fill" : "record.circle")
                Text(studio.recording ? "Parar" : "Gravar")
                KeyHint("R")
            }
        }
        .tint(.red)
        .buttonStyle(.borderedProminent)
        .help(studio.recording ? "R: para e guarda os takes" : "R: grava na Guitarra \(studio.armed); com loop, cada volta vira um take")
    }
}

/// A camada dos takes, sob a TAB no modo Gravar: uma faixa por pista de guitarra, cada take no lugar dele na música
/// (a mesma escala e a mesma agulha da Fita). O take que soa, cheio, com a onda; os outros que passam pelo mesmo trecho,
/// em linhas finas embaixo. Um clique num take faz ele soar; o botão direito tem o menu dele.
struct TakesLane: View {
    let model: SongModel
    let span: Double
    @Local private var renaming: Take?
    @Local private var newName = ""

    /// A altura de cada pista e a da pista 0, o disco (a guitarra da gravação pintada onde soa; sem a separação, onde
    /// a TAB tem nota), pelo `LaneLayout` do modo.
    var row = 46.0
    var record = 24.0
    private var rowHeight: Double { row }
    private var recordHeight: Double { record }
    static let labelWidth = 92.0

    var body: some View {
        let lanes = model.studio.lanes
        GeometryReader { geometry in
            TimelineView(.animation(paused: !model.engine.isPlaying)) { context in
                let host = CACurrentMediaTime() + context.date.timeIntervalSinceNow
                let now = model.engine.songTime(atHost: host)
                Canvas { canvas, size in draw(&canvas, size: size, now: now, lanes: lanes) }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { point in
                if let take = take(at: point, width: geometry.size.width, lanes: lanes) {
                    model.chooseTake(take.id)
                } else if let lane = lane(at: point.y, lanes: lanes) {
                    model.studio.armed = lane
                }
            }
            .background(RightClickCatcher { point, view in
                guard let take = take(at: point, width: geometry.size.width, lanes: lanes) else { return false }
                model.showTakeMenu(take.id, at: point, in: view) { take in
                    newName = take.name
                    renaming = take
                }
                return true
            })
        }
        .frame(height: recordHeight + Double(lanes.count) * rowHeight + 4)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .alert("Renomear take", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Renomear") { if let renaming { model.renameTake(renaming.id, to: newName) } }
            Button("Cancelar", role: .cancel) {}
        }
    }

    private func lane(at y: Double, lanes: [Int]) -> Int? {
        guard y >= 2 + recordHeight else { return nil }
        let index = Int((y - 2 - recordHeight) / rowHeight)
        return lanes.indices.contains(index) ? lanes[index] : nil
    }

    /// O take sob o ponto: o que soa, se o ponto cai nele, senão um dos outros (as linhas finas).
    private func take(at point: CGPoint, width: Double, lanes: [Int]) -> Take? {
        guard let lane = lane(at: point.y, lanes: lanes) else { return nil }
        let start = model.viewStart(now: model.engine.currentTime)
        let seconds = start + point.x / max(width, 1) * span
        let here = model.studio.takes(in: lane).filter { $0.range.contains(seconds) }
        let row = (point.y - 2 - recordHeight).truncatingRemainder(dividingBy: rowHeight)
        if row < rowHeight * 0.68 { return here.first(where: \.active) ?? here.last }
        // Nas linhas finas: a de cima é a mais nova entre as que não soam.
        let others = Array(here.filter { !$0.active }.reversed())
        let index = Int((row - rowHeight * 0.68) / 5)
        return others.indices.contains(index) ? others[index] : others.last
    }

    /// A pista 0: a guitarra do disco onde soa (a faixa separada acima de um oitavo do mais alto dela; sem a separação,
    /// onde a pista da TAB tem nota), para ver onde entrar e onde calar.
    private func drawRecord(_ context: inout GraphicsContext, width: Double, start: Double) {
        func x(_ t: Double) -> Double { (t - start) / span * width }
        let amber = Color(red: 0.95, green: 0.62, blue: 0.16)
        let top = 3.0
        let height = recordHeight - 5
        var spans: [(Double, Double)] = []
        if let peaks = model.guitarPeaks, peaks.perSecond > 0 {
            let loudest = model.guitarLoudest
            let step = max(span / max(width, 1) * 2, 1 / Double(peaks.perSecond))
            var t = max(0, start)
            var open: Double?
            while t <= start + span {
                let sounding = loudest > 0 && peaks.amplitude(from: t, to: t + step) > loudest / 8
                if sounding, open == nil { open = t }
                if !sounding, let from = open {
                    spans.append((from, t))
                    open = nil
                }
                t += step
            }
            if let from = open { spans.append((from, start + span)) }
        } else if model.scoreNotes.indices.contains(model.scoreTrack) {
            for note in model.scoreNotes[model.scoreTrack] {
                let from = model.grid.seconds(at: note.tick)
                let to = model.grid.seconds(at: note.tick + note.duration)
                guard to > start, from < start + span else { continue }
                if let last = spans.last, from - last.1 < 0.12 { spans[spans.count - 1].1 = max(last.1, to) } else { spans.append((from, to)) }
            }
        }
        var painted = Path()
        for (from, to) in spans {
            painted.addRoundedRect(in: CGRect(x: x(from), y: top, width: max(2, x(to) - x(from)), height: height),
                                   cornerSize: CGSize(width: 3, height: 3))
        }
        context.fill(painted, with: .color(amber.opacity(0.45)))
        context.fill(Path(roundedRect: CGRect(x: 2, y: top, width: Self.labelWidth - 6, height: height), cornerRadius: 5),
                     with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
        context.draw(Text("O disco").font(.caption.weight(.semibold)).foregroundStyle(amber),
                     at: CGPoint(x: 7, y: top + height / 2), anchor: .leading)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Double, lanes: [Int]) {
        let width = size.width
        let start = model.viewStart(now: now)
        func x(_ t: Double) -> Double { (t - start) / span * width }
        let studio = model.studio
        // O loop e os compassos, como na Fita.
        if let loop = model.engine.loop {
            context.fill(Path(CGRect(x: x(loop.lowerBound), y: 0, width: x(loop.upperBound) - x(loop.lowerBound), height: size.height)),
                         with: .color(.orange.opacity(0.08)))
        }
        var bars = Path()
        for bar in model.grid.bars where bar >= start && bar <= start + span {
            bars.addRect(CGRect(x: x(bar), y: 0, width: 1, height: size.height))
        }
        context.fill(bars, with: .color(.secondary.opacity(0.25)))
        let red = Color(red: 0.9, green: 0.22, blue: 0.17)
        let colors: [Int: Color] = [1: red, 2: Color(red: 0.18, green: 0.44, blue: 0.84),
                                    3: Color(red: 0.2, green: 0.6, blue: 0.4), 4: Color(red: 0.55, green: 0.36, blue: 0.8)]
        drawRecord(&context, width: width, start: start)
        for (row, lane) in lanes.enumerated() {
            let top = 2 + recordHeight + Double(row) * rowHeight
            let color = colors[lane] ?? .gray
            let block = rowHeight * 0.62
            context.fill(Path(CGRect(x: 0, y: top - 1, width: width, height: 0.5)), with: .color(.secondary.opacity(0.3)))
            let takes = studio.takes(in: lane).filter { $0.end > start && $0.start < start + span }
            // Os que não soam: linhas finas embaixo, a mais nova em cima.
            var thin = 0
            for take in takes.reversed() where !take.active {
                let y = top + block + 3 + Double(thin) * 5
                guard y < top + rowHeight - 3 else { break }
                let rect = CGRect(x: x(take.start), y: y, width: max(2, x(take.end) - x(take.start)), height: 3)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color.opacity(0.35)))
                thin += 1
            }
            for take in takes where take.active {
                let rect = CGRect(x: x(take.start), y: top + 1, width: max(2, x(take.end) - x(take.start)), height: block)
                let shape = Path(roundedRect: rect, cornerRadius: 5)
                context.fill(shape, with: .color(color.opacity(0.13)))
                // Com a nota do take, cada compasso na cor de como foi: verde limpo, âmbar com erros, vermelho difícil.
                if let score = model.takeScores[take.id] {
                    for (bar, share) in score.byBar {
                        guard model.grid.bars.indices.contains(bar - 1) else { continue }
                        let from = max(take.start, model.grid.bars[bar - 1])
                        let to = min(take.end, model.grid.bars.indices.contains(bar) ? model.grid.bars[bar] : take.end)
                        guard to > from else { continue }
                        let tint: Color = share >= 0.9 ? .green : share >= 0.6 ? .orange : red
                        context.fill(Path(CGRect(x: x(from), y: rect.maxY - 4, width: x(to) - x(from), height: 4)),
                                     with: .color(tint.opacity(0.85)))
                    }
                }
                context.stroke(shape, with: .color(color.opacity(0.8)), lineWidth: 1.2)
                if let peaks = studio.peaks[take.id], !peaks.isEmpty {
                    var wave = Path()
                    let middle = rect.midY
                    let half = rect.height / 2 - 3
                    let step = 2.0
                    var px = max(rect.minX, 0)
                    var top: [CGPoint] = []
                    var bottom: [CGPoint] = []
                    while px <= min(rect.maxX, width) {
                        let t = start + px / width * span - take.start
                        let index = Int(t / TakeStudio.peakStep)
                        let value = peaks.indices.contains(index) ? Double(peaks[index]) : 0
                        top.append(CGPoint(x: px, y: middle - value * half))
                        bottom.append(CGPoint(x: px, y: middle + value * half))
                        px += step
                    }
                    if let first = top.first {
                        wave.move(to: first)
                        for point in top.dropFirst() { wave.addLine(to: point) }
                        for point in bottom.reversed() { wave.addLine(to: point) }
                        wave.closeSubpath()
                        context.fill(wave, with: .color(color.opacity(0.75)))
                    }
                }
                let label = (take.favorite ? "★ " : "") + take.name
                    + (model.takeScores[take.id].map { " · \(Int(($0.share * 100).rounded())) %" } ?? "")
                if rect.width > 50 {
                    context.draw(Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color),
                                 at: CGPoint(x: max(rect.minX, Self.labelWidth) + 5, y: rect.minY + 3), anchor: .topLeading)
                }
            }
            // Gravando: o take crescendo, do começo da gravação (ou do loop) até a agulha.
            if studio.recording, lane == studio.armed, let from = studio.recordingFrom {
                let low = model.engine.loop.map { max($0.lowerBound, min(from, now)) } ?? from
                let rect = CGRect(x: x(low), y: top + 1, width: max(2, x(now) - x(low)), height: block)
                context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(red.opacity(0.28)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(red), lineWidth: 1.5)
            }
            // O nome da pista à esquerda.
            let armed = lane == studio.armed
            let name = Text((armed ? "● " : "") + "Guitarra \(lane)").font(.caption.weight(.semibold))
                .foregroundStyle(armed ? red : Color.secondary)
            let count = studio.takes(in: lane).count
            context.fill(Path(roundedRect: CGRect(x: 2, y: top + 2, width: Self.labelWidth - 6, height: 30), cornerRadius: 5),
                         with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
            context.draw(name, at: CGPoint(x: 7, y: top + 4), anchor: .topLeading)
            context.draw(Text(armed ? (studio.recording ? "gravando · volta \(model.recordPass + 1)" : "armada · \(count)")
                                    : "\(count) take\(count == 1 ? "" : "s")")
                            .font(.caption2).foregroundStyle(.secondary),
                         at: CGPoint(x: 7, y: top + 18), anchor: .topLeading)
        }
        context.fill(Path(CGRect(x: x(now) - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
    }
}
