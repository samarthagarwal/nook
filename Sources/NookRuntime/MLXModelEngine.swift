import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import NookCore
import Tokenizers

actor MLXModelEngine {
    private var container: ModelContainer?
    private var loadedModelKey: String?

    init() {
        MLX.Memory.cacheLimit = 512 * 1024 * 1024
    }

    var isModelLoaded: Bool {
        container != nil
    }

    func load(
        source: ModelLoadSource,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws {
        let modelKey: String
        switch source {
        case .bundled(let url):
            modelKey = "bundled:\(url.path)"
        case .remote(let repoId):
            modelKey = "remote:\(repoId)"
        }

        if loadedModelKey == modelKey, container != nil {
            progressHandler(1.0)
            return
        }

        container = nil
        loadedModelKey = nil

        let modelContainer: ModelContainer
        switch source {
        case .bundled(let directory):
            progressHandler(0.2)
            modelContainer = try await LLMModelFactory.shared.loadContainer(
                from: directory,
                using: #huggingFaceTokenizerLoader()
            )
            progressHandler(1.0)

        case .remote(let repoId):
            let configuration = ModelConfiguration(id: repoId)
            modelContainer = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    progressHandler(progress.fractionCompleted)
                }
            )
            progressHandler(1.0)
        }

        container = modelContainer
        loadedModelKey = modelKey
    }

    func unload() {
        container = nil
        loadedModelKey = nil
    }

    func generate(
        promptContext: AssembledPromptContext,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let container else {
            throw MLXModelEngineError.modelNotLoaded
        }

        let messages = MLXPromptBuilder.chatMessages(from: promptContext)
        let parameters = GenerateParameters(
            maxTokens: 256,
            temperature: 0.3
        )

        let session = ChatSession(
            container,
            generateParameters: parameters
        )

        var fullText = ""
        for try await chunk in session.streamResponse(to: messages) {
            fullText += chunk
            onToken(chunk)
        }

        return fullText
    }
}

enum MLXModelEngineError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "The on-device model is not loaded yet."
        }
    }
}
