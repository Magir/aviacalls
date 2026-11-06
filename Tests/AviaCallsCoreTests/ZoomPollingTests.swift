import Foundation
import Testing
@testable import AviaCallsCore

@Suite struct ZoomPollingTests {
    @Test @MainActor func slowReadLeavesMainActorFreeAndSkipsOverlappingPolls() async {
        let release = DispatchSemaphore(value: 0)
        let expected = ZoomRawSnapshot(window: AXNode(role: "AXWindow", title: "Meeting"), muteMenuTitle: nil)
        let polling = ZoomPolling()
        let read = { () -> ZoomRawSnapshot? in
            #expect(!Thread.isMainThread)
            // Если чтение вернулось на главный поток, он не сможет открыть семафор до таймаута.
            #expect(release.wait(timeout: .now() + 2) == .success)
            Thread.sleep(forTimeInterval: 0.1)
            return expected
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let started = polling.poll(read) { snapshot, at in
                #expect(Thread.isMainThread)
                #expect(snapshot == expected)
                #expect(Date().timeIntervalSince(at) >= 0.1)   // время начала чтения, а не его конца
                done.resume()
            }
            #expect(started)
            for _ in 0..<20 {
                #expect(!polling.poll(read) { _, _ in Issue.record("Лишний опрос в очереди") })
            }
            release.signal()
        }
    }

    @Test @MainActor func missingSnapshotDoesNotPreventNextPoll() async {
        let polling = ZoomPolling()
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let started = polling.poll({ nil as ZoomRawSnapshot? }) { snapshot, _ in
                    #expect(snapshot == nil)
                    done.resume()
                }
                #expect(started)
            }
        }
    }
}
