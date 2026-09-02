import Foundation

public enum MCPError: LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case connectFailed(String)
    case httpStatus(Int, String)
    case rpcError(code: Int, message: String)
    case invalidResponse(String)
    case toolFailed(String)
    case notConnected(String)
    case serverNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid MCP server URL: \(url)"
        case .connectFailed(let detail):
            return "Couldn't connect to the MCP server. \(detail)"
        case .httpStatus(let code, let body):
            return "MCP server returned HTTP \(code). \(body)"
        case .rpcError(let code, let message):
            return "MCP error \(code): \(message)"
        case .invalidResponse(let detail):
            return "Unexpected MCP response. \(detail)"
        case .toolFailed(let detail):
            return "MCP tool failed. \(detail)"
        case .notConnected(let name):
            return "\(name) isn't connected."
        case .serverNotFound(let id):
            return "Unknown MCP server (\(id))."
        }
    }
}

public struct MCPDiscoveredTool: Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: [String: AnySendableJSON]

    public init(name: String, description: String, inputSchema: [String: AnySendableJSON] = [:]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Minimal Sendable JSON tree for MCP schemas / results.
public enum AnySendableJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnySendableJSON])
    case object([String: AnySendableJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnySendableJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnySendableJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public static func from(_ any: Any) -> AnySendableJSON {
        switch any {
        case is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as Int: return .number(Double(value))
        case let value as Double: return .number(value)
        case let value as Float: return .number(Double(value))
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map(from))
        case let value as [String: Any]: return .object(value.mapValues(from))
        default: return .string(String(describing: any))
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let value): return value.map(\.anyValue)
        case .object(let value): return value.mapValues(\.anyValue)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

public protocol MCPTransport: Sendable {
    func initialize() async throws
    func listTools() async throws -> [MCPDiscoveredTool]
    func callTool(name: String, arguments: [String: AnySendableJSON]) async throws -> AnySendableJSON
}
