import SwiftUI
import TrackLabCore

/// O bend da nota escolhida na coluna de edição, como o editor do Guitar Pro: o tipo, as alturas de cada etapa em
/// quartos de tom (de ¼ a 3 tons) e o tempo num gráfico da nota, com os pontos de arrastar na grade de 1/12 e, por
/// baixo, o som medido pela Lente. Só escreve formas que o Guitar Pro 7 guarda (`BendForm`): dois movimentos na mesma
/// nota se escrevem em duas ligadas (Dividir, Ligada). Com várias notas escolhidas, vale para todas.
struct BendEditor: View {
    let model: SongModel
    let selection: TabSelection?
    /// O bend enquanto um ponto é arrastado (vai à página ao soltar) e o ponto.
    @Local private var draft: BendForm?
    @Local private var handle: Handle?

    enum Handle { case start, arrive, hold, back, level }

    static let kinds: [(kind: BendForm.Kind, icon: NotationIcon.BendShape)] = [
        (.bend, .bend), (.bendRelease, .release), (.release, .releaseOnly),
        (.prebend, .prebend), (.prebendBend, .prebendBend), (.prebendRelease, .prebendRelease),
    ]
    static let written = Color(red: 0.95, green: 0.62, blue: 0.16)
    static let heard = Color(red: 1, green: 138 / 255, blue: 61 / 255)

