import Foundation

// MARK: - Todos Create Tool

/// Creates an internal Nook todo item.
public final class TodosCreateTool: @unchecked Sendable, AgentTool {
    public static let toolName = "todos.create"
    
    public var name: String { Self.toolName }
    public let description = """
        Create a Nook todo/task when the user asks to add something to their todo list, \
        remember to do something, or track a task. One todo per item. \
        Use for personal tasks, errands, and to-dos. \
        For calendar events with specific times, use calendar.create instead. \
        For iOS Reminders app specifically, use reminders.create instead.
        """
    
    public var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "The todo title/task description"
                ],
                "due": [
                    "type": "string",
                    "description": "Optional due date in natural language (today, tomorrow, next week) or yyyy-MM-dd HH:mm format"
                ],
                "priority": [
                    "type": "string",
                    "enum": ["none", "low", "medium", "high"],
                    "description": "Task priority level"
                ],
                "notes": [
                    "type": "string",
                    "description": "Optional additional notes"
                ]
            ],
            "required": ["title"]
        ]
    }
    
    private let store: TodoStore
    
    public init(store: TodoStore = .shared) {
        self.store = store
    }
    
    public func run(arguments: [String: ToolJSONValue]) async throws -> String {
        guard case .string(let title) = arguments["title"], !title.isEmpty else {
            return "Error: title is required"
        }
        
        let dueDate: Date?
        if case .string(let dueStr) = arguments["due"] {
            dueDate = parseDueDate(dueStr)
        } else {
            dueDate = nil
        }
        
        let priority: TodoItem.Priority
        if case .string(let p) = arguments["priority"] {
            priority = TodoItem.Priority(rawValue: ["none": 0, "low": 1, "medium": 2, "high": 3][p] ?? 0) ?? .none
        } else {
            priority = .none
        }
        
        let notes: String?
        if case .string(let n) = arguments["notes"], !n.isEmpty {
            notes = n
        } else {
            notes = nil
        }
        
        let todo = TodoItem(
            title: title,
            notes: notes,
            dueDate: dueDate,
            priority: priority
        )
        
        try store.create(todo)
        
        var response = "Created todo: \(title)"
        if let due = todo.formattedDueDate {
            response += " (due \(due))"
        }
        return response
    }
    
    private func parseDueDate(_ text: String) -> Date? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let calendar = Calendar.current
        let now = Date()
        
        if lower == "today" || lower == "tonight" {
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
        } else if lower == "tomorrow" {
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        } else if lower == "next week" {
            return calendar.date(byAdding: .weekOfYear, value: 1, to: now)
        }
        
        // Try parsing yyyy-MM-dd HH:mm
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        if let date = formatter.date(from: text) {
            return date
        }
        
        // Try natural language
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        if let match = detector?.firstMatch(in: text, options: [], range: range),
           let date = match.date {
            return date
        }
        
        return nil
    }
}

// MARK: - Todos Complete Tool

/// Marks a Nook todo as complete.
public final class TodosCompleteTool: @unchecked Sendable, AgentTool {
    public static let toolName = "todos.complete"
    
    public var name: String { Self.toolName }
    public let description = """
        Mark a todo as complete when the user says they finished a task, \
        did something on their list, or wants to check off an item. \
        Search by title text - partial matches work.
        """
    
    public var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "match_text": [
                    "type": "string",
                    "description": "Text to match against todo titles (partial match supported)"
                ]
            ],
            "required": ["match_text"]
        ]
    }
    
    private let store: TodoStore
    
    public init(store: TodoStore = .shared) {
        self.store = store
    }
    
    public func run(arguments: [String: ToolJSONValue]) async throws -> String {
        guard case .string(let matchText) = arguments["match_text"], !matchText.isEmpty else {
            return "Error: match_text is required"
        }
        
        guard let todo = try store.findBestMatch(for: matchText) else {
            return "No matching todo found for: \(matchText)"
        }
        
        try store.markCompleted(id: todo.id)
        return "Completed: \(todo.title)"
    }
}

// MARK: - Todos List Tool

/// Lists Nook todos.
public final class TodosListTool: @unchecked Sendable, AgentTool {
    public static let toolName = "todos.list"
    
    public var name: String { Self.toolName }
    public let description = """
        List the user's todos/tasks. Use when they ask what's on their list, \
        what they need to do, or want to see their tasks.
        """
    
    public var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "include_completed": [
                    "type": "boolean",
                    "description": "Whether to include completed todos (default: false)"
                ],
                "search": [
                    "type": "string",
                    "description": "Optional search text to filter todos"
                ]
            ]
        ]
    }
    
    private let store: TodoStore
    
    public init(store: TodoStore = .shared) {
        self.store = store
    }
    
    public func run(arguments: [String: ToolJSONValue]) async throws -> String {
        let includeCompleted: Bool
        if case .bool(let b) = arguments["include_completed"] {
            includeCompleted = b
        } else {
            includeCompleted = false
        }
        
        let searchQuery: String?
        if case .string(let s) = arguments["search"], !s.isEmpty {
            searchQuery = s
        } else {
            searchQuery = nil
        }
        
        let todos: [TodoItem]
        if let query = searchQuery {
            todos = try store.search(query: query)
        } else if includeCompleted {
            todos = try store.fetchAll()
        } else {
            todos = try store.fetchIncomplete()
        }
        
        if todos.isEmpty {
            return includeCompleted ? "No todos found." : "No pending todos. All done!"
        }
        
        var lines: [String] = []
        for todo in todos.prefix(20) {
            let checkbox = todo.isCompleted ? "✓" : "○"
            var line = "\(checkbox) \(todo.title)"
            if let due = todo.formattedDueDate {
                line += " (due \(due))"
            }
            lines.append(line)
        }
        
        if todos.count > 20 {
            lines.append("... and \(todos.count - 20) more")
        }
        
        return lines.joined(separator: "\n")
    }
}

// MARK: - Todos Delete Tool

/// Deletes a Nook todo.
public final class TodosDeleteTool: @unchecked Sendable, AgentTool {
    public static let toolName = "todos.delete"
    
    public var name: String { Self.toolName }
    public let description = """
        Delete a todo when the user wants to remove an item from their list \
        (not just mark it complete).
        """
    
    public var parametersSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "match_text": [
                    "type": "string",
                    "description": "Text to match against todo titles"
                ]
            ],
            "required": ["match_text"]
        ]
    }
    
    private let store: TodoStore
    
    public init(store: TodoStore = .shared) {
        self.store = store
    }
    
    public func run(arguments: [String: ToolJSONValue]) async throws -> String {
        guard case .string(let matchText) = arguments["match_text"], !matchText.isEmpty else {
            return "Error: match_text is required"
        }
        
        // Search all todos including completed
        let all = try store.fetchAll()
        let normalized = matchText.lowercased()
        
        guard let todo = all.first(where: { $0.title.lowercased().contains(normalized) }) else {
            return "No matching todo found for: \(matchText)"
        }
        
        try store.delete(id: todo.id)
        return "Deleted: \(todo.title)"
    }
}
