import AppKit
import ApplicationServices
import AviaCallsCore

/// Снимает дерево окна встречи Zoom через Accessibility. Только читает.
final class ZoomReader {
    static let bundleID = "us.zoom.xos"
    static let meetingWindowID = "zm.meeting.window.main"
    private static let attributes = [kAXRoleAttribute, kAXRoleDescriptionAttribute, kAXIdentifierAttribute, kAXTitleAttribute,
                                     kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray

    private var pid: pid_t = 0
    private var app: AXUIElement?
    private var muteItem: AXUIElement?
    private var lastSight: MeetingPresence.Sight?

    /// Только окно встречи — для CLI и снятия фикстур.
    func read() -> ZoomRawSnapshot? { look(checkMenu: false).snapshot }

    /// Один опрос Zoom. `checkMenu` — если окна встречи нет, проверить пункт меню «Выключить/Включить звук»:
    /// он есть, пока идёт встреча, какое бы окно ни было активно. Нужно только во время встречи.
    func poll(checkMenu: Bool) -> ZoomPoll {
        var poll = look(checkMenu: checkMenu)
        // список окон нужен только для лога, один раз на смену состояния; при молчащем AX он снова упрётся в таймаут
        if checkMenu, poll.sight != .window, poll.sight != lastSight, poll.windowsError == nil { poll.windows = windowsSummary() }
        lastSight = poll.sight
        return poll
    }

    private func look(checkMenu: Bool) -> ZoomPoll {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            app = nil
            return ZoomPoll(snapshot: nil, sight: .none, windowsError: nil, menu: nil)
        }
        if app == nil || pid != running.processIdentifier {
            pid = running.processIdentifier
            let el = AXUIElementCreateApplication(pid)
            app = el
            muteItem = nil
        }
        guard let app else { return ZoomPoll(snapshot: nil, sight: .none, windowsError: nil, menu: nil) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        // «окон нет» и «AX не ответил» — разные ответы: во втором случае про встречу мы ничего не знаем
        guard error == .success || error == .noValue else { return ZoomPoll(snapshot: nil, sight: .unknown, windowsError: error, menu: nil) }
        let windows = value as? [AXUIElement] ?? []
        // Пока пользователь показывает экран, окна встречи нет: остаются плавающее окно с видео и панель показа.
        // Встреча при этом идёт, поэтому читаем то, что есть.
        func titled(_ prefix: String) -> AXUIElement? {
            windows.first { (copy($0, kAXTitleAttribute) as? String)?.hasPrefix(prefix) == true }
        }
        if let window = windows.first(where: { copy($0, kAXIdentifierAttribute) as? String == Self.meetingWindowID })
            ?? titled("zoom floating video") ?? titled("zoom share") {
            let snapshot = ZoomRawSnapshot(window: node(window, depth: 0, parentRole: ""), muteMenuTitle: muteTitle(app))
            return ZoomPoll(snapshot: snapshot, sight: .window, windowsError: nil, menu: nil)
        }
        guard checkMenu else { return ZoomPoll(snapshot: nil, sight: .none, windowsError: nil, menu: nil) }
        let menu = menuState(app)
        let sight: MeetingPresence.Sight
        switch menu {
        case .enabled: sight = .menu
        case .disabled, .missing: sight = .none
        case .failed: sight = .unknown
        }
        return ZoomPoll(snapshot: nil, sight: sight, windowsError: nil, menu: menu)
    }

    /// Окна Zoom одной строкой — для диагностики, когда окно встречи не нашлось.
    func windowsSummary() -> String {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return "Zoom не запущен" }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard error == .success || error == .noValue else { return "AX не отдал список окон: \(Self.describe(error))" }
        let windows = value as? [AXUIElement] ?? []
        guard !windows.isEmpty else { return "окон нет" }
        return windows.map { w in
            let minimized = copy(w, kAXMinimizedAttribute) as? Bool == true ? " свёрнуто" : ""
            return "[id=\(copy(w, kAXIdentifierAttribute) as? String ?? "-") title=\(copy(w, kAXTitleAttribute) as? String ?? "-")"
                + " subrole=\(copy(w, kAXSubroleAttribute) as? String ?? "-")\(minimized)]"
        }.joined(separator: " ")
    }

