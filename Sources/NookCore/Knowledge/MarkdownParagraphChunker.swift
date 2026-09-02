import Foundation

/// Packs Markdown section body into embedding-friendly passages.
///
/// Split order:
/// 1. Blank-line blocks (paragraphs) — keeps Q&A pairs / list clusters intact
/// 2. Pack paragraphs up to a soft word budget
/// 3. Oversized single paragraphs → sentence boundaries (last resort)
enum MarkdownParagraphChunker {
    /// Target size for on-device sentence embeddings (NLEmbedding).
    static let softWordBudget = 140
    /// Never pack past this; flush or sentence-split instead.
    static let hardWordBudget = 200

    static func chunk(text: String) -> [String] {
        let paragraphs = Self.paragraphs(from: text)
        guard !paragraphs.isEmpty else { return [] }

        var passages: [String] = []
        var current: [String] = []
        var currentWords = 0

        func flush() {
            guard !current.isEmpty else { return }
            passages.append(current.joined(separator: "\n\n"))
            current = []
            currentWords = 0
        }

        for paragraph in paragraphs {
            let words = wordCount(paragraph)

            if words > hardWordBudget {
                flush()
                passages.append(contentsOf: splitLongParagraph(paragraph))
                continue
            }

            if !current.isEmpty, currentWords + words > softWordBudget {
                flush()
            }

            // Hard cap: don't grow an already-full pack past the hard budget.
            if !current.isEmpty, currentWords + words > hardWordBudget {
                flush()
            }

            current.append(paragraph)
            currentWords += words
        }

        flush()
        return passages
    }

    static func paragraphs(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        return normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func splitLongParagraph(_ paragraph: String) -> [String] {
        let sentences = sentenceFragments(from: paragraph)
        guard sentences.count > 1 else {
            return wordWindowFallback(paragraph)
        }

        var passages: [String] = []
        var current: [String] = []
        var currentWords = 0

        func flush() {
            guard !current.isEmpty else { return }
            passages.append(current.joined(separator: " "))
            current = []
            currentWords = 0
        }

        for sentence in sentences {
            let words = wordCount(sentence)
            if !current.isEmpty, currentWords + words > softWordBudget {
                flush()
            }
            current.append(sentence)
            currentWords += words
        }
        flush()
        return passages
    }

    /// Rare path: no sentence punctuation and still over budget.
    private static func wordWindowFallback(_ text: String) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        var passages: [String] = []
        var start = 0
        let overlap = 30
        while start < words.count {
            let end = min(start + softWordBudget, words.count)
            passages.append(words[start..<end].joined(separator: " "))
            if end == words.count { break }
            start += max(1, softWordBudget - overlap)
        }
        return passages
    }

    private static func sentenceFragments(from text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sentences.append(trimmed)
            }
        }
        return sentences
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
