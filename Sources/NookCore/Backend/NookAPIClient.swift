import Foundation

/// Configuration for the Nook backend API.
public struct NookAPIConfig: Sendable {
    public let baseURL: URL
    public let timeoutInterval: TimeInterval

    public init(
        baseURL: URL,
        timeoutInterval: TimeInterval = 120
    ) {
        self.baseURL = baseURL
        self.timeoutInterval = timeoutInterval
    }

    /// Default configuration pointing to production.
    public static let production = NookAPIConfig(
        baseURL: URL(string: "https://nook-backend.up.railway.app")!
    )

    /// Local development configuration.
    public static let local = NookAPIConfig(
        baseURL: URL(string: "http://localhost:8000")!
    )
}

/// Errors that can occur when communicating with the backend.
public enum NookAPIError: LocalizedError, Sendable {
    case notAuthenticated
    case unauthorized
    case rateLimitExceeded(retryAfter: Int?)
    case serverError(statusCode: Int, message: String)
    case networkError(Error)
    case decodingError(Error)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Please sign in to continue."
        case .unauthorized:
            return "Your session has expired. Please sign in again."
        case .rateLimitExceeded(let retryAfter):
            if let seconds = retryAfter {
                return "Too many requests. Please try again in \(seconds) seconds."
            }
            return "Too many requests. Please try again later."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server."
        }
    }
}

/// Events streamed from the backend during a chat turn.
public enum BackendStreamEvent: Sendable {
    case token(String)
    case toolRequest(ToolRequestPayload)
    case awaitingTools(TurnStatePayload)
    case done(iterations: Int)
    case error(String)
}

/// Payload for a tool request from the backend.
public struct ToolRequestPayload: Sendable, Codable {
    public let requestId: String
    public let toolName: String
    public let arguments: [String: ToolJSONValue]
    public let requiresConfirmation: Bool
    public let confirmationMessage: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case toolName = "tool_name"
        case arguments
        case requiresConfirmation = "requires_confirmation"
        case confirmationMessage = "confirmation_message"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        toolName = try container.decode(String.self, forKey: .toolName)
        requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation) ?? false
        confirmationMessage = try container.decodeIfPresent(String.self, forKey: .confirmationMessage)

        // Decode arguments as [String: Any] then convert
        if let argsContainer = try? container.decode([String: AnyCodable].self, forKey: .arguments) {
            arguments = argsContainer.mapValues { ToolJSONValue.from($0.value) }
        } else {
            arguments = [:]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(requiresConfirmation, forKey: .requiresConfirmation)
        try container.encodeIfPresent(confirmationMessage, forKey: .confirmationMessage)
        // Arguments encoding would need custom handling
    }
}

/// Payload containing turn state for resuming after tool execution.
public struct TurnStatePayload: Sendable, Codable {
    public let iteration: Int
    public let pendingCount: Int

    enum CodingKeys: String, CodingKey {
        case turnState = "turn_state"
        case pendingCount = "pending_count"
    }

    struct TurnStateInner: Codable {
        let iteration: Int
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let inner = try container.decode(TurnStateInner.self, forKey: .turnState)
        iteration = inner.iteration
        pendingCount = try container.decode(Int.self, forKey: .pendingCount)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pendingCount, forKey: .pendingCount)
    }
}

