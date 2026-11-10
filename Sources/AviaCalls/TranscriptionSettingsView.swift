import AviaCallsCore
import SwiftUI

struct TranscriptionSettingsView: View {
    @ObservedObject var settings: TranscriptionSettings
    @ObservedObject var keySettings: PostprocessingSettings
    @State private var newKey = ""
    @State private var editingKey = false
    @State private var problem: String?

    var body: some View {
        Form {
            Section("Где расшифровывать встречи") {
                Picker("Расшифровка", selection: $settings.mode) {
                    Text("На Mac").tag(TranscriptionMode.local)
                    Text("Через OpenRouter").tag(TranscriptionMode.openRouter)
                }
                .pickerStyle(.segmented)

                if settings.mode == .local {
                    Text("Речь распознаётся на твоём Mac. Аудио не отправляется во внешние сервисы, API-ключ не нужен. Модель распознавания можно скачать через меню AviaCalls.")
                        .font(.callout)
                } else {
                    Text("Аудиозапись отправляется в OpenRouter и провайдеру выбранной модели. Расшифровка платная и расходует лимит твоего ключа OpenRouter. Скачивать модель на Mac не нужно.")
                        .font(.callout)
                }

                if settings.mode == .openRouter {
                    Text("Автоматически расшифровываются только встречи, начатые после выбора этого режима. Старые записи сами не отправляются: для них нажми «Расшифровать через OpenRouter» в окне «Встречи».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if settings.mode == .openRouter {
                Section("Модель OpenRouter") {
                    TextField("Модель", text: $settings.model, prompt: Text(OpenRouterTranscriber.defaultModel))
                    Text("По умолчанию — \(OpenRouterTranscriber.defaultModel). Другая STT-модель должна возвращать таймкоды слов (word timestamps в verbose_json) и поддерживать Zero Data Retention.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Модели OpenRouter", destination: URL(string: "https://openrouter.ai/models")!)
                }

                Section("API-ключ OpenRouter") {
                    Text("Для расшифровки и улучшения текста используется один ключ. Словарь для расшифровки не нужен.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if keySettings.hasAPIKey, !editingKey {
                        HStack {
                            Label("Ключ сохранён в Связке ключей", systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Изменить ключ") { editingKey = true }
                        }
                    } else {
                        SecureField(keySettings.hasAPIKey ? "Новый API-ключ" : "API-ключ", text: $newKey)
                        HStack {
                            Button("Сохранить ключ") {
                                perform {
                                    try keySettings.saveKey(newKey)
                                    newKey = ""
                                    editingKey = false
                                }
                            }
                            .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if keySettings.hasAPIKey {
                                Button("Отмена") { newKey = ""; editingKey = false; problem = nil }
                                Button("Удалить ключ", role: .destructive) {
                                    perform {
                                        try keySettings.removeKey()
                                        newKey = ""
                                        editingKey = false
                                    }
                                }
                            }
                        }
                    }
                    if !keySettings.hasAPIKey {
                        Label("Сохрани ключ, чтобы включить расшифровку через OpenRouter. До этого встречи будут записываться без расшифровки.", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let problem {
                        Text(problem).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520)
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); problem = nil }
        catch { problem = error.localizedDescription }
    }
}
