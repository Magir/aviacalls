import Foundation

/// Решает, идёт ли ещё встреча. «Вижу окно встречи» и «встреча идёт» — разные вещи: окно Zoom временами
/// пропадает из Accessibility (пользователь переключает окна, AX не успевает ответить), а встреча продолжается.
/// Резать запись по одной пропаже окна нельзя: одна встреча разваливалась на несколько записей.
public struct MeetingPresence: Sendable {
    /// Что удалось увидеть в Zoom за один опрос.
    public enum Sight: String, Equatable, Sendable {
        case window    // окно встречи найдено: можно читать участников
        case menu      // окна нет, но в меню Zoom есть рабочий пункт «Выключить/Включить звук»
        case unknown   // AX не ответил: есть ли окно, неизвестно
        case none      // Zoom не запущен, или нет ни окна встречи, ни пункта меню
    }

    /// Сколько секунд без окна и без пункта меню — встреча закончилась.
    public var endAfter: Double
    /// Сколько секунд терпим, что AX молчит, прежде чем считать встречу законченной.
    public var silentAXLimit: Double
    /// Сколько секунд встреча может держаться на одном пункте меню, без окна. Страховка на случай, если пункт
    /// остаётся в меню и после выхода из встречи: запись тогда хотя бы закончится, а не будет идти вечно.
    public var menuOnlyLimit: Double

    private var lastWindow: Date?
    private var lastAlive: Date?   // последний опрос, когда встреча точно шла

    public init(endAfter: Double = 10, silentAXLimit: Double = 60, menuOnlyLimit: Double = 3600) {
        self.endAfter = endAfter
        self.silentAXLimit = silentAXLimit
        self.menuOnlyLimit = menuOnlyLimit
    }

    /// Учитывает опрос и отвечает, идёт ли встреча. Когда встреча закончилась, состояние сбрасывается:
    /// новую встречу начинает только окно, одного пункта меню для этого мало.
    public mutating func update(_ sight: Sight, at now: Date) -> Bool {
        switch sight {
        case .window:
            lastWindow = now
            lastAlive = now
        case .menu:
            if let lastWindow, now.timeIntervalSince(lastWindow) <= menuOnlyLimit { lastAlive = now }
        case .unknown, .none:
            break
        }
        guard let lastAlive else { return false }
        let quiet = now.timeIntervalSince(lastAlive)
        // пока AX молчит, ответа «встречи нет» у нас нет: ждём дольше, но не бесконечно
        let going = quiet <= endAfter || (sight == .unknown && quiet <= silentAXLimit)
        if !going { (self.lastWindow, self.lastAlive) = (nil, nil) }
        return going
    }

    /// Сколько секунд встреча идёт без окна; nil — окно видно сейчас или встречи нет.
    public func withoutWindow(at now: Date) -> Double? {
        guard let lastWindow, now > lastWindow else { return nil }
        return now.timeIntervalSince(lastWindow)
    }
}
