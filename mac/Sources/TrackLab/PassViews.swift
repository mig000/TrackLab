import SwiftUI
import TrackLabCore

/// Antes dos números: como foi a volta (ou as voltas), na opinião de quem tocou. Os números só aparecem depois.
struct SelfRating: View {
    let question: String
    let choose: (String) -> Void

    static let choices = ["Bem", "Mais ou menos", "Mal"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question).font(.callout.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(Self.choices, id: \.self) { choice in
                    Button(choice) { choose(choice) }.frame(maxWidth: .infinity)
                }
            }
            Text("Os números vêm depois: primeiro o ouvido.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A nota de uma volta em uma linha: a fração no tempo e na altura, a barra e o que mais pesou.
struct PassSummary: View {
    let score: PassScore
    var rating: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int((score.share * 100).rounded())) %").font(.system(size: 22, weight: .bold).monospacedDigit())
                    .foregroundStyle(score.clean ? Color.green : score.share >= 0.6 ? Color.orange : Color.red)
                Text("\(score.good) de \(score.total) notas no tempo e na altura").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if score.clean { Label("Limpo", systemImage: "checkmark.seal.fill").font(.caption.weight(.semibold)).foregroundStyle(.green) }
            }
            let parts = [NoteVerdict.early, .late, .wrongPitch, .missed].compactMap { verdict -> String? in
                let count = score.count(verdict)
                return count > 0 ? "\(count) \(verdict.label)" : nil
            }
            if !parts.isEmpty { Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            if let rating { Text("Você achou: \(rating.lowercased())").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// Os lugares a treinar (os dois compassos com mais erro), cada um com "Loop aqui".
struct PassTroubles: View {
    let model: SongModel
    let score: PassScore

    var body: some View {
        let troubles = score.troubles
        if troubles.isEmpty {
            Text("Nenhum compasso com erro.").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(troubles, id: \.bar) { trouble in
                HStack(spacing: 6) {
                    Image(systemName: "scope").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Compasso \(trouble.bar)").font(.caption.weight(.semibold))
                        Text(trouble.text).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Loop aqui") { model.loopOnBar(trouble.bar) }
                }
            }
        }
    }
}

/// Onde caíram os ataques em relação ao escrito: barras de 10 ms de −80 a +80 ms, o zero no meio, e a mediana.
struct TimingHistogram: View {
    let offsets: [Double]

    static let bucket = 0.01
    static let reach = 0.08

    var body: some View {
        let count = Int((Self.reach * 2 / Self.bucket).rounded())
        var buckets = Array(repeating: 0, count: count)
        for offset in offsets {
            let index = Int(((offset + Self.reach) / Self.bucket).rounded(.down))
            buckets[min(count - 1, max(0, index))] += 1
        }
        let top = max(1, buckets.max() ?? 1)
        let sorted = offsets.sorted()
        let median = sorted.isEmpty ? nil : sorted[sorted.count / 2]
        return VStack(alignment: .leading, spacing: 3) {
            GeometryReader { proxy in
                let width = proxy.size.width / Double(count)
                ZStack(alignment: .bottomLeading) {
                    ForEach(0..<count, id: \.self) { index in
                        let center = -Self.reach + (Double(index) + 0.5) * Self.bucket
                        let inside = abs(center) <= PassScore.timing
                        Rectangle()
                            .fill(inside ? Color.green.opacity(0.7) : Color.orange.opacity(0.7))
                            .frame(width: max(1, width - 1), height: proxy.size.height * Double(buckets[index]) / Double(top))
                            .offset(x: Double(index) * width)
                    }
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 1, height: proxy.size.height)
                        .offset(x: proxy.size.width / 2)
                }
            }
            .frame(height: 34)
            HStack {
                Text("cedo").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if let median {
                    let ms = Int((median * 1000).rounded())
                    Text(abs(ms) < 8 ? "no tempo (mediana \(ms) ms)" : ms < 0 ? "adiantado \(-ms) ms" : "atrasado \(ms) ms")
                        .font(.caption2.weight(.medium))
                }
                Spacer()
                Text("tarde").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Onde caíram os ataques")
    }
}

/// Gravar, depois das voltas: como foram (antes dos números), a nota de cada take da gravação, os lugares a treinar,
/// onde caíram os ataques e o que ouvir (você na banda, o disco, ou alternando).
struct TakeReviewGroup: View {
    let model: SongModel

    var body: some View {
        let batch = model.studio.takes.filter { model.takeBatch.contains($0.id) }
        if !batch.isEmpty, !model.studio.recording {
            let scored = batch.compactMap { take in model.takeScores[take.id].map { (take: take, score: $0) } }
            let chosen = scored.first(where: \.take.active) ?? scored.max { $0.score.share < $1.score.share }
            InspectorGroup("Depois das voltas", summary: chosen.map { "\($0.take.name) · \(Int(($0.score.share * 100).rounded())) %" },
                           key: "rec.review") {
                if scored.count < batch.count {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Ouvindo as voltas… \(scored.count) de \(batch.count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.takeRating == nil {
                    SelfRating(question: batch.count > 1 ? "Soa a melhor volta. Como foram?" : "Como foi?") {
                        model.takeRating = $0
                    }
                } else if let chosen {
                    PassSummary(score: chosen.score, rating: model.takeRating)
                    if scored.count > 1 {
                        ForEach(scored.sorted { $0.score.share > $1.score.share }, id: \.take.id) { item in
                            Button { model.chooseTake(item.take.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: item.take.active ? "largecircle.fill.circle" : "circle")
                                    Text(item.take.name).font(.caption)
                                    GeometryReader { proxy in
                                        Capsule().fill(Color.secondary.opacity(0.15))
                                            .overlay(alignment: .leading) {
                                                Capsule().fill(item.score.clean ? Color.green : Color.orange)
                                                    .frame(width: proxy.size.width * item.score.share)
                                            }
                                    }
                                    .frame(height: 5)
                                    Text("\(Int((item.score.share * 100).rounded())) %").font(.caption.monospacedDigit())
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Divider()
                    PassTroubles(model: model, score: chosen.score)
                    TimingHistogram(offsets: chosen.score.offsets)
                }
                Divider()
                Picker("Ouvir", selection: Binding(get: { model.bandListen }, set: { model.applyBandListen($0) })) {
                    ForEach(BandListen.allCases) { choice in Text(choice.label).tag(choice) }
                }
                .help("Você na banda: o take escolhido no lugar da guitarra do disco. O disco: a música como é. "
                      + "Alternar: uma volta cada, para comparar.")
                if let chosen {
                    Button("Exportar o \(chosen.take.name)…") { model.exportTake(chosen.take.id) }
                }
            }
        }
    }
}
