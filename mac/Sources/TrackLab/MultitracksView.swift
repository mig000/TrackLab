import SwiftUI
import TrackLabCore

/// A biblioteca de multitracks: as músicas com as faixas da gravação, achadas pelo índice do motor (sem acento, pelo
/// começo das palavras). "Procurar a TAB" abre a busca do Songsterr com o nome dela, e a música importada nasce com as
/// faixas dela; numa música que já existe, elas entram pelo mixer (Melhorar as faixas). Uma que não serve (uma
/// regravação, uma cópia repetida) pode ser escondida: some da busca daqui e da do Songsterr, e os arquivos ficam no HD;
/// "Escondidas" mostra as escondidas para trazê-las de volta.
struct MultitracksView: View {
    let library: LibraryModel
    @Local private var text = ""
    @Local private var results: [MultitrackSong] = []
    @Local private var showHidden = false
    @Local private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(spacing: 10) {
                TextField("Título, artista ou álbum", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                    .onChange(of: text) { Task { await search() } }
                Toggle(isOn: $showHidden) {
                    Label("Escondidas \(library.multitrackStatus?.hidden ?? 0)", systemImage: "eye.slash")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .onChange(of: showHidden) { Task { await search() } }
                .help("Mostra as multitracks escondidas, para trazê-las de volta à biblioteca")
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
            }
            if results.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary)
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
        if let hidden = status.hidden, hidden > 0 { parts[0] += " (\(hidden) escondida\(hidden == 1 ? "" : "s"))" }
        if let scanned = status.scanned, let date = ISO8601DateFormatter().date(from: scanned) {
            parts.append("indexada em \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        if !status.available { parts.append("HD desligado") }
        return parts.joined(separator: " · ")
    }

    private var emptyMessage: String {
        if !text.isEmpty { return "Nada encontrado." }
        return showHidden ? "Nenhuma multitrack escondida." : "Digite para procurar na biblioteca."
    }

    private func row(_ song: MultitrackSong) -> some View {
        HStack {
            details(song)
            Spacer()
            if song.isHidden {
                Button { Task { await hide(song, false) } } label: { Label("Mostrar de novo", systemImage: "eye") }
                    .help("Volta para a biblioteca: a busca daqui e a do Songsterr passam a achá-la")
            } else {
                Button { Task { await hide(song, true) } } label: { Label("Esconder", systemImage: "eye.slash") }
                    .help("Esconde da biblioteca: some desta busca e da do Songsterr, e o mixer não a oferece mais. "
                        + "Os arquivos ficam no HD; Escondidas a traz de volta")
                Button("Procurar a TAB") {
                    library.importFrom = song
                    NotificationCenter.default.post(name: .importSong, object: nil)
                }
                .help("Procura a música no Songsterr; ao importar, ela vem com as faixas desta multitrack alinhadas ao vídeo")
            }
        }
        .opacity(song.isHidden ? 0.6 : 1)
        .contextMenu {
            Button(song.isHidden ? "Mostrar de novo na biblioteca" : "Esconder da biblioteca") {
                Task { await hide(song, !song.isHidden) }
            }
        }
    }

    private func hide(_ song: MultitrackSong, _ hidden: Bool) async {
        do {
            try await Backend.shared.setMultitrackHidden(song.path, hidden)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        await library.refreshMultitracks()
        await search()
    }

    private func details(_ song: MultitrackSong) -> some View {
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

    /// A busca (com as escondidas, marcadas, se pedidas); sem texto, com "Escondidas", a lista delas.
    private func search() async {
        let query = text, hidden = showHidden
        let found: [MultitrackSong]
        if query.isEmpty && hidden {
            found = (try? await Backend.shared.hiddenMultitracks()) ?? []
        } else {
            found = (try? await Backend.shared.searchMultitracks(query, hidden: hidden)) ?? []
        }
        if query == text, hidden == showHidden { results = found }
    }
}
