import AVFoundation
import CoreAudio

/// Забирает звук, который проигрывает Zoom, через Core Audio process tap (macOS 14.4+).
final class ZoomTap {
    private let writer: TrackWriter
    private let queue = DispatchQueue(label: "aviacalls.zoomtap")      // управление: открыть, закрыть, слушатель устройств
    private let ioQueue = DispatchQueue(label: "aviacalls.zoomtap.io") // звук; на очереди управления нельзя: AudioDeviceStop ждёт, пока
                                                                       // отработает колбэк, и с одной очередью это взаимная блокировка
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var running = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var outputAddress = address(kAudioHardwarePropertyDefaultOutputDevice)

    init(writer: TrackWriter) { self.writer = writer }

    func start() {
        queue.sync {
            running = true
            // сменили устройство вывода (подключили наушники) — агрегат привязан к старому, пересобираем
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.reopen() }
            listener = block
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, queue, block)
            reopen()
        }
    }

    func stop() {
        queue.sync {
            running = false
            if let listener { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outputAddress, queue, listener) }
            listener = nil
            close()
        }
    }

    private func reopen() {
        guard running else { return }
        close()
        do { try open() } catch {
            NSLog("ZoomTap: open failed: %@", "\(error)")
            // Zoom ещё не подключил звук или нет разрешения — пробуем снова; тишину TrackWriter добьёт сам
            close()
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.deviceID == kAudioObjectUnknown else { return }
                self.reopen()
            }
        }
    }

    private func open() throws {
        let processes = try Self.zoomProcesses()
        guard !processes.isEmpty else { throw TapError("Zoom не найден среди аудиопроцессов") }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tapID), "создать tap")

        var asbd = AudioStreamBasicDescription()
        try read(tapID, kAudioTapPropertyFormat, &asbd)
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw TapError("непонятный формат tap") }

        // Агрегат только из tap, без устройства вывода: с устройством вывода внутри он замолкает,
        // как только микрофон включает эхоподавление (проверено на Zoom 7.0.6, macOS 26.5).
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AviaCalls",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "создать агрегатное устройство")

        let writer = self.writer
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, ioQueue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            writer.append(buffer)
        }, "создать IOProc")
        try check(AudioDeviceStart(deviceID, procID), "запустить устройство")
    }

    private func close() {
        if deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            if let procID { AudioDeviceDestroyIOProcID(deviceID, procID) }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        procID = nil
    }

    /// Все аудиопроцессы Zoom: звук может играть не главный процесс, а помощник.
    static func zoomProcesses() throws -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        try check(AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size), "список аудиопроцессов")
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids), "список аудиопроцессов")
        return ids.filter { id in
            var bundle = "" as CFString
            return (try? read(id, kAudioProcessPropertyBundleID, &bundle)) != nil && (bundle as String).hasPrefix("us.zoom")
        }
    }
}

struct TapError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

private func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw TapError("не удалось \(what): OSStatus \(status)") }
}

private func read<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) throws {
    var addr = address(selector)
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    try check(status, "прочитать свойство \(selector)")
}
