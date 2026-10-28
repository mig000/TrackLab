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
            ZStack {
                ScoreView(bridge: model.bridge)
                if let message = model.scoreMessage {
                    Text(message).foregroundStyle(.secondary).padding().background(.background)
                }
            }
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

/// A barra do Ajuste, sobre a Fita: o 1 no toque (U), Desfazer e Refazer, quantas âncoras há e o que o motor disse.
struct AdjustBar: View {
    let model: SongModel

    var body: some View {
        HStack(spacing: 14) {
            Text("Ajuste")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(.orange.opacity(0.15)))
            Button { model.downbeatHere() } label: { Label("O 1 é aqui", systemImage: "metronome") }
                .keyboardShortcut("u", modifiers: [])
                .help("U: tocando, aperte no tempo forte; o começo de compasso mais perto vem até o toque")
            Button { model.undo() } label: { Label("Desfazer", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("⌘Z")
            Button { model.redo() } label: { Label("Refazer", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("⇧⌘Z")
            Text(model.adjustMessage ?? "Arraste uma batida na Fita até onde ela soa; duplo clique prende ou solta.")
                .font(.caption)
                .foregroundStyle(model.adjustMessage == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
            Spacer()
            if model.saving { ProgressView().controlSize(.small) }
            Text(model.anchorCount == 1 ? "1 âncora" : "\(model.anchorCount) âncoras")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Concluir") { model.adjusting = false }
        }
        .buttonStyle(.borderless)
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
            Spacer()
            Stepper(value: Binding(get: { Double(engine.rate) }, set: { engine.rate = Float($0) }),
                    in: Double(StemEngine.rates.lowerBound)...Double(StemEngine.rates.upperBound),
                    step: Double(StemEngine.rateStep)) {
                Text("Velocidade \(Int((engine.rate * 100).rounded())) %").monospacedDigit()
            }
            Stepper(value: Binding(get: { engine.semitones }, set: { engine.semitones = $0 }), in: StemEngine.semitones) {
                Text("Tom \(engine.semitones > 0 ? "+" : "")\(engine.semitones)").monospacedDigit()
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
                if let job = model.separating {
                    ProgressView(value: job.progress ?? 0).frame(width: 140)
                    Text(job.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if model.detail?.audio != nil {
                    Button("Separar as faixas (Demucs 6s)") { Task { await model.separate() } }
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
                        Spacer()
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
