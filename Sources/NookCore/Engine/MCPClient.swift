import Foundation

public actor MCPClient {
    private var servers: [MCPServer]
    
    public init() {
        self.servers = [
            MCPServer(
                id: "github",
                name: "GitHub",
                url: "mcp.github-bridge.dev",
                isConnected: true,
                toolsCountDescription: "2 of 4 tools on",
                approvalPolicy: .consequential,
                tools: [
                    MCPToolEntry(name: "github.search_issues", what: "Read issues in repos you name", isEnabled: true),
                    MCPToolEntry(name: "github.list_prs", what: "Read open pull requests", isEnabled: true),
                    MCPToolEntry(name: "github.read_file", what: "Read file contents", isEnabled: false),
                    MCPToolEntry(name: "github.create_issue", what: "Write a new issue", isEnabled: false)
                ]
            ),
            MCPServer(
                id: "linear",
                name: "Linear",
                url: "mcp.linear.app/sse",
                isConnected: false,
                toolsCountDescription: "Not connected",
                approvalPolicy: .consequential,
                tools: []
            ),
            MCPServer(
                id: "home-assistant",
                name: "Home Assistant",
                url: "not configured",
                isConnected: false,
                toolsCountDescription: "Not connected",
                approvalPolicy: .consequential,
                tools: []
            )
        ]
    }
    
    public func getServers() -> [MCPServer] {
        return servers
    }
    
    public func getServer(id: String) -> MCPServer? {
        return servers.first { $0.id == id }
    }
    
    public func updatePolicy(serverId: String, policy: MCPApprovalPolicy) {
        if let index = servers.firstIndex(where: { $0.id == serverId }) {
            servers[index].approvalPolicy = policy
        }
    }
    
    public func toggleTool(serverId: String, toolId: String) {
        if let sIndex = servers.firstIndex(where: { $0.id == serverId }),
           let tIndex = servers[sIndex].tools.firstIndex(where: { $0.id == toolId }) {
            servers[sIndex].tools[tIndex].isEnabled.toggle()
            let enabledCount = servers[sIndex].tools.filter { $0.isEnabled }.count
            let totalCount = servers[sIndex].tools.count
            servers[sIndex].toolsCountDescription = "\(enabledCount) of \(totalCount) tools on"
        }
    }
    
    public func buildApprovalPayload(toolName: String, parameters: [String: String]) -> OutgoingApprovalPayload {
        let lines = [
            "to    mcp.github-bridge.dev",
            "tool  \(toolName)",
            "repo  alpha/core",
            "query identity provider fallback,",
            "      analytics estimate",
            "state open"
        ]
        
        return OutgoingApprovalPayload(
            serverName: "GitHub",
            serverUrl: "mcp.github-bridge.dev",
            toolName: toolName,
            formattedPayload: lines.joined(separator: "\n"),
            notSentDescription: "your documents, this\n          chat, your memory"
        )
    }
}
