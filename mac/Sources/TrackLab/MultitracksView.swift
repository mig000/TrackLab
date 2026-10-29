import SwiftUI
import TrackLabCore

/// A biblioteca de multitracks: as músicas com as faixas da gravação, achadas pelo índice do motor (sem acento, pelo
/// começo das palavras). Daqui elas se consultam; as faixas entram numa música pelo mixer dela (Melhorar as faixas).
struct MultitracksView: View {
    let library: LibraryModel
    @Local private var text = ""
    @Local private var results: [MultitrackSong] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            TextField("Título, artista ou álbum", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .onChange(of: text) { Task { await search() } }
            if results.isEmpty {
                Text(text.isEmpty ? "Digite para procurar na biblioteca." : "Nada encontrado.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(results) { song in row(song) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await library.refreshMultitracks() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Multitracks").font(.largeTitle.weight(.bold))
                if let status = library.multitrackStatus {
                    Text(summary(status)).foregroundStyle(status.available ? Color.secondary : Color.orange)
                }
            }
            Spacer()
            if let indexing = library.indexing {
                ProgressView().controlSize(.small)
                Text(indexing).font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Indexar a biblioteca") { Task { await library.indexMultitracks() } }
                    .disabled(library.multitrackStatus?.available != true)
                    .help("Lê a biblioteca inteira de novo; no HD externo leva alguns minutos")
            }
        }
    }

    private func summary(_ status: MultitrackStatus) -> String {
        var parts = ["\(status.count) músicas", status.root]
        if let scanned = status.scanned, let date = ISO8601DateFormatter().date(from: scanned) {
            parts.append("indexada em \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        if !status.available { parts.append("HD desligado") }
        return parts.joined(separator: " · ")
    }

    private func row(_ song: MultitrackSong) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(song.title).fontWeight(.medium)
            Text([song.artist, song.album, song.year].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Text((song.instruments.isEmpty ? ["faixas num arquivo só"] : song.instruments).joined(separator: " · ")
                + " — \(song.formatLabel), \(song.collection)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func search() async {
        let query = text
        let found = (try? await Backend.shared.searchMultitracks(query)) ?? []
        if query == text { results = found }
    }
}
