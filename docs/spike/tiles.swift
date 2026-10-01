// Одноразовая проверка: все атрибуты плиток участников и строк списка, с опросом изменений. Только читает.
// swift tiles.swift [секунд]
import AppKit
import ApplicationServices

guard AXIsProcessTrusted(),
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first else {
    print("нет доступа или Zoom не запущен"); exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)

func get(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func children(_ el: AXUIElement) -> [AXUIElement] { get(el, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func str(_ v: CFTypeRef?) -> String {
    guard let v else { return "nil" }
    if CFGetTypeID(v) == AXValueGetTypeID() {
        let ax = v as! AXValue
        var p = CGPoint.zero, s = CGSize.zero
        if AXValueGetValue(ax, .cgPoint, &p) { return "(\(Int(p.x)),\(Int(p.y)))" }
        if AXValueGetValue(ax, .cgSize, &s) { return "\(Int(s.width))x\(Int(s.height))" }
        return "axvalue"
    }
    if CFGetTypeID(v) == AXUIElementGetTypeID() { return "<el>" }
    if let a = v as? [AnyObject] { return "[\(a.count)]" }
    return String("\(v)".prefix(160))
}
// все атрибуты элемента одной строкой на атрибут
func describe(_ el: AXUIElement) -> [String: String] {
    var names: CFArray?
    AXUIElementCopyAttributeNames(el, &names)
    var out: [String: String] = [:]
    for n in (names as? [String] ?? []) { out[n] = str(get(el, n)) }
    return out
}
// плитки и строки списка участников в окне встречи
func targets() -> [(String, AXUIElement)] {
    var res: [(String, AXUIElement)] = []
    guard let win = children(root).first(where: { (get($0, kAXIdentifierAttribute) as? String) == "zm.meeting.window.main" }) else { return res }
    var t = 0, r = 0
    func walk(_ el: AXUIElement, _ depth: Int, _ parentRole: String) {
        if depth > 12 { return }
        let role = get(el, kAXRoleAttribute) as? String ?? ""
        if role == "AXTabGroup" { res.append(("tile\(t)", el)); t += 1
            for (i, k) in children(el).enumerated() { res.append(("tile\(t-1).child\(i)", k)) } }
        if role == "AXRow" { res.append(("row\(r)", el)); r += 1
            func sub(_ e: AXUIElement, _ path: String, _ d: Int) {
                for (i, k) in children(e).enumerated() where d < 4 { res.append(("\(path).\(i)", k)); sub(k, "\(path).\(i)", d + 1) } }
            sub(el, "row\(r-1)", 0) }
        if role == "AXButton" && parentRole == "AXButton" { return }  // кнопки Zoom рекурсивно отдают сами себя
        for k in children(el) { walk(k, depth + 1, role) }
    }
    walk(win, 0, "")
    return res
}

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 0 : 0
var prev: [String: [String: String]] = [:]
for (id, el) in targets() {
    let d = describe(el); prev[id] = d
    print("== \(id)")
    for k in d.keys.sorted() { print("   \(k) = \(d[k]!)") }
}
let start = Date()
while Date().timeIntervalSince(start) < seconds {
    Thread.sleep(forTimeInterval: 0.2)
    var cur: [String: [String: String]] = [:]
    for (id, el) in targets() { cur[id] = describe(el) }
    let t = String(format: "%5.1f", Date().timeIntervalSince(start))
    for id in Set(cur.keys).union(prev.keys).sorted() {
        let a = prev[id] ?? [:], b = cur[id] ?? [:]
        for k in Set(a.keys).union(b.keys).sorted() where a[k] != b[k] {
            print("\(t) \(id) \(k): \(a[k] ?? "—") → \(b[k] ?? "—")")
        }
    }
    prev = cur
}
