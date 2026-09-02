import Foundation
import NookCore

public enum ModelDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(progressPct: Double, transfer: DownloadTransferProgress? = nil)
    case ready
}

public protocol ModelRuntime: Sendable {
    var activeTier: ModelTier { get }
    var downloadState: ModelDownloadState { get }

    func switchTier(_ tier: ModelTier) async throws
    func downloadModel(
        tier: ModelTier,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws

    func generateStreaming(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest,
        toolExecutor: (@Sendable (String, ToolArguments) async throws -> ToolExecutionResult)?,
        onToken: @escaping @Sendable (String) -> Void,
        onToolEvent: (@Sendable (AgentToolEvent) -> Void)?
    ) async throws -> AgentGenerationResult

    func cancelGeneration()
    func releaseLoadedModel() async
    func ensureModelReady() async throws
}

public extension ModelRuntime {
    func ensureModelReady() async throws {}

    func generateStreaming(
        promptContext: AssembledPromptContext,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await generateStreaming(
            promptContext: promptContext,
            request: .textOnly,
            toolExecutor: nil,
            onToken: onToken,
            onToolEvent: nil
        ).text
    }
}

public final class ScriptedModelRuntime: ModelRuntime, @unchecked Sendable {
    public private(set) var activeTier: ModelTier
    public private(set) var downloadState: ModelDownloadState = .ready

    public init(activeTier: ModelTier = ModelTier.recommended) {
        self.activeTier = activeTier
    }

    public func switchTier(_ tier: ModelTier) async throws {
        self.activeTier = tier
    }

    public func downloadModel(
        tier: ModelTier,
        progressHandler: @escaping @Sendable (Double, DownloadTransferProgress?) -> Void
    ) async throws {
        self.activeTier = tier
        self.downloadState = .downloading(progressPct: 0)

        for p in stride(from: 0.1, through: 1.0, by: 0.15) {
            try? await Task.sleep(nanoseconds: 120_000_000)
            progressHandler(p, nil)
        }

        self.downloadState = .ready
    }

    public func generateStreaming(
        promptContext: AssembledPromptContext,
        request: AgentGenerationRequest,
        toolExecutor: (@Sendable (String, ToolArguments) async throws -> ToolExecutionResult)?,
        onToken: @escaping @Sendable (String) -> Void,
        onToolEvent: (@Sendable (AgentToolEvent) -> Void)?
    ) async throws -> AgentGenerationResult {
        let lastUserMsg = promptContext.recentMessages.last(where: { $0.role == .user })?.content ?? ""
        let lower = lastUserMsg.lowercased()
        var citations: [Citation] = []

        let toolNames = request.toolSchemas.compactMap { schema -> String? in
            guard let function = schema["function"] as? [String: any Sendable] else { return nil }
            return function["name"] as? String
        }

        if let toolExecutor,
           toolNames.contains(DocumentsSearchTool.toolName) {
            let result = try await toolExecutor(
                DocumentsSearchTool.toolName,
                ["query": .string(lastUserMsg)]
            )
            citations = result.citations
            onToolEvent?(
                AgentToolEvent(
                    toolName: DocumentsSearchTool.toolName,
                    displayText: result.displayText,
                    citations: result.citations,
                    chunks: result.chunks
                )
            )
        }

        // Prefer answering from injected tool results when the app already forced a search.
        let toolBlock = promptContext.toolResultSummaries.joined(separator: "\n")
        let responseText: String
        if toolBlock.localizedCaseInsensitiveContains("risk")
            || lower.contains("risk") {
            responseText = "Three risks come up repeatedly across your project documents.\n\nTimeline. The integration milestone assumes vendor delivery in week six, but your retro notes record two earlier slips of two to three weeks each.\n\nA single dependency. The spec names one identity provider and no fallback path is documented anywhere in the collection.\n\nUnestimated scope. The risk register flags the analytics work as unestimated, and it is still on the v1 list."
        } else if lower.contains("spec") || lower.contains("match") {
            responseText = "Mostly, with one gap.\n\nYour screenshot puts the review step after submission. The specification puts review before it, so the confirmation copy on this screen would appear too late to be useful.\n\nEverything else matches: field order, the optional note, and the two-button footer."
        } else if lower.contains("github") || lower.contains("issue") {
            responseText = "Two open issues look related.\n\n#418, Identity provider fallback, is unassigned and describes the same single-provider risk your spec has. #402, Analytics scope, is tagged needs-estimate.\n\nNeither is on the current milestone, which is probably the thing worth raising."
        } else if !toolBlock.isEmpty {
            responseText = "I searched your scoped Knowledge on device. Ask a follow-up if you want a narrower passage or a different collection."
        } else {
            responseText = "I've reviewed your knowledge collection on-device. Let me know if you'd like me to examine specific documents, verify against external tools, or prepare a summary."
        }

        var currentIndex = responseText.startIndex
        while currentIndex < responseText.endIndex {
            let nextIndex = responseText.index(currentIndex, offsetBy: 4, limitedBy: responseText.endIndex) ?? responseText.endIndex
            let chunk = String(responseText[currentIndex..<nextIndex])
            onToken(chunk)
            currentIndex = nextIndex
            try? await Task.sleep(nanoseconds: 16_000_000)
        }

        return AgentGenerationResult(text: responseText, citations: citations)
    }

    public func cancelGeneration() {}

    public func releaseLoadedModel() async {}
}
