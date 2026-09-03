import Foundation

// MARK: - Message & Transcript Types

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case localTool
    case externalTool
}

public struct Citation: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let sourceDocument: String
    public let pageOrSection: String
    public let passage: String
    public let surroundingContext: String
    
    public init(
        id: String = UUID().uuidString,
        label: String,
        sourceDocument: String,
        pageOrSection: String,
        passage: String,
        surroundingContext: String
    ) {
        self.id = id
        self.label = label
        self.sourceDocument = sourceDocument
        self.pageOrSection = pageOrSection
        self.passage = passage
        self.surroundingContext = surroundingContext
    }
}

public struct ExternalToolExecution: Codable, Equatable, Sendable {
    public let toolName: String
    public let lines: [String]
    public let footer: String
    
    public init(toolName: String, lines: [String], footer: String) {
        self.toolName = toolName
        self.lines = lines
        self.footer = footer
    }
}

public struct Message: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let conversationId: String
    public let role: MessageRole
    public var content: String
    public var citations: [Citation]
    public var attachedImageName: String?
    public var localToolText: String?
    public var externalToolData: ExternalToolExecution?
    public let createdAt: Date
    
    public init(
        id: String = UUID().uuidString,
        conversationId: String,
        role: MessageRole,
        content: String,
        citations: [Citation] = [],
        attachedImageName: String? = nil,
        localToolText: String? = nil,
        externalToolData: ExternalToolExecution? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.citations = citations
        self.attachedImageName = attachedImageName
        self.localToolText = localToolText
        self.externalToolData = externalToolData
        self.createdAt = createdAt
    }
}

public struct Conversation: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public var whenString: String
    public var snippet: String
    public var tags: [String]
    public var activeKnowledgeScope: [String]
    public let createdAt: Date
    public var updatedAt: Date
    
    public init(
        id: String = UUID().uuidString,
        title: String,
        whenString: String = "now",
        snippet: String,
        tags: [String] = [],
        activeKnowledgeScope: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.whenString = whenString
        self.snippet = snippet
        self.tags = tags
        self.activeKnowledgeScope = activeKnowledgeScope
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Knowledge Domain

public enum CollectionState: String, Codable, Sendable {
    case ready
    case busy
}

public struct KnowledgeCollection: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var count: String
    public var desc: String
    public var status: String
    public var state: CollectionState
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        count: String,
        desc: String,
        status: String,
        state: CollectionState = .ready
    ) {
        self.id = id
        self.name = name
        self.count = count
        self.desc = desc
        self.status = status
        self.state = state
    }
}

public struct KnowledgeDocument: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let collectionId: String
    public var name: String
    public var meta: String
    public var status: String
    public var progressPct: Double?
    
    public init(
        id: String = UUID().uuidString,
        collectionId: String,
        name: String,
        meta: String,
        status: String,
        progressPct: Double? = nil
    ) {
        self.id = id
        self.collectionId = collectionId
        self.name = name
        self.meta = meta
        self.status = status
        self.progressPct = progressPct
    }
}

public struct DocumentChunk: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let documentId: String
    public let text: String
    public let pageOrSection: String
    public let parentSection: String?
    public let embeddingRef: String?
    
    public init(
        id: String = UUID().uuidString,
        documentId: String,
        text: String,
        pageOrSection: String,
        parentSection: String? = nil,
        embeddingRef: String? = nil
    ) {
        self.id = id
        self.documentId = documentId
        self.text = text
        self.pageOrSection = pageOrSection
        self.parentSection = parentSection
        self.embeddingRef = embeddingRef
    }
}

// MARK: - Skills Domain

public enum SkillGroup: String, Codable, Sendable {
    case builtIn = "Built in"
    case imported = "Imported"
    case yours = "Yours"
}

public struct SkillPermission: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let tool: String
    public let what: String
    public var isGranted: Bool
    
    public init(
        id: String = UUID().uuidString,
        tool: String,
        what: String,
        isGranted: Bool = false // Crucial rule: default off
    ) {
        self.id = id
        self.tool = tool
        self.what = what
        self.isGranted = isGranted
    }
}

public struct Skill: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var desc: String
    public var group: SkillGroup
    public var isEnabled: Bool
    public var importedMeta: String
    public var skillMdContent: String
    public var permissions: [SkillPermission]
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        desc: String,
        group: SkillGroup,
        isEnabled: Bool = false,
        importedMeta: String = "Imported · instructions only, nothing executable.",
        skillMdContent: String,
        permissions: [SkillPermission] = []
    ) {
        self.id = id
        self.name = name
        self.desc = desc
        self.group = group
        self.isEnabled = isEnabled
        self.importedMeta = importedMeta
        self.skillMdContent = skillMdContent
        self.permissions = permissions
    }
}

