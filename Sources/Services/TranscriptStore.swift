import Foundation

final class TranscriptStore {
    private let fileManager: FileManager
    private let isoFormatter: ISO8601DateFormatter

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func createSessionDirectory() throws -> URL {
        let baseDirectory = try sessionsRootDirectory()
        let sessionName = isoFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let sessionDirectory = baseDirectory.appendingPathComponent(sessionName, isDirectory: true)

        try fileManager.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )

        return sessionDirectory
    }

    func saveTranscript(_ segments: [TranscriptSegment], in sessionDirectory: URL) throws {
        let jsonURL = sessionDirectory.appendingPathComponent("transcript.json")
        let markdownURL = sessionDirectory.appendingPathComponent("transcript.md")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(segments)
        try data.write(to: jsonURL)

        let markdown = markdownBody(from: segments)
        try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    }

    func saveInsights(_ insights: MeetingInsights, in sessionDirectory: URL) throws {
        let insightsURL = sessionDirectory.appendingPathComponent("insights.md")
        var lines: [String] = ["# Meeting Insights", ""]

        lines.append("## Summary")
        if insights.summaryBullets.isEmpty {
            lines.append("- No summary points generated.")
        } else {
            for bullet in insights.summaryBullets {
                lines.append("- \(bullet)")
            }
        }

        lines.append("")
        lines.append("## Action Items")
        if insights.actionItems.isEmpty {
            lines.append("- No explicit action items detected.")
        } else {
            for item in insights.actionItems {
                lines.append("- \(item)")
            }
        }

        lines.append("")
        let content = lines.joined(separator: "\n")
        try content.write(to: insightsURL, atomically: true, encoding: .utf8)
    }

    private func sessionsRootDirectory() throws -> URL {
        let baseRoot: URL
        if let configured = ProcessInfo.processInfo.environment["MEET_TRANSCRIPT_OUTPUT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty
        {
            baseRoot = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            baseRoot = URL(
                fileURLWithPath: fileManager.currentDirectoryPath,
                isDirectory: true
            )
        }

        let sessionsDirectory = baseRoot.appendingPathComponent("Testing", isDirectory: true)

        try fileManager.createDirectory(
            at: sessionsDirectory,
            withIntermediateDirectories: true
        )

        return sessionsDirectory
    }

    private func markdownBody(from segments: [TranscriptSegment]) -> String {
        var lines = ["# Meeting Transcript", ""]

        for segment in segments {
            let timestamp = isoFormatter.string(from: segment.timestamp)
            lines.append("[\(timestamp)] \(segment.speaker): \(segment.text)")
        }

        return lines.joined(separator: "\n")
    }
}
