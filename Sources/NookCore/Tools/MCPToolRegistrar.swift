import Foundation

/// Keeps `ToolRegistry` in sync with enabled MCP tools from `MCPClient`.
public actor MCPToolRegistrar {
    private let client: MCPClient
    private let registry: ToolRegistry

    public init(client: MCPClient, registry: ToolRegistry) {
        self.client = client
        self.registry = registry
    }

    public func sync() async {
        let bindings = await client.enabledToolBindings()
        let nextNames = Set(bindings.map { Self.registryName(server: $0.server, tool: $0.tool) })

        // Drop every external tool that is no longer enabled — including leftovers from a
        // previous chat session's registrar (ToolRegistry is shared app-wide).
        for name in await registry.allToolNames() {
            guard let tool = await registry.getTool(named: name), tool.isExternal else { continue }
            if !nextNames.contains(name) {
                await registry.unregister(toolNamed: name)
                await registry.setAlwaysAllow(toolName: name, allowed: false)
            }
        }

        for (server, tool) in bindings {
            let requiresApproval = server.approvalPolicy != .never
            let remote = MCPRemoteTool(
                server: server,
                tool: tool,
                client: client,
                requiresApprovalByDefault: requiresApproval
            )
            await registry.register(tool: remote)
        }
    }

    /// Model-facing name: `server_slug.tool_name` so two MCP servers never collide.
    /// Dot separator is far more common in LLM training data than double-underscore,
    /// so small models reproduce it reliably in Gemma `call:server.tool_name{…}` format.
    public static func registryName(server: MCPServer, tool: MCPToolEntry) -> String {
        let slug = server.name
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9_]+"#, with: "", options: .regularExpression)
        let safeSlug = slug.isEmpty ? "mcp" : slug
        return "\(safeSlug).\(tool.name)"
    }
}
