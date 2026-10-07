import Foundation
import WhisperKit

/// Manages Whisper model downloads and lifecycle.
/// Similar pattern to LiteRT model management in NookRuntime.
@MainActor
public final class VoiceModelManager: ObservableObject {
    
    public enum DownloadState: Equatable, Sendable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case error(String)
    }
    
    public struct ModelInfo: Identifiable, Sendable {
        public let id: String
        public let variant: WhisperTranscriber.ModelVariant
        public let displayName: String
        public let size: String
        public let isRecommended: Bool
        
        public init(variant: WhisperTranscriber.ModelVariant, isRecommended: Bool = false) {
            self.id = variant.rawValue
            self.variant = variant
            self.displayName = variant.displayName
            self.size = variant.approximateSize
            self.isRecommended = isRecommended
        }
    }
    
    @Published public private(set) var downloadState: DownloadState = .notDownloaded
    @Published public private(set) var selectedModel: WhisperTranscriber.ModelVariant = .base
    @Published public private(set) var isModelLoaded: Bool = false
    
    /// Available Whisper models.
    public let availableModels: [ModelInfo] = [
        ModelInfo(variant: .tiny),
        ModelInfo(variant: .base, isRecommended: true),
        ModelInfo(variant: .small)
    ]
    
    private let whisperTranscriber: WhisperTranscriber
    private let userDefaults: UserDefaults
    
    private static let selectedModelKey = "nook.voice.selectedModel"
    private static let modelDownloadedKey = "nook.voice.modelDownloaded"
    
    public init(whisperTranscriber: WhisperTranscriber, userDefaults: UserDefaults = .standard) {
        self.whisperTranscriber = whisperTranscriber
        self.userDefaults = userDefaults
        
        // Restore selected model
        if let savedModel = userDefaults.string(forKey: Self.selectedModelKey),
           let variant = WhisperTranscriber.ModelVariant(rawValue: savedModel) {
            self.selectedModel = variant
        }
        
        // Check if model is already downloaded
        Task {
            await checkModelStatus()
        }
    }
    
    // MARK: - Public API
    
    /// Downloads and loads the selected Whisper model.
    public func downloadAndLoadModel() async throws {
        guard downloadState != .downloading(progress: 0) else { return }
        
        downloadState = .downloading(progress: 0)
        
        do {
            // WhisperKit handles download internally
            try await whisperTranscriber.loadModel(selectedModel)
            
            downloadState = .downloaded
            isModelLoaded = true
            
            // Persist selection
            userDefaults.set(selectedModel.rawValue, forKey: Self.selectedModelKey)
            userDefaults.set(true, forKey: Self.modelDownloadedKey)
        } catch {
            downloadState = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Selects a different model variant.
    /// If the model is different from currently loaded, unloads the current model.
    public func selectModel(_ variant: WhisperTranscriber.ModelVariant) {
        guard variant != selectedModel else { return }
        
        // Unload current model if different
        if isModelLoaded {
            whisperTranscriber.unloadModel()
            isModelLoaded = false
            downloadState = .notDownloaded
        }
        
        selectedModel = variant
    }
    
    /// Prepares the model for use (downloads if needed).
    public func prepareForUse() async throws {
        if !isModelLoaded {
            try await downloadAndLoadModel()
        }
    }
    
    /// Unloads the model to free memory.
    public func unloadModel() {
        whisperTranscriber.unloadModel()
        isModelLoaded = false
    }
    
    /// Deletes downloaded model files to free storage.
    public func deleteDownloadedModel() async throws {
        unloadModel()
        
        // WhisperKit stores models in a cache directory
        // We can clear it by removing the cache
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let whisperCache = cacheDir?.appendingPathComponent("huggingface/models") {
            try? FileManager.default.removeItem(at: whisperCache)
        }
        
        downloadState = .notDownloaded
        userDefaults.set(false, forKey: Self.modelDownloadedKey)
    }
    
    /// Estimated storage used by downloaded models.
    public var estimatedStorageUsed: String {
        guard downloadState == .downloaded else { return "0 MB" }
        return selectedModel.approximateSize
    }
    
    // MARK: - Private
    
    private func checkModelStatus() async {
        // Try to load the model to check if it's cached
        // WhisperKit will load from cache if available
        do {
            try await whisperTranscriber.loadModel(selectedModel)
            downloadState = .downloaded
            isModelLoaded = true
        } catch {
            downloadState = .notDownloaded
            isModelLoaded = false
        }
    }
}

// MARK: - Convenience

public extension VoiceModelManager {
    
    /// Creates a shared transcriber and manager pair.
    static func createShared() -> (manager: VoiceModelManager, transcriber: WhisperTranscriber) {
        let transcriber = WhisperTranscriber()
        let manager = VoiceModelManager(whisperTranscriber: transcriber)
        return (manager, transcriber)
    }
}
