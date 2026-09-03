import Foundation

/// Prompt + parse helpers for on-device memory card extraction.
public enum MemoryExtractor {
    public struct Candidate: Equatable, Sendable {
        public let subject: String
        public let kind: String
        public let quote: String
        public let provenance: MemoryProvenance

        public init(
            subject: String,
            kind: String,
            quote: String,
            provenance: MemoryProvenance = .user
        ) {
            self.subject = subject
            self.kind = kind
            self.quote = quote
            self.provenance = provenance
        }
    }

    public static let systemPrompt = """
        You extract durable facts worth remembering from a chat exchange for a private on-device assistant.
        Prefer concrete names, places, preferences, and decisions. Skip chit-chat and filler.
        If there is nothing worth remembering, reply with [].

        Return ONLY a JSON array. Each item:
        {"from":"user"|"assistant","subject":"short title","kind":"person|place|preference|decision|project|other","quote":"verbatim substring"}

        Rules:
        - from=user → quote MUST be copied exactly from the USER message.
        - from=assistant → quote MUST be copied exactly from the ASSISTANT reply.
        - At most 4 items total.
        - Prefer named people/places/facts from the assistant when the user asked a question.
        - No markdown, no prose, JSON only.
        """

    public static func exchangePrompt(userMessage: String, assistantMessage: String) -> String {
        """
        USER:
        \"\"\"
        \(userMessage)
        \"\"\"

        ASSISTANT:
        \"\"\"
        \(assistantMessage)
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
                let provenance: MemoryProvenance = {
                    switch (item.from ?? "user").lowercased() {
                    case "assistant", "model", "reply": return .assistant
                    default: return .user
                    }
                }()
                return Candidate(
                    subject: String(subject.prefix(80)),
                    kind: kind.isEmpty ? "other" : String(kind.prefix(32)).lowercased(),
                    quote: quote,
                    provenance: provenance
                )
            }
        }
        return []
    }

    /// Keep candidates whose quote is a verbatim substring of the matching side's text.
    public static func validated(
        candidates: [Candidate],
        userMessage: String,
        assistantMessage: String
    ) -> [Candidate] {
        candidates.filter { candidate in
            let source = candidate.provenance == .assistant ? assistantMessage : userMessage
            return MemoryStore.quoteIsVerbatim(quote: candidate.quote, in: source)
        }
    }

    private struct JSONCandidate: Decodable {
        let from: String?
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
