import Foundation

/// Keeps `ToolRegistry` in sync with enabled MCP tools from `MCPClient`.
public actor MCPToolRegistrar {
    private let client: MCPClient
    private let registry: ToolRegistry
    private var registeredNames: Set<String> = []

    public init(client: MCPClient, registry: ToolRegistry) {
        self.client = client
        self.registry = registry
    }

    public func sync() async {
        let bindings = await client.enabledToolBindings()
        let nextNames = Set(bindings.map(\.tool.name))

        for name in registeredNames where !nextNames.contains(name) {
            await registry.unregister(toolNamed: name)
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

        registeredNames = nextNames
    }
}
