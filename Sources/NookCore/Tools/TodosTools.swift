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
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "title",
            type: "string",
            description: "The todo title/task description",
            required: true
        ),
        AgentToolParameterSchema(
            name: "due",
            type: "string",
            description: "Optional due date in natural language (today, tomorrow, next week) or yyyy-MM-dd HH:mm format",
            required: false
        ),
        AgentToolParameterSchema(
            name: "priority",
            type: "string",
            description: "Task priority: none, low, medium, or high",
            required: false
        ),
        AgentToolParameterSchema(
            name: "notes",
            type: "string",
            description: "Optional additional notes",
            required: false
        )
    ]
    
    private let store: TodoStore
    
    public init(store: TodoStore = .shared) {
        self.store = store
    }
    
    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            return ToolExecutionResult(
                textForModel: "Error: title is required",
                displayText: "\(Self.toolName) · missing title",
                disposition: .failed
            )
        }
        
        let dueDate: Date?
        if let dueStr = arguments["due"]?.stringValue {
            dueDate = parseDueDate(dueStr)
        } else {
            dueDate = nil
        }
        
        let priority: TodoItem.Priority
        if let p = arguments["priority"]?.stringValue {
            priority = TodoItem.Priority(rawValue: ["none": 0, "low": 1, "medium": 2, "high": 3][p] ?? 0) ?? .none
        } else {
            priority = .none
        }
        
        let notes = arguments["notes"]?.stringValue
        
        let todo = TodoItem(
            title: title,
            notes: notes?.isEmpty == false ? notes : nil,
            dueDate: dueDate,
            priority: priority
        )
        
        do {
            try store.create(todo)
        } catch {
            return ToolExecutionResult(
                textForModel: "Failed to create todo: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }
        
        var response = "Created todo: \(title)"
        if let due = todo.formattedDueDate {
            response += " (due \(due))"
        }
        
        return ToolExecutionResult(
            textForModel: response,
            displayText: "\(Self.toolName) · created",
            disposition: .finished
        )
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
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "match_text",
            type: "string",
            description: "Text to match against todo titles (partial match supported)",
            required: true
        )
    ]
    
    private let store: TodoStore
    
    public init(store: TodoStore = .shared) {
        self.store = store
    }
    
    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        guard let matchText = arguments["match_text"]?.stringValue, !matchText.isEmpty else {
            return ToolExecutionResult(
                textForModel: "Error: match_text is required",
                displayText: "\(Self.toolName) · missing match_text",
                disposition: .failed
            )
        }
        
        guard let todo = try? store.findBestMatch(for: matchText) else {
            return ToolExecutionResult(
                textForModel: "No matching todo found for: \(matchText)",
                displayText: "\(Self.toolName) · not found",
                disposition: .failed
            )
        }
        
        do {
            try store.markCompleted(id: todo.id)
        } catch {
            return ToolExecutionResult(
                textForModel: "Failed to complete todo: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }
        
        return ToolExecutionResult(
            textForModel: "Completed: \(todo.title)",
            displayText: "\(Self.toolName) · completed",
            disposition: .finished
        )
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
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "include_completed",
            type: "boolean",
            description: "Whether to include completed todos (default: false)",
            required: false
        ),
        AgentToolParameterSchema(
            name: "search",
            type: "string",
            description: "Optional search text to filter todos",
            required: false
        )
    ]
    
    private let store: TodoStore
    
    public init(store: TodoStore = .shared) {
        self.store = store
    }
    
    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        let includeCompleted: Bool
        if case .bool(let b) = arguments["include_completed"] {
            includeCompleted = b
        } else {
            includeCompleted = false
        }
        let searchQuery = arguments["search"]?.stringValue
        
        let todos: [TodoItem]
        do {
            if let query = searchQuery, !query.isEmpty {
                todos = try store.search(query: query)
            } else if includeCompleted {
                todos = try store.fetchAll()
            } else {
                todos = try store.fetchIncomplete()
            }
        } catch {
            return ToolExecutionResult(
                textForModel: "Failed to fetch todos: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }
        
        if todos.isEmpty {
            return ToolExecutionResult(
                textForModel: includeCompleted ? "No todos found." : "No pending todos. All done!",
                displayText: "\(Self.toolName) · 0 todos"
            )
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
        
        return ToolExecutionResult(
            textForModel: lines.joined(separator: "\n"),
            displayText: "\(Self.toolName) · \(todos.count) todo\(todos.count == 1 ? "" : "s")"
        )
    }
}

// MARK: - Todos Update Tool

/// Updates an existing Nook todo.
public final class TodosUpdateTool: @unchecked Sendable, AgentTool {
    public static let toolName = "todos.update"
    
    public var name: String { Self.toolName }
    public let description = """
        Update an existing todo when the user wants to change its due date, \
        title, priority, or notes. Use this instead of creating a new todo \
        when modifying an existing task.
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "match_text",
            type: "string",
            description: "Text to match against todo titles to find the todo to update",
            required: true
        ),
        AgentToolParameterSchema(
            name: "title",
            type: "string",
            description: "New title for the todo (optional, only if changing)",
            required: false
        ),
        AgentToolParameterSchema(
            name: "due",
            type: "string",
            description: "New due date in natural language (today, tomorrow, next week) or yyyy-MM-dd HH:mm format. Use 'none' or 'clear' to remove due date.",
            required: false
        ),
        AgentToolParameterSchema(
            name: "priority",
            type: "string",
            description: "New priority: none, low, medium, or high",
            required: false
        ),
        AgentToolParameterSchema(
            name: "notes",
            type: "string",
            description: "New notes for the todo",
            required: false
        )
    ]
    
    private let store: TodoStore
    
    public init(store: TodoStore = .shared) {
        self.store = store
    }
    
    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        guard let matchText = arguments["match_text"]?.stringValue, !matchText.isEmpty else {
            return ToolExecutionResult(
                textForModel: "Error: match_text is required",
                displayText: "\(Self.toolName) · missing match_text",
                disposition: .failed
            )
        }
        
        // Find the todo - check incomplete first, then all (including completed)
        var todo: TodoItem
        if let found = try? store.findBestMatch(for: matchText) {
            todo = found
        } else {
            // Also check completed todos
            let all = (try? store.fetchAll()) ?? []
            let normalized = matchText.lowercased()
            guard let found = all.first(where: { $0.title.lowercased().contains(normalized) }) else {
                return ToolExecutionResult(
                    textForModel: "No matching todo found for: \(matchText)",
                    displayText: "\(Self.toolName) · not found",
                    disposition: .failed
                )
            }
            todo = found
        }
        
        var changes: [String] = []
        
        // Update title if provided
        if let newTitle = arguments["title"]?.stringValue, !newTitle.isEmpty {
            todo.title = newTitle
            changes.append("title")
        }
        
        // Update due date if provided
        if let dueStr = arguments["due"]?.stringValue {
            let lower = dueStr.lowercased().trimmingCharacters(in: .whitespaces)
            if lower == "none" || lower == "clear" || lower == "remove" {
                todo.dueDate = nil
                changes.append("due date removed")
            } else if let newDue = parseDueDate(dueStr) {
                todo.dueDate = newDue
                changes.append("due date")
            }
        }
        
        // Update priority if provided
        if let p = arguments["priority"]?.stringValue {
            let newPriority = TodoItem.Priority(rawValue: ["none": 0, "low": 1, "medium": 2, "high": 3][p] ?? 0) ?? .none
            todo.priority = newPriority
            changes.append("priority")
        }
        
        // Update notes if provided
        if let newNotes = arguments["notes"]?.stringValue {
            todo.notes = newNotes.isEmpty ? nil : newNotes
            changes.append("notes")
        }
        
        if changes.isEmpty {
            return ToolExecutionResult(
                textForModel: "No changes specified for todo: \(todo.title)",
                displayText: "\(Self.toolName) · no changes",
                disposition: .failed
            )
        }
        
        do {
            try store.update(todo)
        } catch {
            return ToolExecutionResult(
                textForModel: "Failed to update todo: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }
        
        var response = "Updated \(todo.title): \(changes.joined(separator: ", "))"
        if let due = todo.formattedDueDate {
            response += " (now due \(due))"
        }
        
        return ToolExecutionResult(
            textForModel: response,
            displayText: "\(Self.toolName) · updated",
            disposition: .finished
        )
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

// MARK: - Todos Delete Tool

/// Deletes a Nook todo.
public final class TodosDeleteTool: @unchecked Sendable, AgentTool {
    public static let toolName = "todos.delete"
    
    public var name: String { Self.toolName }
    public let description = """
        Delete a todo when the user wants to remove an item from their list \
        (not just mark it complete).
        """
    public let isExternal = false
    public let requiresApprovalByDefault = false
    public let parameters: [AgentToolParameterSchema] = [
        AgentToolParameterSchema(
            name: "match_text",
            type: "string",
            description: "Text to match against todo titles",
            required: true
        )
    ]
    
    private let store: TodoStore
    
    public init(store: TodoStore = .shared) {
        self.store = store
    }
    
    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        guard let matchText = arguments["match_text"]?.stringValue, !matchText.isEmpty else {
            return ToolExecutionResult(
                textForModel: "Error: match_text is required",
                displayText: "\(Self.toolName) · missing match_text",
                disposition: .failed
            )
        }
        
        // Search all todos including completed
        let all: [TodoItem]
        do {
            all = try store.fetchAll()
        } catch {
            return ToolExecutionResult(
                textForModel: "Failed to fetch todos: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }
        
        let normalized = matchText.lowercased()
        guard let todo = all.first(where: { $0.title.lowercased().contains(normalized) }) else {
            return ToolExecutionResult(
                textForModel: "No matching todo found for: \(matchText)",
                displayText: "\(Self.toolName) · not found",
                disposition: .failed
            )
        }
        
        do {
            try store.delete(id: todo.id)
        } catch {
            return ToolExecutionResult(
                textForModel: "Failed to delete todo: \(error.localizedDescription)",
                displayText: "\(Self.toolName) · failed",
                disposition: .failed
            )
        }
        
        return ToolExecutionResult(
            textForModel: "Deleted: \(todo.title)",
            displayText: "\(Self.toolName) · deleted",
            disposition: .finished
        )
    }
}
