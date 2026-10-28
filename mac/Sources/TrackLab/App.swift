import AppKit
import SwiftUI
import TrackLabCore

/// Com só as Command Line Tools, o `@State` vira macro sem plugin: o estado das views usa o property wrapper por
/// este nome, como no KaraokeLab e no TabLab.
typealias Local<Value> = SwiftUI.State<Value>

@main
struct TrackLabApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup("TrackLab") {
            RootView()
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Importar do Songsterr…") { NotificationCenter.default.post(name: .importSong, object: nil) }
                    .keyboardShortcut("n")
            }
        }
    }
}

extension Notification.Name {
    static let importSong = Notification.Name("TrackLab.importSong")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Também um app comum quando roda por `swift run`, fora de um bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Backend.shared.stop() }
    }
}

struct RootView: View {
    enum Phase: Equatable {
        case connecting
        case failed(String)
        case ready
    }

    @Local private var phase: Phase = .connecting
    @Local private var library = LibraryModel()
    @Local private var song: SongModel?
    @Local private var importing = false

    var body: some View {
        Group {
            switch phase {
            case .connecting:
                ProgressView("Iniciando o motor…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .failed(message):
                VStack(spacing: 12) {
                    Label("O motor do TrackLab não iniciou", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .multilineTextAlignment(.center).frame(maxWidth: 560)
                    Button("Tentar de novo") { Task { await connect() } }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                split
            }
        }
        .task { await connect() }
        .onReceive(NotificationCenter.default.publisher(for: .importSong)) { _ in
            if phase == .ready { importing = true }
        }
        .sheet(isPresented: $importing) { ImportSheet(library: library) }
    }

    private var split: some View {
        NavigationSplitView {
            Sidebar(library: library, importing: $importing)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let song {
                SongView(model: song).id(song.id)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "guitars").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text(library.songs.isEmpty ? "O repertório está vazio." : "Escolha uma música.")
                        .foregroundStyle(.secondary)
                    Button("Importar do Songsterr…") { importing = true }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: library.selection) { _, id in open(id) }
    }

    private func connect() async {
        phase = .connecting
        do {
            try await Backend.shared.connect()
            await library.refresh()
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func open(_ id: String?) {
        guard id != song?.id else { return }
        song?.close()
        song = nil
        guard let id else { return }
        let model = SongModel(id: id)
        song = model
        Task { await model.load() }
    }
}

private struct Sidebar: View {
    let library: LibraryModel
    @Binding var importing: Bool

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { library.selection }, set: { library.selection = $0 })) {
                if !library.imports.isEmpty {
                    Section("Importando") {
                        ForEach(library.imports) { item in ImportRow(library: library, item: item) }
                    }
                }
                Section("Repertório") {
                    ForEach(library.songs) { song in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(song.displayTitle).lineLimit(1)
                            HStack(spacing: 4) {
                                Text(song.artist ?? "").lineLimit(1)
                                if !song.stems.isEmpty { Image(systemName: "slider.vertical.3").help("Faixas separadas") }
                                if !song.hasAudio { Image(systemName: "speaker.slash").help("Sem áudio") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .tag(song.id)
                    }
                }
            }
            if let error = library.loadError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
            Divider()
            Button { importing = true } label: {
                Label("Importar do Songsterr", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}

private struct ImportRow: View {
    let library: LibraryModel
    let item: LibraryModel.Importing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(item.title).lineLimit(1)
                Spacer()
                if item.done {
                    Button { library.dismiss(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).help("Tirar da lista")
                } else {
                    Button { library.cancel(item.id) } label: { Image(systemName: "stop.circle") }
                        .buttonStyle(.borderless).help("Cancelar")
                }
            }
            if let error = item.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            } else {
                if !item.done { ProgressView(value: item.progress ?? 0).controlSize(.small) }
                Text(item.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .selectionDisabled()
    }
}
