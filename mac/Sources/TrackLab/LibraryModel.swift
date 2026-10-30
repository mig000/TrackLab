import Foundation
import Observation
import TrackLabCore

/// O repertório (as músicas do motor, por estado, com busca e coleções), o Para hoje e as importações em curso.
@Observable
@MainActor
final class LibraryModel {
    /// A seleção da barra lateral que mostra o Para hoje em vez de uma música.
    static let today = "today"
    /// A seleção que mostra a biblioteca de multitracks.
    static let multitracks = "multitracks"
    /// A seleção que mostra a biblioteca de trechos (todos os trechos de todas as músicas).
    static let sections = "sections"

    /// As seleções que não são músicas.
    static let pages: Set<String> = [today, multitracks, sections]

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

    /// Todos os trechos de todas as músicas, para a biblioteca de trechos.
    var sectionItems: [SectionItem] { SectionLibrary.items(songs) }

    /// O índice de multitracks e a varredura em curso (a mensagem da fila).
    private(set) var multitrackStatus: MultitrackStatus?
    private(set) var indexing: String?

    func refreshMultitracks() async {
        multitrackStatus = try? await Backend.shared.multitrackStatus()
    }

    /// Refaz o índice da biblioteca de multitracks, na fila do motor; leva minutos no HD externo.
    func indexMultitracks() async {
        guard indexing == nil else { return }
        do {
            let ticket = try await Backend.shared.scanMultitracks()
            indexing = "Na fila…"
            while true {
                try await Task.sleep(for: .seconds(1))
                let job = try await Backend.shared.job(ticket.id)
                indexing = job.last?.message ?? "Lendo a biblioteca…"
                guard job.finished else { continue }
                indexing = nil
                if job.status == "error" { loadError = job.error ?? "A indexação dos multitracks falhou." }
                await refreshMultitracks()
                return
            }
        } catch {
            indexing = nil
            loadError = error.localizedDescription
        }
    }

    var collections: [Collection] {
        [.all, .needsSync] + Set(songs.map(\.tuningName)).sorted().map { .tuning($0) }
    }

    /// As músicas da coleção e da busca (título, artista, afinação, trecho), por estado.
    var grouped: [(status: StudyStatus, songs: [SongSummary])] {
        let shown = songs.filter { song in
            switch collection {
            case .all: break
            case .needsSync: if !song.needsSync { return false }
            case let .tuning(name): if song.tuningName != name { return false }
            }
            return LibrarySearch.matches(song, search)
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

    /// Abre a música do trecho com o loop dele ligado.
    func open(_ item: SectionItem) {
        pendingSection = item.section.id
        selection = item.songID
    }

    /// Muda um trecho direto da biblioteca (tipo, etiquetas, favorito): a música manda a lista inteira de volta, e o
    /// motor mantém o treino de cada trecho pelo id.
    func edit(_ item: SectionItem, _ change: (inout StudySection) -> Void) {
        guard let song = songs.first(where: { $0.id == item.songID }) else { return }
        let list = song.sections.map { section -> StudySection in
            guard section.id == item.section.id else { return section }
            var copy = section
            change(&copy)
            return copy
        }
        Task {
            do {
                _ = try await Backend.shared.putSections(song.id, list)
                await refresh()
            } catch {
                loadError = error.localizedDescription
            }
        }
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
