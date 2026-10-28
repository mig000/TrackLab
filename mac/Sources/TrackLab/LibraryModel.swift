import Foundation
import Observation
import TrackLabCore

/// O repertório (as músicas do motor) e as importações do Songsterr em curso.
@Observable
@MainActor
final class LibraryModel {
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
