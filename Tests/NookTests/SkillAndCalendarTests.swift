import XCTest
@testable import NookCore

final class SkillAndCalendarTests: XCTestCase {
    func testSlashCommandInvokesSkillAndStripsToken() async {
        let skills = await SkillManager().getAllSkills()
        let invoked = SkillActivation.parseInvocation(
            "/meeting-prep what's on this afternoon",
            skills: skills
        )
        XCTAssertEqual(invoked?.skill.id, "meeting-prep")
        XCTAssertEqual(invoked?.remainder, "what's on this afternoon")
    }

    func testSlashCommandMatchesSkillDisplayName() async {
        let skills = await SkillManager().getAllSkills()
        let invoked = SkillActivation.parseInvocation(
            "/Meeting Prep brief me",
            skills: skills
        )
        XCTAssertEqual(invoked?.skill.id, "meeting-prep")
        XCTAssertEqual(invoked?.remainder, "brief me")
    }

    func testOrdinaryTextDoesNotInvokeASkill() async {
        let skills = await SkillManager().getAllSkills()
        XCTAssertNil(
            SkillActivation.parseInvocation("Brief me for this afternoon", skills: skills)
        )
    }

    func testSlashAutocomplete() async {
        let skills = await SkillManager().getAllSkills()
        XCTAssertEqual(SkillActivation.autocomplete(prefix: "/", skills: skills).map(\.id), ["meeting-prep"])
        XCTAssertEqual(SkillActivation.autocomplete(prefix: "/meet", skills: skills).map(\.id), ["meeting-prep"])
        XCTAssertTrue(SkillActivation.autocomplete(prefix: "/meeting-prep hello", skills: skills).isEmpty)
    }

    func testCatalogOnlyListsMeetingPrep() async {
        let skills = await SkillManager().getAllSkills()
        XCTAssertEqual(skills.map(\.id), ["meeting-prep"])
    }

    func testGrantedToolNamesHonorsToggles() async {
        var skill = await SkillManager().getSkill(id: "meeting-prep")
        XCTAssertNotNil(skill)
        XCTAssertTrue(SkillActivation.grantedToolNames(for: skill).contains(CalendarSearchTool.toolName))

        skill?.permissions[0].isGranted = false
        XCTAssertFalse(SkillActivation.grantedToolNames(for: skill).contains(CalendarSearchTool.toolName))
    }

    func testCalendarSearchToolIsRegistered() async {
        let registry = ToolRegistry()
        let names = await registry.allToolNames()
        XCTAssertTrue(names.contains(CalendarSearchTool.toolName))
        let needsApproval = await registry.requiresApproval(toolName: CalendarSearchTool.toolName)
        XCTAssertFalse(needsApproval)
    }

