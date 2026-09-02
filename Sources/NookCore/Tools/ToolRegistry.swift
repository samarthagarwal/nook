import Foundation

/// OpenAI-style / MLX-compatible tool schema dictionary.
public typealias AgentToolSpec = [String: any Sendable]

public struct AgentToolParameterSchema: Sendable, Equatable {
    public let name: String
    public let type: String
    public let description: String
    public let required: Bool

    public init(name: String, type: String, description: String, required: Bool = true) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
    }
}

/// Sendable JSON-ish values for tool arguments.
public enum ToolJSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ToolJSONValue])
    case object([String: ToolJSONValue])

    public static func from(_ value: Any) -> ToolJSONValue {
        switch value {
        case let v as ToolJSONValue:
            return v
        case is NSNull:
            return .null
        case let v as Bool:
            return .bool(v)
        case let v as Int:
            return .int(v)
        case let v as Double:
            return .double(v)
        case let v as Float:
            return .double(Double(v))
        case let v as String:
            return .string(v)
        case let v as [Any]:
            return .array(v.map(ToolJSONValue.from))
        case let v as [String: Any]:
            return .object(v.mapValues(ToolJSONValue.from))
        default:
            return .string(String(describing: value))
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public typealias ToolArguments = [String: ToolJSONValue]

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var isExternal: Bool { get }
    var requiresApprovalByDefault: Bool { get }
    var parameters: [AgentToolParameterSchema] { get }

    func execute(arguments: ToolArguments) async throws -> ToolExecutionResult
}

public extension AgentTool {
    /// JSON schema passed to the model's native `tools` chat-template branch.
    var schema: AgentToolSpec {
        var properties: [String: any Sendable] = [:]
        var required: [String] = []
        for parameter in parameters {
            properties[parameter.name] = [
                "type": parameter.type,
                "description": parameter.description,
            ] as [String: any Sendable]
            if parameter.required {
                required.append(parameter.name)
            }
        }

        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ]
    }
}

public struct ToolExecutionResult: Sendable {
    public let textForModel: String
    public let displayText: String
    public let citations: [Citation]
    public let chunks: [DocumentChunk]

    public init(
        textForModel: String,
        displayText: String,
        citations: [Citation] = [],
        chunks: [DocumentChunk] = []
    ) {
        self.textForModel = textForModel
        self.displayText = displayText
        self.citations = citations
        self.chunks = chunks
    }
}

/// One tool call observed during generation (for UI chips / citations).
public struct AgentToolEvent: Sendable {
    public let toolName: String
    public let displayText: String
    public let citations: [Citation]
    public let chunks: [DocumentChunk]
    public let isExternal: Bool

    public init(
        toolName: String,
        displayText: String,
        citations: [Citation] = [],
        chunks: [DocumentChunk] = [],
        isExternal: Bool = false
    ) {
        self.toolName = toolName
        self.displayText = displayText
        self.citations = citations
        self.chunks = chunks
        self.isExternal = isExternal
    }
}

/// Request for a model turn that may include native tool calling.
public struct AgentGenerationRequest: Sendable {
    public let toolSchemas: [AgentToolSpec]
    public let maxToolRounds: Int

    public init(toolSchemas: [AgentToolSpec], maxToolRounds: Int = 3) {
        self.toolSchemas = toolSchemas
        self.maxToolRounds = maxToolRounds
    }

    public static let textOnly = AgentGenerationRequest(toolSchemas: [], maxToolRounds: 0)
}

public struct AgentGenerationResult: Sendable {
    public let text: String
    public let citations: [Citation]

    public init(text: String, citations: [Citation] = []) {
        self.text = text
        self.citations = citations
    }
}

public struct OutgoingApprovalPayload: Equatable, Sendable {
    public let serverName: String
    public let serverUrl: String
    public let toolName: String
    public let formattedPayload: String
    public let notSentDescription: String

    public init(
        serverName: String,
        serverUrl: String,
        toolName: String,
        formattedPayload: String,
        notSentDescription: String = "your documents, this\n          chat, your memory"
    ) {
        self.serverName = serverName
        self.serverUrl = serverUrl
        self.toolName = toolName
        self.formattedPayload = formattedPayload
        self.notSentDescription = notSentDescription
    }
}

public enum ToolRegistryError: LocalizedError, Sendable {
    case unknownTool(String)
    case approvalRequired(toolName: String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .approvalRequired(let name):
            return "\(name) requires user approval before leaving the device."
        }
    }
}

public actor ToolRegistry {
    private var registeredTools: [String: any AgentTool] = [:]
    private var alwaysAllowedTools: Set<String> = []
    private var documentsSearchTool: DocumentsSearchTool?
    private var documentsSearchScope: [String] = []

    public init(knowledgeEngine: KnowledgeEngine? = nil) {
        if let knowledgeEngine {
            let tool = DocumentsSearchTool(knowledgeEngine: knowledgeEngine)
            documentsSearchTool = tool
            registeredTools[DocumentsSearchTool.toolName] = tool
        }
    }

    /// Binds the conversation's Knowledge scope for `documents_search` this turn.
    public func setDocumentsSearchScope(_ scope: [String]) {
        documentsSearchScope = scope
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        documentsSearchTool?.boundScope = documentsSearchScope
    }

    public func documentsSearch(
        query: String,
        scopedToCollections: [String]
    ) async -> DocumentsSearchOutput? {
        await documentsSearchTool?.search(query: query, scopedToCollections: scopedToCollections)
    }

    public func register(tool: any AgentTool) {
        registeredTools[tool.name] = tool
    }

    public func unregister(toolNamed name: String) {
        registeredTools.removeValue(forKey: name)
    }

    public func getTool(named name: String) -> (any AgentTool)? {
        registeredTools[name]
    }

    public func allToolNames() -> [String] {
        Array(registeredTools.keys).sorted()
    }

    /// Schemas for tools the model may call this turn.
    public func schemas(forAllowedNames allowed: Set<String>? = nil) -> [AgentToolSpec] {
        registeredTools.values
            .filter { allowed == nil || allowed!.contains($0.name) }
            .sorted { $0.name < $1.name }
            .map(\.schema)
    }

    public func setAlwaysAllow(toolName: String, allowed: Bool) {
        if allowed {
            alwaysAllowedTools.insert(toolName)
        } else {
            alwaysAllowedTools.remove(toolName)
        }
    }

    public func isAlwaysAllowed(toolName: String) -> Bool {
        alwaysAllowedTools.contains(toolName)
    }

    public func requiresApproval(toolName: String) -> Bool {
        guard let tool = registeredTools[toolName] else { return false }
        if !tool.isExternal { return false }
        if isAlwaysAllowed(toolName: toolName) { return false }
        return tool.requiresApprovalByDefault
    }

    public func execute(toolName: String, arguments: ToolArguments) async throws -> ToolExecutionResult {
        guard let tool = registeredTools[toolName] else {
            throw ToolRegistryError.unknownTool(toolName)
        }
        if requiresApproval(toolName: toolName) {
            throw ToolRegistryError.approvalRequired(toolName: toolName)
        }
        // Copy before crossing into nonisolated tool code.
        let args = arguments
        return try await tool.execute(arguments: args)
    }
}
