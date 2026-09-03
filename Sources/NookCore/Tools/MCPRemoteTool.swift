import Foundation

/// Bridges an enabled MCP tool into `ToolRegistry` as an external `AgentTool`.
public struct MCPRemoteTool: AgentTool, Sendable {
    /// Namespaced name shown to the model (`server__tool`).
    public let name: String
    public let description: String
    public let isExternal: Bool = true
    public let requiresApprovalByDefault: Bool
    public let parameters: [AgentToolParameterSchema]

    private let remoteToolName: String
    private let serverId: String
    private let serverName: String
    private let serverURL: String
    private let client: MCPClient

    public init(
        server: MCPServer,
        tool: MCPToolEntry,
        client: MCPClient,
        requiresApprovalByDefault: Bool = true,
        parameters: [AgentToolParameterSchema] = [
            AgentToolParameterSchema(
                name: "query",
                type: "string",
                description: "Primary query or free-form argument for this tool",
                required: false
            ),
        ]
    ) {
        self.name = MCPToolRegistrar.registryName(server: server, tool: tool)
        self.remoteToolName = tool.name
        self.description = "[\(server.name)] \(tool.what)"
        self.requiresApprovalByDefault = requiresApprovalByDefault
        self.parameters = parameters
        self.serverId = server.id
        self.serverName = server.name
        self.serverURL = server.url
        self.client = client
    }

    public func execute(arguments: ToolArguments) async throws -> ToolExecutionResult {
        let started = Date()
        let mcpArgs = Dictionary(
            uniqueKeysWithValues: arguments.map { key, value in
                (key, Self.toMCPJSON(value))
            }
        )
        do {
            let result = try await client.callTool(
                serverId: serverId,
                name: remoteToolName,
                arguments: mcpArgs
            )
            let text = Self.displayString(from: result)
            let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
            let lines = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return ToolExecutionResult(
                textForModel: text,
                displayText: lines.isEmpty ? text : lines.joined(separator: "\n"),
                isExternal: true,
                externalFooter: "\(serverName) · \(serverURL) · \(elapsed)"
            )
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.toolFailed(error.localizedDescription)
        }
    }

    private static func toMCPJSON(_ value: ToolJSONValue) -> AnySendableJSON {
        switch value {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .number(Double(value))
        case .double(let value): return .number(value)
        case .string(let value): return .string(value)
        case .array(let value): return .array(value.map(toMCPJSON))
        case .object(let value): return .object(value.mapValues(toMCPJSON))
        }
    }

    private static func displayString(from json: AnySendableJSON) -> String {
        // Prefer MCP content[].text when present.
        if case .object(let root) = json,
           case .array(let content) = root["content"] {
            let texts: [String] = content.compactMap { item in
                guard case .object(let block) = item,
                      case .string(let type) = block["type"],
                      type == "text",
                      case .string(let text) = block["text"] else {
                    return nil
                }
                return text
            }
            if !texts.isEmpty {
                return texts.joined(separator: "\n")
            }
        }
        if case .string(let text) = json {
            return text
        }
        if let data = try? JSONEncoder().encode(json),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: json)
    }
}
