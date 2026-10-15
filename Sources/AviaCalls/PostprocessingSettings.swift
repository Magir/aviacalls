import AviaCallsCore
import Combine
import Foundation
import Security

@MainActor
final class PostprocessingSettings: ObservableObject {
    @Published var model: String {
        didSet {
            defaults.set(model, forKey: "openRouterModel")
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { automatic = false }
        }
    }
    @Published var automatic: Bool { didSet { defaults.set(automatic, forKey: "glossaryAutomatic") } }
    @Published private(set) var glossaryName: String?
    @Published private(set) var entryCount = 0
    @Published private(set) var hasAPIKey: Bool
    @Published var problem: String?
    private let defaults: UserDefaults
    private let directory: URL
    private var glossaryURL: URL { directory.appendingPathComponent("glossary.csv") }

    init(defaults: UserDefaults = .standard,
         directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AviaCalls")) {
        self.defaults = defaults; self.directory = directory
        model = defaults.string(forKey: "openRouterModel") ?? ""
        automatic = defaults.bool(forKey: "glossaryAutomatic")
        hasAPIKey = defaults.bool(forKey: "openRouterKeySaved")
        glossaryName = defaults.string(forKey: "glossaryName")
        if FileManager.default.fileExists(atPath: glossaryURL.path) {
            do { entryCount = try readGlossary().entries.count }
            catch { problem = "Не удалось открыть подключённый словарь. Подключи CSV заново." }
        }
    }

    var isConfigured: Bool { entryCount > 0 && hasAPIKey && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func connect(_ url: URL) throws {
        let data = try Self.readCSV(url)
        guard let csv = String(data: data, encoding: .utf8) else { throw SettingsError.encoding }
        let glossary = try Glossary(csv: csv)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: glossaryURL, options: .atomic)
        glossaryName = url.lastPathComponent
        defaults.set(glossaryName, forKey: "glossaryName")
        entryCount = glossary.entries.count
        problem = nil
    }

    func disconnect() throws {
        automatic = false
        if FileManager.default.fileExists(atPath: glossaryURL.path) { try FileManager.default.removeItem(at: glossaryURL) }
        glossaryName = nil; entryCount = 0
        defaults.removeObject(forKey: "glossaryName")
        problem = nil
    }

    func saveKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenRouterPostprocessor.Failure.configuration }
        try OpenRouterKeychain.save(key)
        hasAPIKey = true
        defaults.set(true, forKey: "openRouterKeySaved")
        problem = nil
    }

    func removeKey() throws {
        automatic = false
        try OpenRouterKeychain.remove()
        hasAPIKey = false
        defaults.removeObject(forKey: "openRouterKeySaved")
    }

    func configuration() throws -> (glossary: Glossary, key: String, model: String) {
        guard isConfigured else { throw OpenRouterPostprocessor.Failure.configuration }
        return (try readGlossary(), try OpenRouterKeychain.read(), model.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func readGlossary() throws -> Glossary {
        guard let csv = String(data: try Self.readCSV(glossaryURL), encoding: .utf8) else { throw SettingsError.encoding }
        return try Glossary(csv: csv)
    }

    private static func readCSV(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 else { throw SettingsError.size }
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 else { throw SettingsError.size }
        return data
    }

    private enum SettingsError: LocalizedError {
        case encoding, size
        var errorDescription: String? {
            switch self {
            case .encoding: return "Словарь должен быть CSV в кодировке UTF-8. Сохрани файл в этой кодировке и подключи снова."
            case .size: return "Словарь больше 128 КБ. Сократи его и подключи снова."
            }
        }
    }
}

/// Ключ читается только при запуске обработки, в UserDefaults и логи не попадает.
private enum OpenRouterKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ru.magir.aviacalls.openrouter", kSecAttrAccount as String: "api-key"]
    }
    static func read() throws -> String {
        var q = query
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8) else { throw KeyError() }
        return key
    }
    static func save(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw KeyError() }
        } else if status != errSecSuccess { throw KeyError() }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError() }
    }
    private struct KeyError: LocalizedError {
        var errorDescription: String? { "Не удалось получить доступ к API-ключу в Связке ключей. Сохрани ключ заново и разреши доступ macOS." }
    }
}
