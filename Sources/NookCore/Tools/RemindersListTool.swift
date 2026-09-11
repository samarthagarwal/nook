import EventKit
import Foundation

public struct ReminderSnapshot: Sendable {
    public let title: String
    public let due: Date?
    public let listName: String
    public let notes: String?

    public init(title: String, due: Date? = nil, listName: String, notes: String? = nil) {
        self.title = title
        self.due = due
        self.listName = listName
        self.notes = notes
    }
}

public protocol ReminderReading: Sendable {
    func requestAccess() async throws -> Bool
    /// Fetch incomplete reminders, optionally capped to those due before `cutoff`.
    func fetchIncomplete(dueBefore cutoff: Date?) async throws -> [ReminderSnapshot]
}

public final class EventKitReminderReader: @unchecked Sendable, ReminderReading {
    // Shared store — same XPC-connection reason as CalendarSearchTool/CalendarCreateTool.
    private let store = EKEventStore()

    public init() {}

    public func requestAccess() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(iOS 17.0, macOS 14.0, *) {
            switch status {
            case .fullAccess:  return true
            case .denied, .restricted: return false
            default: break
            }
            return try await store.requestFullAccessToReminders()
        } else {
            if status == .authorized { return true }
            if status == .denied || status == .restricted { return false }
            return try await store.requestAccess(to: .reminder)
        }
    }

    public func fetchIncomplete(dueBefore cutoff: Date?) async throws -> [ReminderSnapshot] {
        let store = self.store
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: cutoff,
            calendars: nil
        )
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let snapshots = (reminders ?? [])
                    .map { r -> ReminderSnapshot in
                        let due = r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                        return ReminderSnapshot(
                            title: r.title ?? "(No title)",
                            due: due,
                            listName: r.calendar?.title ?? "Reminders",
                            notes: r.notes
                        )
                    }
                    .sorted { lhs, rhs in
                        switch (lhs.due, rhs.due) {
                        case (let a?, let b?): return a < b
                        case (nil, _?):        return false
                        case (_?, nil):        return true
                        case (nil, nil):       return false
                        }
                    }
                continuation.resume(returning: snapshots)
            }
        }
    }
}

/// On-device Reminders read — registered as `reminders.list`.
public final class RemindersListTool: @unchecked Sendable, AgentTool {
    public static let toolName = "reminders.list"

    public var name: String { Self.toolName }
    public let description = """
        List the user's incomplete reminders. Use when the user asks what reminders \
        they have, what's on their to-do list, or to check for duplicates before \
        creating a new reminder.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "window",
            type: "string",
            description: "today, tomorrow, next_7_days, or all. Defaults to next_7_days.",
            required: false
        ),
    ]

    private let reader: any ReminderReading
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        reader: any ReminderReading = EventKitReminderReader(),
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
                textForModel: "Reminders access failed: \(error.localizedDescription). Ask the user to allow Reminders for Nook in Settings.",
                displayText: "\(Self.toolName) · access failed",
                disposition: .needsUser
            )
        }
        guard granted else {
            return ToolExecutionResult(
                textForModel: "The user has not allowed Reminders access. Ask them to enable Reminders for Nook in Settings.",
                displayText: "\(Self.toolName) · permission denied",
                disposition: .needsUser
            )
        }

        let currentNow = now()
        let window = (arguments["window"]?.stringValue ?? "next_7_days").lowercased()
        let cutoff: Date?
        switch window {
        case "today":
            cutoff = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: currentNow))
        case "tomorrow":
            let startTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: currentNow)) ?? currentNow
            cutoff = calendar.date(byAdding: .day, value: 1, to: startTomorrow)
        case "all":
            cutoff = nil
        default: // next_7_days
            cutoff = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: currentNow))
        }

        let reminders: [ReminderSnapshot]
        do {
            reminders = try await reader.fetchIncomplete(dueBefore: cutoff)
        } catch {
            return ToolExecutionResult(
                textForModel: "Could not read reminders: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · read failed",
                disposition: .failed
            )
        }

        guard !reminders.isEmpty else {
            return ToolExecutionResult(
                textForModel: "No incomplete reminders found for \(window).",
                displayText: "\(Self.toolName) · 0 reminders"
            )
        }

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = "yyyy-MM-dd HH:mm"

        let lines = reminders.prefix(30).map { r -> String in
            var parts = [r.title]
            if let due = r.due { parts.append("due \(fmt.string(from: due))") }
            parts.append(r.listName)
            return "• " + parts.joined(separator: " · ")
        }
        let count = reminders.count

        return ToolExecutionResult(
            textForModel: """
            Incomplete reminders (\(count)):
            \(lines.joined(separator: "\n"))
            """,
            displayText: "\(Self.toolName) · \(count) reminder\(count == 1 ? "" : "s")"
        )
    }
}
