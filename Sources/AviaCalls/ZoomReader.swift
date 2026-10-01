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

    func read() -> ZoomRawSnapshot? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else {
            app = nil
            return nil
        }
        if app == nil || pid != running.processIdentifier {
            pid = running.processIdentifier
            let el = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(el, 1)   // зависший Zoom не должен вешать нас
            app = el
            muteItem = nil
        }
        guard let app, let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement],
              let window = windows.first(where: { copy($0, kAXIdentifierAttribute) as? String == Self.meetingWindowID })
        else { return nil }
        return ZoomRawSnapshot(window: node(window, depth: 0, parentRole: ""), muteMenuTitle: muteTitle(app))
    }

    /// Окна Zoom одной строкой — для диагностики, когда окно встречи не нашлось.
    func windowsSummary() -> String {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first else { return "Zoom не запущен" }
        let windows = copy(AXUIElementCreateApplication(running.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows.map { "[id=\(copy($0, kAXIdentifierAttribute) as? String ?? "-") title=\(copy($0, kAXTitleAttribute) as? String ?? "-")]" }.joined(separator: " ")
    }

    private func copy(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private func node(_ el: AXUIElement, depth: Int, parentRole: String) -> AXNode {
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
        if let item = muteItem, let title = copy(item, kAXTitleAttribute) as? String { return title }
        muteItem = nil
        guard let bar = copy(app, kAXMenuBarAttribute) else { return nil }
        func find(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            if copy(el, kAXIdentifierAttribute) as? String == "onMuteAudio:" { return el }
            guard depth < 4, let kids = copy(el, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
            for kid in kids { if let hit = find(kid, depth + 1) { return hit } }
            return nil
        }
        muteItem = find(bar as! AXUIElement, 0)
        return muteItem.flatMap { copy($0, kAXTitleAttribute) as? String }
    }
}
