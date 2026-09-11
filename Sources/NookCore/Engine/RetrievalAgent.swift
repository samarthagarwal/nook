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
        case searchCalendar(query: String)
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

    // MARK: - Plan API

    /// Result of the planner loop — evidence to pass into the answer turn.
    public struct PlanResult: Sendable {
        /// Full retrieved texts to inject as tool results in the answer context.
        public let evidenceTexts: [String]
        public let citations: [Citation]
        /// Non-nil when the model chose `ask_user` — caller should surface this
        /// directly rather than running an answer turn.
        public let askUserQuestion: String?
    }

    /// Run the planner loop and return collected evidence without generating an answer.
    /// The caller assembles the answer context and handles streaming.
    ///
    /// - Parameters:
    ///   - question: The user's natural-language question.
    ///   - availableActions: Which retrieval actions are currently enabled.
    ///   - executeRetrieval: Runs one `PlannerAction`; returns summary (scratchpad)
    ///     and fullText (answer context).
    ///   - generatePlannerStep: Runs one model generation. Receives
    ///     `(systemPrompt, userMessage)` separately so the caller can build a proper
    ///     `AssembledPromptContext`. Returns raw model output — no streaming needed.
    ///   - onRetrievalStarted: Optional callback fired before each retrieval for
    ///     progress UI.
    public static func plan(
        question: String,
        availableActions: Set<AvailableAction>,
        executeRetrieval: @escaping @Sendable (PlannerAction) async throws -> RetrievalResult,
        generatePlannerStep: @escaping @Sendable (_ system: String, _ user: String) async throws -> String,
        onRetrievalStarted: (@Sendable (PlannerAction) -> Void)? = nil
    ) async throws -> PlanResult {
        var scratchpad: [ScrapbookEntry] = []
        var collectedEvidence: [String] = []
        var collectedCitations: [Citation] = []
        var triedSignatures: Set<String> = []

        for iteration in 0..<maxIterations {
            if Task.isCancelled { throw CancellationError() }

            let (system, user) = buildPlannerContext(
                question: question,
                availableActions: availableActions,
                scratchpad: scratchpad
            )

            let raw = try await generatePlannerStep(system, user)
            let action = parsePlannerAction(from: raw)

            print("[RetrievalAgent] Iteration \(iteration) raw='\(raw.prefix(120))' → \(labelFor(action))")

            switch action {
            case .answer:
                return PlanResult(
                    evidenceTexts: collectedEvidence,
                    citations: collectedCitations,
                    askUserQuestion: nil
                )

            case .askUser(let q):
                return PlanResult(
                    evidenceTexts: collectedEvidence,
                    citations: collectedCitations,
                    askUserQuestion: q
                )

            case .searchConversations, .searchKnowledge, .searchWeb, .searchCalendar, .refine:
                let sig = signatureFor(action)
                guard !triedSignatures.contains(sig) else {
                    print("[RetrievalAgent] Already tried \(sig) — stopping")
                    return PlanResult(
                        evidenceTexts: collectedEvidence,
                        citations: collectedCitations,
                        askUserQuestion: nil
                    )
                }
                triedSignatures.insert(sig)
                onRetrievalStarted?(action)

                do {
                    let result = try await executeRetrieval(action)
                    scratchpad.append(ScrapbookEntry(action: labelFor(action), summary: result.summary))
                    if !result.fullText.isEmpty {
                        collectedEvidence.append(result.fullText)
                    }
                    collectedCitations.append(contentsOf: result.citations)
                } catch {
                    scratchpad.append(ScrapbookEntry(
                        action: labelFor(action),
                        summary: "failed: \(error.localizedDescription)"
                    ))
                }
            }
        }

        // Max iterations reached — answer with whatever was collected.
        return PlanResult(
            evidenceTexts: collectedEvidence,
            citations: collectedCitations,
            askUserQuestion: nil
        )
    }

    // MARK: - Planner context builder

    /// Returns `(system, user)` for one planner step.
    /// Split so the caller can construct a proper `AssembledPromptContext`
    /// with the user part as a `Message` in `recentMessages`.
    static func buildPlannerContext(
        question: String,
        availableActions: Set<AvailableAction>,
        scratchpad: [ScrapbookEntry]
    ) -> (system: String, user: String) {
        let clock = DateFormatter()
        clock.dateStyle = .full
        clock.timeStyle = .short
        let dateStamp = clock.string(from: Date())

        var systemParts: [String] = [
            """
            Current local date and time: \(dateStamp).

            Choose the next retrieval action. Output ONLY one line — \
            copy the format exactly from the examples below, replacing \
            the example query with a real query for the user's question. \
            Do not add explanation or punctuation.
            """
        ]

        var actionLines: [String] = []
        if availableActions.contains(.conversations) {
            actionLines.append("search_conversations: recent project work")
        }
        if availableActions.contains(.knowledge) {
            actionLines.append("search_knowledge: quarterly report summary")
        }
        if availableActions.contains(.web) {
            actionLines.append("search_web: Swift concurrency async await")
        }
        if availableActions.contains(.calendar) {
            actionLines.append("search_calendar: meetings today")
        }
        if availableActions.contains(.refine) {
            actionLines.append("refine: conversations | better query here")
        }
        actionLines.append("answer")

        systemParts.append("Available actions:\n" + actionLines.joined(separator: "\n"))

        var userParts: [String] = ["Question: \(question)"]
        if scratchpad.isEmpty {
            userParts.append("Nothing tried yet.")
        } else {
            let log = scratchpad.map(\.scratchpadLine).joined(separator: "\n")
            userParts.append("Already tried:\n\(log)")
            // Nudge the model to stop searching once it has retrieved something.
            userParts.append("You have collected results. Only search again if a completely different source would help. Otherwise output: answer")
        }
        userParts.append("Next action:")

        return (
            system: systemParts.joined(separator: "\n\n"),
            user: userParts.joined(separator: "\n\n")
        )
    }

    // MARK: - Helpers

    /// Remove duplicate citations (same document + section) preserving order.
    public static func deduplicateCitations(_ citations: [Citation]) -> [Citation] {
        var seen = Set<String>()
        return citations.filter { c in
            let key = "\(c.sourceDocument)|\(c.pageOrSection)".lowercased()
            return seen.insert(key).inserted
        }
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
        if lower.hasPrefix("search_calendar:") {
            let q = extractPayload(line, after: "search_calendar:")
            return q.isEmpty ? .answer : .searchCalendar(query: q)
        }
        if lower.hasPrefix("refine:") {
            let payload = extractPayload(line, after: "refine:")
            let parts = payload.components(separatedBy: "|")
            let source = parts.first?.trimmingCharacters(in: .whitespaces) ?? ""
            let query = parts.dropFirst().joined(separator: "|").trimmingCharacters(in: .whitespaces)
            return (source.isEmpty || query.isEmpty) ? .answer : .refine(source: source, query: query)
        }
        if lower.hasPrefix("ask_user:") {
            // Planner should not ask users — treat as "answer now".
            return .answer
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
        case .searchCalendar(let q): return "search_calendar(\(q))"
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
    case calendar
    case refine
}
