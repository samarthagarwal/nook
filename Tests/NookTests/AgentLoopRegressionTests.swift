import XCTest
@testable import NookCore

/// Reproduces the on-device incident that motivated the loop rewrite: a small model
/// that keeps emitting tool calls and never produces prose. These run the real
/// `CalendarSearchTool` and `RemindersCreateTool` against fake EventKit doubles, and
/// mirror how `AgentSession` dispatches and grounds them.
final class AgentLoopRegressionTests: XCTestCase {
    /// The incident: "remind me 10 minutes before that meeting" made the model look
    /// the meeting up, create the reminder, then re-emit the create with drifting
    /// `notes` until the round budget ran out — writing a duplicate and answering
    /// nothing. One write, one confirmation, and the spare steps must go unused.
    func testReminderTurnWritesOnceAndAnswersWithoutSpinning() async throws {
        let world = Fixture()
        let script = ScriptedModel([
            .calls([
                AgentToolCall(
                    name: "calendar.search",
                    arguments: ["window": .string("today"), "query": .string("Shubh")]
                )
            ]),
            .calls([
                AgentToolCall(
                    name: "reminders.create",
                    arguments: [
                        "title": .string("Meeting with Shubh"),
                        "due": .string("2026-09-04 10:50"),
                        "notes": .string("Reminder: Meeting with Shubh"),
                    ]
                )
            ]),
            // Everything below is the spin. Reaching it is the failure.
            .calls([
                AgentToolCall(
                    name: "reminders.create",
                    arguments: [
                        "title": .string("Meeting with Shubh"),
                        "due": .string("2026-09-04 10:50"),
                        "notes": .string("Meeting with Shubh reminder"),
                    ]
                )
            ]),
            .calls([
                AgentToolCall(
                    name: "reminders.create",
                    arguments: [
                        "title": .string("Meeting with Shubh"),
                        "due": .string("2026-09-04 10:50"),
                        "notes": .string("Don't forget"),
                    ]
                )
            ]),
        ])

        let output = try await world.run(
            userText: "Can you set up a reminder, 10 minutes before that meeting?",
            script: script
        )

        XCTAssertEqual(world.writer.created.count, 1, "the model's retry must not write a second reminder")
        let due = try XCTUnwrap(world.writer.created.first?.due)
        XCTAssertEqual(world.calendar.component(.hour, from: due), 10)
        XCTAssertEqual(world.calendar.component(.minute, from: due), 50)

        XCTAssertEqual(script.consumed, 2, "the turn must end on the successful create")
        XCTAssertEqual(world.executedTools, ["calendar.search", "reminders.create"])
        XCTAssertTrue(output.text.contains("Created reminder"), output.text)
        XCTAssertTrue(output.text.contains("Meeting with Shubh"), output.text)
    }

    /// A read tool has no terminal result, so the spin has to be bounded by the
    /// budget instead. Drifting arguments defeat signature dedupe on purpose.
    func testReadOnlySpinIsBoundedAndStillAnswers() async throws {
        let world = Fixture()
        let script = ScriptedModel(
            (0..<8).map { index in
                .calls([
                    AgentToolCall(
                        name: "calendar.search",
                        arguments: [
                            "window": .string("today"),
                            "query": .string("Shubh \(index)"),
                        ]
                    )
                ])
            }
            // The answer turn stays silent, as LiteRT does when it suppresses
            // unparsed tool markup. The turn must still say something useful.
            + [.text("")]
        )

        let output = try await world.run(userText: "What's on my calendar?", script: script)

        XCTAssertEqual(
            world.executedTools.count,
            AgentLoop.maxCallsPerTool,
            "calendar.search must stop at its per-tool budget despite changing arguments"
        )
        XCTAssertEqual(
            script.consumed,
            AgentLoop.maxToolRounds + 1,
            "at most one answer turn after the tool rounds"
        )
        XCTAssertEqual(world.proseOnlyTurns, 1)
        XCTAssertTrue(output.text.contains("Meeting with Shubh"), output.text)
    }

