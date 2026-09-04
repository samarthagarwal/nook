import EventKit
import Foundation

public struct ReminderDraft: Sendable, Equatable {
    public let title: String
    public let due: Date?
    public let notes: String?

    public init(title: String, due: Date? = nil, notes: String? = nil) {
        self.title = title
        self.due = due
        self.notes = notes
    }
}

public protocol ReminderWriting: Sendable {
    func requestAccess() async throws -> Bool
    /// Returns the reminder list name the item was saved to.
    func create(_ draft: ReminderDraft) async throws -> String
    /// List name of an open reminder with the same title and due minute, if one
    /// already exists. Makes a repeated create a no-op instead of a duplicate.
    func listContainingDuplicate(of draft: ReminderDraft) async throws -> String?
}

public extension ReminderWriting {
    func listContainingDuplicate(of draft: ReminderDraft) async throws -> String? { nil }
}

public final class EventKitReminderWriter: @unchecked Sendable, ReminderWriting {
    public init() {}

    public func requestAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(iOS 17.0, macOS 14.0, *) {
            switch status {
            case .fullAccess:
                return true
            case .denied, .restricted:
                return false
            default:
                break
            }
            return try await EKEventStore().requestFullAccessToReminders()
        } else {
            if status == .authorized { return true }
            if status == .denied || status == .restricted { return false }
            return try await EKEventStore().requestAccess(to: .reminder)
        }
    }

    public func create(_ draft: ReminderDraft) async throws -> String {
        try await MainActor.run {
            let store = EKEventStore()
            let list = try Self.reminderList(in: store)
            let reminder = EKReminder(eventStore: store)
            reminder.title = draft.title
            reminder.notes = draft.notes
            reminder.calendar = list
            if let due = draft.due {
                var components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute],
                    from: due
                )
                components.timeZone = TimeZone.current
                reminder.dueDateComponents = components
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
            try store.save(reminder, commit: true)
            return list.title
        }
    }

    public func listContainingDuplicate(of draft: ReminderDraft) async throws -> String? {
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let wantedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let wantedMinute = draft.due.map { RemindersCreateTool.dueMinute($0) }

        // Compare inside the callback so no EKReminder crosses the continuation.
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            store.fetchReminders(matching: predicate) { reminders in
                let match = (reminders ?? []).first { reminder in
                    let title = (reminder.title ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    guard title == wantedTitle else { return false }
                    guard let wantedMinute else { return reminder.dueDateComponents == nil }
                    guard let components = reminder.dueDateComponents,
                          let existing = Calendar.current.date(from: components) else {
                        return false
                    }
                    return RemindersCreateTool.dueMinute(existing) == wantedMinute
                }
                continuation.resume(returning: match?.calendar?.title)
            }
        }
    }

    /// Simulator and fresh devices often have no default list until one is created.
    /// Never attach a new list to Exchange/subscribed/birthday sources — those throw
    /// EKError 24 ("That account does not support reminders").
    static func reminderList(in store: EKEventStore) throws -> EKCalendar {
        if let list = store.defaultCalendarForNewReminders() {
            return list
        }
        if let list = store.calendars(for: .reminder).first {
            return list
        }

        var lastError: Error?
        for sourceType: EKSourceType in [.local, .calDAV] {
            for source in store.sources where source.sourceType == sourceType {
                let list = EKCalendar(for: .reminder, eventStore: store)
                list.title = "Reminders"
                list.source = source
                do {
                    try store.saveCalendar(list, commit: true)
                    return list
                } catch {
                    lastError = error
                    continue
                }
            }
        }
        throw RemindersCreateToolError.cannotCreateList(underlying: lastError)
    }
}

/// Local tools the model may call without a Skill grant.
public enum AlwaysOfferedLocalTools {
    public static let names: Set<String> = [RemindersCreateTool.toolName]

    public static func contains(_ name: String) -> Bool {
        names.contains(name)
    }
}

/// On-device Reminders write — registered as `reminders.create`.
public final class RemindersCreateTool: @unchecked Sendable, AgentTool {
    public static let toolName = "reminders.create"

