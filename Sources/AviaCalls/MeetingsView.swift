import AviaCallsCore
import SwiftUI

/// Окно со списком встреч: слева встречи, справа участники, кнопки и расшифровка выбранной.
struct MeetingsView: View {
    @ObservedObject var recorder: RecorderController
    @State private var meetings: [MeetingSummary] = []
    @State private var selection: URL?

    var body: some View {
        NavigationSplitView {
            List(meetings, selection: $selection) { meeting in
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.title).font(.headline).lineLimit(1)
                    Text(Self.when(meeting)).font(.subheadline).foregroundStyle(.secondary)
                    let people = MeetingLibrary.participantsLine(meeting.participants)
                    if !people.isEmpty { Text(people).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                .padding(.vertical, 3)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .overlay { if meetings.isEmpty { Text("Записанных встреч пока нет").foregroundStyle(.secondary) } }
        } detail: {
            VStack(spacing: 0) {
                if recorder.model != .ready { ModelBanner(recorder: recorder) }
                if let meeting = meetings.first(where: { $0.id == selection }) {
                    MeetingDetail(meeting: meeting, recorder: recorder)
                } else {
                    Text("Выбери встречу слева").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: recorder.libraryVersion) { reload() }
        .onChange(of: recorder.recording) { reload() }
    }

    private func reload() {
        meetings = MeetingLibrary.load(root: RecorderController.root)
        if selection == nil || !meetings.contains(where: { $0.id == selection }) { selection = meetings.first?.id }
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
    @State private var lines: [TranscriptLine] = []
    @State private var copied = false

    private var transcriptURL: URL { meeting.dir.appendingPathComponent("transcript.md") }

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
                    Button(copied ? "Скопировано" : "Скопировать путь к папке") { copyPath() }
                }
                .padding(.top, 4)
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
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(line.speaker)  ").bold() + Text(line.time).font(.caption).foregroundStyle(.secondary)
                            if line.speaker == "(экран)", let image = NSImage(contentsOf: meeting.dir.appendingPathComponent(line.text)) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 260).cornerRadius(4)
                                    .onTapGesture { NSWorkspace.shared.open(meeting.dir.appendingPathComponent(line.text)) }
                            } else {
                                Text(line.text).textSelection(.enabled)
                            }
                        }
                    }
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
        NSPasteboard.general.setString(meeting.dir.path, forType: .string)
        copied = true
    }
}