    var body: some View {
        let current = selection?.bendForm
        let form = draft ?? current
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Bend").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("B altura · ⇧B tipo").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .help("Dois movimentos na mesma nota (sobe, volta e sobe de novo) não cabem no Guitar Pro 7: escreva em duas "
                  + "notas ligadas, com Dividir (/) ou Ligada (L).")
            kindGrid(current)
            if let note = summary(form) {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let form {
                heights(form)
                graph(form)
                timing(form)
            }
        }
        .disabled(selection == nil)
        .onChange(of: selection?.bend) { draft = nil }
        .onChange(of: selection?.ownTick) { draft = nil }
    }

    // MARK: - Partes

    /// Os seis tipos; o escolhido de novo tira o bend. A Volta só numa ligada que traz um bend.
    private func kindGrid(_ current: BendForm?) -> some View {
        let carried = selection?.carried ?? 0
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(Self.kinds, id: \.kind) { item in
                Toggle(isOn: Binding(get: { (draft ?? current)?.kind == item.kind }, set: { _ in choose(item.kind, current) })) {
                    VStack(spacing: 1) {
                        NotationIconView(icon: .bend(item.icon, ""))
                        Text(item.kind.label).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
                .disabled(item.kind == .release && carried == 0)
                .help(help(item.kind))
            }
        }
    }

    private func choose(_ kind: BendForm.Kind, _ current: BendForm?) {
        draft = nil
        if current?.kind == kind {
            model.setBend(nil)
        } else {
            model.setBend(BendForm.make(kind, from: current, carried: selection?.carried ?? 0))
        }
    }

    private func help(_ kind: BendForm.Kind) -> String {
        switch kind {
        case .bend: "A corda sobe depois de tocar (de novo: tira o bend)"
        case .bendRelease: "Sobe, segura e volta (a 0 ou a uma altura menor)"
        case .release: "Volta de um bend que vem da nota ligada de antes"
        case .prebend: "A corda já está dobrada antes de tocar"
        case .prebendBend: "Toca dobrada e sobe mais"
        case .prebendRelease: "Toca dobrada e volta"
        }
    }

    /// O que as alturas não dizem: sem bend, a ligada que segura o de antes, uma forma de outro editor, ou que o bend
    /// vale para várias notas. Nil quando não há o que dizer.
    private func summary(_ form: BendForm?) -> String? {
        guard let selection else { return nil }
        guard form != nil else {
            if selection.bend.isEmpty {
                return selection.carried > 0 ? "Segura o bend de antes (\(BendForm.name(selection.carried)))" : "Sem bend"
            }
            return "Dois movimentos (de outro editor): um tipo reescreve"
        }
        return selection.count > 1 ? "Vale para as \(selection.count) notas escolhidas" : nil
    }

    /// As alturas do tipo: o pré-bend, até onde sobe e até onde volta (na Volta, a de partida é a que vem ligada).
    @ViewBuilder
    private func heights(_ form: BendForm) -> some View {
        if form.kind.usesPre, form.kind != .release {
            heightRow("Pré", form.pre, 1...(form.kind == .prebendBend ? BendForm.maxHeight - 1 : BendForm.maxHeight),
                      chips: [1, 2, 3, 4, 6, 8]) { var f = form; f.pre = $0; return f }
        }
        if form.kind.usesTop {
            heightRow("Sobe a", form.top, (form.kind == .prebendBend ? form.pre + 1 : 1)...BendForm.maxHeight,
                      chips: [1, 2, 3, 4, 6, 8]) { var f = form; f.top = $0; return f }
        }
        if form.kind.usesEnd {
            let from = form.kind == .bendRelease ? form.top : form.pre
            heightRow("Volta a", form.end, 0...max(0, from - 1), chips: [0, 1, 2, 3, 4, 6]) { var f = form; f.end = $0; return f }
        }
    }

    private func heightRow(_ title: String, _ value: Int, _ allowed: ClosedRange<Int>, chips: [Int],
                           _ change: @escaping (Int) -> BendForm) -> some View {
        let set: (Int) -> Void = { model.setBend(change(min(max($0, allowed.lowerBound), allowed.upperBound))) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(BendForm.name(value)).font(.caption.weight(.semibold))
            }
            HStack(spacing: 2) {
                ForEach(chips.filter(allowed.contains), id: \.self) { q in
                    Toggle(isOn: Binding(get: { value == q }, set: { _ in set(q) })) {
                        Text(BendForm.name(q)).fixedSize()
                    }
                    .toggleStyle(.button)
                }
                Spacer(minLength: 0)
                Button("−") { set(value - 1) }.disabled(value <= allowed.lowerBound).help("¼ de tom a menos")
                Button("+") { set(value + 1) }.disabled(value >= allowed.upperBound).help("¼ de tom a mais")
            }
            .controlSize(.mini)
        }
    }

    /// Os atalhos de tempo: rápido (como o Guitar Pro 8 grava), ao longo da nota (como o Songsterr importa), atrasado.
    private func timing(_ form: BendForm) -> some View {
        HStack(spacing: 3) {
            ForEach(BendForm.Timing.allCases, id: \.self) { item in
                Toggle(isOn: Binding(get: { form.timing == item }, set: { _ in model.setBend(form.timed(item)) })) {
                    Text(item.label).frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
            }
        }
        .disabled(form.kind == .prebend)
    }

    // MARK: - O gráfico

    /// A nota no tempo (0 a 60, da esquerda à direita) e a altura em quartos de tom: a linha do bend escrito, os
    /// pontos de arrastar e os do som medido.
    private func graph(_ form: BendForm) -> some View {
        let sound = model.selectedBendSound()
        let highest = max(4, Int(form.points.map { $0[1] }.max() ?? 0),
                          Int((sound.map(\.quarterTones).max() ?? 0).rounded(.up)))
        let top = Double(min(BendForm.maxHeight, highest + 1))
        return VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geometry in
                let plot = Self.plot(geometry.size)
                Canvas { context, _ in
                    draw(form, sound: sound, top: top, plot: plot, in: &context)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag(form, at: $0, top: top, plot: plot) }
                    .onEnded { _ in
                        if let draft { model.setBend(draft) }
                        handle = nil
                    })
            }
            .frame(height: 104)
            Text(times(form) + (sound.isEmpty ? "" : " · ● o som"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static func plot(_ size: CGSize) -> CGRect {
        CGRect(x: 16, y: 6, width: max(1, size.width - 22), height: max(1, size.height - 12))
    }

    private func draw(_ form: BendForm, sound: [(fraction: Double, quarterTones: Double)], top: Double, plot: CGRect,
                      in context: inout GraphicsContext) {
        let x = { (offset: Double) in plot.minX + offset / 60 * plot.width }
        let y = { (q: Double) in plot.maxY - min(max(q, -0.5), top) / top * plot.height }
        var grid = Path()
        for offset in stride(from: 0.0, through: 60, by: BendForm.step) {
            grid.move(to: CGPoint(x: x(offset), y: plot.minY))
            grid.addLine(to: CGPoint(x: x(offset), y: plot.maxY))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
        var quarters = Path()
        for offset in stride(from: 0.0, through: 60, by: 15) {
            quarters.move(to: CGPoint(x: x(offset), y: plot.minY))
            quarters.addLine(to: CGPoint(x: x(offset), y: plot.maxY))
        }
        for tone in stride(from: 0.0, through: top, by: 4) {
            quarters.move(to: CGPoint(x: plot.minX, y: y(tone)))
            quarters.addLine(to: CGPoint(x: plot.maxX, y: y(tone)))
            context.draw(Text(BendForm.name(Int(tone))).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: plot.minX - 8, y: y(tone)))
        }
        context.stroke(quarters, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
        for sample in sound {
            let point = CGPoint(x: x(sample.fraction * 60), y: y(sample.quarterTones))
            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.4, y: point.y - 1.4, width: 2.8, height: 2.8)),
                         with: .color(Self.heard.opacity(0.85)))
        }
        var line = Path()
        let points = form.points
        line.move(to: CGPoint(x: plot.minX, y: y(points[0][1])))
        for point in points { line.addLine(to: CGPoint(x: x(point[0]), y: y(point[1]))) }
        line.addLine(to: CGPoint(x: plot.maxX, y: y(points[points.count - 1][1])))
        context.stroke(line, with: .color(Self.written), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        for (which, offset, q) in Self.handles(form) {
            let center = CGPoint(x: x(offset), y: y(q))
            let circle = Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            context.fill(circle, with: .color(handle == which ? Self.written : Color(nsColor: .textBackgroundColor)))
            context.stroke(circle, with: .color(Self.written), lineWidth: 1.8)
        }
    }

    /// Os pontos de arrastar de cada tipo: (qual, instante 0–60, altura).
    private static func handles(_ form: BendForm) -> [(Handle, Double, Double)] {
        let pre = Double(form.pre), top = Double(form.top), end = Double(form.end)
        return switch form.kind {
        case .bend: [(.start, form.start, 0), (.arrive, form.arrive, top)]
        case .bendRelease: [(.start, form.start, 0), (.arrive, form.arrive, top), (.hold, form.hold, top),
                            (.back, form.back, end)]
        case .release, .prebendRelease: [(.start, form.start, pre), (.arrive, form.arrive, end)]
        case .prebend: [(.level, 30, pre)]
        case .prebendBend: [(.start, form.start, pre), (.arrive, form.arrive, top)]
        }
    }

    /// Arrastar um ponto: o instante na grade de 1/12 da nota e a altura em quartos de tom (a do começo do bend e da
    /// volta que vem ligada não mudam pela altura).
    private func drag(_ base: BendForm, at value: DragGesture.Value, top: Double, plot: CGRect) {
        let form = draft ?? base
        if handle == nil {
            let near = Self.handles(form).map { item -> (Handle, Double) in
                let center = CGPoint(x: plot.minX + item.1 / 60 * plot.width,
                                     y: plot.maxY - min(item.2, top) / top * plot.height)
                return (item.0, hypot(center.x - value.startLocation.x, center.y - value.startLocation.y))
            }
            .min { $0.1 < $1.1 }
            guard let near, near.1 < 18 else { return }
            handle = near.0
        }
        guard let handle else { return }
        let offset = ((value.location.x - plot.minX) / plot.width * 60 / BendForm.step).rounded() * BendForm.step
        let q = Int(((plot.maxY - value.location.y) / plot.height * top).rounded())
        var next = form
        switch handle {
        case .start:
            next.start = offset
            if form.kind == .prebendBend || form.kind == .prebendRelease { next.pre = q }
        case .arrive:
            next.arrive = offset
            if form.kind.usesTop { next.top = q } else { next.end = q }
        case .hold:
            next.hold = offset
            next.top = q
        case .back:
            next.back = offset
            next.end = q
        case .level:
            next.pre = q
        }
        draft = next.valid()
    }

    /// Os instantes em % da nota.
    private func times(_ form: BendForm) -> String {
        let pct = { (offset: Double) in "\(Int((offset / 60 * 100).rounded())) %" }
        return switch form.kind {
        case .bend, .prebendBend: "começa \(pct(form.start)) · chega \(pct(form.arrive))"
        case .bendRelease: "sobe \(pct(form.start))–\(pct(form.arrive)) · volta \(pct(form.hold))–\(pct(form.back))"
        case .release, .prebendRelease: "volta \(pct(form.start))–\(pct(form.arrive))"
        case .prebend: "segura a nota toda"
        }
    }
}