    func testCalendarSearchFiltersAndFormatsEvents() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 15))!

        let todayStart = calendar.startOfDay(for: now)
        let vendor = CalendarEventSnapshot(
            title: "Vendor sync",
            start: calendar.date(byAdding: .hour, value: 14, to: todayStart)!,
            end: calendar.date(byAdding: .hour, value: 15, to: todayStart)!,
            location: "Office",
            calendarTitle: "Work",
            isAllDay: false
        )
        let standup = CalendarEventSnapshot(
            title: "Standup",
            start: calendar.date(byAdding: .hour, value: 10, to: todayStart)!,
            end: calendar.date(byAdding: .hour, value: 10, to: todayStart)!.addingTimeInterval(15 * 60),
            calendarTitle: "Work",
            isAllDay: false
        )
        let reader = MockCalendarReader(events: [vendor, standup])
        let tool = CalendarSearchTool(reader: reader, calendar: calendar, now: { now })

        let allToday = try await tool.execute(arguments: ["window": .string("today")])
        XCTAssertTrue(allToday.textForModel.contains("Vendor sync"))
        XCTAssertTrue(allToday.textForModel.contains("Standup"))
        XCTAssertTrue(allToday.textForModel.contains("2026-09-03 14:00"))
        XCTAssertTrue(allToday.displayText.contains("2 events"))
        XCTAssertFalse(allToday.isExternal)

        let filtered = try await tool.execute(arguments: [
            "window": .string("today"),
            "query": .string("vendor"),
        ])
        XCTAssertTrue(filtered.textForModel.contains("Vendor sync"))
        XCTAssertFalse(filtered.textForModel.contains("Standup"))
        XCTAssertTrue(filtered.displayText.contains("1 events"))

        let utterance = try await tool.execute(arguments: [
            "query": .string("Brief me for this afternoon"),
        ])
        XCTAssertTrue(utterance.textForModel.contains("Vendor sync"))
        XCTAssertTrue(utterance.textForModel.contains("Standup"))
    }

    func testGenericQueryDoesNotBecomeTitleFilter() {
        XCTAssertNil(CalendarSearchTool.titleFilter(from: "Brief me for this afternoon"))
        XCTAssertNil(CalendarSearchTool.titleFilter(from: "afternoon"))
        XCTAssertEqual(CalendarSearchTool.titleFilter(from: "vendor"), "vendor")
    }

    func testCalendarSearchReportsDeniedAccess() async throws {
        let reader = MockCalendarReader(accessGranted: false, events: [])
        let tool = CalendarSearchTool(reader: reader)
        let result = try await tool.execute(arguments: [:])
        XCTAssertTrue(result.textForModel.contains("not allowed Calendar access"))
        XCTAssertTrue(result.displayText.contains("permission denied"))
        XCTAssertEqual(result.disposition, .needsUser)
    }

    func testReplaceSkillPersistsGrants() async {
        let manager = SkillManager()
        var skill = await manager.getSkill(id: "meeting-prep")!
        skill.isEnabled = false
        skill.permissions[0].isGranted = false
        await manager.replaceSkill(skill)

        let stored = await manager.getSkill(id: "meeting-prep")
        XCTAssertEqual(stored?.isEnabled, false)
        XCTAssertEqual(stored?.permissions.first?.isGranted, false)
        let enabled = await manager.enabledSkills()
        XCTAssertFalse(enabled.contains(where: { $0.id == "meeting-prep" }))
    }

    func testSystemPromptIncludesOnlyInvokedSkill() async {
        let skill = await SkillManager().getSkill(id: "meeting-prep")!
        let idle = NookSystemPrompt.withSkills(base: "You are Nook.", active: nil)
        XCTAssertFalse(idle.contains("Meeting Prep"))
        let prompt = NookSystemPrompt.withSkills(base: "You are Nook.", active: skill)
        XCTAssertTrue(prompt.contains("Meeting Prep"))
        XCTAssertTrue(prompt.contains("invoked"))
        XCTAssertFalse(prompt.contains("Enabled Skills"))
    }

    func testRemindersCreateToolIsRegisteredWithoutApproval() async {
        let registry = ToolRegistry()
        let names = await registry.allToolNames()
        XCTAssertTrue(names.contains(RemindersCreateTool.toolName))
        let needsApproval = await registry.requiresApproval(toolName: RemindersCreateTool.toolName)
        XCTAssertFalse(needsApproval)
        XCTAssertTrue(AlwaysOfferedLocalTools.contains(RemindersCreateTool.toolName))
    }

    func testRemindersCreateWritesDraftAndStripsUtterancePrefix() async throws {
        let writer = MockReminderWriter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 15))!
        let tool = RemindersCreateTool(writer: writer, calendar: calendar, now: { now })

        let result = try await tool.execute(arguments: [
            "query": .string("Remind me to call the vendor"),
            "due": .string("tomorrow"),
        ])
        XCTAssertTrue(result.textForModel.contains("call the vendor"))
        XCTAssertTrue(result.displayText.contains("call the vendor"))
        XCTAssertEqual(writer.created.last?.title, "call the vendor")
        XCTAssertNotNil(writer.created.last?.due)
    }

    func testRemindersCreateReportsDeniedAccess() async throws {
        let writer = MockReminderWriter(accessGranted: false)
        let tool = RemindersCreateTool(writer: writer)
        let result = try await tool.execute(arguments: ["title": .string("Buy milk")])
        XCTAssertTrue(result.textForModel.contains("not allowed Reminders access"))
        XCTAssertEqual(result.disposition, .needsUser)
        XCTAssertTrue(writer.created.isEmpty)
    }

    func testReminderRejectsNonAbsoluteDueWithoutCreating() async throws {
        let writer = MockReminderWriter()
        let tool = RemindersCreateTool(writer: writer)
        let result = try await tool.execute(arguments: [
            "title": .string("Meeting with Shubh"),
            "due": .string("10 minutes before meeting with Shubh"),
        ])
        XCTAssertTrue(result.textForModel.contains("not an absolute time"))
        XCTAssertTrue(result.textForModel.contains("ask the user"))
        XCTAssertTrue(writer.created.isEmpty)
    }

    func testToolNameResolverAliasesReminderCreate() {
        let available: Set<String> = [
            RemindersCreateTool.toolName,
            CalendarSearchTool.toolName,
        ]
        XCTAssertEqual(
            ToolNameResolver.resolve("reminder.create", available: available),
            RemindersCreateTool.toolName
        )
        XCTAssertEqual(
            ToolNameResolver.resolve("reminders.create", available: available),
            RemindersCreateTool.toolName
        )
        XCTAssertNil(ToolNameResolver.resolve("reminder.create", available: [CalendarSearchTool.toolName]))
    }

    func testReminderDueTenMinutesBeforeGroundedMeeting() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 1, minute: 0))!
        let grounding = """
        Can you set up a reminder, 10 minutes before that meeting?
        • 2026-09-04 11:00–12:00 · Meeting with Shubh · Work
        """
        let fromPhrase = RemindersCreateTool.resolveDue(
            from: "10 minutes before that meeting",
            calendar: calendar,
            now: now,
            grounding: grounding
        )
        guard case .exact(let phraseDate, _) = fromPhrase else {
            return XCTFail("expected 10:50 from before-phrase")
        }
        XCTAssertEqual(calendar.component(.hour, from: phraseDate), 10)
        XCTAssertEqual(calendar.component(.minute, from: phraseDate), 50)

        let fromClock = RemindersCreateTool.resolveDue(
            from: "11:00",
            calendar: calendar,
            now: now,
            grounding: grounding
        )
        guard case .exact(let clockDate, _) = fromClock else {
            return XCTFail("expected 10:50 from meeting clock + lead time")
        }
        XCTAssertEqual(calendar.component(.hour, from: clockDate), 10)
        XCTAssertEqual(calendar.component(.minute, from: clockDate), 50)

        let stamped = RemindersCreateTool.resolveDue(
            from: "2026-09-04 10:50",
            calendar: calendar,
            now: now,
            grounding: grounding
        )
        guard case .exact(let stampDate, _) = stamped else {
            return XCTFail("expected structured 10:50 unchanged")
        }
        XCTAssertEqual(calendar.component(.hour, from: stampDate), 10)
        XCTAssertEqual(calendar.component(.minute, from: stampDate), 50)
    }

    func testReminderAcceptsStructuredLeadTimeBeforeGroundedEvent() async throws {
        let writer = MockReminderWriter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 1, minute: 0))!
        let tool = RemindersCreateTool(writer: writer, calendar: calendar, now: { now })
        tool.setGroundingText(
            """
            Can you set up a reminder, 10 minutes before that meeting?
            * **11:00–12:00:** Meeting with Shubh · Work
            """
        )
        let result = try await tool.execute(arguments: [
            "title": .string("Meeting with Shubh"),
            "due": .string("2026-09-04 10:50"),
        ])
        XCTAssertTrue(result.textForModel.contains("Created reminder"), result.textForModel)
        XCTAssertEqual(calendar.component(.hour, from: writer.created[0].due!), 10)
        XCTAssertEqual(calendar.component(.minute, from: writer.created[0].due!), 50)
    }

    func testReminderDueInTenMinutes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_000_000)
        let parsed = RemindersCreateTool.resolveDue(from: "in 10 minutes", calendar: calendar, now: now)
        guard case .exact(let date, _) = parsed else {
            return XCTFail("expected exact due")
        }
        XCTAssertEqual(date.timeIntervalSince(now), 600, accuracy: 1)
        if case .unparsed = RemindersCreateTool.resolveDue(
            from: "10 minutes before meeting with shubh",
            calendar: calendar,
            now: now
        ) {
            // expected
        } else {
            XCTFail("relative English due must be unparsed")
        }
    }

    func testReminderRejectsInventedStructuredDue() async throws {
        let writer = MockReminderWriter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 15))!
        let tool = RemindersCreateTool(writer: writer, calendar: calendar, now: { now })
        tool.setGroundingText("Can you remind me 10 minutes before the meeting with Shubh?")

        let result = try await tool.execute(arguments: [
            "title": .string("Meeting with Shubh"),
            "due": .string("2025-03-10 10:00"),
        ])
        XCTAssertTrue(result.textForModel.contains("not said by the user"))
        XCTAssertTrue(result.textForModel.contains("lookup"))
        XCTAssertTrue(writer.created.isEmpty)
    }

    func testReminderAcceptsStructuredDueFromToolResult() async throws {
        let writer = MockReminderWriter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 15))!
        let tool = RemindersCreateTool(writer: writer, calendar: calendar, now: { now })
        tool.setGroundingText(
            """
            Can you remind me 10 minutes before the meeting with Shubh?
            • 2026-09-04 11:00–12:00 · Meeting with Shubh · Work
            """
        )

        let result = try await tool.execute(arguments: [
            "title": .string("Meeting with Shubh"),
            "due": .string("2026-09-04 10:50"),
        ])
        XCTAssertTrue(result.textForModel.contains("Created reminder"))
        XCTAssertEqual(writer.created.count, 1)
    }

    /// A re-emitted create with drifting cosmetic arguments must not write twice.
    func testReminderCreateIsIdempotentOnTitleAndDueMinute() async throws {
        let writer = MockReminderWriter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 15))!
        let tool = RemindersCreateTool(writer: writer, calendar: calendar, now: { now })
        tool.setGroundingText("• 2026-09-04 11:00–12:00 · Meeting with Shubh · Work")

        let first = try await tool.execute(arguments: [
            "title": .string("Meeting with Shubh"),
            "due": .string("2026-09-04 10:50"),
        ])
        let second = try await tool.execute(arguments: [
            "title": .string("Meeting with Shubh"),
            "due": .string("2026-09-04 10:50"),
            "notes": .string("Reminder: Meeting with Shubh"),
        ])

        XCTAssertTrue(first.textForModel.contains("Created reminder"), first.textForModel)
        XCTAssertTrue(second.textForModel.contains("already in"), second.textForModel)
        XCTAssertEqual(second.disposition, .finished)
        XCTAssertEqual(writer.created.count, 1)
    }

    func testReminderParsesElevenAMInLocalTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 0, minute: 14))!

        let stamped = RemindersCreateTool.dueDate(from: "2026-09-04 11:00", calendar: calendar, now: now)
        XCTAssertEqual(calendar.component(.hour, from: stamped!), 11)
        XCTAssertEqual(calendar.component(.minute, from: stamped!), 0)
        let formatted = RemindersCreateTool.formatDue(stamped!, calendar: calendar)
        XCTAssertTrue(formatted.contains("11"), formatted)
        XCTAssertFalse(formatted.contains("5:30"), formatted)

        let clock = RemindersCreateTool.dueDate(from: "11 AM", calendar: calendar, now: now)
        XCTAssertEqual(calendar.component(.hour, from: clock!), 11)
    }

    func testReminderAcceptsClockGroundedOnSameDay() async throws {
        let writer = MockReminderWriter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 0, minute: 14))!
        let tool = RemindersCreateTool(writer: writer, calendar: calendar, now: { now })
        tool.setGroundingText("Can you set a reminder at 11 AM?")

        let result = try await tool.execute(arguments: [
            "title": .string("Important Meeting"),
            "due": .string("2026-09-04 11:00"),
        ])
        XCTAssertTrue(result.textForModel.contains("Created reminder"), result.textForModel)
        XCTAssertEqual(writer.created.count, 1)
        XCTAssertEqual(calendar.component(.hour, from: writer.created[0].due!), 11)
    }

    func testReminderRejectsPlaceholderTitle() async throws {
        let writer = MockReminderWriter()
        let tool = RemindersCreateTool(writer: writer)
        let result = try await tool.execute(arguments: [
            "title": .string("Set reminder"),
            "due": .string("tomorrow"),
        ])
        XCTAssertTrue(result.textForModel.contains("needs a title"))
        XCTAssertEqual(result.disposition, .needsUser)
        XCTAssertTrue(writer.created.isEmpty)
    }

    func testReminderRejectionDoesNotGroundTheInventedDate() async throws {
        let writer = MockReminderWriter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 15))!
        let tool = RemindersCreateTool(writer: writer, calendar: calendar, now: { now })
        tool.setGroundingText(
            """
            Set a reminder tomorrow
            reminders.create:
            due “2026-09-10 11:00” was not said by the user
            """
        )
        let result = try await tool.execute(arguments: [
            "title": .string("Important Meeting"),
            "due": .string("2026-09-10 11:00"),
        ])
        XCTAssertTrue(result.textForModel.contains("not said by the user"))
        XCTAssertEqual(result.disposition, .completed)
        XCTAssertTrue(writer.created.isEmpty)
    }

    func testGrantedToolsIncludeEveryEnabledSkill() {
        let meeting = Skill(
            id: "meeting-prep",
            name: "Meeting Prep",
            desc: "Brief from calendar",
            group: .builtIn,
            isEnabled: true,
            skillMdContent: "# Meeting Prep",
            permissions: [
                SkillPermission(tool: CalendarSearchTool.toolName, what: "Read Calendar", isGranted: true)
            ]
        )
        let extra = Skill(
            id: "notes",
            name: "Notes",
            desc: "Take notes",
            group: .yours,
            isEnabled: true,
            skillMdContent: "# Notes",
            permissions: [
                SkillPermission(tool: "notes.search", what: "Search notes", isGranted: true)
            ]
        )
        let granted = SkillActivation.grantedToolNames(for: [meeting, extra])
        XCTAssertEqual(granted, [CalendarSearchTool.toolName, "notes.search"])
    }

    func testReminderTitleFallsBackToNotes() {
        XCTAssertEqual(
            RemindersCreateTool.title(from: [
                "notes": .string("Meeting with Shubh"),
                "due": .string("2026-09-04 10:00"),
            ]),
            "Meeting with Shubh"
        )
        XCTAssertNil(RemindersCreateTool.title(from: ["title": .string("Reminder")]))
    }

    func testReminderTodayUsesClockFromGrounding() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 0, minute: 21))!
        let parsed = RemindersCreateTool.resolveDue(
            from: "today",
            calendar: calendar,
            now: now,
            grounding: "Set up a reminder for 10 am today."
        )
        guard case .exact(let date, _) = parsed else {
            return XCTFail("expected today 10:00")
        }
        XCTAssertEqual(calendar.component(.hour, from: date), 10)
        XCTAssertEqual(calendar.component(.minute, from: date), 0)
    }

    func testReminderTitleStripping() {
        XCTAssertEqual(
            RemindersCreateTool.strippedTitle("Remind me to send the invoice"),
            "send the invoice"
        )
        XCTAssertEqual(RemindersCreateTool.title(from: [:]), nil)
        XCTAssertEqual(
            RemindersCreateTool.title(from: ["title": .string("  Buy milk  ")]),
            "Buy milk"
        )
    }
}

private struct MockCalendarReader: CalendarEventReading {
    var accessGranted: Bool = true
    var events: [CalendarEventSnapshot]

    func requestAccess() async throws -> Bool {
        accessGranted
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEventSnapshot] {
        events.filter { $0.start < end && $0.end > start }
    }
}

private final class MockReminderWriter: ReminderWriting, @unchecked Sendable {
    var accessGranted: Bool
    var created: [ReminderDraft] = []

    init(accessGranted: Bool = true) {
        self.accessGranted = accessGranted
    }

    func requestAccess() async throws -> Bool {
        accessGranted
    }

    func create(_ draft: ReminderDraft) async throws -> String {
        created.append(draft)
        return "Reminders"
    }

    func listContainingDuplicate(of draft: ReminderDraft) async throws -> String? {
        let match = created.contains { existing in
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