    public var name: String { Self.toolName }
    public let description = """
        Create an iPhone reminder when the user asks to be reminded or add a to-do. \
        Do not ask for confirmation. Never invent due — use today, tomorrow, tonight, \
        in 10 minutes, or yyyy-MM-dd HH:mm copied from the user or a lookup. \
        If the time is unknown, look it up or ask. Never say the reminder was set \
        unless a tool result says Created reminder.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "title",
            type: "string",
            description: "The reminder title, e.g. Call the vendor.",
            required: true
        ),
        AgentToolParameterSchema(
            name: "due",
            type: "string",
            description: "Absolute due only: today, tomorrow, tonight, in 10 minutes, or yyyy-MM-dd HH:mm. Omit if unknown.",
            required: false
        ),
        AgentToolParameterSchema(
            name: "notes",
            type: "string",
            description: "Optional extra notes.",
            required: false
        ),
    ]

    private let writer: any ReminderWriting
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private let groundingLock = NSLock()
    private var groundingText = ""

    public init(
        writer: any ReminderWriting = EventKitReminderWriter(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.writer = writer
        self.calendar = calendar
        self.now = now
    }

    /// User messages plus this-turn tool results. Structured dues must appear here.
    public func setGroundingText(_ text: String) {
        groundingLock.lock()
        groundingText = text
        groundingLock.unlock()
    }

    private func currentGroundingText() -> String {
        groundingLock.lock()
        defer { groundingLock.unlock() }
        return groundingText
    }

    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        let title = Self.title(from: arguments)
        guard let title, !Self.isPlaceholderTitle(title) else {
            return ToolExecutionResult(
                textForModel: "reminders.create needs a title. Ask the user what to remind them about.",
                displayText: "\(Self.toolName) · missing title",
                disposition: .needsUser
            )
        }

        let grounding = currentGroundingText()
        switch Self.resolveDue(
            from: arguments["due"]?.stringValue,
            calendar: calendar,
            now: now(),
            grounding: grounding
        ) {
        case .unparsed(let raw):
            return ToolExecutionResult(
                textForModel: """
                due “\(raw)” is not an absolute time. Do not create the reminder yet. \
                If another tool can look the time up, call that tool now, then call \
                reminders.create with due as yyyy-MM-dd HH:mm. \
                If you still do not know the time, stop calling tools and ask the user.
                """,
                displayText: "\(Self.toolName) · need a time",
                disposition: .completed
            )
        case .exact(let parsed, let raw):
            if Self.isInventedStructuredDue(raw: raw, parsed: parsed, calendar: calendar, now: now(), source: grounding) {
                return ToolExecutionResult(
                    textForModel: """
                    That due was not said by the user and is not in a prior lookup result. \
                    Do not invent another date. Call a lookup tool now (for example calendar.search), \
                    then retry reminders.create with that yyyy-MM-dd HH:mm — or stop and ask the user.
                    """,
                    displayText: "\(Self.toolName) · invented time",
                    disposition: .completed
                )
            }
            if parsed.addingTimeInterval(60) < now() {
                return ToolExecutionResult(
                    textForModel: """
                    due “\(raw)” is in the past. Do not create the reminder. \
                    Look up a future time with another tool or ask the user.
                    """,
                    displayText: "\(Self.toolName) · past time",
                    disposition: .completed
                )
            }
        case .none:
            break
        }

        let granted: Bool
        do {
            granted = try await writer.requestAccess()
        } catch {
            return ToolExecutionResult(
                textForModel: "Reminders access failed: \(error.localizedDescription). Ask the user to allow Reminders for Nook in Settings.",
                displayText: "\(Self.toolName) · access failed",
                disposition: .needsUser
            )
        }
        guard granted else {
            return ToolExecutionResult(
                textForModel: "The user has not allowed Reminders access. Ask them to enable Reminders for Nook in Settings, then try again.",
                displayText: "\(Self.toolName) · permission denied",
                disposition: .needsUser
            )
        }

        let due: Date?
        if case .exact(let parsed, _) = Self.resolveDue(
            from: arguments["due"]?.stringValue,
            calendar: calendar,
            now: now(),
            grounding: grounding
        ) {
            due = parsed
        } else {
            due = nil
        }
        return try await save(
            title: title,
            due: due,
            notes: Self.notes(from: arguments),
            writer: writer
        )
    }

    private func save(
        title: String,
        due: Date?,
        notes: String?,
        writer: any ReminderWriting
    ) async throws -> ToolExecutionResult {
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = ReminderDraft(
            title: title,
            due: due,
            notes: (trimmedNotes?.isEmpty == false) ? trimmedNotes : nil
        )

        let when = due.map { " due \(Self.formatDue($0, calendar: calendar))" } ?? ""

        // A model that re-emits the create rarely re-emits identical arguments, so
        // dedupe on the effect rather than on the call.
        if let existing = try? await writer.listContainingDuplicate(of: draft) {
            return ToolExecutionResult(
                textForModel: "“\(title)”\(when) is already in the “\(existing)” list on this iPhone.",
                displayText: "\(Self.toolName) · \(title) (already set)",
                disposition: .finished
            )
        }

        do {
            let listName = try await writer.create(draft)
            return ToolExecutionResult(
                textForModel: "Created reminder “\(title)”\(when) in the “\(listName)” list on this iPhone.",
                displayText: "\(Self.toolName) · \(title)",
                disposition: .finished
            )
        } catch {
            return ToolExecutionResult(
                textForModel: """
                Could not create the reminder: \(error.localizedDescription). \
                Do not say the reminder was set. Tell the user to open the Reminders app, \
                create a list, allow Nook access, then ask again. \
                The iOS Simulator does not use Mac Reminders.
                """,
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }
    }

    /// LiteRT often puts the whole request in `query` instead of `title`.
    static func title(from arguments: ToolArguments) -> String? {
        let candidates = [
            arguments["title"]?.stringValue,
            arguments["query"]?.stringValue,
            arguments["notes"]?.stringValue,
        ]
        for raw in candidates {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { continue }
            let stripped = Self.strippedTitle(trimmed)
            guard !stripped.isEmpty, !isPlaceholderTitle(stripped) else { continue }
            return stripped
        }
        return nil
    }

    static func strippedTitle(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "remind me to ", "remind me ", "set a reminder to ",
            "add a reminder to ", "add a reminder ", "remember to ",
        ]
        let lowered = text.lowercased()
        for prefix in prefixes {
            if lowered.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPlaceholderTitle(_ title: String) -> Bool {
        let lowered = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "set reminder", "a reminder", "reminder", "remind me",
            "the reminder", "new reminder", "untitled",
        ].contains(lowered)
    }

    enum DueResolution: Equatable {
        case none
        case exact(Date, raw: String)
        case unparsed(String)
    }

    static func resolveDue(
        from raw: String?,
        calendar: Calendar,
        now: Date,
        grounding: String = ""
    ) -> DueResolution {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return .none }
        let lowered = trimmed.lowercased()
        if (lowered == "today" || lowered == "tonight"),
           let clock = firstClock(in: grounding),
           let dated = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: now) {
            return .exact(
                applyLeadTime(dated, grounding: grounding, raw: trimmed, calendar: calendar),
                raw: trimmed
            )
        }
        if let minutes = minutesBefore(in: lowered),
           let event = firstEventDate(in: grounding, calendar: calendar, now: now) {
            return .exact(event.addingTimeInterval(TimeInterval(-minutes * 60)), raw: trimmed)
        }
        if let date = dueDate(from: trimmed, calendar: calendar, now: now) {
            if looksLikeStructuredStamp(trimmed) {
                return .exact(date, raw: trimmed)
            }
            return .exact(
                applyLeadTime(date, grounding: grounding, raw: trimmed, calendar: calendar),
                raw: trimmed
            )
        }
        return .unparsed(trimmed)
    }

    /// Structured yyyy-MM-dd dues must appear in the user text or a tool result.
    /// Relative tokens (today, tomorrow, in N minutes) are not invented.
    static func isInventedStructuredDue(
        raw: String,
        parsed: Date,
        calendar: Calendar,
        now: Date,
        source: String
    ) -> Bool {
        if isRelativeDueToken(raw) { return false }
        return !isStructuredDueGrounded(parsed: parsed, calendar: calendar, now: now, source: source)
    }

    static func isRelativeDueToken(_ raw: String) -> Bool {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered == "today" || lowered == "tomorrow" || lowered == "tonight" { return true }
        if relativeMinutes(in: lowered) != nil { return true }
        if minutesBefore(in: lowered) != nil { return true }
        return parseClock(lowered) != nil
    }

    static func isStructuredDueGrounded(
        parsed: Date,
        calendar: Calendar,
        now: Date,
        source: String
    ) -> Bool {
        let lowered = source
            .components(separatedBy: .newlines)
            .filter { !$0.lowercased().contains("not said by the user") }
            .joined(separator: "\n")
            .lowercased()
        guard !lowered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        let stamp = yyyyMMdd(parsed, calendar: calendar)
        if lowered.contains(stamp) { return true }

        let monthDay = DateFormatter()
        monthDay.calendar = calendar
        monthDay.timeZone = calendar.timeZone
        monthDay.locale = Locale(identifier: "en_US")
        monthDay.dateFormat = "MMMM d"
        if lowered.contains(monthDay.string(from: parsed).lowercased()) { return true }
        monthDay.dateFormat = "MMM d"
        if lowered.contains(monthDay.string(from: parsed).lowercased()) { return true }

        if calendar.isDate(parsed, inSameDayAs: now),
           lowered.contains("today") || lowered.contains("tonight") {
            return true
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(parsed, inSameDayAs: tomorrow),
           lowered.contains("tomorrow") {
            return true
        }

        if clockMentioned(in: lowered, matching: parsed, calendar: calendar),
           calendar.isDate(parsed, inSameDayAs: now)
            || (calendar.date(byAdding: .day, value: 1, to: now).map { calendar.isDate(parsed, inSameDayAs: $0) } == true) {
            return true
        }
        if let event = firstEventDate(in: source, calendar: calendar, now: now), parsed < event {
            let minutes = event.timeIntervalSince(parsed) / 60
            if minutes > 0, minutes <= 120, lowered.contains("before") || lowered.contains("minute") {
                return true
            }
        }
        return false
    }

    static func yyyyMMdd(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func notes(from arguments: ToolArguments) -> String? {
        guard let raw = arguments["notes"]?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.lowercased() == "null" || trimmed.lowercased() == "nil" { return nil }
        return trimmed
    }

    static func dueDate(from raw: String?, calendar: Calendar, now: Date) -> Date? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        if lowered == "today" {
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
        }
        if lowered == "tonight" {
            return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now)
        }
        if lowered == "tomorrow" {
            let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: start)
        }
        if let minutes = relativeMinutes(in: lowered) {
            return now.addingTimeInterval(TimeInterval(minutes * 60))
        }
        if let clock = parseClock(lowered) {
            return date(on: now, at: clock, calendar: calendar)
        }

        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = calendar.timeZone
        local.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = local.date(from: trimmed) { return date }
        local.dateFormat = "yyyy-MM-dd"
        if trimmed.count == 10, let date = local.date(from: trimmed) { return date }

        // Only true ISO strings (T / Z). `yyyy-MM-dd HH:mm` must not hit date-only UTC midnight.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        return nil
    }

    static func firstClock(in source: String) -> (hour: Int, minute: Int)? {
        let lowered = source.lowercased()
        let pattern = #"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)\b"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
           let snippet = Range(match.range, in: lowered) {
            return parseClock(String(lowered[snippet]))
        }
        let pattern24 = #"\b(\d{1,2}):(\d{2})\b"#
        if let regex = try? NSRegularExpression(pattern: pattern24),
           let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
           let hourRange = Range(match.range(at: 1), in: lowered),
           let minuteRange = Range(match.range(at: 2), in: lowered),
           let hour = Int(lowered[hourRange]),
           let minute = Int(lowered[minuteRange]),
           (0...23).contains(hour), (0...59).contains(minute) {
            return (hour, minute)
        }
        return parseClock(lowered.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func firstEventDate(in source: String, calendar: Calendar, now: Date) -> Date? {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = calendar.timeZone
        local.dateFormat = "yyyy-MM-dd HH:mm"
        let stamp = #"(\d{4}-\d{2}-\d{2} \d{2}:\d{2})"#
        if let regex = try? NSRegularExpression(pattern: stamp),
           let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
           let range = Range(match.range(at: 1), in: source),
           let date = local.date(from: String(source[range])) {
            return date
        }
        if let clock = firstClock(in: source) {
            return date(on: now, at: clock, calendar: calendar)
        }
        return nil
    }

    static func minutesBefore(in lowered: String) -> Int? {
        let pattern = #"(\d+)\s*(minutes?|mins?)\s+before"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              let amountRange = Range(match.range(at: 1), in: lowered),
              let amount = Int(lowered[amountRange]) else {
            return nil
        }
        return amount
    }

    /// Minute-resolution identity for duplicate detection.
    static func dueMinute(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }

    static func looksLikeStructuredStamp(_ raw: String) -> Bool {
        raw.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    static func applyLeadTime(_ date: Date, grounding: String, raw: String, calendar: Calendar) -> Date {
        let blob = "\(grounding) \(raw)".lowercased()
        guard let minutes = minutesBefore(in: blob),
              let event = firstEventDate(in: grounding, calendar: calendar, now: date) else {
            return date
        }
        if abs(date.timeIntervalSince(event)) < 60 {
            return event.addingTimeInterval(TimeInterval(-minutes * 60))
        }
        return date
    }

    static func parseClock(_ lowered: String) -> (hour: Int, minute: Int)? {
        let pattern = #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              let hourRange = Range(match.range(at: 1), in: lowered),
              var hour = Int(lowered[hourRange]) else {
            return nil
        }
        var minute = 0
        if match.range(at: 2).location != NSNotFound,
           let minuteRange = Range(match.range(at: 2), in: lowered) {
            minute = Int(lowered[minuteRange]) ?? 0
        }
        let meridiem: String
        if match.range(at: 3).location != NSNotFound,
           let meridiemRange = Range(match.range(at: 3), in: lowered) {
            meridiem = String(lowered[meridiemRange]).replacingOccurrences(of: ".", with: "")
        } else {
            meridiem = ""
        }
        if meridiem == "pm", hour < 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if meridiem.isEmpty, match.range(at: 2).location == NSNotFound { return nil }
        return (hour, minute)
    }

    static func date(on now: Date, at clock: (hour: Int, minute: Int), calendar: Calendar) -> Date? {
        guard var candidate = calendar.date(
            bySettingHour: clock.hour,
            minute: clock.minute,
            second: 0,
            of: now
        ) else { return nil }
        if candidate.addingTimeInterval(60) < now,
           let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           let rolled = calendar.date(bySettingHour: clock.hour, minute: clock.minute, second: 0, of: tomorrow) {
            candidate = rolled
        }
        return candidate
    }

    static func clockMentioned(in source: String, matching parsed: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: parsed)
        let minute = calendar.component(.minute, from: parsed)
        let hhmm = String(format: "%02d:%02d", hour, minute)
        let h = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour)
        let suffix = hour >= 12 ? "pm" : "am"
        let compact = "\(h)\(suffix)"
        let spaced = minute == 0 ? "\(h) \(suffix)" : String(format: "%d:%02d %@", h, minute, suffix)
        return source.contains(hhmm)
            || source.contains(spaced)
            || source.contains(compact)
            || source.contains("\(h):\(String(format: "%02d", minute)) \(suffix)")
    }

    static func formatDue(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relativeMinutes(in lowered: String) -> Int? {
        let pattern = #"^in\s+(\d+)\s*(minutes?|mins?|hours?|hrs?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              let amountRange = Range(match.range(at: 1), in: lowered),
              let unitRange = Range(match.range(at: 2), in: lowered),
              let amount = Int(lowered[amountRange]) else {
            return nil
        }
        let unit = String(lowered[unitRange])
        return unit.hasPrefix("hour") || unit.hasPrefix("hr") ? amount * 60 : amount
    }

}

enum RemindersCreateToolError: LocalizedError {
    case noReminderList
    case cannotCreateList(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .noReminderList:
            return "No Reminders list is available on this device."
        case .cannotCreateList(let underlying):
            let detail = underlying?.localizedDescription ?? "no reminder-capable account"
            return "Could not create a Reminders list (\(detail)). Open the Reminders app once and add a list."
        }
    }
}
