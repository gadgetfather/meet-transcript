import Foundation

struct MeetingInsights {
    let summaryBullets: [String]
    let actionItems: [String]
}

final class MeetingInsightsService {
    private let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "he",
        "in", "is", "it", "its", "of", "on", "that", "the", "to", "was", "were", "will",
        "with", "we", "you", "your", "they", "this", "those", "these", "or", "if", "but"
    ]

    private let actionKeywords: [String] = [
        "need to", "should", "will", "let's", "todo", "to-do", "action item", "follow up",
        "please", "can you", "i will", "we will", "next step", "by tomorrow", "by monday"
    ]

    func generate(from segments: [TranscriptSegment]) -> MeetingInsights {
        let sentenceEntries = buildSentenceEntries(from: segments)
        let summary = buildSummary(from: sentenceEntries)
        let actionItems = buildActionItems(from: sentenceEntries)

        return MeetingInsights(
            summaryBullets: summary,
            actionItems: actionItems
        )
    }

    private func buildSentenceEntries(from segments: [TranscriptSegment]) -> [(speaker: String, sentence: String)] {
        var entries: [(speaker: String, sentence: String)] = []

        for segment in segments {
            let parts = splitSentences(segment.text)
            for sentence in parts {
                let cleaned = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard cleaned.count >= 10 else {
                    continue
                }
                entries.append((speaker: segment.speaker, sentence: cleaned))
            }
        }

        return entries
    }

    private func buildSummary(from entries: [(speaker: String, sentence: String)]) -> [String] {
        guard !entries.isEmpty else {
            return []
        }

        let frequencies = wordFrequencies(in: entries.map(\.sentence))
        let scored = entries.enumerated().map { index, entry in
            let words = normalizedWords(from: entry.sentence)
            let score = words.reduce(0) { partial, word in
                partial + (frequencies[word] ?? 0)
            }
            return (index: index, score: score, speaker: entry.speaker, sentence: entry.sentence)
        }

        let top = scored
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.index < rhs.index
                }
                return lhs.score > rhs.score
            }
            .prefix(5)
            .sorted { $0.index < $1.index }

        return top.map { item in
            "\(item.speaker): \(item.sentence)"
        }
    }

    private func buildActionItems(from entries: [(speaker: String, sentence: String)]) -> [String] {
        var items: [String] = []

        for entry in entries {
            let lower = entry.sentence.lowercased()
            guard actionKeywords.contains(where: { lower.contains($0) }) else {
                continue
            }

            let item = "\(entry.speaker): \(entry.sentence)"
            if !items.contains(item) {
                items.append(item)
            }
        }

        return Array(items.prefix(8))
    }

    private func splitSentences(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ".!?\\n")
        return text.components(separatedBy: separators)
    }

    private func normalizedWords(from text: String) -> [String] {
        let lowered = text.lowercased()
        let pieces = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return pieces.filter { word in
            !word.isEmpty && !stopWords.contains(word)
        }
    }

    private func wordFrequencies(in sentences: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for sentence in sentences {
            for word in normalizedWords(from: sentence) {
                result[word, default: 0] += 1
            }
        }
        return result
    }
}