    /// The reported 10:40: the model had already subtracted the lead time, then
    /// grounding echoed that adjusted stamp back and it was subtracted a second
    /// time. Reproduced by putting the adjusted time ahead of the event in
    /// grounding, which is what a memory hit about the reminder does.
    func testAlreadyAdjustedDueIsNotShiftedASecondTime() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 9))!
        let writer = RecordingReminderWriter()
        let tool = RemindersCreateTool(writer: writer, calendar: calendar, now: { now })

        tool.setGroundingText(
            """
            Can you set up a reminder, 10 minutes before that meeting?
            Reminder “Meeting with Shubh” at 2026-09-04 10:50
            • 2026-09-04 11:00–12:00 · Meeting with Shubh · Work
            """
        )

        let result = try await tool.execute(arguments: [
            "title": .string("Meeting with Shubh"),
            "due": .string("2026-09-04 10:50"),
        ])

        XCTAssertTrue(result.textForModel.contains("Created reminder"), result.textForModel)
        let due = try XCTUnwrap(writer.created.first?.due)
        XCTAssertEqual(calendar.component(.hour, from: due), 10)
        XCTAssertEqual(
            calendar.component(.minute, from: due),
            50,
            "10:40 means the 10-minute lead time was subtracted twice"
        )
    }

    /// The answer turn must not carry the syntax it is meant to suppress.
    func testAnswerTurnIsProseOnlyAndCarriesNoToolSyntax() async throws {
        let world = Fixture()
        let call = AgentToolCall(
            name: "calendar.search",
            arguments: ["window": .string("today")]
        )
        let script = ScriptedModel([
            .calls([call]),
            .calls([call]),
            .text("You have a meeting with Shubh at 11am."),
        ])

        let output = try await world.run(userText: "What's on my calendar?", script: script)

        let answerTurn = try XCTUnwrap(world.lastProseOnlyContext)
        let joined = answerTurn.toolResultSummaries.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Meeting with Shubh"), "observations must survive")
        XCTAssertFalse(joined.contains("calendar.search:"), "a tool name in call position primes another call")
        XCTAssertFalse(joined.lowercased().contains("do not call"), "negative instructions name the tool again")
        XCTAssertTrue(joined.contains(AgentLoop.synthesisInstruction))
        XCTAssertEqual(output.text, "You have a meeting with Shubh at 11am.")
    }
}

// MARK: - Fixture

/// Real tools, fake EventKit, deterministic clock.
private final class Fixture: @unchecked Sendable {
    let calendar: Calendar
    let now: Date
    let writer = RecordingReminderWriter()
    let calendarTool: CalendarSearchTool
    let remindersTool: RemindersCreateTool

