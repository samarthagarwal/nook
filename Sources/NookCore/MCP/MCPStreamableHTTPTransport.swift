import Foundation

/// JSON-RPC client for MCP Streamable HTTP (POST to a single endpoint).
public actor MCPStreamableHTTPTransport: MCPTransport {
    public let endpoint: URL
    private let authHeaderValue: String
    private let session: URLSession
    private var nextID = 1
    private var sessionId: String?
    private let protocolVersion = "2025-03-26"

    public init(
        endpoint: URL,
        authHeaderValue: String = "",
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.authHeaderValue = authHeaderValue
        self.session = session
    }

    public func initialize() async throws {
        _ = try await rpc(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("nook"),
                    "version": .string("1.0"),
                ]),
            ])
        )
        try await notify(method: "notifications/initialized", params: nil)
    }

    public func listTools() async throws -> [MCPDiscoveredTool] {
        let result = try await rpc(method: "tools/list", params: .object([:]))
        guard case .object(let root) = result,
              case .array(let tools) = root["tools"] else {
            throw MCPError.invalidResponse("tools/list missing tools array")
        }

        return tools.compactMap { item in
            guard case .object(let tool) = item,
                  case .string(let name) = tool["name"] else {
                return nil
            }
            let description: String
            if case .string(let text) = tool["description"] {
                description = text
            } else {
                description = name
            }
            let schema: [String: AnySendableJSON]
            if case .object(let input) = tool["inputSchema"] {
                schema = input
            } else {
                schema = [:]
            }
            return MCPDiscoveredTool(name: name, description: description, inputSchema: schema)
        }
    }

    public func callTool(
        name: String,
        arguments: [String: AnySendableJSON]
    ) async throws -> AnySendableJSON {
        let result = try await rpc(
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": .object(arguments),
            ]),
            mcpName: name
        )
        return result
    }

    // MARK: - JSON-RPC

    private func rpc(
        method: String,
        params: AnySendableJSON?,
        mcpName: String? = nil
    ) async throws -> AnySendableJSON {
        let id = nextID
        nextID += 1

        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id, // Int — some servers (e.g. Tavily) reject float ids with empty 202 bodies
            "method": method,
        ]
        if let params {
            body["params"] = params.anyValue
        }

        let (data, http) = try await post(body: body, method: method, mcpName: mcpName)
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !sid.isEmpty {
            sessionId = sid
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw MCPError.httpStatus(http.statusCode, String(bodyText.prefix(200)))
        }

        // 202/204 with empty body is valid for notifications, not for requests.
        if data.isEmpty {
            throw MCPError.invalidResponse(
                "Empty body (HTTP \(http.statusCode), \(http.value(forHTTPHeaderField: "Content-Type") ?? "no content-type")). Check the URL and auth."
            )
        }

        let jsonObject = try Self.decodeResponseJSON(
            data: data,
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        )
        if case .object(let root) = jsonObject {
            if case .object(let error) = root["error"] {
                let code: Int
                if case .number(let value) = error["code"] {
                    code = Int(value)
                } else {
                    code = -1
                }
                let message: String
                if case .string(let text) = error["message"] {
                    message = text
                } else {
                    message = "RPC error"
                }
                throw MCPError.rpcError(code: code, message: message)
            }
            if let result = root["result"] {
                return result
            }
        }
        throw MCPError.invalidResponse("Missing result")
    }

    private func notify(method: String, params: AnySendableJSON?) async throws {
        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let params {
            body["params"] = params.anyValue
        }
        // Servers often return 202 Accepted with an empty body for notifications.
        _ = try? await post(body: body, method: method, mcpName: nil)
    }

    private func post(
        body: [String: Any],
        method: String,
        mcpName: String?
    ) async throws -> (Data, HTTPURLResponse) {
        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw MCPError.invalidResponse("Failed to encode JSON-RPC body")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(method, forHTTPHeaderField: "Mcp-Method")
        if let mcpName {
            request.setValue(mcpName, forHTTPHeaderField: "Mcp-Name")
        }
        if let sessionId, !sessionId.isEmpty {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if !authHeaderValue.isEmpty {
            let value = authHeaderValue.hasPrefix("Bearer ")
                ? authHeaderValue
                : "Bearer \(authHeaderValue)"
            request.setValue(value, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = payload
        request.timeoutInterval = 60

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MCPError.connectFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MCPError.invalidResponse("Not an HTTP response")
        }
        return (data, http)
    }

    /// Parses either a bare JSON object or an SSE (`text/event-stream`) frame wrapping JSON-RPC.
    static func decodeResponseJSON(data: Data, contentType: String?) throws -> AnySendableJSON {
        let contentType = contentType?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            let text = String(data: data, encoding: .utf8) ?? ""
            guard let jsonData = extractJSONData(fromSSE: text) else {
                let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = preview.isEmpty
                    ? "empty body (\(data.count) bytes)"
                    : String(preview.prefix(120))
                throw MCPError.invalidResponse("Empty SSE payload (\(snippet))")
            }
            return try JSONDecoder().decode(AnySendableJSON.self, from: jsonData)
        }

        // Some servers mislabel JSON as event-stream; also accept raw JSON anytime.
        if let object = try? JSONDecoder().decode(AnySendableJSON.self, from: data) {
            return object
        }
        // Last resort: body may still be SSE despite a missing/wrong Content-Type.
        if let text = String(data: data, encoding: .utf8),
           let jsonData = extractJSONData(fromSSE: text) {
            return try JSONDecoder().decode(AnySendableJSON.self, from: jsonData)
        }
        throw MCPError.invalidResponse("Could not decode MCP response")
    }

    /// Returns the last JSON payload from an SSE stream (concatenating multi-line `data:` fields).
    static func extractJSONData(fromSSE text: String) -> Data? {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var events: [String] = []
        var dataLines: [String] = []

        func flush() {
            guard !dataLines.isEmpty else { return }
            events.append(dataLines.joined(separator: "\n"))
            dataLines.removeAll(keepingCapacity: true)
        }

        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                flush()
                continue
            }
            if line.hasPrefix(":") {
                continue // SSE comment / keepalive
            }
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") {
                    value.removeFirst()
                }
                dataLines.append(value)
            }
        }
        flush()

        for event in events.reversed() {
            let trimmed = event.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "[DONE]" else { continue }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                return trimmed.data(using: .utf8)
            }
        }

        // Bare JSON body with an event-stream content type.
        let bare = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if bare.hasPrefix("{") || bare.hasPrefix("[") {
            return bare.data(using: .utf8)
        }
        return nil
    }
}
