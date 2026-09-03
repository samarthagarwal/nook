import XCTest
@testable import NookCore
@testable import NookRuntime

final class MCPAndLiteRTToolTests: XCTestCase {
    func testLiteRTToolCallParserExtractsFunctionCall() {
        let raw = """
        {"tool_calls":[{"id":"1","function":{"name":"github.search_issues","arguments":{"query":"identity"}}}]}
        """
        let calls = LiteRTToolCallParser.parse(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "github.search_issues")
        XCTAssertEqual(calls[0].arguments["query"]?.stringValue, "identity")
        XCTAssertEqual(LiteRTToolCallParser.visibleText(from: raw), "")
    }

    func testLiteRTToolCallParserHandlesUnclosedFence() {
        let raw = """
        ```json
        {"tool_calls":[{"id":"1","function":{"name":"tavily_search","arguments":{"query":"WWDC"}}}]}
        """
        let calls = LiteRTToolCallParser.parse(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "tavily_search")
        XCTAssertEqual(calls[0].arguments["query"]?.stringValue, "WWDC")
        XCTAssertEqual(LiteRTToolCallParser.visibleText(from: raw), "")
    }

    func testLiteRTToolCallParserRepairsTruncatedJSON() {
        let raw = """
        {"name":"tavily_search","arguments":{"query":"WWDC"
        """
        let calls = LiteRTToolCallParser.parse(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "tavily_search")
        XCTAssertEqual(calls[0].arguments["query"]?.stringValue, "WWDC")
    }

    func testLiteRTToolCallParserSimpleNameFormat() {
        let raw = #"{"name":"tavily_search","arguments":{"query":"Apple WWDC"}}"#
        let calls = LiteRTToolCallParser.parse(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "tavily_search")
    }

    func testLiteRTToolCallParserGemmaNativeFormat() {
        let raw = #"<|tool_call>call:tavily_search{query:"cost of latest Mac Studio with M5 Max chip"}<tool_call|>"#
        let calls = LiteRTToolCallParser.parse(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "tavily_search")
        XCTAssertEqual(
            calls[0].arguments["query"]?.stringValue,
            "cost of latest Mac Studio with M5 Max chip"
        )
        XCTAssertEqual(LiteRTToolCallParser.visibleText(from: raw), "")
    }

    func testLiteRTVisibleTextStripsToolCallLeavingProse() {
        let raw = """
        Russia invaded Ukraine in 2022.
        <|tool_call>call:tavily_search{query:"Russia Ukraine"}<tool_call|>
        """
        let visible = LiteRTToolCallParser.visibleText(from: raw)
        XCTAssertTrue(visible.contains("Russia invaded Ukraine"))
        XCTAssertFalse(visible.contains("tool_call"))
        XCTAssertFalse(visible.contains("tavily_search"))
    }

    func testLiteRTVisibleTextHidesBareToolCallOnly() {
        let raw = #"<|tool_call>call:tavily_search{query:"Russia Ukraine"}<tool_call|>"#
        XCTAssertEqual(LiteRTToolCallParser.visibleText(from: raw), "")
    }

