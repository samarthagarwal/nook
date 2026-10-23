import Foundation

/// Handles tool execution requests from the backend.
///
/// When the backend orchestrator decides a tool should be called, it sends
/// a tool request to the iOS app. This handler:
/// 1. Receives the request
/// 2. Checks if user confirmation is needed
/// 3. Executes the tool via ToolRegistry
/// 4. Returns the result
public actor ToolRequestHandler {
    private let toolRegistry: ToolRegistry

    public init(toolRegistry: ToolRegistry) {
        self.toolRegistry = toolRegistry
    }

    /// Handle a tool request from the backend.
    ///
    /// - Parameters:
    ///   - request: The tool request from the backend
    ///   - onConfirmationNeeded: Closure called when user confirmation is required.
    ///                           Returns true if user confirms, false to decline.
    /// - Returns: The tool result to send back to the backend
    public func handle(
        request: ToolRequestPayload,
        onConfirmationNeeded: @Sendable @escaping (ToolRequestPayload) async -> Bool
    ) async -> ToolResultPayload {
        // Check if confirmation is required
        if request.requiresConfirmation {
            let confirmed = await onConfirmationNeeded(request)
            if !confirmed {
                return ToolResultPayload(
                    requestId: request.requestId,
                    success: false,
                    result: "User declined to execute this action.",
                    displayText: "\(request.toolName) · declined",
                    error: "User did not confirm"
                )
            }
        }

        // Execute the tool locally
        do {
            // Convert arguments to ToolArguments format
            let arguments = request.arguments

            let result = try await toolRegistry.execute(
                toolName: request.toolName,
                arguments: arguments
            )

            return ToolResultPayload(
                requestId: request.requestId,
                success: true,
                result: result.textForModel,
                displayText: result.displayText,
                citations: result.citations.map { citation in
                    [
                        "id": citation.id,
                        "label": citation.label,
                        "sourceDocument": citation.sourceDocument,
                        "pageOrSection": citation.pageOrSection,
                        "passage": citation.passage,
                        "surroundingContext": citation.surroundingContext,
                    ]
                }
            )
        } catch let error as ToolRegistryError {
            return ToolResultPayload(
                requestId: request.requestId,
                success: false,
                result: "Tool error: \(error.localizedDescription)",
                displayText: "\(request.toolName) · failed",
                error: error.localizedDescription
            )
        } catch {
            return ToolResultPayload(
                requestId: request.requestId,
                success: false,
                result: "Unexpected error: \(error.localizedDescription)",
                displayText: "\(request.toolName) · error",
                error: error.localizedDescription
            )
        }
    }

    /// Convert a ToolResultPayload to the format needed for turn state.
    nonisolated public func resultToTurnStateEntry(
        _ result: ToolResultPayload,
        toolName: String
    ) -> TurnStateToolResult {
        TurnStateToolResult(
            toolCallId: result.requestId,
            toolName: toolName,
            content: result.result,
            success: result.success
        )
    }
}

/// A Sendable representation of a tool result for turn state.
public struct TurnStateToolResult: Sendable {
    public let toolCallId: String
    public let toolName: String
    public let content: String
    public let success: Bool

    public init(toolCallId: String, toolName: String, content: String, success: Bool) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.success = success
    }

    /// Convert to dictionary for encoding.
    public func toDictionary() -> [String: Any] {
        [
            "tool_call_id": toolCallId,
            "tool_name": toolName,
            "content": content,
            "success": success,
        ]
    }
}

/// Manages turn state on the iOS side.
///
/// This class tracks the current state of an agent turn, including
/// pending tool calls and completed results. It's used to build
/// the turn_state payload sent back to the backend.
public final class ClientTurnState: @unchecked Sendable {
    private var _iteration: Int = 0
    private var _pendingToolCalls: [[String: Any]] = []
    private var _completedToolResults: [[String: Any]] = []
    private var _executedToolIds: Set<String> = []
    private let lock = NSLock()

    public init() {}

    /// Current iteration number.
    public var iteration: Int {
        lock.lock()
        defer { lock.unlock() }
        return _iteration
    }

    /// Increment the iteration counter.
    public func incrementIteration() {
        lock.lock()
        _iteration += 1
        lock.unlock()
    }

    /// Add a pending tool call.
    public func addPendingToolCall(_ toolCall: [String: Any]) {
        lock.lock()
        _pendingToolCalls.append(toolCall)
        lock.unlock()
    }

    /// Add a completed tool result.
    public func addCompletedResult(_ result: [String: Any]) {
        lock.lock()
        _completedToolResults.append(result)
        lock.unlock()
    }

    /// Mark a tool as executed.
    public func markExecuted(toolId: String) {
        lock.lock()
        _executedToolIds.insert(toolId)
        lock.unlock()
    }

    /// Check if a tool has already been executed.
    public func hasExecuted(toolId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _executedToolIds.contains(toolId)
    }

    /// Clear pending tool calls (after they've been processed).
    public func clearPendingCalls() {
        lock.lock()
        _pendingToolCalls = []
        lock.unlock()
    }

    /// Convert to payload for backend.
    public func toPayload() -> TurnStateEncodable {
        lock.lock()
        defer { lock.unlock() }
        return TurnStateEncodable(
            iteration: _iteration,
            pendingToolCalls: _pendingToolCalls,
            completedToolResults: _completedToolResults,
            executedToolIds: _executedToolIds
        )
    }

    /// Reset state for a new turn.
    public func reset() {
        lock.lock()
        _iteration = 0
        _pendingToolCalls = []
        _completedToolResults = []
        _executedToolIds = []
        lock.unlock()
    }
}
