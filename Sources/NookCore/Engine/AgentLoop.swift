import Foundation

/// One ReAct loop for a user turn. Runtimes only generate a single step.
///
/// The turn runs in two phases: a bounded tool phase, then at most one synthesis
/// attempt. Repeats are bounded by a per-tool call budget rather than by argument
/// equality, because a model that re-emits a call rarely re-emits identical
/// arguments. Every round either executes something new or exits, so the loop can
/// never re-send an identical prompt.
public enum AgentLoop {
    /// Default rounds in which the model may call a tool (used when request doesn't override).
    public static let maxToolRounds = 3
    /// How many times one tool may run in a single turn.
    public static let maxCallsPerTool = 2

    public struct Output: Sendable {
        public let text: String
        public let citations: [Citation]

        public init(text: String, citations: [Citation] = []) {
            self.text = text
            self.citations = citations
        }
    }

    public static func run(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest,
        generateStep: @escaping @Sendable (AssembledPromptContext, AgentGenerationRequest) async throws -> AgentGenerationResult,
        execute: @escaping @Sendable (String, ToolArguments) async throws -> ToolExecutionResult,
        onToolEvent: @escaping @Sendable (AgentToolEvent) -> Void,
        resolveName: (@Sendable (String) async -> String?)? = nil
    ) async throws -> Output {
        var context = promptContext
        var citations: [Citation] = []
        var observations: [String] = promptContext.toolResultSummaries
        var callCounts: [String: Int] = [:]
        var resolvedSignatures: Set<String> = []

        // Honour a per-request tool-round cap if specified; fall back to the static default.
        let effectiveMaxToolRounds = request.maxToolRounds > 0
            ? request.maxToolRounds
            : maxToolRounds

        // Plain chat: one unconstrained attempt, nothing to synthesise from.
        guard !request.toolSchemas.isEmpty else {
            let step = try await generateStep(context, request)
            let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Output(
                text: text.isEmpty ? Self.deterministicAnswer(from: observations) : text,
                citations: step.citations
            )
        }

        toolPhase: for round in 0..<effectiveMaxToolRounds {
            if Task.isCancelled { throw CancellationError() }
            let step = try await generateStep(
                context,
                AgentGenerationRequest(toolSchemas: request.toolSchemas, maxToolRounds: 0)
            )
            citations.append(contentsOf: step.citations)

            #if DEBUG
            if step.toolCalls.isEmpty {
                print("[NookDiag] AgentLoop round \(round): no tool call, text='\(step.text.prefix(120))'")
            } else {
                print("[NookDiag] AgentLoop round \(round): tool calls=\(step.toolCalls.map(\.name).joined(separator: ", "))")
            }
            #endif

            guard !step.toolCalls.isEmpty else {
                let text = step.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return Output(text: text, citations: citations)
                }
                // Nothing usable — stop asking for a call and go answer.
                break toolPhase
            }

            var executedAny = false
            for call in step.toolCalls {
                // Resolve before budgeting so `tavily_tavily_search` and
                // `tavily__tavily_search` share one budget and one chip.
                let resolvedName: String
                if let resolveName {
                    guard let mapped = await resolveName(call.name) else {
                        print("[AgentLoop] Unknown tool \(call.name) — not showing a chip")
                        observations.append(
                            "Tool '\(call.name)' is unknown. Use an exact tool name from the list."
                        )
                        continue
                    }
                    if mapped != call.name {
                        print("[AgentLoop] Resolved '\(call.name)' → '\(mapped)'")
                    }
                    resolvedName = mapped
                } else {
                    resolvedName = call.name
                }

                let signature = "\(resolvedName):\(Self.argumentKey(call.arguments))"
                if resolvedSignatures.contains(signature) {
                    print("[AgentLoop] \(resolvedName) already resolved with these arguments")
                    continue
                }
                let count = callCounts[resolvedName, default: 0]
                guard count < maxCallsPerTool else {
                    print("[AgentLoop] \(resolvedName) over budget (\(count)/\(maxCallsPerTool))")
                    continue
                }
                callCounts[resolvedName] = count + 1
                print("[AgentLoop] Round \(round) \(resolvedName)")

                let result = try await execute(resolvedName, call.arguments)
                resolvedSignatures.insert(signature)
                executedAny = true
                citations.append(contentsOf: result.citations)
                onToolEvent(
                    AgentToolEvent(
                        toolName: resolvedName,
                        displayText: result.displayText,
                        citations: result.citations,
                        chunks: result.chunks,
                        isExternal: result.isExternal
                    )
                )
                observations.append(Self.observation(for: result))

                // The tool already answered the user (or needs them). End the turn
                // now — do not run the rest of this step's calls.
                if result.disposition == .finished || result.disposition == .needsUser {
                    return Output(text: result.textForModel, citations: citations)
                }
            }

            context = context.replacingToolResults(observations)
            // Every call was over budget / unknown; another round would repeat this one.
            if !executedAny { break toolPhase }
        }

        // One synthesis attempt. `proseOnly` lets a runtime forbid tool syntax
        // outright instead of relying on the model to take a hint.
        if !observations.isEmpty {
            observations.append(Self.synthesisInstruction)
        }
        context = context.replacingToolResults(observations)
        let answer = try await generateStep(
            context,
            AgentGenerationRequest(toolSchemas: [], maxToolRounds: 0, responseMode: .proseOnly)
        )
        citations.append(contentsOf: answer.citations)
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return Output(text: text, citations: citations)
        }

        return Output(text: Self.deterministicAnswer(from: observations), citations: citations)
    }

    static func argumentKey(_ arguments: ToolArguments) -> String {
        arguments.keys.sorted().map { key in
            "\(key)=\(arguments[key]?.stringValue ?? "")"
        }.joined(separator: ",")
    }

    /// Positive phrasing, and no tool name — naming the tool on an answer turn
    /// primes the model to call it again.
    static let synthesisInstruction =
        "Use the information above to answer the user in one or two short sentences."

    /// Observations carry no `toolName:` prefix: that reads as a call site and is
    /// the strongest cue for the model to emit another one.
    static func observation(for result: ToolExecutionResult) -> String {
        result.textForModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Last resort when the model produced no prose at all.
    static func deterministicAnswer(from observations: [String]) -> String {
        if let created = observations.reversed().first(where: { $0.contains("Created reminder") }),
           let line = created
            .components(separatedBy: .newlines)
            .first(where: { $0.contains("Created reminder") }) {
            return line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let calendar = observations.reversed().first(where: { $0.contains("Calendar events") }) {
            return plainCalendarReply(from: calendar)
        }
        return observations.isEmpty
            ? "I couldn't generate a reply. Please try again."
            : "I used the available tools but couldn't form a follow-up answer. Please try asking again."
    }

    private static func plainCalendarReply(from block: String) -> String {
        let lines = block
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("•") }
        if lines.isEmpty { return block }
        return "Here's what's on the calendar:\n\n" + lines.joined(separator: "\n")
    }
}

public extension AssembledPromptContext {
    func replacingToolResults(_ results: [String]) -> AssembledPromptContext {
        AssembledPromptContext(
            systemPrompt: systemPrompt,
            activeSkillInstructions: activeSkillInstructions,
            retrievedEvidence: retrievedEvidence,
            recentMessages: recentMessages,
            toolResultSummaries: results,
            totalEstimatedTokens: totalEstimatedTokens
        )
    }
}
