import AviaCallsCore
import SwiftUI
import UniformTypeIdentifiers

struct PostprocessingSettingsView: View {
    @ObservedObject var settings: PostprocessingSettings
    @State private var newKey = ""
    @State private var importing = false
    @State private var instruction = ""
    @State private var editingKey = false

    private var hasUnsavedInstruction: Bool {
        instruction != settings.instruction
    }

    private var canSaveInstruction: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (hasUnsavedInstruction || settings.needsInstructionReview)
    }

    var body: some View {
        Form {
            Section("Обработка текста") {
                Toggle("Автоматически улучшать новые встречи", isOn: $settings.automatic)
                    .disabled(!settings.isConfigured && !settings.automatic)
                Text("Текст реплик и весь подключённый словарь отправляются в OpenRouter и выбранному провайдеру. Аудио и снимки остаются на компьютере. Обработка платная, исходная расшифровка сохраняется.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.needsInstructionReview {
                    Label("Сохранённая инструкция перенесена из прежней версии. Проверь её и сохрани, даже без изменений, или восстанови инструкцию по умолчанию.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if !settings.isConfigured {
                    Label("Чтобы включить обработку, подключи словарь, укажи модель и сохрани API-ключ.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Новые записи обрабатываются только после включения. Для старых встреч выбери «Улучшить текст…» в окне «Встречи».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Инструкция для улучшения текста") {
                Text("Опиши, какие правки нужны. Инструкция применяется к следующей обработке после сохранения.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $instruction)
                    .font(.body)
                    .frame(minHeight: 180, maxHeight: 280)
                HStack {
                    Button("Сохранить инструкцию") { settings.updateInstruction(instruction) }
                        .disabled(!canSaveInstruction)
                    Button("Восстановить по умолчанию") {
                        settings.restoreDefaultInstruction()
                        instruction = settings.instruction
                    }
                    .disabled(instruction == OpenRouterPostprocessor.defaultInstruction
                                && instruction == settings.instruction
                                && !settings.needsInstructionReview)
                    Spacer()
                    if hasUnsavedInstruction {
                        Text("Есть несохранённые изменения")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Сохранено")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("Полная системная инструкция") {
                    Text("Ниже — фактическая инструкция, которая будет отправлена при следующей обработке с сохранённым текстом выше.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(OpenRouterPostprocessor.systemInstruction(for: settings.instruction))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 130, maxHeight: 220)
                }
            }

            Section("Модель и ключ OpenRouter") {
                TextField("Модель", text: $settings.model, prompt: Text("ID модели: provider/model"))
                Link("Выбрать модель в OpenRouter", destination: URL(string: "https://openrouter.ai/models?supported_parameters=structured_outputs")!)
                Text("Выбери модель, которая поддерживает структурированный ответ и доступна у провайдера с Zero Data Retention. Запросы оплачиваются с твоего счёта OpenRouter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.hasAPIKey, !editingKey {
                    HStack {
                        Label("API-ключ сохранён в Связке ключей", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Изменить ключ") { editingKey = true }
                    }
                } else {
                    SecureField(settings.hasAPIKey ? "Новый API-ключ" : "API-ключ", text: $newKey)
                    HStack {
                        Button("Сохранить ключ") {
                            perform { try settings.saveKey(newKey); newKey = ""; editingKey = false }
                        }
                        .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if settings.hasAPIKey {
                            Button("Отмена") { newKey = ""; editingKey = false }
                            Button("Удалить ключ", role: .destructive) { perform { try settings.removeKey(); newKey = ""; editingKey = false } }
                        }
                    }
                }
            }

            Section("Словарь") {
                Text("Имена и внутренние названия с пояснениями помогают исправлять ошибки распознавания.")
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
                .disabled(settings.loadingGlossary)
                if settings.loadingGlossary { ProgressView("Загружаю словарь…").controlSize(.small) }
                DisclosureGroup("Требования к CSV") {
                    Text("CSV в UTF-8, столбцы term и description. До 5000 терминов и 1 МиБ. Пояснение можно оставить пустым. Приложение хранит локальную копию: чтобы обновить словарь, подключи новый файл.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let problem = settings.problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 650)
        .onAppear { instruction = settings.instruction }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            Task {
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try await settings.connect(url)
                } catch { settings.problem = error.localizedDescription }
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); settings.problem = nil }
        catch { settings.problem = error.localizedDescription }
    }
}
