import Foundation
import Testing
@testable import AviaCallsCore

@Suite struct ZoomPollingTests {
    @Test @MainActor func slowReadLeavesMainActorFreeAndSkipsOverlappingPolls() async {
        let release = DispatchSemaphore(value: 0)
        let expected = ZoomRawSnapshot(window: AXNode(role: "AXWindow", title: "Meeting"), muteMenuTitle: nil)
        let polling = ZoomPolling {
            #expect(!Thread.isMainThread)
            // Если чтение вернулось на главный поток, он не сможет открыть семафор до таймаута.
            #expect(release.wait(timeout: .now() + 2) == .success)
            return expected
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let started = polling.poll { snapshot in
                #expect(Thread.isMainThread)
                #expect(snapshot == expected)
                done.resume()
            }
            #expect(started)
            for _ in 0..<20 {
                #expect(!polling.poll { _ in Issue.record("Лишний опрос в очереди") })
            }
            release.signal()
        }
    }

    @Test @MainActor func missingSnapshotDoesNotPreventNextPoll() async {
        let polling = ZoomPolling { nil }
        for _ in 0..<2 {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let started = polling.poll { snapshot in
                    #expect(snapshot == nil)
                    done.resume()
                }
                #expect(started)
            }
        }
    }
}
