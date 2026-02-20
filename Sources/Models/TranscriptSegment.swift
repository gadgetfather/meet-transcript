import Foundation

struct TranscriptSegment: Identifiable, Codable, Hashable {
    let id: UUID
    let speaker: String
    let text: String
    let timestamp: Date
    let isFinal: Bool

    init(
        id: UUID = UUID(),
        speaker: String,
        text: String,
        timestamp: Date = Date(),
        isFinal: Bool
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.isFinal = isFinal
    }
}

struct TranscriptionEvent {
    let speaker: String
    let text: String
    let timestamp: Date
    let isFinal: Bool
}
