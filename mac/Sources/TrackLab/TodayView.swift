import SwiftUI
import TrackLabCore

/// Para hoje: a tela em que o app abre. Os trechos perto da meta, os esquecidos há dias, os ainda sem recorde, a
/// revisão do repertório e as músicas novas já conferidas; um clique abre a música no trecho.
struct TodayView: View {
    let library: LibraryModel
    @Binding var importing: Bool

    var body: some View {
        let items = library.today
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Para hoje").font(.largeTitle.weight(.bold))
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .foregroundStyle(.secondary)
                }
                if items.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(items) { item in
                            Button { library.open(item) } label: { TodayCard(item: item) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nada para hoje ainda.").font(.headline)
            Text("Escolha uma música, mude o estado para Aprendendo e marque os trechos que quer treinar: eles aparecem "
                + "aqui pelo que está perto da meta, esquecido há dias ou ainda sem recorde.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520, alignment: .leading)
            if library.songs.isEmpty {
                Button("Importar do Songsterr…") { importing = true }
            }
        }
    }
}

private struct TodayCard: View {
    let item: TodayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.reason).font(.caption).foregroundStyle(.secondary)
            Text(item.title).font(.headline).lineLimit(2)
            if let goal = item.goal {
                ProgressView(value: Double(min(item.best ?? 0, goal)), total: Double(goal))
                    .tint(.orange)
                HStack {
                    Text(item.best.map { "limpo \($0) %" } ?? "ainda sem recorde")
                    Spacer()
                    Text("meta \(goal) %")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            } else if !item.detail.isEmpty {
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
        .contentShape(Rectangle())
    }
}