// MARK: - Connections / MCP Domain

public enum MCPApprovalPolicy: String, Codable, CaseIterable, Sendable {
    case everyCall = "Every call"
    case consequential = "Consequential"
    case never = "Never"
}

public struct MCPToolEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var what: String
    public var isEnabled: Bool
    
    public init(id: String = UUID().uuidString, name: String, what: String, isEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.what = what
        self.isEnabled = isEnabled
    }
}

public struct MCPServer: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var url: String
    /// Optional auth header value (e.g. Bearer token). Stored locally.
    public var authHeaderValue: String
    public var isConnected: Bool
    public var toolsCountDescription: String
    public var approvalPolicy: MCPApprovalPolicy
    public var tools: [MCPToolEntry]
    
    public init(
        id: String = UUID().uuidString,
        name: String,
        url: String,
        authHeaderValue: String = "",
        isConnected: Bool,
        toolsCountDescription: String = "",
        approvalPolicy: MCPApprovalPolicy = .consequential,
        tools: [MCPToolEntry] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.authHeaderValue = authHeaderValue
        self.isConnected = isConnected
        self.toolsCountDescription = toolsCountDescription
        self.approvalPolicy = approvalPolicy
        self.tools = tools
    }

    /// Host + path only — never query/fragment (API keys are sometimes put in the URL).
    public var displayURL: String {
        if var components = URLComponents(string: url) {
            components.query = nil
            components.fragment = nil
            if let cleaned = components.string, !cleaned.isEmpty {
                return cleaned
            }
        }
        if let queryStart = url.firstIndex(of: "?") {
            return String(url[..<queryStart])
        }
        if let fragmentStart = url.firstIndex(of: "#") {
            return String(url[..<fragmentStart])
        }
        return url
    }

    /// Tools for list chips: enabled first, then the rest (full set — UI fits what it can).
    public var toolsOrderedForChips: [MCPToolEntry] {
        tools.filter(\.isEnabled) + tools.filter { !$0.isEnabled }
    }
}

// MARK: - Memory Domain

public struct MemoryItem: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var subject: String
    public var kind: String
    public var quote: String
    public var source: String
    public var isForgotten: Bool
    
    public init(
        id: String = UUID().uuidString,
        subject: String,
        kind: String,
        quote: String,
        source: String,
        isForgotten: Bool = false
    ) {
        self.id = id
        self.subject = subject
        self.kind = kind
        self.quote = quote
        self.source = source
        self.isForgotten = isForgotten
    }
}

// MARK: - Model Tier

public struct ModelTier: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let size: String
    public let desc: String
    public let longDesc: String
    public let tags: [String]
    public let isDefault: Bool
    
    public init(
        id: String,
        name: String,
        size: String,
        desc: String,
        longDesc: String,
        tags: [String],
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.desc = desc
        self.longDesc = longDesc
        self.tags = tags
        self.isDefault = isDefault
    }

    /// True when model weights ship inside the app bundle (no network download).
    public var shipsBundled: Bool {
        // Only LiteRT Bundled ships weights in the IPA; MLX always downloads.
        id == "bundled" && NookInferenceConfig.usesLiteRT
    }
    
    /// Tier recommended for first-time download (chat + vision).
    public static var recommended: ModelTier {
        standardTiers.first { $0.tags.contains("recommended") } ?? standardTiers[0]
    }

    public static let standardTiers: [ModelTier] = [
        ModelTier(
            id: "bundled",
            name: "Bundled",
            size: "331 MB",
            desc: "Ships with the app. Lightest chat, no download.",
            longDesc: "Qwen3 0.6B (INT4, LiteRT-LM) included in the app package.",
            tags: ["text", "bundled"],
            isDefault: true
        ),
        ModelTier(
            id: "fast",
            name: "Fast",
            size: "1.6 GB",
            desc: "Stronger everyday chat than Bundled.",
            longDesc: "Qwen2.5 1.5B Instruct (Q8, LiteRT-LM). Good step up before Balanced.",
            tags: ["text", "tools"]
        ),
        ModelTier(
            id: "balanced",
            name: "Balanced",
            size: "2.6 GB",
            desc: "Recommended. Stronger reasoning, multimodal.",
            longDesc: "Gemma 4 E2B via LiteRT-LM (Metal). Full chat with vision and tool calling.",
            tags: ["text", "images", "tools", "recommended"]
        )
    ]
}