    private let lock = NSLock()
    private var executed: [String] = []
    private var proseOnlyCount = 0
    private var proseOnlyContext: AssembledPromptContext?
    private var lookups: [String] = []

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 9))!

        let meeting = CalendarEventSnapshot(
            title: "Meeting with Shubh",
            start: calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 11))!,
            end: calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12))!,
            calendarTitle: "Work",
            isAllDay: false
        )
        let fixedNow = now
        calendarTool = CalendarSearchTool(
            reader: StubCalendarReader(events: [meeting]),
            calendar: calendar,
            now: { fixedNow }
        )
        remindersTool = RemindersCreateTool(
            writer: writer,
            calendar: calendar,
            now: { fixedNow }
        )
    }

    /// Non-async so it stays usable from the executor's async context.
    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var executedTools: [String] {
        sync { executed }
    }

    var proseOnlyTurns: Int {
        sync { proseOnlyCount }
    }

    var lastProseOnlyContext: AssembledPromptContext? {
        sync { proseOnlyContext }
    }

    func run(userText: String, script: ScriptedModel) async throws -> AgentLoop.Output {
        try await AgentLoop.run(
            promptContext: promptContext(userText: userText),
            request: AgentGenerationRequest(
                toolSchemas: [calendarTool.schema, remindersTool.schema],
                maxToolRounds: 0
            ),
            generateStep: { [weak self] context, request in
                if request.responseMode == .proseOnly {
                    XCTAssertTrue(request.toolSchemas.isEmpty, "an answer turn must not offer tools")
                    self?.recordProseOnly(context)
                }
                return script.next()
            },
            execute: { [weak self] name, arguments in
                guard let self else { throw CancellationError() }
                return try await self.execute(name: name, arguments: arguments, userText: userText)
            },
            onToolEvent: { _ in }
        )
    }

    /// Mirrors `AgentSession`: dispatch by name, and ground `reminders.create` in the
    /// user text plus this turn's lookup results.
    private func execute(
        name: String,
        arguments: ToolArguments,
        userText: String
    ) async throws -> ToolExecutionResult {
        let grounding = sync {
            executed.append(name)
            return ([userText] + lookups).joined(separator: "\n")
        }

        switch name {
        case CalendarSearchTool.toolName:
            let result = try await calendarTool.execute(arguments: arguments)
            sync { lookups.append(result.textForModel) }
            return result
        case RemindersCreateTool.toolName:
            remindersTool.setGroundingText(grounding)
            return try await remindersTool.execute(arguments: arguments)
        default:
            return ToolExecutionResult(
                textForModel: "Unknown tool \(name).",
                displayText: "unknown",
                disposition: .failed
            )
        }
    }

    private func recordProseOnly(_ context: AssembledPromptContext) {
        lock.lock()
        proseOnlyCount += 1
        proseOnlyContext = context
        lock.unlock()
    }

    private func promptContext(userText: String) -> AssembledPromptContext {
        AssembledPromptContext(
            systemPrompt: "You are Nook.",
            activeSkillInstructions: nil,
            retrievedEvidence: [],
            recentMessages: [
                Message(conversationId: "regression", role: .user, content: userText)
            ],
            toolResultSummaries: [],
            totalEstimatedTokens: 0
        )
    }
}

private final class ScriptedModel: @unchecked Sendable {
    enum Step {
        case calls([AgentToolCall])
        case text(String)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var used = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var consumed: Int {
        lock.lock()
        defer { lock.unlock() }
        return used
    }

    func next() -> AgentGenerationResult {
        lock.lock()
        defer { lock.unlock() }
        guard used < steps.count else {
            XCTFail("model asked for more steps than the script provides")
            return AgentGenerationResult(text: "")
        }
        let step = steps[used]
        used += 1
        switch step {
        case .calls(let calls):
            return AgentGenerationResult(text: "", toolCalls: calls)
        case .text(let text):
            return AgentGenerationResult(text: text)
        }
    }
}

private struct StubCalendarReader: CalendarEventReading {
    var events: [CalendarEventSnapshot]

    func requestAccess() async throws -> Bool { true }

    func events(from start: Date, to end: Date) async throws -> [CalendarEventSnapshot] {
        events.filter { $0.start < end && $0.end > start }
    }
}

private final class RecordingReminderWriter: ReminderWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [ReminderDraft] = []

    private func sync<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var created: [ReminderDraft] {
        sync { drafts }
    }

    func requestAccess() async throws -> Bool { true }

    func create(_ draft: ReminderDraft) async throws -> String {
        sync { drafts.append(draft) }
        return "Reminders"
    }

    func listContainingDuplicate(of draft: ReminderDraft) async throws -> String? {
        sync {
            let match = drafts.contains { existing in
                guard existing.title.lowercased() == draft.title.lowercased() else { return false }
                switch (existing.due, draft.due) {
                case (nil, nil):
                    return true
                case (let lhs?, let rhs?):
                    return RemindersCreateTool.dueMinute(lhs) == RemindersCreateTool.dueMinute(rhs)
                default:
                    return false
                }
            }
            return match ? "Reminders" : nil
        }
    }
}
