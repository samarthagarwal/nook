import AVFoundation
import Speech
import Foundation

/// Real-time speech transcription using Apple's Speech framework.
/// Provides streaming transcription with partial (tentative) and final results.
@MainActor
public final class LiveTranscriber: ObservableObject {
    
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case transcribing
        case stopping
        case error(String)
    }
    
    /// A segment of transcribed text with finality status.
    public struct TranscriptSegment: Equatable, Sendable {
        public let text: String
        public let isFinal: Bool
        public let confidence: Float
        public let timestamp: TimeInterval
        
        public init(text: String, isFinal: Bool, confidence: Float = 1.0, timestamp: TimeInterval = 0) {
            self.text = text
            self.isFinal = isFinal
            self.confidence = confidence
            self.timestamp = timestamp
        }
    }
    
    @Published public private(set) var state: State = .idle
    @Published public private(set) var currentTranscript: String = ""
    @Published public private(set) var segments: [TranscriptSegment] = []
    
    /// The portion of text that is still tentative (not yet finalized by Speech)
    @Published public private(set) var tentativeText: String = ""
    
    /// The portion of text that has been finalized
    @Published public private(set) var finalizedText: String = ""
    
    private var recognizer: SFSpeechRecognizer?
    /// The current recognition request. Thread-safe for appending audio buffers.
    public private(set) var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioFormat: AVAudioFormat?
    
    /// Locale for speech recognition. Defaults to device locale.
    public var locale: Locale {
        didSet {
            recognizer = SFSpeechRecognizer(locale: locale)
        }
    }
    
    public init(locale: Locale = .current) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }
    
    // MARK: - Public API
    
    /// Requests speech recognition permission.
    public func requestPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
    
    /// Current authorization status.
    public var authorizationStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }
    
    /// Checks if speech recognition is available for the current locale.
    public var isAvailable: Bool {
        recognizer?.isAvailable ?? false
    }
    
    /// Starts live transcription.
    /// - Parameter audioFormat: The format of audio buffers that will be appended.
    public func startTranscribing(audioFormat: AVAudioFormat) throws {
        guard state == .idle else {
            throw LiveTranscriberError.alreadyTranscribing
        }
        
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw LiveTranscriberError.recognizerUnavailable
        }
        
        state = .starting
        
        // Reset state
        currentTranscript = ""
        tentativeText = ""
        finalizedText = ""
        segments = []
        
        self.audioFormat = audioFormat
        
        // Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        
        // Prefer on-device recognition for privacy, but fall back to server if unavailable
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        
        // Enable automatic punctuation if available
        if #available(iOS 16.0, macOS 13.0, *) {
            request.addsPunctuation = true
        }
        
        self.recognitionRequest = request
        
        // Start recognition task on the main queue to avoid threading issues
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognitionResult(result, error: error)
            }
        }
        
        state = .transcribing
    }
    
    /// Appends an audio buffer to the recognition request.
    /// Call this from AudioRecorder's onAudioBuffer callback.
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard state == .transcribing else { return }
        recognitionRequest?.append(buffer)
    }
    
    /// Stops transcription and finalizes results.
    public func stopTranscribing() {
        guard state == .transcribing || state == .starting else { return }
        
        state = .stopping
        
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
        audioFormat = nil
        
        // Move any remaining tentative text to finalized
        if !tentativeText.isEmpty {
            finalizedText = currentTranscript
            tentativeText = ""
        }
        
        state = .idle
    }
    
    /// Returns the full transcript (finalized + tentative).
    public var fullTranscript: String {
        currentTranscript
    }
    
    // MARK: - Private
    
    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            // Ignore cancellation errors during normal stop
            if (error as NSError).code == 1 || (error as NSError).code == 216 {
                return
            }
            state = .error(error.localizedDescription)
            return
        }
        
        guard let result = result else { return }
        
        let transcription = result.bestTranscription
        currentTranscript = transcription.formattedString
        
        // Determine which part is finalized vs tentative
        // Apple Speech marks the result as final when it's confident
        if result.isFinal {
            finalizedText = currentTranscript
            tentativeText = ""
        } else {
            // Heuristic: words with high confidence are considered "finalized" for display
            // This creates the effect of tentative words at the end
            updateFinalizedAndTentative(from: transcription)
        }
        
        // Update segments with timing information
        updateSegments(from: transcription, isFinal: result.isFinal)
    }
    
    private func updateFinalizedAndTentative(from transcription: SFTranscription) {
        let segments = transcription.segments
        guard !segments.isEmpty else {
            finalizedText = ""
            tentativeText = ""
            return
        }
        
        // Find the split point: words with confidence >= threshold are "finalized"
        // Keep last 2-3 words as tentative for visual feedback
        let tentativeWordCount = 2
        let splitIndex = max(0, segments.count - tentativeWordCount)
        
        let finalizedSegments = segments.prefix(splitIndex)
        let tentativeSegments = segments.suffix(from: splitIndex)
        
        finalizedText = finalizedSegments.map { $0.substring }.joined(separator: " ")
        tentativeText = tentativeSegments.map { $0.substring }.joined(separator: " ")
        
        // Ensure proper spacing
        if !finalizedText.isEmpty && !tentativeText.isEmpty {
            finalizedText += " "
        }
    }
    
    private func updateSegments(from transcription: SFTranscription, isFinal: Bool) {
        segments = transcription.segments.map { segment in
            TranscriptSegment(
                text: segment.substring,
                isFinal: isFinal || segment.confidence > 0.8,
                confidence: Float(segment.confidence),
                timestamp: segment.timestamp
            )
        }
    }
}

// MARK: - Errors

public enum LiveTranscriberError: LocalizedError {
    case alreadyTranscribing
    case notTranscribing
    case recognizerUnavailable
    case permissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .alreadyTranscribing:
            return "Transcription is already in progress"
        case .notTranscribing:
            return "No transcription in progress"
        case .recognizerUnavailable:
            return "Speech recognition is not available"
        case .permissionDenied:
            return "Speech recognition permission denied"
        }
    }
}
