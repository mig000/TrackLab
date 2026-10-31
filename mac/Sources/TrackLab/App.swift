import AppKit
import SwiftUI
import TrackLabCore

/// Com só as Command Line Tools, o `@State` vira macro sem plugin: o estado das views usa o property wrapper por
/// este nome, como no KaraokeLab e no TabLab.
typealias Local<Value> = SwiftUI.State<Value>

@main
struct TrackLabApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    /// A aparência do app (Visualizar › Aparência): a do sistema, clara (papel: a TAB preta e a Lente em tinta) ou
    /// escura.
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup("TrackLab") {
            RootView()
                .frame(minWidth: 980, minHeight: 640)
                .onChange(of: appearance, initial: true) { Self.apply(appearance) }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Importar do Songsterr…") { NotificationCenter.default.post(name: .importSong, object: nil) }
                    .keyboardShortcut("n")
            }
            // A música aberta decide: o ajuste do mapa, ou o Desfazer de sempre (os campos de texto).
            CommandGroup(after: .toolbar) {
                Button("Aproximar") { NotificationCenter.default.post(name: .zoomIn, object: nil) }
                    .keyboardShortcut("+")
                Button("Afastar") { NotificationCenter.default.post(name: .zoomOut, object: nil) }
                    .keyboardShortcut("-")
                Button("TAB em páginas ou na faixa") { NotificationCenter.default.post(name: .togglePage, object: nil) }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Mostrar ou esconder a onda") { NotificationCenter.default.post(name: .toggleWave, object: nil) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Mostrar ou esconder a lente") { NotificationCenter.default.post(name: .toggleLens, object: nil) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Picker("Aparência", selection: $appearance) {
                    Text("Do sistema").tag("system")
                    Text("Clara (papel)").tag("light")
                    Text("Escura").tag("dark")
                }
                // ⌥⌘M: ⌘M é o Minimizar do macOS.
                Button("Mostrar ou esconder o mixer") { NotificationCenter.default.post(name: .toggleMixer, object: nil) }
                    .keyboardShortcut("m", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Desfazer") { NotificationCenter.default.post(name: .undoTempo, object: nil) }
                    .keyboardShortcut("z")
                Button("Refazer") { NotificationCenter.default.post(name: .redoTempo, object: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                Divider()
                Button("Corrigir a TAB pelo som") { NotificationCenter.default.post(name: .correctBySound, object: nil) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Sincronizar o mapa pelo som") { NotificationCenter.default.post(name: .syncBySound, object: nil) }
            }
        }
        Settings { SettingsView() }
    }
}

extension Notification.Name {
    static let importSong = Notification.Name("TrackLab.importSong")
    static let undoTempo = Notification.Name("TrackLab.undoTempo")
    static let zoomIn = Notification.Name("TrackLab.zoomIn")
    static let zoomOut = Notification.Name("TrackLab.zoomOut")
    static let toggleMixer = Notification.Name("TrackLab.toggleMixer")
    static let toggleWave = Notification.Name("TrackLab.toggleWave")
    static let togglePage = Notification.Name("TrackLab.togglePage")
    static let toggleLens = Notification.Name("TrackLab.toggleLens")
    static let redoTempo = Notification.Name("TrackLab.redoTempo")
    static let correctBySound = Notification.Name("TrackLab.correctBySound")
    static let syncBySound = Notification.Name("TrackLab.syncBySound")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Também um app comum quando roda por `swift run`, fora de um bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Antes de sair, a música grava o que estava a caminho (a edição da TAB que a página ainda não mandou, os
    /// trechos): o motor sai com o app, então espera essas gravações (alguns décimos de segundo; no máximo 5 s).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            Task { @MainActor in
                await SongModel.finishAll()
                self.replyOnce(sender)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self.replyOnce(sender)
            }
        }
        return .terminateLater
    }

    private var replied = false

    @MainActor private func replyOnce(_ sender: NSApplication) {
        guard !replied else { return }
        replied = true
        sender.reply(toApplicationShouldTerminate: true)
    }

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
        // ⌘Z e ⇧⌘Z do menu Editar: o ajuste do mapa da música aberta, se houver o que desfazer; senão o Desfazer de
        // sempre, pela cadeia de respondedores (os campos de texto).
        .onReceive(NotificationCenter.default.publisher(for: .undoTempo)) { _ in
            if let song, song.canUndoAny { song.undoAny() } else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .redoTempo)) { _ in
            if let song, song.canRedoAny { song.redoAny() } else { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importSong)) { _ in
            if phase == .ready { importing = true }
        }
        .sheet(isPresented: $importing, onDismiss: { library.importFrom = nil }) {
            ImportSheet(library: library, multitrack: library.importFrom)
        }
    }

    private var split: some View {
        NavigationSplitView {
            Sidebar(library: library, importing: $importing)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if library.selection == LibraryModel.today {
                TodayView(library: library, importing: $importing)
            } else if library.selection == LibraryModel.multitracks {
                MultitracksView(library: library)
            } else if library.selection == LibraryModel.sections {
                SectionsView(library: library)
            } else if let song {
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
            await library.refreshMultitracks()
            // O app abre no que tocar hoje.
            if library.selection == nil { library.selection = LibraryModel.today }
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func open(_ id: String?) {
        let section = library.pendingSection
        library.pendingSection = nil
        if let song, id == song.id {
            if let section, let found = song.sections.first(where: { $0.id == section }) { song.activate(found) }
            return
        }
        song?.close()
        song = nil
        guard let id, !LibraryModel.pages.contains(id) else { return }
        let model = SongModel(id: id)
        model.startSection = section
        let library = library
        model.onStudyChange = { Task { await library.refresh() } }
        song = model
        SongModel.opened = model
        Task { await model.load() }
    }
}

private struct Sidebar: View {
    let library: LibraryModel
    @Binding var importing: Bool

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { library.selection }, set: { library.selection = $0 })) {
                Label("Para hoje", systemImage: "sun.max")
                    .badge(library.today.count)
                    .tag(LibraryModel.today)
                Label("Trechos", systemImage: "bookmark")
                    .badge(library.sectionItems.count)
                    .tag(LibraryModel.sections)
                if !library.imports.isEmpty {
                    Section("Importando") {
                        ForEach(library.imports) { item in ImportRow(library: library, item: item) }
                    }
                }
                ForEach(library.grouped, id: \.status) { group in
                    Section(group.status.label) {
                        ForEach(group.songs) { song in SongRow(song: song).tag(song.id) }
                    }
                }
                Section("Fontes") {
                    Label("Multitracks", systemImage: "square.stack.3d.up")
                        .badge(library.multitrackStatus?.count ?? 0)
                        .tag(LibraryModel.multitracks)
                }
            }
            .searchable(text: Binding(get: { library.search }, set: { library.search = $0 }), placement: .sidebar,
                        prompt: "Título, artista, afinação, trecho")
            if let error = library.loadError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
            Divider()
            Picker("Coleção", selection: Binding(get: { library.collection }, set: { library.collection = $0 })) {
                ForEach(library.collections, id: \.self) { collection in Text(collection.label).tag(collection) }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            Button { importing = true } label: {
                Label("Importar do Songsterr", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }
}

private struct SongRow: View {
    let song: SongSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(song.displayTitle).lineLimit(1)
            HStack(spacing: 4) {
                Text([song.artist, song.tuningName == "Padrão" ? nil : song.tuningName].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                if !song.stems.isEmpty { Image(systemName: "slider.vertical.3").help("Faixas separadas") }
                if !song.hasAudio { Image(systemName: "speaker.slash").help("Sem áudio") }
                if song.needsSync {
                    Image(systemName: "metronome").help("Sincronização a conferir: \(song.checked) de \(song.measures ?? 0) compassos")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

extension TrackLabApp {
    /// A aparência escolhida em todo o app (a página da partitura e a Lente seguem o esquema de cores da janela).
    static func apply(_ appearance: String) {
        NSApp.appearance = switch appearance {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }
}
