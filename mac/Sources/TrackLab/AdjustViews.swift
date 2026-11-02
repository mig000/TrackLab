import SwiftUI
import TrackLabCore

/// No alto do Ajuste, a música inteira: o andamento de cada compasso pelo mapa (um ponto fora do lugar aparece como
/// pico), embaixo o quanto os ataques ouvidos chegam depois (para cima) ou antes (para baixo) do mapa em cada
/// compasso, os compassos a olhar em vermelho e os conferidos em verde; o trecho que a Fita mostra e a agulha. Um
/// clique leva a música até ali.
struct AdjustOverview: View {
    let model: SongModel
    let span: Double

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Canvas { context, size in draw(in: &context, size: size) }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                let duration = max(1, model.engine.duration)
                model.seek(to: value.location.x / max(1, geometry.size.width) * duration, at: model.playheadAt)
            })
        }
        .frame(height: 92)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .help("A música inteira: em cima o andamento de cada compasso pelo mapa (um pico é um ponto fora do lugar); "
              + "embaixo, quanto o som chega depois (para cima) ou antes (para baixo) do mapa. Um clique leva a música até ali.")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let duration = max(1, model.engine.duration)
        func x(_ t: Double) -> Double { t / duration * width }
        let review = model.adjustReview
        let red = Color(red: 0.9, green: 0.22, blue: 0.17)
        let blue = Color(red: 0.25, green: 0.5, blue: 0.95)

        // O andamento: uma linha, em volta da mediana (±8 %).
        let tempos = review.map(\.bpm).filter { $0 > 0 }.sorted()
        let median = tempos.isEmpty ? 120 : tempos[tempos.count / 2]
        let curveTop = 12.0
        let curveBottom = 46.0
        func y(_ bpm: Double) -> Double {
            let fraction = max(-1, min(1, (bpm / median - 1) / 0.08))
            return (curveTop + curveBottom) / 2 - fraction * (curveBottom - curveTop) / 2
        }
        context.fill(Path(CGRect(x: 0, y: (curveTop + curveBottom) / 2, width: width, height: 0.5)),
                     with: .color(.secondary.opacity(0.3)))
        var curve = Path()
        for (index, bar) in review.enumerated() where bar.bpm > 0 {
            let point = CGPoint(x: x(bar.start), y: y(bar.bpm))
            if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
        }
        context.stroke(curve, with: .color(.primary.opacity(0.75)), lineWidth: 1.2)
        context.draw(CanvasLabel.image("andamento · \(Int(median.rounded())) bpm", size: 9, weight: .semibold,
                                       color: .secondaryLabelColor, dark: false),
                     at: CGPoint(x: 4, y: 2), anchor: .topLeading)

        // O som contra o mapa, por compasso.
        let baseline = 70.0
        context.fill(Path(CGRect(x: 0, y: baseline, width: width, height: 0.5)), with: .color(.secondary.opacity(0.3)))
        var later = Path()
        var doubt = Path()
        for (index, bar) in review.enumerated() {
            let next = index + 1 < review.count ? review[index + 1].start : bar.start + 2
            let barWidth = max(1.5, x(next) - x(bar.start) - 1)
            if let offset = bar.attacks ?? bar.detector {
                let h = min(16, abs(offset) / 0.1 * 16)
                let rect = CGRect(x: x(bar.start), y: offset > 0 ? baseline - h : baseline, width: barWidth, height: max(1, h))
                if bar.doubtful { doubt.addRect(rect) } else { later.addRect(rect) }
            } else if bar.doubtful {
                doubt.addRect(CGRect(x: x(bar.start), y: baseline - 3, width: barWidth, height: 6))
            }
        }
        context.fill(later, with: .color(blue.opacity(0.7)))
        context.fill(doubt, with: .color(red))
        context.draw(CanvasLabel.image("o som contra o mapa", size: 9, weight: .semibold, color: .secondaryLabelColor, dark: false),
                     at: CGPoint(x: 4, y: 50), anchor: .topLeading)

        // Os conferidos, embaixo.
        var checked = Path()
        for (index, bar) in review.enumerated() where model.checkedBars.contains(bar.bar) {
            let next = index + 1 < review.count ? review[index + 1].start : bar.start + 2
            checked.addRect(CGRect(x: x(bar.start), y: size.height - 4, width: max(1, x(next) - x(bar.start)), height: 3))
        }
        context.fill(checked, with: .color(.green.opacity(0.85)))

        // O trecho que a Fita mostra e a agulha.
        let now = model.engine.currentTime
        let view = model.viewStart(now: now)
        let window = CGRect(x: x(view), y: 1, width: max(2, x(view + span) - x(view)), height: size.height - 2)
        context.fill(Path(window), with: .color(.orange.opacity(0.08)))
        context.stroke(Path(window), with: .color(.orange.opacity(0.7)), lineWidth: 1)
        context.fill(Path(CGRect(x: x(now) - 1, y: 0, width: 2, height: size.height)), with: .color(.accentColor))
    }
}

