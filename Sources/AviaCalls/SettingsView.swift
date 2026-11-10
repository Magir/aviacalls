import AviaCallsCore
import SwiftUI
import UniformTypeIdentifiers

/// Одно окно настроек: где расшифровывать, общий ключ OpenRouter, обработка текста, папка встреч.
struct SettingsView: View {
    let recorder: RecorderController
    @ObservedObject var transcription: TranscriptionSettings
    @ObservedObject var settings: PostprocessingSettings
    @AppStorage("meetingsDir") private var meetingsDir = ""
    @State private var newKey = ""
    @State private var importing = false
    @State private var instruction = ""
    @State private var editingKey = false
    @State private var instructionExpanded = false
    @State private var launchAtLogin = LoginItem.enabled

    init(recorder: RecorderController) {
        self.recorder = recorder
        transcription = recorder.transcription
        settings = recorder.postprocessing.settings
    }

    private var hasUnsavedInstruction: Bool {
        instruction != settings.instruction
    }

    private var canSaveInstruction: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && hasUnsavedInstruction
    }

    private var missingSetup: String? {
        var steps: [String] = []
        if settings.loadingGlossary {
            steps.append("дождись загрузки словаря")
        } else if settings.entryCount == 0 {
            steps.append("подключи словарь")
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

            Section("Запуск") {
                Toggle("Запускать при входе", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        LoginItem.enabled = on
                        launchAtLogin = LoginItem.enabled   // macOS мог отказать: показываем, что вышло на деле
                    }
            }

            Section("Расшифровка") {
                Picker("Где расшифровывать", selection: $transcription.mode) {
                    Text("На Mac").tag(TranscriptionMode.local)
                    Text("Через OpenRouter").tag(TranscriptionMode.openRouter)
                }
                .pickerStyle(.segmented)

                if transcription.mode == .local {
                    Text("Речь распознаётся на твоём Mac. Аудио не отправляется во внешние сервисы, API-ключ не нужен. Модель распознавания ставится в блоке ниже.")
                        .font(.callout)
                } else {
                    Text("Аудиозапись отправляется в OpenRouter и провайдеру выбранной модели. Расшифровка платная и расходует лимит твоего ключа OpenRouter. Скачивать модель на Mac не нужно.")
                        .font(.callout)
                    Text("Автоматически расшифровываются только встречи, начатые после выбора этого режима. Старые записи сами не отправляются: для них нажми «Расшифровать через OpenRouter» в окне «Встречи».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Модель", text: $transcription.model, prompt: Text(OpenRouterTranscriber.defaultModel))
                    Text("По умолчанию — \(OpenRouterTranscriber.defaultModel). Другая STT-модель должна возвращать таймкоды слов (word timestamps в verbose_json) и поддерживать Zero Data Retention.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Модели OpenRouter", destination: URL(string: "https://openrouter.ai/models")!)
                    if !settings.hasAPIKey {
                        Label("Сохрани API-ключ ниже, чтобы включить расшифровку через OpenRouter. До этого встречи будут записываться без расшифровки.", systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ModelSection(recorder: recorder)

            Section("API-ключ OpenRouter") {
                Text("Один ключ для расшифровки через OpenRouter и для обработки текста. Запросы оплачиваются с твоего счёта OpenRouter.")
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

            Section("Обработка текста") {
                Toggle("Автоматически улучшать новые встречи", isOn: $settings.automatic)
                    .disabled(!settings.isConfigured && !settings.automatic)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Исправляет пунктуацию и ошибки распознавания, убирает очевидные слова-паразиты и случайные повторы.")
                    Text("Для улучшения текста в OpenRouter и провайдеру модели отправляются реплики и весь словарь. Обработка платная. Этот шаг не отправляет аудио или снимки, исходная расшифровка сохраняется на компьютере.")
                    Text("Автоматически обрабатываются записи, начатые после включения. Для старых встреч выбери «Улучшить текст…» в окне «Встречи».")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let missingSetup {
                    Label(missingSetup, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                TextField("Модель", text: $settings.model, prompt: Text(OpenRouterPostprocessor.defaultModel))
                Link("Выбрать модель в OpenRouter", destination: URL(string: "https://openrouter.ai/models?supported_parameters=structured_outputs")!)
                Text("Выбери модель, которая поддерживает структурированный ответ и доступна у провайдера с Zero Data Retention.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                                    && instruction == settings.instruction)
                    }
                    if hasUnsavedInstruction {
                        Text("Есть несохранённые изменения")
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

            Section("Папка встреч") {
                LabeledContent("Сохранять в", value: (RecorderController.root.path as NSString).abbreviatingWithTildeInPath)
                HStack {
                    Button("Выбрать папку…") { chooseMeetingsDir() }
                    if !meetingsDir.isEmpty {
                        Button("Вернуть по умолчанию") { setMeetingsDir("") }
                    }
                    Button("Открыть в Finder") { recorder.openMeetingsFolder() }
                }
                Text("Сюда пишутся новые встречи, и эту папку показывает окно «Встречи». Уже записанные встречи сами не переезжают: перенеси их папки в Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 650)
        .onAppear { instruction = settings.instruction; launchAtLogin = LoginItem.enabled }
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

    private func chooseMeetingsDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.message = "Куда сохранять встречи"
        panel.directoryURL = RecorderController.root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // папка по умолчанию — это пустая настройка, а не путь: так кнопка «Вернуть по умолчанию» не висит зря
        setMeetingsDir(url.standardizedFileURL == RecorderController.defaultRoot.standardizedFileURL
                       ? "" : (url.path as NSString).abbreviatingWithTildeInPath)
    }

    private func setMeetingsDir(_ value: String) {
        meetingsDir = value
        recorder.meetingsFolderChanged()
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation(); settings.problem = nil }
        catch { settings.problem = error.localizedDescription }
    }
}

/// Локальная модель: статус, установка, удаление. Отдельный View: RecorderController публикует изменения
/// каждые полсекунды записи, и перерисовываться из-за них должно не всё окно настроек.
private struct ModelSection: View {
    @ObservedObject var recorder: RecorderController

    var body: some View {
        Section("Модель распознавания на Mac") {
            switch recorder.model {
            case .ready:
                HStack {
                    Label("Установлена", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Удалить модель", role: .destructive) { recorder.removeModel() }
                        .disabled(recorder.jobs > 0)
                        .help(recorder.jobs > 0 ? "Дождись конца расшифровки" : "Освободит \(WhisperModel.downloadSize) на диске")
                }
            case .missing:
                HStack {
                    Label("Не установлена", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Установить (\(WhisperModel.downloadSize))") { recorder.installModel() }
                }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Качаю модель: \(Int(fraction * 100))%") }
            case .preparing:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Готовлю модель к работе, это пара минут")
                }
            case .failed(let message):
                Text("Модель не установилась: \(message)").foregroundStyle(.red).textSelection(.enabled)
                Button("Повторить установку") { recorder.installModel() }
            }
            Text("Whisper large-v3-turbo, \(WhisperModel.downloadSize). Нужна только для расшифровки на Mac; с OpenRouter её можно удалить. Без модели встречи в режиме «На Mac» записываются и ждут установки.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
