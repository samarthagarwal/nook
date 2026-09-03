import EventKit
import Foundation

public struct CalendarEventSnapshot: Sendable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
    public let notes: String?
    public let calendarTitle: String
    public let isAllDay: Bool

    public init(
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        notes: String? = nil,
        calendarTitle: String,
        isAllDay: Bool
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
        self.calendarTitle = calendarTitle
        self.isAllDay = isAllDay
    }
}

public protocol CalendarEventReading: Sendable {
    func requestAccess() async throws -> Bool
    func events(from start: Date, to end: Date) async throws -> [CalendarEventSnapshot]
}

public final class EventKitCalendarReader: @unchecked Sendable, CalendarEventReading {
    public init() {}

    public func requestAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, macOS 14.0, *) {
            switch status {
            case .fullAccess:
                return true
            case .denied, .restricted:
                return false
            default:
                break
            }
            return try await EKEventStore().requestFullAccessToEvents()
        } else {
            if status == .authorized { return true }
            if status == .denied || status == .restricted { return false }
            return try await EKEventStore().requestAccess(to: .event)
        }
    }

    public func events(from start: Date, to end: Date) async throws -> [CalendarEventSnapshot] {
        // A new store after permission — the instance used for requestAccess often
        // still reports zero calendars until it is recreated.
        let store = EKEventStore()
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: calendars.isEmpty ? nil : calendars
        )
        return store.events(matching: predicate).map { event in
            CalendarEventSnapshot(
                title: event.title ?? "(No title)",
                start: event.startDate,
                end: event.endDate,
                location: event.location,
                notes: event.notes,
                calendarTitle: event.calendar?.title ?? "Calendar",
                isAllDay: event.isAllDay
            )
        }
    }
}

/// On-device EventKit search — registered as `calendar.search`.
public final class CalendarSearchTool: @unchecked Sendable, AgentTool {
    public static let toolName = "calendar.search"

