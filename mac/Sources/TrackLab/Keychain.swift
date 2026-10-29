import Foundation
import Security
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