/// Conferir de ouvido: um compasso por vez, em loop e com o clique; Certo marca conferido e passa ao seguinte, Cedo e
/// Tarde empurram o 1 dele 10 ms e tocam de novo. Embaixo, a grade de todos os compassos.
struct AdjustCheckSheet: View {
    let model: SongModel

    var body: some View {
        let review = model.adjustReview
        let bar = model.checkingBar ?? 1
        let item = review.indices.contains(bar - 1) ? review[bar - 1] : nil
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text("c. \(bar)").font(.system(size: 44, weight: .bold)).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.checkOnlyDoubtful ? "Passo 3 · os duvidosos" : "Passo 4 · conferir a música")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(partName(bar) ?? "").font(.headline)
                    if let item {
                        Text("\(Int(item.bpm.rounded())) bpm · \(clock(item.start))").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Spacer()
                Picker("Ouvir", selection: Binding(get: { model.adjustListen }, set: { model.adjustListen = $0 })) {
                    ForEach(AdjustListen.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if let item {
                HStack(spacing: 18) {
                    evidence("Os ataques da guitarra", item.attacks, count: item.attackCount)
                    evidence("A batida do detector", item.detector, count: nil)
                    if item.tempoJump { Label("o andamento salta aqui", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
                .font(.callout)
            }
            HStack(spacing: 12) {
                Button { model.nudgeCheckingBar(by: 0.01) } label: {
                    VStack(spacing: 2) { Text("← Cedo").font(.title3); Text("o mapa antes do som").font(.caption).foregroundStyle(.secondary) }
                        .frame(minWidth: 130, minHeight: 44)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.checkBarOK() } label: {
                    HStack { Text("Certo").font(.title2.weight(.semibold)); KeyHint("C") }.frame(maxWidth: .infinity, minHeight: 44)
                }
                .keyboardShortcut("c", modifiers: [])
                .buttonStyle(.borderedProminent)
                Button { model.nudgeCheckingBar(by: -0.01) } label: {
                    VStack(spacing: 2) { Text("Tarde →").font(.title3); Text("o mapa depois do som").font(.caption).foregroundStyle(.secondary) }
                        .frame(minWidth: 130, minHeight: 44)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .controlSize(.large)
            HStack {
                Text("Cedo e Tarde empurram o 1 do compasso 10 ms e tocam de novo; Certo marca conferido, prende o 1 dele e já toca o seguinte.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let correction = item?.correction, abs(correction) >= 0.005 {
                    let ms = Int((correction * 1000).rounded())
                    Button { model.snapCheckingBar() } label: {
                        HStack(spacing: 4) { Text("Até o som (\(ms > 0 ? "+" : "−")\(abs(ms)) ms)"); KeyHint("A") }
                    }
                    .keyboardShortcut("a", modifiers: [])
                    .help("O 1 do compasso vai até onde os ataques e o detector dizem, e toca de novo")
                }
            }
            HStack {
                Toggle("Pular os que concordam com o som (a menos de 15 ms)", isOn: Binding(
                    get: { model.checkSkipAgreeing }, set: { model.checkSkipAgreeing = $0 }))
                Spacer()
                Text("\(model.checkSession.checked) conferidos · \(model.checkSession.nudged) empurrões · \(model.checkSession.skipped) pulados")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let change = model.checkChange {
                MapChangeView(change: change, current: bar, checked: model.checkedBars)
            }
            BarGrid(model: model, review: review, current: bar)
            HStack {
                Button("Pular este") { model.skipCheckingBar() }.keyboardShortcut(.downArrow, modifiers: [])
                Spacer()
                Button("Parar") { model.stopChecking() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 720)
    }

    private func evidence(_ title: String, _ offset: Double?, count: Int?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color(offset)).frame(width: 9, height: 9)
            Text(title).foregroundStyle(.secondary)
            if let offset {
                let ms = Int((offset * 1000).rounded())
                Text("\(ms > 0 ? "+" : ms < 0 ? "−" : "")\(abs(ms)) ms").monospacedDigit().fontWeight(.semibold)
            } else {
                Text(count.map { $0 > 0 ? "poucos (\($0))" : "nenhum" } ?? "nenhuma perto").foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ offset: Double?) -> Color {
        guard let offset else { return .gray.opacity(0.5) }
        return abs(offset) >= AdjustReview.threshold ? .red : .green
    }

    private func partName(_ bar: Int) -> String? {
        guard let range = model.barRange(bar) else { return nil }
        return model.songParts().last { $0.from <= range.lowerBound + 0.01 }?.name
    }

    private func clock(_ seconds: Double) -> String {
        let total = max(0, seconds)
        return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
    }
}

/// O que o último empurrão mudou no mapa: as batidas de antes (cinza) e de depois (laranja), ligadas, com o 1 de cada
/// compasso mais grosso e o número; embaixo, o andamento de cada compasso antes e depois e quanto o 1 andou. O áudio
/// não muda: só onde as batidas da TAB caem nele.
struct MapChangeView: View {
    let change: MapChange
    let current: Int
    let checked: Set<Int>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("O que mudou no mapa").font(.caption.weight(.semibold))
                Spacer()
                HStack(spacing: 10) {
                    Label("antes", systemImage: "circle.fill").foregroundStyle(.secondary)
                    Label("depois", systemImage: "circle.fill").foregroundStyle(.orange)
                }
                .labelStyle(.titleAndIcon)
                .font(.caption2)
                .imageScale(.small)
            }
            Canvas { context, size in draw(in: &context, size: size) }
                .frame(height: 64)
            HStack(spacing: 0) {
                ForEach(change.bars, id: \.bar) { bar in
                    VStack(spacing: 2) {
                        Text("c. \(bar.bar)\(checked.contains(bar.bar) ? " ✓" : "")")
                            .font(.caption.weight(bar.bar == current ? .bold : .regular))
                            .foregroundStyle(checked.contains(bar.bar) ? .green : .primary)
                        Text(tempo(bar)).font(.caption2.monospacedDigit())
                            .foregroundStyle(abs(bar.bpmAfter - bar.bpmBefore) >= 0.05 ? .primary : .secondary)
                        if abs(bar.shift) >= 0.0005 {
                            Text("1 \(bar.shift > 0 ? "+" : "−")\(Int((abs(bar.shift) * 1000).rounded())) ms")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.orange)
                        } else {
                            Text("1 no lugar").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Text("O áudio não muda: o compasso de antes e os de depois esticam ou encolhem um pouco para o 1 andar.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.06)))
    }

    private func tempo(_ bar: MapChange.Bar) -> String {
        let a = String(format: "%.1f", bar.bpmBefore)
        let b = String(format: "%.1f", bar.bpmAfter)
        return a == b ? "\(a) bpm" : "\(a) → \(b) bpm"
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let times = change.beats.flatMap { [$0.before, $0.after] }
        guard let low = times.min(), let high = times.max(), high > low else { return }
        let width = Double(size.width)
        func x(_ t: Double) -> Double { 6 + (t - low) / (high - low) * (width - 12) }
        let top = 8.0
        let bottom = Double(size.height) - 8
        var before = Path()
        var after = Path()
        var links = Path()
        for beat in change.beats {
            let h = beat.downbeat ? 14.0 : 8.0
            let w = beat.downbeat ? 2.5 : 1.5
            before.addRect(CGRect(x: x(beat.before) - w / 2, y: top, width: w, height: h))
            after.addRect(CGRect(x: x(beat.after) - w / 2, y: bottom - h, width: w, height: h))
            links.move(to: CGPoint(x: x(beat.before), y: top + h))
            links.addLine(to: CGPoint(x: x(beat.after), y: bottom - h))
        }
        context.stroke(links, with: .color(.orange.opacity(0.45)), lineWidth: 1)
        context.fill(before, with: .color(.secondary))
        context.fill(after, with: .color(.orange))
    }
}

/// Todos os compassos em quadradinhos: conferido em verde, a olhar em vermelho, o resto em cinza; o da vez com um
/// anel. Um clique confere aquele.
struct BarGrid: View {
    let model: SongModel
    let review: [BarReview]
    let current: Int

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 13, maximum: 13), spacing: 3)], spacing: 3) {
            ForEach(review, id: \.bar) { item in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(model.checkedBars.contains(item.bar) ? Color.green : item.doubtful ? Color.red : Color.gray.opacity(0.3))
                    .frame(width: 13, height: 13)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.accentColor, lineWidth: item.bar == current ? 2 : 0).padding(-2))
                    .help("Compasso \(item.bar)")
                    .onTapGesture {
                        model.checkingBar = item.bar
                        model.playCheckingBar()
                    }
            }
        }
        .frame(maxHeight: 180)
    }
}
