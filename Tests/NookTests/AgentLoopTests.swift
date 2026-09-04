import XCTest
@testable import NookCore

final class AgentLoopTests: XCTestCase {
    func testToolThenProseCompletesTurn() async throws {
        let steps: [AgentGenerationResult] = [
            AgentGenerationResult(
                text: "",
                toolCalls: [AgentToolCall(name: "calendar.search", arguments: ["window": .string("today")])]
            ),
            AgentGenerationResult(text: "You have a vendor sync at 2pm."),
        ]
        let box = ScriptedSteps(steps)
        let executed = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { context, _ in
                XCTAssertTrue(context.toolResultSummaries.isEmpty || executed.count == 1)
                return box.next()
            },
            execute: { name, _ in
                executed.append(name)
                return ToolExecutionResult(
                    textForModel: "Calendar events\n• 2026-09-04 14:00–15:00 · Vendor sync",
                    displayText: "calendar.search · 1 events"
                )
            },
            onToolEvent: { _ in }
        )

        XCTAssertEqual(executed.names, ["calendar.search"])
        XCTAssertEqual(output.text, "You have a vendor sync at 2pm.")
    }

    func testFinishedToolEndsTurnWithToolText() async throws {
        let box = ScriptedSteps([
            AgentGenerationResult(
                text: "",
                toolCalls: [AgentToolCall(name: "reminders.create", arguments: ["title": .string("Shubh")])]
            ),
            AgentGenerationResult(text: "should not run"),
        ])
        let generateCount = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, _ in
                generateCount.increment()
                return box.next()
            },
            execute: { _, _ in
                ToolExecutionResult(
                    textForModel: "Created reminder “Meeting with Shubh” due 4 Sep 2026 at 10:50 AM in the “Reminders” list on this iPhone.",
                    displayText: "reminders.create · Meeting with Shubh",
                    disposition: .finished
                )
            },
            onToolEvent: { _ in }
        )

        XCTAssertEqual(generateCount.count, 1)
        XCTAssertTrue(output.text.contains("Created reminder"))
    }

    func testNeedsUserStopsWithoutAnotherModelStep() async throws {
        let box = ScriptedSteps([
            AgentGenerationResult(
                text: "",
                toolCalls: [AgentToolCall(name: "reminders.create", arguments: [:])]
            ),
            AgentGenerationResult(text: "should not run"),
        ])
        let generateCount = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, _ in
                generateCount.increment()
                return box.next()
            },
            execute: { _, _ in
                ToolExecutionResult(
                    textForModel: "reminders.create needs a title. Ask the user what to remind them about.",
                    displayText: "reminders.create · missing title",
                    disposition: .needsUser
                )
            },
            onToolEvent: { _ in }
        )

        XCTAssertEqual(generateCount.count, 1)
        XCTAssertTrue(output.text.contains("needs a title"))
    }

    func testRepeatedCompletedToolStopsAndAsksForProse() async throws {
        let call = AgentToolCall(name: "calendar.search", arguments: ["query": .string("today")])
        let box = ScriptedSteps([
            AgentGenerationResult(text: "", toolCalls: [call]),
            AgentGenerationResult(text: "", toolCalls: [call]),
            AgentGenerationResult(text: "You have a meeting with Shubh at 11am."),
        ])
        let executeCount = CounterBox()
        let sawProseOnly = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, request in
                if request.responseMode == .proseOnly {
                    XCTAssertTrue(request.toolSchemas.isEmpty)
                    sawProseOnly.increment()
                }
                return box.next()
            },
            execute: { _, _ in
                executeCount.increment()
                return ToolExecutionResult(
                    textForModel: "Calendar events\n• 2026-09-04 11:00–12:00 · Meeting with Shubh",
                    displayText: "calendar.search · 1 events"
                )
            },
            onToolEvent: { _ in }
        )

        XCTAssertEqual(executeCount.count, 1)
        XCTAssertEqual(sawProseOnly.count, 1)
        XCTAssertEqual(output.text, "You have a meeting with Shubh at 11am.")
    }

    /// Argument drift defeats signature dedupe, so the per-tool budget has to stop it.
    func testDriftingArgumentsAreStoppedByPerToolBudget() async throws {
        let box = ScriptedSteps(
            (0..<6).map { index in
                AgentGenerationResult(
                    text: "",
                    toolCalls: [
                        AgentToolCall(
                            name: "reminders.create",
                            arguments: ["title": .string("Call"), "notes": .string("note \(index)")]
                        )
                    ]
                )
            }
        )
        let executeCount = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, _ in box.next() },
            execute: { _, _ in
                executeCount.increment()
                return ToolExecutionResult(
                    textForModel: "Could not create the reminder: no reminder list.",
                    displayText: "reminders.create · failed",
                    disposition: .failed
                )
            },
            onToolEvent: { _ in }
        )

        XCTAssertEqual(executeCount.count, AgentLoop.maxCallsPerTool)
        XCTAssertFalse(output.text.isEmpty)
    }

    /// A terminal result must end the turn without running the rest of the step.
    func testFinishedResultSkipsSiblingCallsInSameStep() async throws {
        let box = ScriptedSteps([
            AgentGenerationResult(
                text: "",
                toolCalls: [
                    AgentToolCall(name: "reminders.create", arguments: ["title": .string("Call")]),
                    AgentToolCall(name: "calendar.search", arguments: ["query": .string("today")]),
                ]
            )
        ])
        let executed = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, _ in box.next() },
            execute: { name, _ in
                executed.append(name)
                return ToolExecutionResult(
                    textForModel: "Created reminder “Call” in the “Reminders” list on this iPhone.",
                    displayText: "reminders.create · Call",
                    disposition: .finished
                )
            },
            onToolEvent: { _ in }
        )

        XCTAssertEqual(executed.names, ["reminders.create"])
        XCTAssertTrue(output.text.contains("Created reminder"))
    }

    /// Observations must not carry a `toolName:` prefix into the answer turn.
    func testAnswerTurnContextHasNoToolNamePrefix() async throws {
        let box = ScriptedSteps([
            AgentGenerationResult(
                text: "",
                toolCalls: [AgentToolCall(name: "calendar.search", arguments: ["query": .string("today")])]
            ),
            AgentGenerationResult(text: "", toolCalls: [AgentToolCall(name: "calendar.search", arguments: ["query": .string("today")])]),
            AgentGenerationResult(text: "Meeting with Shubh at 11am."),
        ])

        _ = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { context, request in
                if request.responseMode == .proseOnly {
                    let joined = context.toolResultSummaries.joined(separator: "\n")
                    XCTAssertFalse(joined.contains("calendar.search:"))
                    XCTAssertTrue(joined.contains(AgentLoop.synthesisInstruction))
                }
                return box.next()
            },
            execute: { _, _ in
                ToolExecutionResult(
                    textForModel: "Calendar events\n• 2026-09-04 11:00–12:00 · Meeting with Shubh",
                    displayText: "calendar.search · 1 events"
                )
            },
            onToolEvent: { _ in }
        )
    }

    /// When the model never produces prose, the turn still answers from observations.
    func testSilentAnswerTurnFallsBackToDeterministicRender() async throws {
        let call = AgentToolCall(name: "calendar.search", arguments: ["query": .string("today")])
        let box = ScriptedSteps([
            AgentGenerationResult(text: "", toolCalls: [call]),
            AgentGenerationResult(text: "", toolCalls: [call]),
            AgentGenerationResult(text: ""),
        ])

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, _ in box.next() },
            execute: { _, _ in
                ToolExecutionResult(
                    textForModel: "Calendar events\n• 2026-09-04 11:00–12:00 · Meeting with Shubh",
                    displayText: "calendar.search · 1 events"
                )
            },
            onToolEvent: { _ in }
        )

        XCTAssertTrue(output.text.contains("Meeting with Shubh"))
    }

    func testFailedObservationContinuesThenSkipsIdenticalRetry() async throws {
        let box = ScriptedSteps([
            AgentGenerationResult(
                text: "",
                toolCalls: [AgentToolCall(name: "reminders.create", arguments: ["title": .string("Call")])]
            ),
            AgentGenerationResult(
                text: "",
                toolCalls: [AgentToolCall(name: "reminders.create", arguments: ["title": .string("Call")])]
            ),
            AgentGenerationResult(text: "I couldn't create the reminder."),
        ])
        let executeCount = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, _ in box.next() },
            execute: { _, _ in
                executeCount.increment()
                return ToolExecutionResult(
                    textForModel: "Could not create the reminder: that account does not support reminders.",
                    displayText: "reminders.create · failed",
                    disposition: .failed
                )
            },
            onToolEvent: { _ in }
        )

        XCTAssertEqual(executeCount.count, 1)
        XCTAssertEqual(output.text, "I couldn't create the reminder.")
    }

    /// An unparsable tool attempt goes straight to the answer turn instead of
    /// re-asking for a call with the same prompt.
    func testEmptyToolAttemptGoesStraightToAnswerTurn() async throws {
        let box = ScriptedSteps([
            AgentGenerationResult(text: ""),
            AgentGenerationResult(text: "You have a meeting at 11am."),
        ])
        let sawProseOnly = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, request in
                if request.responseMode == .proseOnly { sawProseOnly.increment() }
                return box.next()
            },
            execute: { _, _ in
                ToolExecutionResult(textForModel: "no", displayText: "no")
            },
            onToolEvent: { _ in }
        )

        XCTAssertEqual(sawProseOnly.count, 1)
        XCTAssertEqual(output.text, "You have a meeting at 11am.")
    }

    func testProseWithNoToolCallsEndsImmediately() async throws {
        let executed = CounterBox()
        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, _ in AgentGenerationResult(text: "Hello.") },
            execute: { _, _ in
                executed.increment()
                return ToolExecutionResult(textForModel: "no", displayText: "no")
            },
            onToolEvent: { _ in }
        )
        XCTAssertEqual(executed.count, 0)
        XCTAssertEqual(output.text, "Hello.")
    }

    /// Collapsed MCP names and the canonical form share one budget and one chip.
    func testCollapsedMcpNameSharesBudgetAndChipWithCanonical() async throws {
        let box = ScriptedSteps([
            AgentGenerationResult(
                text: "",
                toolCalls: [
                    AgentToolCall(
                        name: "tavily_tavily_search",
                        arguments: ["query": .string("nook app")]
                    ),
                    AgentToolCall(
                        name: "tavily__tavily_search",
                        arguments: ["query": .string("nook app")]
                    ),
                ]
            ),
            AgentGenerationResult(text: "Here is what I found."),
        ])
        let executed = CounterBox()
        let chips = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, _ in box.next() },
            execute: { name, _ in
                executed.append(name)
                return ToolExecutionResult(
                    textForModel: "Search results for nook app…",
                    displayText: "\(name) · 3 results",
                    isExternal: true
                )
            },
            onToolEvent: { _ in chips.increment() },
            resolveName: { requested in
                ToolNameResolver.resolve(
                    requested,
                    available: ["tavily__tavily_search", "calendar.search"]
                )
            }
        )

        XCTAssertEqual(executed.names, ["tavily__tavily_search"])
        XCTAssertEqual(chips.count, 1)
        XCTAssertEqual(output.text, "Here is what I found.")
    }

    /// Unknown names stay off the UI — observation only, no "Skipped unavailable" chip.
    func testUnknownToolDoesNotEmitChip() async throws {
        let box = ScriptedSteps([
            AgentGenerationResult(
                text: "",
                toolCalls: [AgentToolCall(name: "not_a_tool", arguments: [:])]
            ),
            AgentGenerationResult(text: "I couldn't find a tool for that."),
        ])
        let chips = CounterBox()
        let executed = CounterBox()

        let output = try await AgentLoop.run(
            promptContext: Self.promptContext(),
            request: Self.toolRequest(),
            generateStep: { _, _ in box.next() },
            execute: { _, _ in
                executed.increment()
                return ToolExecutionResult(textForModel: "no", displayText: "no")
            },
            onToolEvent: { _ in chips.increment() },
            resolveName: { _ in nil }
        )

        XCTAssertEqual(executed.count, 0)
        XCTAssertEqual(chips.count, 0)
        XCTAssertEqual(output.text, "I couldn't find a tool for that.")
    }

    private static func promptContext() -> AssembledPromptContext {
        AssembledPromptContext(
            systemPrompt: "You are Nook.",
            activeSkillInstructions: nil,
            retrievedEvidence: [],
            recentMessages: [
                Message(conversationId: "loop", role: .user, content: "Brief me")
            ],
            toolResultSummaries: [],
            totalEstimatedTokens: 0
        )
    }

    private static func toolRequest() -> AgentGenerationRequest {
        AgentGenerationRequest(
            toolSchemas: [
                ["function": ["name": "calendar.search"] as [String: any Sendable]]
            ],
            maxToolRounds: 0
        )
    }
}

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedNames: [String] = []
    private var storedCount = 0

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedNames
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    func append(_ name: String) {
        lock.lock()
        storedNames.append(name)
        storedCount += 1
        lock.unlock()
    }

    func increment() {
        lock.lock()
        storedCount += 1
        lock.unlock()
    }
}

private final class ScriptedSteps: @unchecked Sendable {
    private var remaining: [AgentGenerationResult]

    init(_ steps: [AgentGenerationResult]) {
        remaining = steps
    }

    func next() -> AgentGenerationResult {
        if remaining.isEmpty {
            return AgentGenerationResult(text: "unexpected extra step")
        }
        return remaining.removeFirst()
    }
}
