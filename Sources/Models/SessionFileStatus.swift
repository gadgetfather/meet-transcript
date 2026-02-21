import Foundation

struct SessionFileStatus: Identifiable, Hashable {
    let sessionDirectory: URL
    let sessionName: String
    let recordedAt: Date?
    let fileNames: [String]

    var id: String {
        sessionDirectory.path
    }

    var hasMicrophoneAudio: Bool {
        fileNames.contains("microphone.caf")
    }

    var hasSystemAudio: Bool {
        fileNames.contains("system.caf")
    }

    var hasTranscriptJSON: Bool {
        fileNames.contains("transcript.json")
    }

    var hasTranscriptMarkdown: Bool {
        fileNames.contains("transcript.md")
    }

    var hasTranscript: Bool {
        hasTranscriptJSON && hasTranscriptMarkdown
    }

    var needsTranscriptGeneration: Bool {
        !hasTranscript && (hasMicrophoneAudio || hasSystemAudio)
    }

    var fileSummary: String {
        if fileNames.isEmpty {
            return "No files"
        }
        return fileNames.joined(separator: ", ")
    }
}