    static func describe(_ error: AXError) -> String {
        switch error {
        case .cannotComplete: return "cannotComplete (\(error.rawValue)): Zoom не ответил за секунду"
        case .invalidUIElement: return "invalidUIElement (\(error.rawValue))"
        case .apiDisabled: return "apiDisabled (\(error.rawValue)): нет доступа «Универсальный доступ»"
        case .attributeUnsupported: return "attributeUnsupported (\(error.rawValue))"
        case .noValue: return "noValue (\(error.rawValue))"
        default: return "AXError \(error.rawValue)"
        }
    }

    private func copy(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        // Таймаут действует только на этот AXUIElement, дочерние элементы его не наследуют.
        AXUIElementSetMessagingTimeout(el, 1)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private func node(_ el: AXUIElement, depth: Int, parentRole: String) -> AXNode {
        AXUIElementSetMessagingTimeout(el, 1)
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(el, Self.attributes, [], &raw)
        let values = raw as? [Any] ?? []
        func string(_ i: Int) -> String? {
            guard i < values.count, let s = values[i] as? String, !s.isEmpty else { return nil }
            return s
        }
        let role = string(0) ?? "?"
        var children: [AXNode] = []
        // кнопки Zoom отдают сами себя как ребёнка; без этой проверки обход не кончается
        if depth < 14, !(role == "AXButton" && parentRole == "AXButton"), values.count > 6, let kids = values[6] as? [AXUIElement] {
            children = kids.map { node($0, depth: depth + 1, parentRole: role) }
        }
        return AXNode(role: role, roleDescription: string(1), identifier: string(2), title: string(3),
                      description: string(4), value: string(5), children: children)
    }

    /// Название пункта меню «Выключить звук / Включить звук» — свой микрофон. Меню видно всегда, панель кнопок прячется.
    private func muteTitle(_ app: AXUIElement) -> String? {
        guard case .found(let item) = findMuteItem(app) else { return nil }
        return copy(item, kAXTitleAttribute) as? String
    }

    /// Есть ли в меню Zoom рабочий пункт «Выключить/Включить звук». Выключенный пункт встречей не считаем:
    /// так меньше шанс, что пункт, оставшийся в меню после встречи, будет держать запись.
    private func menuState(_ app: AXUIElement) -> ZoomPoll.Menu {
        switch findMuteItem(app) {
        case .failed(let error): return .failed(error)
        case .missing: return .missing
        case .found(let item):
            let title = copy(item, kAXTitleAttribute) as? String ?? "?"
            return copy(item, kAXEnabledAttribute) as? Bool == false ? .disabled(title) : .enabled(title)
        }
    }

    private enum Lookup { case found(AXUIElement), missing, failed(AXError) }

    /// Пункт onMuteAudio: в меню Zoom. Найденный пункт запоминаем; пропал из меню — ищем заново.
    private func findMuteItem(_ app: AXUIElement) -> Lookup {
        if let item = muteItem, copy(item, kAXTitleAttribute) is String { return .found(item) }
        muteItem = nil
        var bar: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar)
        guard error == .success, let bar else { return error == .noValue ? .missing : .failed(error) }
        func find(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            if copy(el, kAXIdentifierAttribute) as? String == "onMuteAudio:" { return el }
            guard depth < 4, let kids = copy(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for kid in kids { if let hit = find(kid, depth + 1) { return hit } }
            return nil
        }
        muteItem = find(bar as! AXUIElement, 0)
        return muteItem.map { .found($0) } ?? .missing
    }
}

/// Что видно в Zoom за один опрос.
struct ZoomPoll {
    enum Menu: CustomStringConvertible {
        case enabled(String), disabled(String), missing, failed(AXError)
        var description: String {
            switch self {
            case .enabled(let t): return "пункт onMuteAudio: есть («\(t)»)"
            case .disabled(let t): return "пункт onMuteAudio: есть, но выключен («\(t)»)"
            case .missing: return "пункта onMuteAudio: нет"
            case .failed(let e): return "меню не прочиталось: \(ZoomReader.describe(e))"
            }
        }
    }

    var snapshot: ZoomRawSnapshot?   // окно встречи нашлось — дерево для разбора
    var sight: MeetingPresence.Sight
    var windowsError: AXError?       // AX не отдал список окон
    var menu: Menu?                  // nil — меню не смотрели
    var windows: String? = nil       // окна Zoom одной строкой, когда окно встречи только что пропало
}
