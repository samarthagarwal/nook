import Foundation

/// A bounded retrieval-escalation agent that decides *which sources* to try
/// before answering, rather than re-deciding on every tool round in the main loop.
///
/// # Flow
/// 1. **Planner loop** (compact context, no chat history, no evidence yet)
///    The model sees a manifest of available retrieval actions and a growing
///    scratchpad of what has been tried. It picks one action per iteration.
///    Max `maxIterations` rounds; each entry is a one-line summary (~20 tokens).
///
/// 2. **Answer turn** (full context, loaded evidence)
///    Once the planner emits `.answer` (or we hit the cap), the collected
///    results are passed to `AgentLoop` as pre-assembled tool results and
///    the model generates the final response with streaming.
///
/// # Why two contexts?
/// Keeping the planner context minimal (system + question + scratchpad) means
/// retrieved content never pollutes the decision-making turn — the 2B model
/// doesn't need to read 2 000 tokens of calendar events to decide whether to
/// also search past chats. The answer turn loads the full evidence once.
public enum RetrievalAgent {

    // MARK: - Public API

    public static let maxIterations = 5

    /// Result of one planner step.
    public enum PlannerAction: Sendable {
        case searchConversations(query: String)
        case searchKnowledge(query: String)
        case searchWeb(query: String)
        case refine(source: String, query: String)
        case askUser(question: String)
        case answer
    }

    public struct ScrapbookEntry: Sendable {
        public let action: String
        public let summary: String
        public init(action: String, summary: String) {
            self.action = action
            self.summary = summary
        }
        /// Compact one-liner for the planner scratchpad (~20 tokens).
        var scratchpadLine: String { "[\(action)] → \(summary)" }
    }

    /// Execute the full retrieval-then-answer flow.
    ///
    /// - Parameters:
    ///   - question: The user's natural-language question.
    ///   - availableActions: Which retrieval actions are currently enabled.
    ///   - executeRetrieval: Closure that runs a `PlannerAction` and returns a
    ///     `(summary, fullText)` pair — summary goes in the scratchpad, fullText
    ///     goes into the answer context.
    ///   - generatePlannerStep: Runs one generation against the planner context.
    ///     Must return the raw model text (no streaming needed here).
    ///   - generateAnswer: Runs the final answer generation with the assembled
    ///     evidence; this call *does* stream tokens.
    /// - Returns: The final answer text and any citations.
    public static func run(
        question: String,
        availableActions: Set<AvailableAction>,
        executeRetrieval: @escaping @Sendable (PlannerAction) async throws -> RetrievalResult,
        generatePlannerStep: @escaping @Sendable (String) async throws -> String,
        generateAnswer: @escaping @Sendable ([String]) async throws -> AgentLoop.Output
    ) async throws -> AgentLoop.Output {
        var scratchpad: [ScrapbookEntry] = []
        var collectedEvidence: [String] = []
        var triedSignatures: Set<String> = []

        for iteration in 0..<maxIterations {
            if Task.isCancelled { throw CancellationError() }

            let prompt = buildPlannerPrompt(
                question: question,
                availableActions: availableActions,
                scratchpad: scratchpad
            )

            let raw = try await generatePlannerStep(prompt)
            let action = parsePlannerAction(from: raw)

            print("[RetrievalAgent] Iteration \(iteration): \(raw.prefix(120))")

            switch action {
            case .answer:
                break

            case .askUser(let q):
                // Surface the question directly — stop looping.
                return AgentLoop.Output(text: q, citations: [])

            case .searchConversations(let query),
                 .searchKnowledge(let query),
                 .searchWeb(let query),
                 .refine(_, let query):
                let sig = signatureFor(action)
                guard !triedSignatures.contains(sig) else {
                    print("[RetrievalAgent] Already tried \(sig) — stopping early")
                    break
                }
                triedSignatures.insert(sig)

                do {
                    let result = try await executeRetrieval(action)
                    scratchpad.append(ScrapbookEntry(
                        action: labelFor(action),
                        summary: result.summary
                    ))
                    if !result.fullText.isEmpty {
                        collectedEvidence.append(result.fullText)
                    }
                } catch {
                    scratchpad.append(ScrapbookEntry(
                        action: labelFor(action),
                        summary: "failed: \(error.localizedDescription)"
                    ))
                }
                continue
            }

            // Either .answer was chosen or we hit a duplicate — proceed to answer.
            break
        }

        return try await generateAnswer(collectedEvidence)
    }

