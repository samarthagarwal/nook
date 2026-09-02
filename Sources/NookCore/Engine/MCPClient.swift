import Foundation

/// Persisted MCP server configs + live transports for connect / discover / call.
public actor MCPClient {
    private static let storageKey = "nook.mcp.servers.v1"

    private var servers: [MCPServer]
    private var transports: [String: MCPStreamableHTTPTransport] = [:]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([MCPServer].self, from: data) {
            self.servers = decoded
        } else {
            self.servers = []
        }
    }

    public func getServers() -> [MCPServer] {
        servers
    }

    public func getServer(id: String) -> MCPServer? {
        servers.first { $0.id == id }
    }

    public func addServer(name: String, url: String, authHeaderValue: String) throws -> MCPServer {
        let normalizedURL = Self.normalizeURLString(url)
        guard URL(string: normalizedURL) != nil else {
            throw MCPError.invalidURL(url)
        }
        let trimmedAuth = authHeaderValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Reuse an existing row with the same URL so retries don't create duplicates.
        if let index = servers.firstIndex(where: { $0.url == normalizedURL }) {
            if !trimmedName.isEmpty {
                servers[index].name = trimmedName
            }
            servers[index].authHeaderValue = trimmedAuth
            persist()
            return servers[index]
        }

        let server = MCPServer(
            name: trimmedName.isEmpty ? "MCP Server" : trimmedName,
            url: normalizedURL,
            authHeaderValue: trimmedAuth,
            isConnected: false,
            toolsCountDescription: "Not connected"
        )
        servers.append(server)
        persist()
        return server
    }

    /// Persists only after a successful connect. Failed attempts leave no orphan row.
    public func addAndConnect(
        name: String,
        url: String,
        authHeaderValue: String
    ) async throws -> MCPServer {
        let normalizedURL = Self.normalizeURLString(url)
        let existingIds = Set(servers.map(\.id))
        let server = try addServer(name: name, url: url, authHeaderValue: authHeaderValue)
        let createdNew = !existingIds.contains(server.id)
        do {
            return try await connect(serverId: server.id)
        } catch {
            if createdNew {
                removeServer(id: server.id)
            } else if server.url == normalizedURL {
                // Keep the existing row, but clear a half-connected flag from a failed refresh.
                if let index = servers.firstIndex(where: { $0.id == server.id }) {
                    servers[index].isConnected = false
                    servers[index].toolsCountDescription = "Not connected"
                    persist()
                }
            }
            throw error
        }
    }

    public func removeServer(id: String) {
        servers.removeAll { $0.id == id }
        transports[id] = nil
        persist()
    }

    public func updatePolicy(serverId: String, policy: MCPApprovalPolicy) {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[index].approvalPolicy = policy
        persist()
    }

    public func toggleTool(serverId: String, toolId: String) {
        guard let sIndex = servers.firstIndex(where: { $0.id == serverId }),
              let tIndex = servers[sIndex].tools.firstIndex(where: { $0.id == toolId }) else {
            return
        }
        servers[sIndex].tools[tIndex].isEnabled.toggle()
        refreshToolsDescription(at: sIndex)
        persist()
    }

    public func applyServerUpdate(_ updated: MCPServer) {
        guard let index = servers.firstIndex(where: { $0.id == updated.id }) else { return }
        servers[index] = updated
        refreshToolsDescription(at: index)
        persist()
    }

    public func connect(serverId: String) async throws -> MCPServer {
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else {
            throw MCPError.serverNotFound(serverId)
        }
        let server = servers[index]
        guard let endpoint = URL(string: Self.normalizeURLString(server.url)) else {
            throw MCPError.invalidURL(server.url)
        }

        let transport = MCPStreamableHTTPTransport(
            endpoint: endpoint,
            authHeaderValue: server.authHeaderValue
        )
        try await transport.initialize()
        let discovered = try await transport.listTools()
        transports[serverId] = transport

        let previousEnabled = Dictionary(
            uniqueKeysWithValues: server.tools.map { ($0.name, $0.isEnabled) }
        )
        servers[index].tools = discovered.map { tool in
            MCPToolEntry(
                name: tool.name,
                what: tool.description,
                isEnabled: previousEnabled[tool.name] ?? false
            )
        }
        servers[index].isConnected = true
        refreshToolsDescription(at: index)
        persist()
        return servers[index]
    }

    public func disconnect(serverId: String) {
        transports[serverId] = nil
        guard let index = servers.firstIndex(where: { $0.id == serverId }) else { return }
        servers[index].isConnected = false
        servers[index].toolsCountDescription = "Not connected"
        persist()
    }

    public func callTool(
        serverId: String,
        name: String,
        arguments: [String: AnySendableJSON]
    ) async throws -> AnySendableJSON {
        guard let server = servers.first(where: { $0.id == serverId }) else {
            throw MCPError.serverNotFound(serverId)
        }
        guard server.isConnected, let transport = transports[serverId] else {
            // Reconnect if process restarted but flags say connected.
            _ = try await connect(serverId: serverId)
            guard let transport = transports[serverId] else {
                throw MCPError.notConnected(server.name)
            }
            return try await transport.callTool(name: name, arguments: arguments)
        }
        return try await transport.callTool(name: name, arguments: arguments)
    }

    public func buildApprovalPayload(
        serverId: String,
        toolName: String,
        arguments: ToolArguments
    ) -> OutgoingApprovalPayload {
        let server = servers.first { $0.id == serverId }
        let url = server?.url ?? "unknown"
        let name = server?.name ?? "MCP"
        let argsJSON = Self.encodeArgumentsJSON(arguments)
        var lines = [
            "to    \(url)",
            "tool  \(toolName)",
        ]
        let sortedKeys = arguments.keys.sorted()
        for key in sortedKeys {
            lines.append("\(key)  \(Self.stringify(arguments[key]!))")
        }
        return OutgoingApprovalPayload(
            serverName: name,
            serverUrl: url,
            toolName: toolName,
            formattedPayload: lines.joined(separator: "\n"),
            notSentDescription: "your documents, this chat, your memory",
            argumentsJSON: argsJSON
        )
    }

    /// Enabled tools across connected servers (for ToolRegistry sync).
    public func enabledToolBindings() -> [(server: MCPServer, tool: MCPToolEntry)] {
        servers
            .filter(\.isConnected)
            .flatMap { server in
                server.tools.filter(\.isEnabled).map { (server, $0) }
            }
    }

    // MARK: - Persistence helpers

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func refreshToolsDescription(at index: Int) {
        let enabled = servers[index].tools.filter(\.isEnabled).count
        let total = servers[index].tools.count
        if servers[index].isConnected {
            servers[index].toolsCountDescription = "\(enabled) of \(total) tools on"
        } else {
            servers[index].toolsCountDescription = "Not connected"
        }
    }

    static func normalizeURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    static func encodeArgumentsJSON(_ arguments: ToolArguments) -> String {
        let object = Dictionary(uniqueKeysWithValues: arguments.map { ($0.key, json(from: $0.value)) })
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func arguments(fromJSON string: String) -> ToolArguments {
        guard let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.mapValues { ToolJSONValue.from($0) }
    }

    private static func json(from value: ToolJSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(json(from:))
        case .object(let value): return value.mapValues { json(from: $0) }
        }
    }

    private static func stringify(_ value: ToolJSONValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .array, .object:
            if let data = try? JSONSerialization.data(withJSONObject: json(from: value)),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return String(describing: value)
        }
    }
}
