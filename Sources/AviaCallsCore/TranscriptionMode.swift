import Foundation

/// Способ распознавания аудио. Отсутствующее поле в старой встрече не разрешает облачную отправку.
public enum TranscriptionMode: String, Codable, CaseIterable, Sendable {
    case local
    case openRouter
}
