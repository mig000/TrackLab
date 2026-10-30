import SwiftUI
import TrackLabCore

/// Importar do Songsterr: cole o link da música ou pesquise por nome. A importação corre no motor (partitura, áudio
/// do vídeo vinculado, mapa de tempo, separação) e o progresso aparece na barra lateral.
struct ImportSheet: View {
    let library: LibraryModel
    /// Vindo de Fontes › Multitracks: a busca abre com o artista e o título dela e a música entra com as faixas dela.
    var multitrack: MultitrackSong?
    @Environment(\.dismiss) private var dismiss
    @Local private var text = ""
    @Local private var results: [SearchResult] = []
    @Local private var searching = false
    @Local private var error: String?

    private var isLink: Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("songsterr.com/") || (!value.isEmpty && value.allSatisfy(\.isNumber))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Importar do Songsterr").font(.title3.weight(.semibold))
            if let multitrack {
                Label("Com as faixas da multitrack: \(multitrack.instruments.joined(separator: ", ")) "
                      + "(\(multitrack.formatLabel), \(multitrack.collection))", systemImage: "square.stack.3d.up")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            HStack {
                TextField("Link do Songsterr ou nome da música", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button(isLink ? "Importar" : "Pesquisar", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).count < 2 && !isLink)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if searching {
                ProgressView().frame(maxWidth: .infinity)
            }
            List(results) { result in
                HStack {
                    VStack(alignment: .leading) {
                        Text(result.title)
                        Text("\(result.artist) · \(result.tracks) pistas").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let multitrack = result.multitrack {
                        Text("Multitrack")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.15)))
                            .help("Na biblioteca de multitracks: \(multitrack.instruments.joined(separator: ", ")) "
                                + "(\(multitrack.formatLabel), \(multitrack.collection))")
                    }
                    Button("Importar") { start(String(result.id), title: "\(result.artist) — \(result.title)") }
                }
            }
            .frame(minHeight: 260)
            HStack {
                Text(multitrack.map { $0.format == "mogg" }.map { $0
                    ? "A música entra com as faixas separadas na GPU e depois as do .mogg, reconhecidas por elas e alinhadas ao vídeo."
                    : "A música entra com a partitura, o áudio do vídeo do Songsterr e as faixas da multitrack alinhadas a ele." }
                    ?? "A música entra com a partitura, o áudio do vídeo do Songsterr e as faixas separadas na GPU.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Fechar") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            // Da multitrack: a busca já vai com o nome dela.
            guard let multitrack, text.isEmpty else { return }
            text = [multitrack.artist, multitrack.title].compactMap { $0 }.joined(separator: " ")
            submit()
        }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLink {
            start(value, title: value)
            return
        }
        guard value.count >= 2 else { return }
        searching = true
        error = nil
        Task {
            defer { searching = false }
            do {
                results = try await Backend.shared.search(value)
                if results.isEmpty { error = "Nada encontrado para “\(value)”." }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func start(_ reference: String, title: String) {
        let multitrack = multitrack
        Task { await library.importSong(reference, title: title, multitrack: multitrack) }
        dismiss()
    }
}
