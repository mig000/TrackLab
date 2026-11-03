import Foundation
import Security
import TrackLabCore
import SwiftUI

/// A chave da API do MVSEP nas Chaves do macOS (serviço "TrackLab"). O app a lê só na hora de enviar uma música e a
/// passa ao motor no cabeçalho daquele pedido; ela nunca vai para um arquivo do TrackLab.
enum MVSEPKey {
    private static let service = "TrackLab"
    private static let account = "mvsep-api-key"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Se há uma chave guardada, sem ler o segredo (assim o macOS não pede permissão): só os atributos.
    static var isSaved: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(match as CFDictionary)
        guard !clean.isEmpty else { return true }
        var item = match
        item[kSecValueData as String] = Data(clean.utf8)
        item[kSecAttrLabel as String] = "TrackLab — chave da API do MVSEP"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

/// TrackLab › Ajustes (⌘,): a chave do MVSEP.
struct SettingsView: View {
    @Local private var key = ""
    @Local private var saved = MVSEPKey.isSaved
    @Local private var message: String?

    var body: some View {
        Form {
            Section {
                SecureField("Chave da API", text: $key, prompt: Text(saved ? "guardada nas Chaves do macOS" : "cole aqui"))
                HStack {
                    Button("Guardar") {
                        let ok = MVSEPKey.save(key)
                        saved = MVSEPKey.isSaved
                        message = ok ? (saved ? "Guardada nas Chaves do macOS." : "Chave apagada.") : "Não consegui guardar."
                        key = ""
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    if saved {
                        Button("Apagar") {
                            MVSEPKey.save("")
                            saved = MVSEPKey.isSaved
                            message = "Chave apagada."
                        }
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
            } header: {
                Text("MVSEP")
            } footer: {
                Text("A chave fica em mvsep.com, na sua conta (API). O TrackLab a usa só quando você pede a guitarra do "
                     + "MVSEP de uma música; cada pedido gasta uma das conversões do dia.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LibrarySection()
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}

/// A biblioteca (3/11): a pasta das músicas, num disco escolhido; mudar move as músicas para lá.
private struct LibrarySection: View {
    @Local private var info: LibraryInfo?
    @Local private var status: String?
    @Local private var moving = false

    var body: some View {
        Section {
            if let info {
                LabeledContent("Pasta") {
                    Text(info.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                LabeledContent("Disco", value: info.volume)
                LabeledContent("Músicas", value: "\(info.songs) · \(Self.size(info.bytes))")
                LabeledContent("Livre no disco", value: Self.size(info.free))
            } else {
                Text(status ?? "Lendo…").foregroundStyle(.secondary)
            }
            HStack {
                Button("Mostrar no Finder") {
                    if let path = info?.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                .disabled(info == nil)
                Button("Mover para outra pasta…") { choose() }
                    .disabled(info == nil || moving)
            }
            if let status, info != nil { Text(status).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text("Biblioteca")
        } footer: {
            Text("Cada música é uma pasta com a partitura, o áudio em MP3, as faixas e o que você estudou. Para um "
                 + "backup, copie esta pasta. Mover copia cada música, confere a cópia e só então apaga a original.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await load() }
    }

    private func load() async {
        do { info = try await Backend.shared.library() } catch { status = error.localizedDescription }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Mover para cá"
        panel.message = "Escolha a pasta da biblioteca (por exemplo, uma pasta TrackLab no disco das multitracks)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await move(to: url.path) }
    }

    private func move(to path: String) async {
        moving = true
        defer { moving = false }
        // A música aberta fecha antes (grava o que estava a caminho e solta os arquivos).
        NotificationCenter.default.post(name: .libraryWillMove, object: nil)
        status = "Fechando a música aberta…"
        try? await Task.sleep(for: .seconds(2))
        do {
            let ticket = try await Backend.shared.moveLibrary(to: path)
            while true {
                try await Task.sleep(for: .milliseconds(500))
                let job = try await Backend.shared.job(ticket.id)
                status = job.last?.message ?? "Movendo…"
                guard job.finished else { continue }
                status = job.status == "done" ? "Biblioteca movida." : (job.error ?? "Não deu para mover.")
                break
            }
        } catch {
            status = error.localizedDescription
        }
        await load()
        NotificationCenter.default.post(name: .libraryMoved, object: nil)
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
