import Foundation

final class TranscriptStore {
    private let fileManager: FileManager
    private let isoFormatter: ISO8601DateFormatter
    private let isoFormatterNoFraction: ISO8601DateFormatter

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFormatterNoFraction = ISO8601DateFormatter()
        isoFormatterNoFraction.formatOptions = [.withInternetDateTime]
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

    func listSessionFiles() throws -> [SessionFileStatus] {
        let root = try sessionsRootDirectory()
        let directoryURLs = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }

        let sessions: [SessionFileStatus] = try directoryURLs.map { directoryURL in
            let fileURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
                .filter { url in
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                }

            let fileNames = fileURLs
                .map(\.lastPathComponent)
                .sorted()

            return SessionFileStatus(
                sessionDirectory: directoryURL,
                sessionName: directoryURL.lastPathComponent,
                recordedAt: inferredSessionStartDate(
                    for: directoryURL,
                    fileURLs: fileURLs
                ),
                fileNames: fileNames
            )
        }

        return sessions.sorted { lhs, rhs in
            let leftDate = lhs.recordedAt ?? .distantPast
            let rightDate = rhs.recordedAt ?? .distantPast
            if leftDate == rightDate {
                return lhs.sessionName > rhs.sessionName
            }
            return leftDate > rightDate
        }
    }

    func inferredSessionStartDate(for sessionDirectory: URL) -> Date? {
        let microphoneURL = sessionDirectory.appendingPathComponent("microphone.caf")
        let systemURL = sessionDirectory.appendingPathComponent("system.caf")
        let candidates = [microphoneURL, systemURL].filter { fileManager.fileExists(atPath: $0.path) }
        return inferredSessionStartDate(for: sessionDirectory, fileURLs: candidates)
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

    private func inferredSessionStartDate(
        for sessionDirectory: URL,
        fileURLs: [URL]
    ) -> Date? {
        if let parsed = parsedDate(fromSessionName: sessionDirectory.lastPathComponent) {
            return parsed
        }

        for url in fileURLs {
            if let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                if let creationDate = values.creationDate {
                    return creationDate
                }
                if let modifiedDate = values.contentModificationDate {
                    return modifiedDate
                }
            }
        }

        if let values = try? sessionDirectory.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            if let creationDate = values.creationDate {
                return creationDate
            }
            if let modifiedDate = values.contentModificationDate {
                return modifiedDate
            }
        }

        return nil
    }

    private func parsedDate(fromSessionName sessionName: String) -> Date? {
        guard let separatorIndex = sessionName.firstIndex(of: "T") else {
            return nil
        }

        let datePart = String(sessionName[..<separatorIndex])
        var timePart = String(sessionName[sessionName.index(after: separatorIndex)...])
        let hasZuluSuffix = timePart.hasSuffix("Z")
        if hasZuluSuffix {
            timePart.removeLast()
        }

        let pieces = timePart.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard pieces.count == 3 else {
            return nil
        }

        let normalizedTimePart = "\(pieces[0]):\(pieces[1]):\(pieces[2])"
        let normalizedTimestamp = "\(datePart)T\(normalizedTimePart)\(hasZuluSuffix ? "Z" : "")"
        return isoFormatter.date(from: normalizedTimestamp)
            ?? isoFormatterNoFraction.date(from: normalizedTimestamp)
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
