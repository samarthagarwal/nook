import Foundation

/// Handles chat when the backend is unreachable.
///
/// Uses the existing local model infrastructure (AgentLoop, local ModelRuntime)
/// to provide degraded but functional chat capabilities offline.
///
/// Limitations vs online mode:
/// - Limited to single tool round
/// - No server-side safeguards
/// - Uses smaller on-device model
/// - No usage tracking
public final class OfflineSession: @unchecked Sendable {
    private let toolRegistry: ToolRegistry
    private let contextAssembler: ContextAssembler

    /// Whether offline mode is currently active.
    @MainActor
    public private(set) var isOffline: Bool = false

    public init(
        toolRegistry: ToolRegistry,
        contextAssembler: ContextAssembler = ContextAssembler()
    ) {
        self.toolRegistry = toolRegistry
        self.contextAssembler = contextAssembler
    }

    /// Check if we should use offline mode.
    ///
    /// Returns true if:
    /// - Backend is unreachable
    /// - User has opted for offline-first
    /// - Network is unavailable
    public func shouldUseOfflineMode(apiClient: NookAPIClient?) async -> Bool {
        guard let client = apiClient else { return true }
        let reachable = await client.isReachable()
        return !reachable
    }

    /// Run a chat turn using local model.
    ///
    /// This uses the existing AgentLoop infrastructure with a local model.
    /// The implementation delegates to the existing local processing path.
    ///
    /// - Parameters:
    ///   - message: User's message
    ///   - conversation: Current conversation
    ///   - messages: Chat history
    ///   - generateStep: Step function for model generation
    ///   - onToolEvent: Callback for tool execution events
    /// - Returns: The assistant's response
    public func processMessage(
        message: String,
        conversation: Conversation,
        messages: [Message],
        generateStep: @escaping @Sendable (
            _ context: AssembledPromptContext,
            _ request: AgentGenerationRequest
        ) async throws -> AgentGenerationResult,
        onToolEvent: @escaping @Sendable (AgentToolEvent) -> Void
    ) async throws -> AgentLoop.Output {
        // Build context using existing assembler
        let promptContext = contextAssembler.assemble(
            baseSystemPrompt: offlineSystemPrompt,
            activeSkill: nil,
            evidenceChunks: [],
            chatHistory: messages,
            toolResults: []
        )

        // Get tool schemas from registry
        let toolSchemas = await toolRegistry.schemas()

        // Build request - limited to fewer tool rounds offline
        let request = AgentGenerationRequest(
            toolSchemas: toolSchemas,
            maxToolRounds: 1 // Limited offline
        )

        // Run the existing agent loop
        return try await AgentLoop.run(
            promptContext: promptContext,
            request: request,
            generateStep: generateStep,
            execute: { [weak self] toolName, arguments in
                guard let self else { throw CancellationError() }
                return try await self.toolRegistry.execute(
                    toolName: toolName,
                    arguments: arguments
                )
            },
            onToolEvent: onToolEvent
        )
    }

    /// System prompt for offline mode.
    private var offlineSystemPrompt: String {
        let clock = DateFormatter()
        clock.dateStyle = .full
        clock.timeStyle = .short

        return """
        You are Nook, running in offline mode on the user's iPhone.

        Current local date and time: \(clock.string(from: Date())).

        You are using an on-device model with limited capabilities compared to online mode. \
        Be concise and helpful. Use available tools when needed, but note that some features \
        may be limited offline.

        If the user asks for something that requires internet connectivity (web search, \
        external services), let them know they need to be online for that feature.
        """
    }
}

// MARK: - Offline Status Banner

/// Information about the current offline status for UI display.
public struct OfflineStatus: Sendable, Equatable {
    public let isOffline: Bool
    public let reason: OfflineReason
    public let canRetryOnline: Bool

    public enum OfflineReason: Sendable, Equatable {
        case backendUnreachable
        case networkUnavailable
        case userPreference
        case authenticationRequired
    }

    public var bannerMessage: String {
        switch reason {
        case .backendUnreachable:
            return "Offline mode — server unreachable"
        case .networkUnavailable:
            return "Offline mode — no internet connection"
        case .userPreference:
            return "Offline mode — using on-device model"
        case .authenticationRequired:
            return "Sign in for full features"
        }
    }

    public static let online = OfflineStatus(
        isOffline: false,
        reason: .userPreference,
        canRetryOnline: false
    )

    public init(isOffline: Bool, reason: OfflineReason, canRetryOnline: Bool) {
        self.isOffline = isOffline
        self.reason = reason
        self.canRetryOnline = canRetryOnline
    }
}