    // MARK: - Planner prompt

    private static func buildPlannerPrompt(
        question: String,
        availableActions: Set<AvailableAction>,
        scratchpad: [ScrapbookEntry]
    ) -> String {
        var parts: [String] = []

        parts.append("""
        You are a retrieval planner. Decide what to do next to answer the user's question.
        Output ONLY one action from the list below — nothing else.
        """)

        var actionLines: [String] = []
        if availableActions.contains(.conversations) {
            actionLines.append("search_conversations: <query>")
        }
        if availableActions.contains(.knowledge) {
            actionLines.append("search_knowledge: <query>")
        }
        if availableActions.contains(.web) {
            actionLines.append("search_web: <query>")
        }
        if availableActions.contains(.refine) {
            actionLines.append("refine: <source> | <new_query>")
        }
        actionLines.append("ask_user: <clarifying question>")
        actionLines.append("answer")

        parts.append("Actions:\n" + actionLines.joined(separator: "\n"))
        parts.append("Question: \(question)")

        if !scratchpad.isEmpty {
            let log = scratchpad.map(\.scratchpadLine).joined(separator: "\n")
            parts.append("Already tried:\n\(log)")
        } else {
            parts.append("Nothing tried yet.")
        }

        parts.append("Next action:")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Action parsing

    /// Parse the model's one-line output into a structured action.
    /// Tolerant: trims whitespace, lowercases prefix, falls back to `.answer`.
    static func parsePlannerAction(from raw: String) -> PlannerAction {
        let line = raw
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let lower = line.lowercased()

        if lower.hasPrefix("search_conversations:") {
            let q = extractPayload(line, after: "search_conversations:")
            return q.isEmpty ? .answer : .searchConversations(query: q)
        }
        if lower.hasPrefix("search_knowledge:") {
            let q = extractPayload(line, after: "search_knowledge:")
            return q.isEmpty ? .answer : .searchKnowledge(query: q)
        }
        if lower.hasPrefix("search_web:") {
            let q = extractPayload(line, after: "search_web:")
            return q.isEmpty ? .answer : .searchWeb(query: q)
        }
        if lower.hasPrefix("refine:") {
            let payload = extractPayload(line, after: "refine:")
            let parts = payload.components(separatedBy: "|")
            let source = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let query = parts.dropFirst().joined(separator: "|").trimmingCharacters(in: .whitespaces)
            return (source.isEmpty || query.isEmpty) ? .answer : .refine(source: source, query: query)
        }
        if lower.hasPrefix("ask_user:") {
            let q = extractPayload(line, after: "ask_user:")
            return q.isEmpty ? .answer : .askUser(question: q)
        }
        // "answer" or anything unrecognised → proceed to answer turn
        return .answer
    }

    private static func extractPayload(_ line: String, after prefix: String) -> String {
        let idx = line.index(line.startIndex, offsetBy: prefix.count, limitedBy: line.endIndex) ?? line.endIndex
        return String(line[idx...]).trimmingCharacters(in: .whitespaces)
    }

    private static func labelFor(_ action: PlannerAction) -> String {
        switch action {
        case .searchConversations(let q): return "search_conversations(\(q))"
        case .searchKnowledge(let q): return "search_knowledge(\(q))"
        case .searchWeb(let q): return "search_web(\(q))"
        case .refine(let s, let q): return "refine(\(s), \(q))"
        case .askUser(let q): return "ask_user(\(q))"
        case .answer: return "answer"
        }
    }

    private static func signatureFor(_ action: PlannerAction) -> String {
        labelFor(action)
    }
}

// MARK: - Supporting types

public struct RetrievalResult: Sendable {
    /// One-line summary for the planner scratchpad.
    public let summary: String
    /// Full retrieved text to include in the answer context.
    public let fullText: String
    public let citations: [Citation]

    public init(summary: String, fullText: String, citations: [Citation] = []) {
        self.summary = summary
        self.fullText = fullText
        self.citations = citations
    }
}

public enum AvailableAction: Hashable, Sendable {
    case conversations
    case knowledge
    case web
    case refine
}
