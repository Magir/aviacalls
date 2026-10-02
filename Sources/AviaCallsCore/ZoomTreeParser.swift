import Foundation

/// Разбирает дерево окна встречи Zoom. Чистая функция: на вход снимок, на выход состояние.
public enum ZoomTreeParser {
    // ponytail: словарь ролей неполный; роль не из словаря останется частью имени.
    // Дополнять по реальным фикстурам (Tests/AviaCallsCoreTests/Fixtures).
    static let knownRoles: Set<String> = ["я", "me", "организатор", "host", "соорганизатор", "co-host", "гость", "guest"]

    public static func parse(window: AXNode, muteMenuTitle: String?) -> ZoomSnapshot {
        var title: String?
        var tiles: [(name: String, mic: Bool?, speaking: Bool)] = []
        var rows: [(text: String, mic: Bool?)] = []

        func walk(_ n: AXNode) {
            if n.identifier == "MeetingTopBarInfoButton" { title = title ?? n.description; return }
            if n.role == "AXTabGroup", let d = n.description, let t = parseTile(d) { tiles.append(t); return }
            if n.role == "AXRow", let r = parseRow(n) { rows.append(r); return }
            n.children.forEach(walk)
        }
        walk(window)

        var order: [String] = []
        var byName: [String: Participant] = [:]
        for t in tiles {
            if var p = byName[t.name] {
                // тёзок не различить: считаем одним; микрофон включён, если включён хоть у одного
                if t.mic == true { p.micOn = true } else if p.micOn == nil { p.micOn = t.mic }
                byName[t.name] = p
            } else {
                order.append(t.name)
                byName[t.name] = Participant(name: t.name, micOn: t.mic, isMe: false)
            }
        }
        for r in rows {
            // имя с плитки надёжнее: по нему понимаем, где в строке списка кончается имя и начинаются роли
            let tileName = order.filter { r.text == $0 || r.text.hasPrefix($0 + " (") }.max { $0.count < $1.count }
            let name: String, roleList: [String]
            if let tileName {
                name = tileName
                roleList = roles(in: String(r.text.dropFirst(tileName.count)))
            } else {
                (name, roleList) = splitRoles(r.text)
            }
            let isMe = roleList.contains("я") || roleList.contains("me")
            if var p = byName[name] {
                p.isMe = p.isMe || isMe
                p.micOn = p.micOn ?? r.mic
                byName[name] = p
            } else {
                order.append(name)
                byName[name] = Participant(name: name, micOn: r.mic, isMe: isMe)
            }
        }
        return ZoomSnapshot(title: title, participants: order.compactMap { byName[$0] },
                            listOpen: !rows.isEmpty, myMicOn: muteMenuTitle.flatMap(micFromAction),
                            activeSpeaker: tiles.first(where: \.speaking)?.name)
    }

    /// "Имя, Звук компьютера включен, Video off[, active speaker]" → имя, микрофон, говорит ли. Имя может содержать запятые.
    static func parseTile(_ d: String) -> (name: String, mic: Bool?, speaking: Bool)? {
        let parts = d.components(separatedBy: ", ")
        guard let i = parts.indices.dropFirst().first(where: { isAudioPart(parts[$0]) }) else { return nil }
        // метка говорящего появляется на встречах от трёх человек; на живой встрече стояла ровно у одного участника
        let speaking = parts[(i + 1)...].contains { norm($0) == "active speaker" }
        return (parts[..<i].joined(separator: ", "), micState(parts[i]), speaking)
    }

    static func parseRow(_ row: AXNode) -> (text: String, mic: Bool?)? {
        guard let cell = row.children.first(where: { $0.identifier?.hasPrefix("ZMHCTableItemType_") == true }),
              let text = cell.children.first(where: { $0.role == "AXStaticText" })?.value, !text.isEmpty else { return nil }
        // у хоста микрофон участника — кнопка-действие («Выключить звук»), у гостя — картинка-состояние («Computer audio muted»)
        let mic = cell.children.compactMap { child -> Bool? in
            guard let d = child.description else { return nil }
            switch child.role {
            case "AXButton": return micFromAction(d)
            case "AXImage": return micState(d)
            default: return nil
            }
        }.first
        return (text, mic)
    }

    /// "Имя (Организатор, я)" → ("Имя", ["организатор", "я"]). Скобки не из словаря ролей считаем частью имени.
    static func splitRoles(_ text: String) -> (String, [String]) {
        guard text.hasSuffix(")"), let open = text.range(of: " (", options: .backwards) else { return (text, []) }
        let found = roles(in: String(text[open.lowerBound...]))
        guard !found.isEmpty, found.allSatisfy(knownRoles.contains) else { return (text, []) }
        return (String(text[..<open.lowerBound]), found)
    }

    static func roles(in suffix: String) -> [String] {
        let t = suffix.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("("), t.hasSuffix(")") else { return [] }
        return norm(String(t.dropFirst().dropLast())).components(separatedBy: ", ")
    }

    static func isAudioPart(_ s: String) -> Bool {
        let l = norm(s)
        return ["звук", "audio", "телефон", "phone"].contains { l.contains($0) }
    }

    /// Состояние из описания плитки: "Звук компьютера включен" / "Computer audio muted".
    static func micState(_ s: String) -> Bool? {
        let l = norm(s)
        if l.contains("выключен") || (l.contains("muted") && !l.contains("unmuted")) { return false }
        if l.contains("включен") || l.contains("unmuted") { return true }
        return nil
    }

    /// Состояние из названия действия: кнопка "Выключить звук" значит, что микрофон сейчас включён.
    static func micFromAction(_ s: String) -> Bool? {
        let l = norm(s)
        if l.contains("видео") || l.contains("video") { return nil }
        if l.contains("выключить") { return true }
        if l.contains("включить") || l.contains("попросить вкл") || l.contains("unmute") { return false }
        if l.contains("mute") { return true }
        return nil
    }

    /// Zoom местами ставит неразрывный пробел («Попросить\u{a0}вкл»).
    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "\u{a0}", with: " ")
    }
}
