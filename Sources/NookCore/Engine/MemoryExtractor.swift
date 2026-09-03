import Foundation

/// Prompt + parse helpers for on-device memory card extraction from a single user message.
public enum MemoryExtractor {
    public struct Candidate: Equatable, Sendable {
        public let subject: String
        public let kind: String
        public let quote: String

        public init(subject: String, kind: String, quote: String) {
            self.subject = subject
            self.kind = kind
            self.quote = quote
        }
    }

    public static let systemPrompt = """
        You extract durable personal facts from ONE user message for a private on-device assistant.
        Only use the user message. Do not invent people, places, or preferences that are not stated.
        If there is nothing worth remembering, reply with [].

        Return ONLY a JSON array. Each item:
        {"subject":"short title","kind":"person|place|preference|decision|project|other","quote":"verbatim substring of the user message"}

        Rules:
        - quote MUST be copied exactly from the user message (substring).
        - At most 3 items.
        - Prefer concrete facts over chit-chat.
        - No markdown, no prose, JSON only.
        """

    public static func userPrompt(for message: String) -> String {
        """
        User message:
        \"\"\"
        \(message)
        \"\"\"
        """
    }

    public static func parseCandidates(from raw: String) -> [Candidate] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let data = extractJSONArrayData(from: trimmed),
           let decoded = try? JSONDecoder().decode([JSONCandidate].self, from: data) {
            return decoded.compactMap { item in
                let subject = item.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                let kind = item.kind.trimmingCharacters(in: .whitespacesAndNewlines)
                let quote = item.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !subject.isEmpty, !quote.isEmpty else { return nil }
                return Candidate(
                    subject: String(subject.prefix(80)),
                    kind: kind.isEmpty ? "other" : String(kind.prefix(32)).lowercased(),
                    quote: quote
                )
            }
        }
        return []
    }

    /// Keep candidates whose quote is a verbatim (normalized) substring of the user message.
    public static func validated(
        candidates: [Candidate],
        againstUserMessage message: String
    ) -> [Candidate] {
        candidates.filter { MemoryStore.quoteIsVerbatim(quote: $0.quote, in: message) }
    }

    private struct JSONCandidate: Decodable {
        let subject: String
        let kind: String
        let quote: String
    }

    private static func extractJSONArrayData(from text: String) -> Data? {
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) is [Any] {
            return data
        }
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]"),
              start < end
        else {
            return nil
        }
        let slice = String(text[start...end])
        return slice.data(using: .utf8)
    }
}
