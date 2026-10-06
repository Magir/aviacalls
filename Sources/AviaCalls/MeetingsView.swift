import AviaCallsCore
import SwiftUI

/// Окно со списком встреч: слева встречи, справа участники, кнопки и расшифровка выбранной.
struct MeetingsView: View {
    @ObservedObject var recorder: RecorderController
    @State private var meetings: [MeetingSummary] = []
    @State private var selection: URL?
    @State private var query = ""
    @State private var hits: [MeetingLibrary.SearchHit] = []

    /// Что показываем слева: все встречи или только те, где нашёлся запрос.
    private var shown: [MeetingSummary] { query.trimmingCharacters(in: .whitespaces).isEmpty ? meetings : hits.map(\.meeting) }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Поиск по всем встречам", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                List(shown, selection: $selection) { meeting in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title).font(.headline).lineLimit(1)
                        Text(Self.when(meeting)).font(.subheadline).foregroundStyle(.secondary)
                        let people = MeetingLibrary.participantsLine(meeting.participants)
                        if !people.isEmpty { Text(people).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        if let hit = hits.first(where: { $0.meeting.id == meeting.id }), !query.isEmpty {
                            Text(hit.lines.isEmpty ? "Совпадение в названии или участниках" : "Совпадений в тексте: \(hit.lines.count)")
                                .font(.caption).foregroundStyle(.tint)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .overlay {
                    if meetings.isEmpty { Text("Записанных встреч пока нет").foregroundStyle(.secondary) }
                    else if shown.isEmpty { Text("Ничего не нашлось").foregroundStyle(.secondary) }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            VStack(spacing: 0) {
                if recorder.model != .ready { ModelBanner(recorder: recorder) }
                if let meeting = shown.first(where: { $0.id == selection }) {
                    // запрос из общего поиска подсвечивает строки и внутри встречи, пока не введён свой
                    MeetingDetail(meeting: meeting, recorder: recorder, globalQuery: query)
                } else {
                    Text("Выбери встречу слева").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: recorder.libraryVersion) { reload() }
        .onChange(of: recorder.recording) { reload() }
        .onChange(of: query) { reload() }
    }

    private func reload() {
        meetings = MeetingLibrary.load(root: RecorderController.root)
        hits = MeetingLibrary.search(root: RecorderController.root, query: query)
        if selection == nil || !shown.contains(where: { $0.id == selection }) { selection = shown.first?.id }
    }

    /// «2 октября 2026, 23:25 · 4 мин»
    static func when(_ meeting: MeetingSummary) -> String {
        let date = meeting.start.formatted(.dateTime.day().month(.wide).year().hour().minute())
        guard let end = meeting.end else { return date }
        return "\(date) · \(max(1, Int(end.timeIntervalSince(meeting.start) / 60))) мин"
    }
}

private struct ModelBanner: View {
    @ObservedObject var recorder: RecorderController

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            switch recorder.model {
            case .missing, .failed:
                Text("Модель распознавания речи не установлена. Встречи записываются, но не расшифровываются.")
                Spacer()
                Button("Скачать (\(WhisperModel.downloadSize))") { recorder.installModel() }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Качаю модель распознавания: \(Int(fraction * 100))%") }
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Готовлю модель к работе, это пара минут")
                Spacer()
            case .ready:
                EmptyView()
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.15))
    }
}

private struct MeetingDetail: View {
    let meeting: MeetingSummary
    @ObservedObject var recorder: RecorderController
    var globalQuery = ""
    @State private var lines: [TranscriptLine] = []
    @State private var copied = false
    @State private var localQuery = ""

