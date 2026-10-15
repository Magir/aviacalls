import AviaCallsCore
import SwiftUI
import UniformTypeIdentifiers

struct PostprocessingSettingsView: View {
    @ObservedObject var settings: PostprocessingSettings
    @State private var newKey = ""
    @State private var importing = false

    var body: some View {
        Form {
            Section("Словарь") {
                Text("Имена и внутренние названия с пояснениями помогают модели исправлять ошибки распознавания.")
                    .foregroundStyle(.secondary)
                if let name = settings.glossaryName, settings.entryCount > 0 {
                    LabeledContent(name, value: "Терминов: \(settings.entryCount)")
                } else {
                    Text("Словарь не подключён").foregroundStyle(.secondary)
                }
                HStack {
                    Button(settings.entryCount > 0 ? "Заменить CSV…" : "Подключить CSV…") { importing = true }
                    if settings.glossaryName != nil {
                        Button("Отключить словарь") { perform { try settings.disconnect() } }
                    }
                }
                Text("CSV в UTF-8, столбцы term и description. До 5000 терминов и 1 МиБ. Пояснение можно оставить пустым. Приложение хранит локальную копию: чтобы обновить словарь, подключи новый файл.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("OpenRouter") {
                TextField("Модель", text: $settings.model, prompt: Text("ID модели: provider/model"))
                Link("Модели OpenRouter", destination: URL(string: "https://openrouter.ai/models?supported_parameters=structured_outputs")!)
                Text("Нужна модель с JSON Schema, доступная у провайдера с Zero Data Retention. Запросы оплачиваются с твоего счёта OpenRouter.")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField(settings.hasAPIKey ? "Новый API-ключ" : "API-ключ", text: $newKey)
                HStack {
                    Button("Сохранить ключ") {
                        perform { try settings.saveKey(newKey); newKey = "" }
                    }.disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if settings.hasAPIKey {
                        Text("Ключ сохранён в Связке ключей").font(.caption).foregroundStyle(.secondary)
                        Button("Удалить ключ") { perform { try settings.removeKey(); newKey = "" } }
                    }
                }
            }
            Section("Инструкция модели") {
                Text("Словарь и JSON реплик прикрепляются к запросу отдельно.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: Binding(get: { settings.instruction }, set: settings.updateInstruction))
                    .font(.body)
                    .frame(minHeight: 220, maxHeight: 300)
                Button("Восстановить инструкцию по умолчанию") { settings.restoreDefaultInstruction() }
                    .disabled(settings.instruction == OpenRouterPostprocessor.defaultInstruction)
            }
            Section("Обработка встреч") {
                Text("При обработке текст реплик и весь подключённый словарь передаются OpenRouter и провайдеру модели. Аудио и снимки остаются на компьютере. Запросы платные.")
                Toggle("Автоматически обрабатывать новые встречи", isOn: $settings.automatic)
                    .disabled(!settings.isConfigured && !settings.automatic)
                Text("Действует для записей, начатых после включения. Старые встречи можно обработать вручную в окне «Встречи». Исходная расшифровка сохраняется.")
                    .font(.caption).foregroundStyle(.secondary)
                if !settings.isConfigured {
                    Text("Для обработки подключи словарь, укажи модель и сохрани API-ключ.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem = settings.problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 620)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            perform {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try settings.connect(url)
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); settings.problem = nil }
        catch { settings.problem = error.localizedDescription }
    }
}