/// Client for communicating with the Nook backend.
public actor NookAPIClient {
    private let config: NookAPIConfig
    private let session: URLSession
    private let authProvider: @Sendable () async throws -> String

    public init(
        config: NookAPIConfig = .production,
        authProvider: @Sendable @escaping () async throws -> String
    ) {
        self.config = config
        self.authProvider = authProvider

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeoutInterval
        sessionConfig.timeoutIntervalForResource = config.timeoutInterval * 2
        self.session = URLSession(configuration: sessionConfig)
    }

    /// Check if the backend is reachable.
    nonisolated public func isReachable() async -> Bool {
        let url = config.baseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Stream a chat request to the backend.
    nonisolated public func chat(request: ChatRequestPayload) -> AsyncThrowingStream<BackendStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let url = config.baseURL.appendingPathComponent("chat")
                    var urlRequest = URLRequest(url: url)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    // Add auth header
                    let token = try await authProvider()
                    urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                    // Encode body
                    let encoder = JSONEncoder()
                    encoder.keyEncodingStrategy = .convertToSnakeCase
                    urlRequest.httpBody = try encoder.encode(request)

                    // Start SSE stream
                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: NookAPIError.invalidResponse)
                        return
                    }

                    try checkStatusCode(httpResponse)

                    // Parse SSE events
                    var eventType: String?
                    var eventData: String = ""

                    for try await line in bytes.lines {
                        if line.hasPrefix("event:") {
                            eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            eventData = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        } else if line.isEmpty {
                            // End of event
                            if let type = eventType, !eventData.isEmpty {
                                if let event = parseSSEEvent(type: type, data: eventData) {
                                    continuation.yield(event)
                                    if case .done = event {
                                        continuation.finish()
                                        return
                                    }
                                    if case .error = event {
                                        continuation.finish()
                                        return
                                    }
                                }
                            }
                            eventType = nil
                            eventData = ""
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
        }
    }

    /// Submit a tool result to the backend.
    public func submitToolResult(
        conversationId: String,
        result: ToolResultPayload
    ) async throws {
        let url = config.baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent(conversationId)
            .appendingPathComponent("tool-result")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let token = try await authProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(result)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NookAPIError.invalidResponse
        }

        try checkStatusCode(httpResponse)
    }

    /// Get current usage stats.
    public func getUsage() async throws -> UsageStats {
        let url = config.baseURL.appendingPathComponent("chat/usage")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let token = try await authProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NookAPIError.invalidResponse
        }

        try checkStatusCode(httpResponse)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UsageStats.self, from: data)
    }

    // MARK: - Private Helpers

    nonisolated private func checkStatusCode(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw NookAPIError.unauthorized
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Int.init)
            throw NookAPIError.rateLimitExceeded(retryAfter: retryAfter)
        default:
            throw NookAPIError.serverError(
                statusCode: response.statusCode,
                message: HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            )
        }
    }

    nonisolated private func parseSSEEvent(type: String, data: String) -> BackendStreamEvent? {
        guard let jsonData = data.data(using: .utf8) else { return nil }

        switch type {
        case "token":
            if let dict = try? JSONDecoder().decode([String: String].self, from: jsonData),
               let content = dict["content"] {
                return .token(content)
            }

        case "tool_request":
            if let payload = try? JSONDecoder().decode(ToolRequestPayload.self, from: jsonData) {
                return .toolRequest(payload)
            }

        case "awaiting_tools":
            if let payload = try? JSONDecoder().decode(TurnStatePayload.self, from: jsonData) {
                return .awaitingTools(payload)
            }

        case "done":
            if let dict = try? JSONDecoder().decode([String: Int].self, from: jsonData),
               let iterations = dict["iterations"] {
                return .done(iterations: iterations)
            }
            return .done(iterations: 0)

        case "error":
            if let dict = try? JSONDecoder().decode([String: String].self, from: jsonData),
               let message = dict["message"] {
                return .error(message)
            }

        default:
            break
        }

        return nil
    }

    nonisolated private func mapError(_ error: Error) -> Error {
        if let apiError = error as? NookAPIError {
            return apiError
        }
        if let urlError = error as? URLError {
            return NookAPIError.networkError(urlError)
        }
        return NookAPIError.networkError(error)
    }
}

// MARK: - Request/Response Payloads

/// Payload for a chat request to the backend.
public struct ChatRequestPayload: Sendable, Encodable {
    public let conversationId: String
    public let message: String
    public let conversationHistory: [[String: AnyCodable]]
    public let availableTools: [[String: AnyCodable]]
    public let turnState: TurnStateEncodable?
    public let maxIterations: Int
    public let maxDurationSeconds: Int

    public init(
        conversationId: String,
        message: String,
        conversationHistory: [[String: Any]],
        availableTools: [[String: Any]],
        turnState: TurnStateEncodable? = nil,
        maxIterations: Int = 10,
        maxDurationSeconds: Int = 120
    ) {
        self.conversationId = conversationId
        self.message = message
        self.conversationHistory = conversationHistory.map { $0.mapValues { AnyCodable($0) } }
        self.availableTools = availableTools.map { $0.mapValues { AnyCodable($0) } }
        self.turnState = turnState
        self.maxIterations = maxIterations
        self.maxDurationSeconds = maxDurationSeconds
    }
}

/// Encodable turn state for sending back to backend.
public struct TurnStateEncodable: Sendable, Encodable {
    public let iteration: Int
    public let pendingToolCalls: [[String: AnyCodable]]
    public let completedToolResults: [[String: AnyCodable]]
    public let executedToolIds: [String]

    public init(
        iteration: Int,
        pendingToolCalls: [[String: Any]],
        completedToolResults: [[String: Any]],
        executedToolIds: Set<String>
    ) {
        self.iteration = iteration
        self.pendingToolCalls = pendingToolCalls.map { $0.mapValues { AnyCodable($0) } }
        self.completedToolResults = completedToolResults.map { $0.mapValues { AnyCodable($0) } }
        self.executedToolIds = Array(executedToolIds)
    }
}

/// Payload for a tool result submission.
public struct ToolResultPayload: Sendable, Encodable {
    public let requestId: String
    public let success: Bool
    public let result: String
    public let displayText: String
    public let error: String?
    public let citations: [[String: AnyCodable]]

    public init(
        requestId: String,
        success: Bool,
        result: String,
        displayText: String,
        error: String? = nil,
        citations: [[String: Any]] = []
    ) {
        self.requestId = requestId
        self.success = success
        self.result = result
        self.displayText = displayText
        self.error = error
        self.citations = citations.map { $0.mapValues { AnyCodable($0) } }
    }
}

/// Usage statistics from the backend.
public struct UsageStats: Sendable, Decodable {
    public let usedToday: Int
    public let limitToday: Int
    public let remaining: Int
}

// MARK: - AnyCodable Helper

/// Type-erased Codable wrapper for arbitrary JSON values.
///
/// Safety: This type is marked `@unchecked Sendable` because we only store
/// JSON-compatible values (strings, numbers, bools, arrays, and dictionaries
/// of the same) which are inherently safe to pass across actor boundaries.
public struct AnyCodable: @unchecked Sendable, Codable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Unsupported type: \(type(of: value))"
            ))
        }
    }
}
