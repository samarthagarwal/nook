import SwiftUI
import NookDesign
import NookCore

public struct TodosView: View {
    @ObservedObject public var state: ObservableTodosState
    public let onOpenSourceChat: (String) -> Void
    
    @State private var searchText: String = ""
    @State private var showCompleted: Bool = false
    @State private var showAddTodo: Bool = false
    @State private var newTodoTitle: String = ""
    
    public init(
        state: ObservableTodosState,
        onOpenSourceChat: @escaping (String) -> Void
    ) {
        self.state = state
        self.onOpenSourceChat = onOpenSourceChat
    }
    
    private var displayedTodos: [TodoItem] {
        let base = showCompleted ? state.allTodos : state.incompleteTodos
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return base
        }
        return state.filtered(query: searchText, includeCompleted: showCompleted)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Todos")
                    .font(NookTypography.tabRootTitle)
                    .foregroundColor(NookColors.ink)
                Spacer()
                
                // Add button
                Button(action: { showAddTodo = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(NookColors.ink)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // Description
            HStack {
                Text("Tasks created from voice or chat. Mark them done when you're finished.")
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink62)
                    .lineSpacing(4)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(NookColors.ink40)
                
                TextField("Search todos", text: $searchText)
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink)
                    .textFieldStyle(.plain)
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(NookColors.ink40)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.pillLg)
                    .fill(NookColors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookRadius.pillLg)
                    .strokeBorder(NookColors.hairlineStrong, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            
            // Toggle for showing completed
            HStack {
                Button(action: { showCompleted.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: showCompleted ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 14))
                            .foregroundColor(showCompleted ? NookColors.local : NookColors.ink40)
                        Text("Show completed")
                            .font(NookTypography.badge)
                            .foregroundColor(NookColors.ink62)
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                if state.incompleteCount > 0 {
                    Text("\(state.incompleteCount) remaining")
                        .font(NookTypography.badge)
                        .foregroundColor(NookColors.ink45)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            
            // Todo list
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if displayedTodos.isEmpty {
                        emptyState
                    } else {
                        ForEach(displayedTodos) { todo in
                            todoCard(todo)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
        .onAppear {
            state.reload()
        }
        .sheet(isPresented: $showAddTodo) {
            addTodoSheet
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(searchText.isEmpty
                 ? (showCompleted ? "No todos yet" : "All done!")
                 : "No matches")
                .font(NookTypography.cardTitleSerif)
                .foregroundColor(NookColors.ink)
            Text(searchText.isEmpty
                 ? (showCompleted
                    ? "Say \"remind me to...\" or \"I need to...\" to create a todo with your voice."
                    : "You've completed all your tasks. Nice work!")
                 : "Try a different search term.")
                .font(NookTypography.body)
                .foregroundColor(NookColors.ink62)
                .lineSpacing(4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NookRadius.cardLg)
                .fill(NookColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NookRadius.cardLg)
                .strokeBorder(NookColors.hairline, lineWidth: 1)
        )
    }
    
    // MARK: - Todo Card
    
    private func todoCard(_ todo: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Checkbox
            Button(action: {
                state.toggleCompletion(todo)
            }) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundColor(todo.isCompleted ? NookColors.local : NookColors.ink40)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 6) {
                // Title
                Text(todo.title)
                    .font(NookTypography.cardTitleSerif)
                    .foregroundColor(todo.isCompleted ? NookColors.ink45 : NookColors.ink)
                    .strikethrough(todo.isCompleted)
                
                // Due date & priority
                HStack(spacing: 8) {
                    if let dueDate = todo.formattedDueDate {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 11))
                            Text(dueDate)
                        }
                        .font(NookTypography.badge)
                        .foregroundColor(dueDateColor(for: todo))
                    }
                    
                    if todo.priority != .none {
                        Text(todo.priority.symbol)
                            .font(NookTypography.badgeMedium)
                            .foregroundColor(priorityColor(for: todo.priority))
                    }
                }
                
                // Notes if present
                if let notes = todo.notes, !notes.isEmpty {
                    Text(notes)
                        .font(NookTypography.meta)
                        .foregroundColor(NookColors.ink55)
                        .lineLimit(2)
                }
                
                // Actions
                HStack {
                    if let conversationId = todo.sourceConversationId {
                        Button(action: {
                            onOpenSourceChat(conversationId)
                        }) {
                            Text("Open source")
                                .font(NookTypography.badge)
                                .foregroundColor(NookColors.local)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Spacer()
                    
                    Button(action: {
                        state.delete(todo)
                    }) {
                        Text("Delete")
                            .font(NookTypography.badge)
                            .foregroundColor(NookColors.ink45)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: NookRadius.cardLg)
                .fill(NookColors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: NookRadius.cardLg)
                .strokeBorder(NookColors.hairline, lineWidth: 1)
        )
        .nookCardShadow()
    }
    
    // MARK: - Add Todo Sheet
    
    private var addTodoSheet: some View {
        NavigationView {
            VStack(spacing: 20) {
                TextField("What do you need to do?", text: $newTodoTitle)
                    .font(NookTypography.body)
                    .textFieldStyle(.plain)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: NookRadius.cardLg)
                            .fill(NookColors.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: NookRadius.cardLg)
                            .strokeBorder(NookColors.hairlineStrong, lineWidth: 1)
                    )
                
                Spacer()
            }
            .padding(20)
            .background(NookColors.paper.ignoresSafeArea())
            .navigationTitle("New Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        newTodoTitle = ""
                        showAddTodo = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if !newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                            state.create(title: newTodoTitle)
                            newTodoTitle = ""
                            showAddTodo = false
                        }
                    }
                    .disabled(newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
    
    // MARK: - Helpers
    
    private func dueDateColor(for todo: TodoItem) -> Color {
        guard let dueDate = todo.dueDate, !todo.isCompleted else {
            return NookColors.ink45
        }
        
        if dueDate < Date() {
            return NookColors.external // Overdue
        } else if Calendar.current.isDateInToday(dueDate) {
            return NookColors.local // Due today
        }
        return NookColors.ink45
    }
    
    private func priorityColor(for priority: TodoItem.Priority) -> Color {
        switch priority {
        case .none: return NookColors.ink45
        case .low: return NookColors.ink55
        case .medium: return NookColors.local
        case .high: return NookColors.external
        }
    }
}

// MARK: - Observable State

@MainActor
public final class ObservableTodosState: ObservableObject {
    @Published public var incompleteTodos: [TodoItem] = []
    @Published public var completedTodos: [TodoItem] = []
    @Published public var incompleteCount: Int = 0
    
    private let store: TodoStore
    
    public var allTodos: [TodoItem] {
        incompleteTodos + completedTodos
    }
    
    public init(store: TodoStore = .shared) {
        self.store = store
        reload()
    }
    
    public func reload() {
        do {
            incompleteTodos = try store.fetchIncomplete()
            completedTodos = try store.fetchCompleted(limit: 30)
            incompleteCount = try store.incompleteCount()
        } catch {
            print("[TodosState] Failed to reload: \(error)")
        }
    }
    
    public func filtered(query: String, includeCompleted: Bool) -> [TodoItem] {
        let base = includeCompleted ? allTodos : incompleteTodos
        let lower = query.lowercased()
        return base.filter {
            $0.title.lowercased().contains(lower) ||
            ($0.notes?.lowercased().contains(lower) ?? false)
        }
    }
    
    public func toggleCompletion(_ todo: TodoItem) {
        do {
            if todo.isCompleted {
                try store.markIncomplete(id: todo.id)
            } else {
                try store.markCompleted(id: todo.id)
            }
            reload()
        } catch {
            print("[TodosState] Failed to toggle: \(error)")
        }
    }
    
    public func delete(_ todo: TodoItem) {
        do {
            try store.delete(id: todo.id)
            reload()
        } catch {
            print("[TodosState] Failed to delete: \(error)")
        }
    }
    
    public func create(title: String) {
        let todo = TodoItem(title: title)
        do {
            try store.create(todo)
            reload()
        } catch {
            print("[TodosState] Failed to create: \(error)")
        }
    }
}
