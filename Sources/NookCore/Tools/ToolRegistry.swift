import Foundation

public protocol AgentTool: Sendable {
    var name: String { get }
    var description: String { get }
    var isExternal: Bool { get }
    var requiresApprovalByDefault: Bool { get }
    
    func execute(arguments: [String: Any]) async throws -> String
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

public actor ToolRegistry {
    private var registeredTools: [String: any AgentTool] = [:]
    private var alwaysAllowedTools: Set<String> = []
    
    public init() {}
    
    public func register(tool: any AgentTool) {
        registeredTools[tool.name] = tool
    }
    
    public func unregister(toolNamed name: String) {
        registeredTools.removeValue(forKey: name)
    }
    
    public func getTool(named name: String) -> (any AgentTool)? {
        return registeredTools[name]
    }
    
    public func allToolNames() -> [String] {
        return Array(registeredTools.keys).sorted()
    }
    
    public func setAlwaysAllow(toolName: String, allowed: Bool) {
        if allowed {
            alwaysAllowedTools.insert(toolName)
        } else {
            alwaysAllowedTools.remove(toolName)
        }
    }
    
    public func isAlwaysAllowed(toolName: String) -> Bool {
        return alwaysAllowedTools.contains(toolName)
    }
    
    public func requiresApproval(toolName: String) -> Bool {
        guard let tool = registeredTools[toolName] else { return false }
        if !tool.isExternal { return false }
        if isAlwaysAllowed(toolName: toolName) { return false }
        return tool.requiresApprovalByDefault
    }
}
