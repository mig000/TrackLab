import Foundation
import Observation
import TrackLabCore

/// O repertório (as músicas do motor, por estado, com busca e coleções), o Para hoje e as importações em curso.
@Observable
@MainActor
final class LibraryModel {
    /// A seleção da barra lateral que mostra o Para hoje em vez de uma música.
    static let today = "today"

    /// As coleções da barra lateral: todas, as que falta conferir a sincronização, uma afinação.
    enum Collection: Hashable {
        case all
        case needsSync
        case tuning(String)

        var label: String {
            switch self {
            case .all: "Todas"
            case .needsSync: "Sincronização a conferir"
            case let .tuning(name): name
            }
        }
    }

    struct Importing: Identifiable, Equatable {
        let id: String
        var title: String
        var message: String
        var progress: Double?
        var error: String?
        var done = false
    }

    private(set) var songs: [SongSummary] = []
    private(set) var loadError: String?
    private(set) var imports: [Importing] = []
    var selection: String?
    var search = ""
    var collection = Collection.all
    /// O trecho a abrir na próxima música selecionada (um item do Para hoje).
    var pendingSection: String?

    var today: [TodayItem] { TodayPlan.items(songs) }

    var collections: [Collection] {
        [.all, .needsSync] + Set(songs.map(\.tuningName)).sorted().map { .tuning($0) }
    }

    /// As músicas da coleção e da busca (título, artista, afinação, trecho), por estado.
    var grouped: [(status: StudyStatus, songs: [SongSummary])] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let shown = songs.filter { song in
            switch collection {
            case .all: break
            case .needsSync: if !song.needsSync { return false }
            case let .tuning(name): if song.tuningName != name { return false }
            }
            let text = ([song.displayTitle, song.artist ?? "", song.tuningName, song.status.label] + song.sections.map(\.name))
                .joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
        return StudyStatus.allCases.compactMap { status in
            let list = shown.filter { $0.status == status }
            return list.isEmpty ? nil : (status, list)
        }
    }

    /// Abre a música de um item do Para hoje, já no trecho dele.
    func open(_ item: TodayItem) {
        pendingSection = item.sectionID
        selection = item.songID
    }

    func refresh() async {
        do {
            songs = try await Backend.shared.songs().sorted {
                ($0.artist ?? "", $0.displayTitle) < ($1.artist ?? "", $1.displayTitle)
            }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Importa uma música do Songsterr (link ou número) e separa as faixas; quando termina, a seleciona.
    func importSong(_ reference: String, title: String) async {
        do {
            let ticket = try await Backend.shared.importSong(reference)
            imports.append(Importing(id: ticket.id, title: title, message: "Na fila…"))
            await follow(ticket.id)
        } catch {
            imports.append(Importing(id: UUID().uuidString, title: title, message: "", error: error.localizedDescription, done: true))
        }
    }

    private func follow(_ id: String) async {
        while true {
            do {
                try await Task.sleep(for: .milliseconds(500))
                let job = try await Backend.shared.job(id)
                update(id) {
                    $0.message = job.last?.message ?? "Importando…"
                    $0.progress = job.last?.progress
                }
                guard job.finished else { continue }
                update(id) {
                    $0.done = true
                    if job.status == "error" { $0.error = job.error ?? "A importação falhou." }
                    if job.status == "cancelled" { $0.error = "Importação cancelada." }
                    if let warning = job.result?.warning { $0.message = "Pronta, sem as faixas separadas: \(warning)" }
                }
                await refresh()
                if let song = job.result?.song { selection = song.id }
                if job.status == "done", job.result?.warning == nil { imports.removeAll { $0.id == id } }
                return
            } catch {
                update(id) {
                    $0.done = true
                    $0.error = error.localizedDescription
                }
                return
            }
        }
    }

    func cancel(_ id: String) {
        Task { try? await Backend.shared.cancel(id) }
    }

    func dismiss(_ id: String) {
        imports.removeAll { $0.id == id }
    }

    private func update(_ id: String, _ change: (inout Importing) -> Void) {
        guard let index = imports.firstIndex(where: { $0.id == id }) else { return }
        change(&imports[index])
    }
}
