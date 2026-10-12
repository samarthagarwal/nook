import Foundation

/// A todo/task item managed by Nook.
public struct TodoItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var isCompleted: Bool
    public var completedAt: Date?
    public var priority: Priority
    
    /// The conversation where this todo was created (for "Open source" linking)
    public var sourceConversationId: String?
    public var sourceMessageId: String?
    
    public let createdAt: Date
    public var updatedAt: Date
    
    public enum Priority: Int, Codable, Sendable, CaseIterable {
        case none = 0
        case low = 1
        case medium = 2
        case high = 3
        
        public var label: String {
            switch self {
            case .none: return "No priority"
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }
        
        public var symbol: String {
            switch self {
            case .none: return ""
            case .low: return "!"
            case .medium: return "!!"
            case .high: return "!!!"
            }
        }
    }
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        notes: String? = nil,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        priority: Priority = .none,
        sourceConversationId: String? = nil,
        sourceMessageId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.priority = priority
        self.sourceConversationId = sourceConversationId
        self.sourceMessageId = sourceMessageId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    /// Formatted due date string for display
    public var formattedDueDate: String? {
        guard let dueDate = dueDate else { return nil }
        
        let calendar = Calendar.current
        let now = Date()
        
        if calendar.isDateInToday(dueDate) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "Today \(formatter.string(from: dueDate))"
        } else if calendar.isDateInTomorrow(dueDate) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "Tomorrow \(formatter.string(from: dueDate))"
        } else if calendar.isDate(dueDate, equalTo: now, toGranularity: .weekOfYear) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: dueDate)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: dueDate)
        }
    }
    
    /// Returns a copy marked as completed
    public func completed() -> TodoItem {
        var copy = self
        copy.isCompleted = true
        copy.completedAt = Date()
        copy.updatedAt = Date()
        return copy
    }
    
    /// Returns a copy marked as not completed
    public func uncompleted() -> TodoItem {
        var copy = self
        copy.isCompleted = false
        copy.completedAt = nil
        copy.updatedAt = Date()
        return copy
    }
}