    private var transcriptURL: URL { meeting.dir.appendingPathComponent("transcript.md") }
    private var screensURL: URL { meeting.dir.appendingPathComponent("screens") }
    private var hasScreens: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: screensURL.path))?.isEmpty == false) }
    /// Свой поиск по встрече главнее общего.
    private var effectiveQuery: String { localQuery.isEmpty ? globalQuery : localQuery }
    private var visibleLines: [TranscriptLine] { MeetingLibrary.filter(lines, query: effectiveQuery) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title).font(.title2).bold().textSelection(.enabled)
                Text(MeetingsView.when(meeting)).foregroundStyle(.secondary)
                if !meeting.participants.isEmpty {
                    Text(meeting.participants.joined(separator: ", ")).font(.callout).textSelection(.enabled)
                }
                HStack {
                    Button("Открыть расшифровку") { NSWorkspace.shared.open(transcriptURL) }.disabled(!meeting.hasTranscript)
                    Button("Открыть запись") { openRecording() }.disabled(!meeting.hasAudio)
                    Button("Открыть скриншоты") { NSWorkspace.shared.open(screensURL) }.disabled(!hasScreens)
                    Button(copied ? "Скопировано" : "Скопировать путь к папке") { copyPath() }
                }
                .padding(.top, 4)
                if !lines.isEmpty {
                    HStack {
                        TextField("Поиск в этой встрече", text: $localQuery).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
                        if !effectiveQuery.isEmpty {
                            Text("\(visibleLines.count) из \(lines.count) реплик").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding()
            Divider()
            transcript
        }
        .task(id: "\(meeting.dir.path) \(meeting.hasTranscript) \(recorder.libraryVersion)") { load() }
    }

    @ViewBuilder private var transcript: some View {
        if !lines.isEmpty {
            // ponytail: строки выделяются по одной; выделить весь текст разом — через «Открыть расшифровку»
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleLines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(line.speaker)  ").bold() + Text(line.time).font(.caption).foregroundStyle(.secondary)
                            if line.speaker == "(экран)", let image = NSImage(contentsOf: meeting.dir.appendingPathComponent(line.text)) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260).cornerRadius(4)
                                    .onTapGesture { NSWorkspace.shared.open(meeting.dir.appendingPathComponent(line.text)) }
                            } else {
                                Text(Self.highlighted(line.text, effectiveQuery)).textSelection(.enabled)
                            }
                        }
                    }
                    if visibleLines.isEmpty { Text("В этой встрече ничего не нашлось").foregroundStyle(.secondary) }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                if recorder.isTranscribing(meeting.dir) {
                    ProgressView()
                    Text("Расшифровываю…").foregroundStyle(.secondary)
                } else if meeting.hasTranscript {
                    Text("На встрече никто ничего не сказал").foregroundStyle(.secondary)
                } else if meeting.hasAudio {
                    Text("Расшифровки пока нет").foregroundStyle(.secondary)
                    Button("Расшифровать") { recorder.transcribe(meeting.dir) }.disabled(recorder.model != .ready)
                } else {
                    Text("В папке нет ни записи, ни расшифровки").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func load() {
        lines = MeetingLibrary.lines((try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? "")
        copied = false
    }

    /// Найденное подсвечено жёлтым; сравнение без учёта регистра и ё.
    static func highlighted(_ text: String, _ query: String) -> AttributedString {
        var result = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return result }
        var from = text.startIndex
        // diacriticInsensitive уравнивает ё и е
        while let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex),
              let lower = AttributedString.Index(r.lowerBound, within: result), let upper = AttributedString.Index(r.upperBound, within: result) {
            result[lower..<upper].backgroundColor = .yellow.opacity(0.5)
            from = r.upperBound
        }
        return result
    }

    /// Общий файл с обоими голосами собирается после расшифровки; для старых встреч собираем по нажатию.
    private func openRecording() {
        let mixed = meeting.dir.appendingPathComponent("recording.m4a")
        if FileManager.default.fileExists(atPath: mixed.path) {
            NSWorkspace.shared.open(mixed)
        } else {
            let dir = meeting.dir
            Task {
                let url = (try? await Pipeline.mix(dir: dir)) ?? MeetingStore(existing: dir).audioURL("zoom")
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MeetingLibrary.shellPath(meeting.dir.path), forType: .string)
        copied = true
    }
}
