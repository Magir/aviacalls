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
    @Published private(set) var instruction: String
    @Published private(set) var needsInstructionReview: Bool
    @Published private(set) var glossaryName: String?
    @Published private(set) var entryCount = 0
    @Published private(set) var hasAPIKey: Bool
    @Published private(set) var loadingGlossary = false
    @Published var problem: String?
    private let defaults: UserDefaults
    private let directory: URL
    private let readKey: @Sendable () throws -> String
    private var glossary: Glossary?
    private var loadingTask: Task<Glossary, Error>?
    private var glossaryURL: URL { directory.appendingPathComponent("glossary.csv") }

    init(defaults: UserDefaults = .standard,
         directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AviaCalls"),
         readKey: @escaping @Sendable () throws -> String = { try OpenRouterKeychain.read() }) {
        self.defaults = defaults; self.directory = directory
        self.readKey = readKey
        model = defaults.string(forKey: "openRouterModel") ?? ""
        let savedInstruction = PostprocessingInstruction(saved: defaults.string(forKey: "openRouterInstruction"),
                                                        version: defaults.integer(forKey: "openRouterInstructionVersion"))
        instruction = savedInstruction.text
        needsInstructionReview = savedInstruction.needsReview
        automatic = defaults.bool(forKey: "glossaryAutomatic") && !savedInstruction.needsReview
        if savedInstruction.needsReview { defaults.set(false, forKey: "glossaryAutomatic") }
        hasAPIKey = defaults.bool(forKey: "openRouterKeySaved")
        glossaryName = defaults.string(forKey: "glossaryName")
        if FileManager.default.fileExists(atPath: glossaryURL.path) {
            let url = glossaryURL
            loadingGlossary = true
            let task = Task.detached(priority: .utility) { try Self.readGlossary(url) }
            loadingTask = task
            Task { [weak self] in
                do {
                    let glossary = try await task.value
                    self?.glossary = glossary
                    self?.entryCount = glossary.entries.count
                } catch { self?.problem = "Не удалось открыть подключённый словарь. Подключи CSV заново." }
                self?.loadingTask = nil
                self?.loadingGlossary = false
            }
        }
    }

    var isConfigured: Bool { !needsInstructionReview && entryCount > 0 && hasAPIKey && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func connect(_ url: URL) async throws {
        guard !loadingGlossary else { throw SettingsError.busy }
        loadingGlossary = true
        let directory = directory, target = glossaryURL
        let task = Task.detached(priority: .userInitiated) {
            let data = try Self.readCSV(url)
            guard let csv = String(data: data, encoding: .utf8) else { throw SettingsError.encoding }
            let glossary = try Glossary(csv: csv)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return glossary
        }
        loadingTask = task
        defer { loadingTask = nil; loadingGlossary = false }
        let glossary = try await task.value
        self.glossary = glossary
        glossaryName = url.lastPathComponent
        defaults.set(glossaryName, forKey: "glossaryName")
        entryCount = glossary.entries.count
        problem = nil
    }

    func disconnect() throws {
        guard !loadingGlossary else { throw SettingsError.busy }
        automatic = false
        if FileManager.default.fileExists(atPath: glossaryURL.path) { try FileManager.default.removeItem(at: glossaryURL) }
        glossaryName = nil; entryCount = 0
        glossary = nil
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

    func updateInstruction(_ value: String) {
        instruction = Self.instruction(from: value)
        if instruction == OpenRouterPostprocessor.defaultInstruction {
            defaults.removeObject(forKey: "openRouterInstruction")
        } else {
            defaults.set(instruction, forKey: "openRouterInstruction")
        }
        defaults.set(PostprocessingInstruction.version, forKey: "openRouterInstructionVersion")
        needsInstructionReview = false
    }

    func restoreDefaultInstruction() {
        updateInstruction(OpenRouterPostprocessor.defaultInstruction)
    }

    func configuration() async throws -> (glossary: Glossary, key: String, model: String, instruction: String) {
        guard !needsInstructionReview else { throw SettingsError.instructionReview }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines), instruction = instruction
        guard hasAPIKey, !model.isEmpty else { throw OpenRouterPostprocessor.Failure.configuration }
        let glossary: Glossary?
        if let task = loadingTask { glossary = try await task.value }
        else { glossary = self.glossary }
        guard let glossary, !glossary.entries.isEmpty else { throw OpenRouterPostprocessor.Failure.configuration }
        let readKey = readKey
        let key = try await Task.detached(priority: .userInitiated) { try readKey() }.value
        return (glossary, key, model, instruction)
    }

    private static func instruction(from value: String?) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return OpenRouterPostprocessor.defaultInstruction
        }
        return value
    }

    private nonisolated static func readGlossary(_ url: URL) throws -> Glossary {
        guard let csv = String(data: try readCSV(url), encoding: .utf8) else { throw SettingsError.encoding }
        return try Glossary(csv: csv)
    }

    private nonisolated static func readCSV(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Glossary.maximumUTF8Bytes else { throw SettingsError.size }
        let data = try Data(contentsOf: url)
        guard data.count <= Glossary.maximumUTF8Bytes else { throw SettingsError.size }
        return data
    }

    private enum SettingsError: LocalizedError {
        case encoding, size, busy, instructionReview
        var errorDescription: String? {
            switch self {
            case .encoding: return "Словарь должен быть CSV в кодировке UTF-8. Сохрани файл в этой кодировке и подключи снова."
            case .size: return "Словарь больше 1 МиБ. Сократи его и подключи снова."
            case .busy: return "Дождись загрузки словаря."
            case .instructionReview: return "После обновления проверь и сохрани инструкцию в настройках обработки или восстанови инструкцию по умолчанию."
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
