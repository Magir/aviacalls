import Foundation
import Testing
@testable import AviaCallsCore

private func at(_ t: Double) -> Date { Date(timeIntervalSince1970: 1_000_000 + t) }

/// Прогоняет опросы раз в секунду с `from` по `to` включительно; возвращает ответ на последнем.
private func run(_ p: inout MeetingPresence, _ sight: MeetingPresence.Sight, from: Double, to: Double) -> Bool {
    var going = false
    for t in stride(from: from, through: to, by: 1) { going = p.update(sight, at: at(t)) }
    return going
}

@Suite struct MeetingPresenceTests {
    @Test func windowStartsMeeting() {
        var p = MeetingPresence()
        #expect(p.update(.none, at: at(0)) == false)
        #expect(p.update(.window, at: at(1)) == true)
    }

    @Test func menuAloneDoesNotStartMeeting() {
        // пункт меню мог остаться от прошлой встречи; начало — только по окну
        var p = MeetingPresence()
        #expect(run(&p, .menu, from: 0, to: 30) == false)
    }

    @Test func shortLossOfWindowKeepsMeeting() {
        var p = MeetingPresence()
        _ = p.update(.window, at: at(0))
        #expect(run(&p, .none, from: 1, to: 10) == true)
        #expect(p.update(.window, at: at(11)) == true)
    }

    @Test func noWindowAndNoMenuEndsMeeting() {
        var p = MeetingPresence()
        _ = p.update(.window, at: at(0))
        #expect(run(&p, .none, from: 1, to: 11) == false)
    }

    @Test func menuKeepsMeetingWithoutWindow() {
        // случай из жизни: пользователь переключается между окнами, окно встречи пропадает на минуты
        var p = MeetingPresence()
        _ = p.update(.window, at: at(0))
        #expect(run(&p, .menu, from: 1, to: 130) == true)
        #expect(p.withoutWindow(at: at(130)) == 130)
        #expect(p.update(.window, at: at(131)) == true)
        #expect(p.withoutWindow(at: at(131)) == nil)
    }

    @Test func meetingEndsAfterMenuItemDisappears() {
        var p = MeetingPresence()
        _ = p.update(.window, at: at(0))
        _ = run(&p, .menu, from: 1, to: 60)
        #expect(run(&p, .none, from: 61, to: 70) == true)
        #expect(p.update(.none, at: at(71)) == false)
    }

    @Test func menuOnlyMeetingEndsAfterLimit() {
        // если пункт меню переживает встречу, запись всё равно закончится
        var p = MeetingPresence(endAfter: 10, menuOnlyLimit: 100)
        _ = p.update(.window, at: at(0))
        #expect(run(&p, .menu, from: 1, to: 110) == true)
        #expect(p.update(.menu, at: at(111)) == false)
    }

    @Test func silentAXHoldsMeetingLonger() {
        var p = MeetingPresence(endAfter: 10, silentAXLimit: 60)
        _ = p.update(.window, at: at(0))
        #expect(run(&p, .unknown, from: 1, to: 60) == true)
        #expect(p.update(.unknown, at: at(61)) == false)
    }

    @Test func definiteAnswerAfterSilentAXEndsMeeting() {
        // AX снова отвечает, и окна нет — ждать больше нечего
        var p = MeetingPresence(endAfter: 10, silentAXLimit: 60)
        _ = p.update(.window, at: at(0))
        _ = run(&p, .unknown, from: 1, to: 30)
        #expect(p.update(.none, at: at(31)) == false)
    }

    @Test func endedMeetingIsNotRevivedByMenu() {
        var p = MeetingPresence()
        _ = p.update(.window, at: at(0))
        #expect(run(&p, .none, from: 1, to: 11) == false)
        #expect(run(&p, .menu, from: 12, to: 20) == false)
        #expect(p.withoutWindow(at: at(20)) == nil)
        #expect(p.update(.window, at: at(21)) == true)
    }
}