    public var name: String { Self.toolName }
    public let description = """
        Look up event start times (yyyy-MM-dd HH:mm) before a reminder about a meeting. \
        Also use for briefs and today's schedule. Pass window only unless they named a title.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "window",
            type: "string",
            description: "Time window: today, tomorrow, or next_7_days. Defaults to today.",
            required: false
        ),
        AgentToolParameterSchema(
            name: "query",
            type: "string",
            description: "Only an event title to match. Never the user's whole message.",
            required: false
        ),
    ]

    private let reader: any CalendarEventReading
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        reader: any CalendarEventReading = EventKitCalendarReader(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reader = reader
        self.calendar = calendar
        self.now = now
    }

    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        let granted: Bool
        do {
            granted = try await reader.requestAccess()
        } catch {
            return ToolExecutionResult(
                textForModel: "Calendar access failed: \(error.localizedDescription). Ask the user to allow Calendar for Nook in Settings.",
                displayText: "\(Self.toolName) · access failed",
                disposition: .needsUser
            )
        }
        guard granted else {
            return ToolExecutionResult(
                textForModel: "The user has not allowed Calendar access. Ask them to enable Calendar for Nook in Settings, then try again.",
                displayText: "\(Self.toolName) · permission denied",
                disposition: .needsUser
            )
        }

        let rawQuery = arguments["query"]?.stringValue
        var window = Self.window(from: arguments["window"]?.stringValue)
        if arguments["window"]?.stringValue == nil, let inferred = Self.windowHint(from: rawQuery) {
            window = inferred
        }
        let titleFilter = Self.titleFilter(from: rawQuery)
        let range = Self.dateRange(window: window, calendar: calendar, now: now())
        let rawEvents: [CalendarEventSnapshot]
        do {
            rawEvents = try await reader.events(from: range.start, to: range.end)
        } catch {
            return ToolExecutionResult(
                textForModel: "Could not read calendar events: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · read failed",
                disposition: .failed
            )
        }

        var filtered = Self.filter(events: rawEvents, query: titleFilter ?? "")
            .sorted { $0.start < $1.start }
        var usedFilter = titleFilter
        if filtered.isEmpty, titleFilter != nil, !rawEvents.isEmpty {
            filtered = rawEvents.sorted { $0.start < $1.start }
            usedFilter = nil
        }
        var limited = Array(filtered.prefix(25))
        var windowNote = window.displayName

        if limited.isEmpty, window == .today {
            let week = Self.dateRange(window: .next7Days, calendar: calendar, now: now())
            if let upcoming = try? await reader.events(from: week.start, to: week.end),
               !upcoming.isEmpty {
                limited = Array(upcoming.sorted { $0.start < $1.start }.prefix(25))
                windowNote = "the next 7 days (nothing today)"
                window = .next7Days
            }
        }

        if limited.isEmpty {
            let filterNote = usedFilter.map { " matching “\($0)”" } ?? ""
            return ToolExecutionResult(
                textForModel: "No calendar events\(filterNote) in \(window.displayName). If the user added the event on a Mac, it will not appear in the iOS Simulator Calendar.",
                displayText: "\(Self.toolName) · \(window.rawValue) · 0 events"
            )
        }

        let lines = limited.map { Self.format($0, calendar: calendar) }
        return ToolExecutionResult(
            textForModel: """
            Calendar events for \(windowNote) (on device). Use these for the brief; do not invent meetings:
            \(lines.joined(separator: "\n"))
            """,
            displayText: "\(Self.toolName) · \(window.rawValue) · \(limited.count) events"
        )
    }

    enum Window: String {
        case today
        case tomorrow
        case next7Days = "next_7_days"

        var displayName: String {
            switch self {
            case .today: return "today"
            case .tomorrow: return "tomorrow"
            case .next7Days: return "the next 7 days"
            }
        }
    }

    static func window(from raw: String?) -> Window {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "tomorrow": return .tomorrow
        case "next_7_days", "week", "next week": return .next7Days
        default: return .today
        }
    }

    /// LiteRT often stuffs the user's whole message into `query`.
    static func windowHint(from raw: String?) -> Window? {
        guard let lowered = raw?.lowercased() else { return nil }
        if lowered.contains("tomorrow") { return .tomorrow }
        if lowered.contains("week") { return .next7Days }
        return nil
    }

    private static let genericQueryTokens: Set<String> = [
        "brief", "today", "tomorrow", "afternoon", "morning", "evening",
        "calendar", "meeting", "meetings", "schedule", "prep", "prepare",
        "what", "when", "this", "week", "next", "events", "event", "please",
    ]

    /// Drops user-utterance / generic queries so they do not hide every event.
    static func titleFilter(from raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if tokens.count > 4 || trimmed.count > 24 { return nil }
        let meaningful = Set(tokens.filter { $0.count >= 3 && !["for", "the", "and"].contains($0) })
        if meaningful.isEmpty || meaningful.isSubset(of: genericQueryTokens) {
            return nil
        }
        return trimmed
    }

    static func dateRange(window: Window, calendar: Calendar, now: Date) -> (start: Date, end: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        switch window {
        case .today:
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
            return (startOfToday, end)
        case .tomorrow:
            let start = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            return (start, end)
        case .next7Days:
            let end = calendar.date(byAdding: .day, value: 7, to: startOfToday) ?? now
            return (startOfToday, end)
        }
    }

    static func filter(events: [CalendarEventSnapshot], query: String) -> [CalendarEventSnapshot] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return events }
        return events.filter { event in
            let haystack = [event.title, event.location, event.notes, event.calendarTitle]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            return haystack.contains(needle)
        }
    }

    static func format(_ event: CalendarEventSnapshot, calendar: Calendar) -> String {
        let startStamp = absoluteStamp(event.start, calendar: calendar)
        let when: String
        if event.isAllDay {
            when = "\(Self.yyyyMMdd(event.start, calendar: calendar)) all day"
        } else if calendar.isDate(event.start, inSameDayAs: event.end) {
            when = "\(startStamp)–\(clockStamp(event.end, calendar: calendar))"
        } else {
            when = "\(startStamp)–\(absoluteStamp(event.end, calendar: calendar))"
        }
        var parts = [when, event.title]
        if let location = event.location, !location.isEmpty {
            parts.append(location)
        }
        parts.append(event.calendarTitle)
        return "• " + parts.joined(separator: " · ")
    }

    static func absoluteStamp(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func yyyyMMdd(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func clockStamp(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
