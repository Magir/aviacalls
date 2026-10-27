import AviaCallsCore
import SwiftUI
import UniformTypeIdentifiers

struct PostprocessingSettingsView: View {
    @ObservedObject var settings: PostprocessingSettings
    @State private var newKey = ""
    @State private var importing = false
    @State private var instruction = ""
    @State private var editingKey = false
    @State private var instructionExpanded = false

    private var hasUnsavedInstruction: Bool {
        instruction != settings.instruction
    }

    private var canSaveInstruction: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (hasUnsavedInstruction || settings.needsInstructionReview)
    }

    private var missingSetup: String? {
        var steps: [String] = []
        if settings.loadingGlossary {
            steps.append("дождись загрузки словаря")
        } else if settings.entryCount == 0 {
            steps.append("подключи словарь")
        }
        if settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            steps.append("укажи модель")
        }
        if !settings.hasAPIKey {
            steps.append("сохрани API-ключ")
        }
        guard !steps.isEmpty else { return nil }
        return "Чтобы включить обработку: \(steps.joined(separator: ", "))."
    }

    var body: some View {
        Form {
            if let problem = settings.problem {
                Text(problem).foregroundStyle(.red).textSelection(.enabled)
            }

            Section("Обработка текста") {
                Toggle("Автоматически улучшать новые встречи", isOn: $settings.automatic)
                    .disabled(!settings.isConfigured && !settings.automatic)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Исправляет пунктуацию и ошибки распознавания, убирает очевидные слова-паразиты и случайные повторы.")
                    Text("Текст реплик и весь словарь отправляются в OpenRouter и провайдеру модели. Обработка платная. Аудио, снимки и исходная расшифровка остаются на компьютере.")
                    Text("Автоматически обрабатываются записи, начатые после включения. Для старых встреч выбери «Улучшить текст…» в окне «Встречи».")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if settings.needsInstructionReview {
                    Label("Сохранённая инструкция перенесена из прежней версии. Автоматическая обработка выключена: проверь инструкцию и сохрани её, затем включи обработку снова.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if let missingSetup {
                    Label(missingSetup, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                if let name = settings.glossaryName, settings.entryCount > 0 {
                    LabeledContent(name, value: "Терминов: \(settings.entryCount)")
                } else {
                    Text(settings.loadingGlossary ? "Загружаю словарь…" : "Словарь не подключён")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(settings.entryCount > 0 ? "Заменить CSV…" : "Подключить CSV…") { importing = true }
                    if settings.glossaryName != nil {
                        Button("Отключить словарь") { perform { try settings.disconnect() } }
                    }
                }
                .disabled(settings.loadingGlossary)
                DisclosureGroup("Требования к CSV") {
                    Text("Имена и названия с пояснениями помогают исправлять ошибки распознавания. CSV в UTF-8, столбцы term и description. До 5000 терминов и 1 МиБ. Пояснение можно оставить пустым. Приложение хранит локальную копию: чтобы обновить словарь, подключи новый файл.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup("Инструкция модели", isExpanded: $instructionExpanded) {
                    Text("Опиши, какие правки нужны. Инструкция применяется к следующей обработке после сохранения.")
                        .font(.caption)
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
                    }
                    if hasUnsavedInstruction {
                        Text("Есть несохранённые изменения")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if settings.needsInstructionReview {
                        Text("Нужно проверить")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Сохранено")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 650)
        .onAppear {
            instruction = settings.instruction
            instructionExpanded = settings.needsInstructionReview
        }
        .onChange(of: settings.needsInstructionReview) {
            if settings.needsInstructionReview { instructionExpanded = true }
        }
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
