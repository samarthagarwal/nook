import EventKit
import Foundation

public struct CalendarEventDraft: Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
    public let notes: String?

    public init(
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.notes = notes
    }
}

public protocol CalendarEventWriting: Sendable {
    func requestAccess() async throws -> Bool
    /// Returns the calendar title the event was saved to.
    func create(_ draft: CalendarEventDraft) async throws -> String
}

public final class EventKitCalendarWriter: @unchecked Sendable, CalendarEventWriting {
    // One shared store per writer — EventKit's XPC connection is per-instance.
    // Creating a new store on every call causes the "XPC connection was invalidated" error.
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(iOS 17.0, macOS 14.0, *) {
            switch status {
            case .fullAccess:  return true
            case .denied, .restricted: return false
            default: break
            }
            return try await store.requestFullAccessToEvents()
        } else {
            if status == .authorized { return true }
            if status == .denied || status == .restricted { return false }
            return try await store.requestAccess(to: .event)
        }
    }

    public func create(_ draft: CalendarEventDraft) async throws -> String {
        // EKEventStore.save() is thread-safe — no MainActor.run needed.
        // Running on MainActor while the keyboard is active causes a 3s timeout.
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.location = draft.location
        event.notes = draft.notes

        guard let cal = store.defaultCalendarForNewEvents else {
            throw CalendarCreateError.noDefaultCalendar
        }
        event.calendar = cal
        try store.save(event, span: .thisEvent, commit: true)
        return cal.title
    }
}

enum CalendarCreateError: LocalizedError {
    case noDefaultCalendar
    var errorDescription: String? {
        "No default calendar found. Open the Calendar app, create a calendar, and allow Nook access in Settings."
    }
}

/// On-device EventKit event creation — registered as `calendar.create`.
public final class CalendarCreateTool: @unchecked Sendable, AgentTool {
    public static let toolName = "calendar.create"

    public var name: String { Self.toolName }
    public let description = """
        Create a calendar event when the user asks to schedule a meeting, appointment, call, \
        or another event with a real clock time (yyyy-MM-dd HH:mm). \
        Never use this for a to-do, task, checklist, or todo list — those are reminders.create. \
        Do not invent a start of "today" or a date without a time. \
        Requires title and start. End defaults to 1 hour after start.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "title",
            type: "string",
            description: "Event title.",
            required: true
        ),
        AgentToolParameterSchema(
            name: "start",
            type: "string",
            description: "Start time as yyyy-MM-dd HH:mm.",
            required: true
        ),
        AgentToolParameterSchema(
            name: "end",
            type: "string",
            description: "End time as yyyy-MM-dd HH:mm. Defaults to 1 hour after start.",
            required: false
        ),
        AgentToolParameterSchema(
            name: "location",
            type: "string",
            description: "Optional location.",
            required: false
        ),
        AgentToolParameterSchema(
            name: "notes",
            type: "string",
            description: "Optional event notes.",
            required: false
        ),
    ]

    private let writer: any CalendarEventWriting
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        writer: any CalendarEventWriting = EventKitCalendarWriter(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.writer = writer
        self.calendar = calendar
        self.now = now
    }

    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        let title = (arguments["title"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return ToolExecutionResult(
                textForModel: "calendar.create requires a title.",
                displayText: "\(Self.toolName) · missing title",
                disposition: .needsUser
            )
        }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd HH:mm"

        let startRaw = (arguments["start"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = fmt.date(from: startRaw) else {
            return ToolExecutionResult(
                textForModel: """
                calendar.create: start "\(startRaw)" is not a valid yyyy-MM-dd HH:mm timestamp. \
                Ask the user for the exact date and time.
                """,
                displayText: "\(Self.toolName) · invalid start",
                disposition: .needsUser
            )
        }

        let end: Date
        if let endRaw = arguments["end"]?.stringValue,
           !endRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let parsed = fmt.date(from: endRaw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            end = parsed
        } else {
            end = start.addingTimeInterval(3600)
        }

        let granted: Bool
        do {
            granted = try await writer.requestAccess()
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

        let draft = CalendarEventDraft(
            title: title,
            start: start,
            end: end,
            location: arguments["location"]?.stringValue,
            notes: arguments["notes"]?.stringValue
        )

        do {
            let calTitle = try await writer.create(draft)
            let confirmMsg = "Created calendar event \"\(title)\" on \(fmt.string(from: start)) in the \"\(calTitle)\" calendar."
            print("[CalendarCreate] \(confirmMsg)")
            return ToolExecutionResult(
                textForModel: confirmMsg,
                displayText: "\(Self.toolName) · \(title)",
                disposition: .finished
            )
        } catch {
            let errMsg = "Could not create the event: \(error.localizedDescription)."
            print("[CalendarCreate] ERROR: \(errMsg)")
            return ToolExecutionResult(
                textForModel: errMsg,
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }
    }
}
