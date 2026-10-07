import Foundation
import WhisperKit

/// High-quality speech transcription using WhisperKit.
/// Used for final transcription pass after recording stops.
@MainActor
public final class WhisperTranscriber: ObservableObject {
    
    public enum State: Equatable, Sendable {
        case idle
        case loading
        case ready
        case transcribing(progress: Double)
        case error(String)
    }
    
    public enum ModelVariant: String, CaseIterable, Sendable {
        case tiny = "tiny"
        case base = "base"
        case small = "small"
        
        public var displayName: String {
            switch self {
            case .tiny: return "Whisper Tiny"
            case .base: return "Whisper Base"
            case .small: return "Whisper Small"
            }
        }
        
        public var approximateSize: String {
            switch self {
            case .tiny: return "~75 MB"
            case .base: return "~150 MB"
            case .small: return "~500 MB"
            }
        }
    }
    
    /// A timestamped segment from Whisper transcription.
    public struct TimestampedSegment: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let text: String
        public let startTime: TimeInterval
        public let endTime: TimeInterval
        
        public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
            self.id = UUID()
            self.text = text
            self.startTime = startTime
            self.endTime = endTime
        }
        
        public var formattedStartTime: String {
            let minutes = Int(startTime) / 60
            let seconds = Int(startTime) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    /// Full transcription result with metadata.
    public struct TranscriptionOutput: Sendable {
        public let text: String
        public let segments: [TimestampedSegment]
        public let language: String?
        public let duration: TimeInterval
        
        public init(text: String, segments: [TimestampedSegment], language: String?, duration: TimeInterval) {
            self.text = text
            self.segments = segments
            self.language = language
            self.duration = duration
        }
    }
    
    @Published public private(set) var state: State = .idle
    @Published public private(set) var downloadProgress: Double = 0
    
    private var whisperKit: WhisperKit?
    private var currentModel: ModelVariant?
    
    public init() {}
    
    // MARK: - Public API
    
    /// Loads the Whisper model. Call this before transcribing.
    /// - Parameter model: The model variant to load.
    public func loadModel(_ model: ModelVariant = .base) async throws {
        guard state == .idle || state.isError else {
            if currentModel == model && state == .ready {
                return
            }
            throw WhisperTranscriberError.alreadyLoading
        }
        
        state = .loading
        downloadProgress = 0
        
        do {
            whisperKit = try await WhisperKit(
                model: "openai_whisper-\(model.rawValue)",
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: false,
                prewarm: true,
                load: true
            )
            currentModel = model
            state = .ready
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Checks if a model is downloaded and ready.
    public var isModelLoaded: Bool {
        state == .ready && whisperKit != nil
    }
    
    /// Transcribes an audio file.
    /// - Parameter audioURL: URL to the audio file (m4a, wav, etc.)
    /// - Returns: Transcription result with timestamped segments.
    public func transcribe(audioURL: URL) async throws -> TranscriptionOutput {
        guard let whisperKit = whisperKit, state == .ready else {
            throw WhisperTranscriberError.modelNotLoaded
        }
        
        state = .transcribing(progress: 0)
        
        do {
            let results = try await whisperKit.transcribe(
                audioPath: audioURL.path,
                decodeOptions: DecodingOptions(
                    task: .transcribe,
                    language: nil,  // Auto-detect
                    wordTimestamps: true,
                    chunkingStrategy: .vad
                )
            ) { [weak self] progress in
                // Update progress based on text length as a heuristic
                let textLength = progress.text.count
                Task { @MainActor [weak self] in
                    // Estimate progress: assume typical transcription produces ~500 chars
                    let estimatedProgress = min(Double(textLength) / 500.0, 0.95)
                    self?.state = .transcribing(progress: estimatedProgress)
                }
                return true  // Continue transcription
            }
            
            // Convert WhisperKit results to our format
            let segments = convertToTimestampedSegments(results)
            let fullText = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let language = results.first?.language
            let duration = results.last?.segments.last?.end ?? 0
            
            state = .ready
            
            return TranscriptionOutput(
                text: fullText,
                segments: segments,
                language: language,
                duration: TimeInterval(duration)
            )
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Unloads the model to free memory.
    public func unloadModel() {
        Task {
            await whisperKit?.unloadModels()
        }
        whisperKit = nil
        currentModel = nil
        state = .idle
    }
    
    // MARK: - Private
    
    private func convertToTimestampedSegments(_ results: [TranscriptionResult]) -> [TimestampedSegment] {
        var segments: [TimestampedSegment] = []
        var currentSentence = ""
        var sentenceStart: Float = 0
        var sentenceEnd: Float = 0
        
        for result in results {
            for segment in result.segments {
                // Check if this segment ends a sentence
                let text = segment.text.trimmingCharacters(in: .whitespaces)
                let endsPunctuation = text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!")
                
                if currentSentence.isEmpty {
                    sentenceStart = segment.start
                }
                
                currentSentence += (currentSentence.isEmpty ? "" : " ") + text
                sentenceEnd = segment.end
                
                if endsPunctuation {
                    // Commit the sentence as a segment
                    segments.append(TimestampedSegment(
                        text: currentSentence,
                        startTime: TimeInterval(sentenceStart),
                        endTime: TimeInterval(sentenceEnd)
                    ))
                    currentSentence = ""
                }
            }
        }
        
        // Add any remaining text as final segment
        if !currentSentence.isEmpty {
            segments.append(TimestampedSegment(
                text: currentSentence,
                startTime: TimeInterval(sentenceStart),
                endTime: TimeInterval(sentenceEnd)
            ))
        }
        
        return segments
    }
}

// MARK: - State Extension

extension WhisperTranscriber.State {
    var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

// MARK: - Errors

public enum WhisperTranscriberError: LocalizedError {
    case modelNotLoaded
    case alreadyLoading
    case transcriptionFailed
    case audioFileNotFound
    
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model not loaded. Call loadModel() first."
        case .alreadyLoading:
            return "Model is already loading"
        case .transcriptionFailed:
            return "Transcription failed"
        case .audioFileNotFound:
            return "Audio file not found"
        }
    }
}
