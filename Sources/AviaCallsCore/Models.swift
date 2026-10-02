import Foundation

/// Узел дерева Accessibility, снятый с окна Zoom.
public struct AXNode: Codable, Equatable, Sendable {
    public var role: String
    public var roleDescription: String?
    public var identifier: String?
    public var title: String?
    public var description: String?
    public var value: String?
    public var children: [AXNode]

    public init(role: String, roleDescription: String? = nil, identifier: String? = nil, title: String? = nil,
                description: String? = nil, value: String? = nil, children: [AXNode] = []) {
        self.role = role; self.roleDescription = roleDescription; self.identifier = identifier
        self.title = title; self.description = description; self.value = value; self.children = children
    }
}

/// Всё, что читаем из Zoom за один опрос. В таком виде лежат фикстуры тестов.
public struct ZoomRawSnapshot: Codable, Equatable, Sendable {
    public var window: AXNode
    public var muteMenuTitle: String?
    public init(window: AXNode, muteMenuTitle: String?) { self.window = window; self.muteMenuTitle = muteMenuTitle }
}

public struct Participant: Codable, Equatable, Sendable {
    public var name: String
    public var micOn: Bool?   // nil — состояние не прочиталось
    public var isMe: Bool
    public init(name: String, micOn: Bool?, isMe: Bool) { self.name = name; self.micOn = micOn; self.isMe = isMe }
}

public struct ZoomSnapshot: Equatable, Sendable {
    public var title: String?
    public var participants: [Participant]
    public var listOpen: Bool    // панель участников открыта — список полный
    public var myMicOn: Bool?
    public var activeSpeaker: String?   // кого Zoom сейчас считает говорящим; nil — метки нет
    public init(title: String?, participants: [Participant], listOpen: Bool, myMicOn: Bool?, activeSpeaker: String? = nil) {
        self.title = title; self.participants = participants; self.listOpen = listOpen; self.myMicOn = myMicOn
        self.activeSpeaker = activeSpeaker
    }
}

public struct Word: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public struct Utterance: Codable, Equatable, Sendable {
    public var start: Double
    public var speaker: String
    public var text: String
    public init(start: Double, speaker: String, text: String) { self.start = start; self.speaker = speaker; self.text = text }
}