    func testLiteRTToolCallParserGemmaDelimitedStrings() {
        let raw = #"<|tool_call>call:tavily_search{query:<|"|>WWDC news<|"|>}<tool_call|>"#
        let calls = LiteRTToolCallParser.parse(from: raw)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "tavily_search")
        XCTAssertEqual(calls[0].arguments["query"]?.stringValue, "WWDC news")
    }

    func testLiteRTToolCallParserHidesTruncatedToolJSON() {
        let raw = """
        ```json
        {"tool_calls":[{"id":"1","function":{"name":"tavily_search","arguments":{"query":
        """
        // Still truncated after repair may yield empty query — but should not crash.
        XCTAssertTrue(LiteRTToolCallParser.looksLikeToolAttempt(raw))
    }

    func testMCPApprovalPayloadIncludesArguments() async {
        let client = MCPClient(defaults: UserDefaults(suiteName: "nook-mcp-test-\(UUID().uuidString)")!)
        let server = try! await client.addServer(
            name: "Test",
            url: "https://example.com/mcp",
            authHeaderValue: ""
        )
        // Mark connected without network so payload builder can resolve server.
        await client.applyServerUpdate(
            MCPServer(
                id: server.id,
                name: server.name,
                url: server.url,
                authHeaderValue: "",
                isConnected: true,
                toolsCountDescription: "1 of 1 tools on",
                tools: [MCPToolEntry(name: "demo.tool", what: "Demo", isEnabled: true)]
            )
        )
        let payload = await client.buildApprovalPayload(
            serverId: server.id,
            toolName: "demo.tool",
            arguments: ["query": .string("alpha")]
        )
        XCTAssertTrue(payload.formattedPayload.contains("demo.tool"))
        XCTAssertTrue(payload.formattedPayload.contains("alpha"))
        XCTAssertTrue(payload.argumentsJSON.contains("alpha"))
    }

    func testMCPToolRegistrarRegistersEnabledTools() async throws {
        let defaults = UserDefaults(suiteName: "nook-mcp-reg-\(UUID().uuidString)")!
        let client = MCPClient(defaults: defaults)
        let registry = ToolRegistry()
        let registrar = MCPToolRegistrar(client: client, registry: registry)

        let server = try await client.addServer(
            name: "Demo",
            url: "https://example.com/mcp",
            authHeaderValue: ""
        )
        await client.applyServerUpdate(
            MCPServer(
                id: server.id,
                name: "Demo",
                url: server.url,
                isConnected: true,
                toolsCountDescription: "1 of 1 tools on",
                tools: [
                    MCPToolEntry(name: "demo.search", what: "Search", isEnabled: true),
                    MCPToolEntry(name: "demo.hidden", what: "Hidden", isEnabled: false),
                ]
            )
        )

        await registrar.sync()
        let names = await registry.allToolNames()
        XCTAssertTrue(names.contains("demo__demo.search"))
        XCTAssertFalse(names.contains("demo__demo.hidden"))
        XCTAssertFalse(names.contains("demo.search"))
        let tool = await registry.getTool(named: "demo__demo.search")
        XCTAssertTrue(tool?.isExternal == true)
        XCTAssertEqual(tool?.description.contains("[Demo]"), true)

        await client.applyServerUpdate(
            MCPServer(
                id: server.id,
                name: "Demo",
                url: server.url,
                isConnected: true,
                toolsCountDescription: "0 of 2 tools on",
                tools: [
                    MCPToolEntry(name: "demo.search", what: "Search", isEnabled: false),
                    MCPToolEntry(name: "demo.hidden", what: "Hidden", isEnabled: false),
                ]
            )
        )
        let freshRegistrar = MCPToolRegistrar(client: client, registry: registry)
        await freshRegistrar.sync()
        let afterDisable = await registry.allToolNames()
        XCTAssertFalse(afterDisable.contains("demo__demo.search"))
    }

    func testAddAndConnectRemovesOrphanOnFailure() async throws {
        let defaults = UserDefaults(suiteName: "nook-mcp-orphan-\(UUID().uuidString)")!
        let client = MCPClient(defaults: defaults)
        do {
            _ = try await client.addAndConnect(
                name: "Broken",
                url: "https://127.0.0.1:9/mcp-does-not-exist",
                authHeaderValue: ""
            )
            XCTFail("Expected connect failure")
        } catch {
            let servers = await client.getServers()
            XCTAssertTrue(servers.isEmpty, "Failed add should not leave an orphan server")
        }
    }

    func testAddServerReusesSameURL() async throws {
        let defaults = UserDefaults(suiteName: "nook-mcp-dedupe-\(UUID().uuidString)")!
        let client = MCPClient(defaults: defaults)
        let first = try await client.addServer(
            name: "One",
            url: "https://example.com/mcp",
            authHeaderValue: "a"
        )
        let second = try await client.addServer(
            name: "Two",
            url: "https://example.com/mcp",
            authHeaderValue: "b"
        )
        XCTAssertEqual(first.id, second.id)
        let servers = await client.getServers()
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "Two")
        XCTAssertEqual(servers[0].authHeaderValue, "b")
    }

    func testStreamableHTTPTransportParsesToolsList() async throws {
        MockURLProtocol.requestHandler = { request in
            let method = request.value(forHTTPHeaderField: "Mcp-Method") ?? ""
            let body: [String: Any]
            if method == "initialize" {
                body = [
                    "jsonrpc": "2.0",
                    "id": 1,
                    "result": [
                        "protocolVersion": "2025-03-26",
                        "capabilities": [:],
                        "serverInfo": ["name": "mock", "version": "1"],
                    ],
                ]
            } else if method == "tools/list" {
                body = [
                    "jsonrpc": "2.0",
                    "id": 2,
                    "result": [
                        "tools": [
                            [
                                "name": "echo",
                                "description": "Echo text",
                                "inputSchema": [
                                    "type": "object",
                                    "properties": ["text": ["type": "string"]],
                                ],
                            ],
                        ],
                    ],
                ]
            } else if method == "notifications/initialized" {
                body = ["ok": true]
            } else {
                body = ["jsonrpc": "2.0", "id": 99, "error": ["code": -1, "message": "unexpected \(method)"]]
            }
            let data = try JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let transport = MCPStreamableHTTPTransport(
            endpoint: URL(string: "https://example.com/mcp")!,
            session: session
        )
        try await transport.initialize()
        let tools = try await transport.listTools()
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0].name, "echo")
        XCTAssertEqual(tools[0].description, "Echo text")
    }

    func testSSEResponseParsingHandlesCRLFAndEventFraming() throws {
        let sse = "event: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\r\n\r\n"
        let json = try MCPStreamableHTTPTransport.decodeResponseJSON(
            data: Data(sse.utf8),
            contentType: "text/event-stream"
        )
        guard case .object(let root) = json,
              case .object(let result) = root["result"],
              case .bool(true) = result["ok"] else {
            return XCTFail("Expected result.ok == true")
        }
    }

    func testSSEResponseParsingHandlesCROnlyLineEndings() throws {
        let sse = "event: message\rdata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}\r\r"
        let json = try MCPStreamableHTTPTransport.decodeResponseJSON(
            data: Data(sse.utf8),
            contentType: "text/event-stream"
        )
        guard case .object(let root) = json,
              case .object(let result) = root["result"],
              case .array = result["tools"] else {
            return XCTFail("Expected result.tools array")
        }
    }

    func testLiveTavilyInitializeAndListTools() async throws {
        // Tavily accepts a placeholder key for handshake/tools/list (no real search).
        let transport = MCPStreamableHTTPTransport(
            endpoint: URL(string: "https://mcp.tavily.com/mcp/?tavilyApiKey=tvly-fake")!
        )
        try await transport.initialize()
        let tools = try await transport.listTools()
        XCTAssertFalse(tools.isEmpty)
        XCTAssertTrue(tools.contains(where: { $0.name.contains("tavily") || $0.name.contains("search") }))
    }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
