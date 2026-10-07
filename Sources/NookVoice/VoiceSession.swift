import AVFoundation
import Foundation

/// Coordinates a complete voice input session with hybrid transcription.
/// Uses Apple Speech for real-time preview and WhisperKit for final polish.
@MainActor
public final class VoiceSession: ObservableObject {
    
    public enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case recording
        case transcribing(progress: Double)
        case reviewing(TranscriptionResult)
        case error(String)
        
        public var isActive: Bool {
            switch self {
            case .recording, .transcribing: return true
            default: return false
            }
        }
    }
    
    public enum Mode: Sendable {
        /// Chat mode: quick transcription, no audio saved, simpler result
        case chat
        /// Knowledge mode: full transcription with timestamps, optional audio save
        case knowledge
    }
    
    /// Result of a voice session.
    public struct TranscriptionResult: Equatable, Sendable {
        public let text: String
        public let segments: [WhisperTranscriber.TimestampedSegment]
        public let duration: TimeInterval
        public let audioURL: URL?
        public let language: String?
        
        public var wordCount: Int {
            text.split(separator: " ").count
        }
        
        public var formattedDuration: String {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
    
    @Published public private(set) var state: State = .idle
    @Published public private(set) var liveTranscript: String = ""
    @Published public private(set) var finalizedText: String = ""
    @Published public private(set) var tentativeText: String = ""
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var audioLevel: AudioRecorder.AudioLevel = .init(average: 0, peak: 0)
    
    public let mode: Mode
    
    private let audioRecorder: AudioRecorder
    private let liveTranscriber: LiveTranscriber
    private let whisperTranscriber: WhisperTranscriber
    
    private var audioFileURL: URL?
    
    /// Callback when live transcript updates (for UI)
    public var onLiveTranscriptUpdate: ((String, String, String) -> Void)?  // (full, finalized, tentative)
    
    /// Callback when audio level updates (for waveform)
    public var onAudioLevelUpdate: ((AudioRecorder.AudioLevel) -> Void)?
    
    public init(
        mode: Mode,
        audioRecorder: AudioRecorder = AudioRecorder(),
        liveTranscriber: LiveTranscriber = LiveTranscriber(),
        whisperTranscriber: WhisperTranscriber
    ) {
        self.mode = mode
        self.audioRecorder = audioRecorder
        self.liveTranscriber = liveTranscriber
        self.whisperTranscriber = whisperTranscriber
        
        setupBindings()
    }
    
    // MARK: - Public API
    
    /// Checks and requests all necessary permissions.
    /// Returns true if all permissions granted.
    public func requestPermissions() async -> Bool {
        state = .requestingPermission
        
        // Request microphone permission
        let micGranted = await audioRecorder.requestPermission()
        guard micGranted else {
            state = .error("Microphone permission denied")
            return false
        }
        
        // Request speech recognition permission
        let speechStatus = await liveTranscriber.requestPermission()
        guard speechStatus == .authorized else {
            state = .error("Speech recognition permission denied")
            return false
        }
        
        state = .idle
        return true
    }
    
    /// Checks if all permissions are granted.
    public var hasPermissions: Bool {
        audioRecorder.permissionStatus == .granted &&
        liveTranscriber.authorizationStatus == .authorized
    }
    
    /// Checks if the Whisper model is loaded and ready.
    public var isWhisperReady: Bool {
        whisperTranscriber.isModelLoaded
    }
    
    /// Starts a voice recording session.
    public func startRecording() async throws {
        guard state == .idle else {
            throw VoiceSessionError.sessionInProgress
        }
        
        if !hasPermissions {
            let granted = await requestPermissions()
            if !granted {
                throw VoiceSessionError.permissionDenied
            }
        }
        
        // Load WhisperKit model if not already loaded
        if !whisperTranscriber.isModelLoaded {
            try await whisperTranscriber.loadModel(.base)
        }
        
        // Reset state
        liveTranscript = ""
        finalizedText = ""
        tentativeText = ""
        duration = 0
        
        // Start audio recording (save to file for WhisperKit final transcription)
        audioFileURL = try audioRecorder.startRecording(saveToFile: true)
        
        // NOTE: Live transcription disabled - causes crashes with AVAudioEngine conflicts
        // WhisperKit provides final transcription after recording stops
        
        state = .recording
    }
    
    /// Stops recording and begins final transcription.
    public func stopRecording() async throws -> TranscriptionResult {
        guard state == .recording else {
            throw VoiceSessionError.notRecording
        }
        
        // Stop live transcription first
        liveTranscriber.stopTranscribing()
        
        // Stop audio recording
        let audioURL = audioRecorder.stopRecording()
        let recordedDuration = duration
        
        // Check if we have audio to transcribe
        guard let audioURL = audioURL else {
            throw VoiceSessionError.noAudioRecorded
        }
        
        // Start WhisperKit final transcription
        state = .transcribing(progress: 0)
        
        let whisperResult: WhisperTranscriber.TranscriptionOutput
        do {
            whisperResult = try await whisperTranscriber.transcribe(audioURL: audioURL)
        } catch {
            // Reset state on transcription failure
            state = .error("Transcription failed: \(error.localizedDescription)")
            throw error
        }
        
        let result = TranscriptionResult(
            text: whisperResult.text,
            segments: whisperResult.segments,
            duration: recordedDuration,
            audioURL: mode == .knowledge ? audioURL : nil,  // Only keep audio for Knowledge
            language: whisperResult.language
        )
        
        // Clean up audio file for chat mode
        if mode == .chat {
            try? FileManager.default.removeItem(at: audioURL)
        }
        
        state = .reviewing(result)
        return result
    }
    
    /// Discards the current recording.
    public func discardRecording() {
        liveTranscriber.stopTranscribing()
        audioRecorder.discardRecording()
        
        liveTranscript = ""
        finalizedText = ""
        tentativeText = ""
        duration = 0
        audioFileURL = nil
        
        state = .idle
    }
    
    /// Finalizes the session after review.
    /// - Parameter keepAudio: If true (and mode is .knowledge), keeps the audio file.
    /// - Returns: The final result.
    public func finalizeSession(keepAudio: Bool = true) -> TranscriptionResult? {
        guard case .reviewing(let result) = state else { return nil }
        
        // Delete audio if user chose not to keep it
        if !keepAudio, let audioURL = result.audioURL {
            try? FileManager.default.removeItem(at: audioURL)
            let updatedResult = TranscriptionResult(
                text: result.text,
                segments: result.segments,
                duration: result.duration,
                audioURL: nil,
                language: result.language
            )
            state = .idle
            return updatedResult
        }
        
        state = .idle
        return result
    }
    
    /// Resets the session to idle state.
    public func reset() {
        discardRecording()
        state = .idle
    }
    
    // MARK: - Private
    
    private func setupBindings() {
        // Bind audio recorder state
        audioRecorder.$duration
            .assign(to: &$duration)
        
        audioRecorder.$audioLevel
            .assign(to: &$audioLevel)
        
        // Bind live transcriber state
        liveTranscriber.$currentTranscript
            .assign(to: &$liveTranscript)
        
        liveTranscriber.$finalizedText
            .assign(to: &$finalizedText)
        
        liveTranscriber.$tentativeText
            .assign(to: &$tentativeText)
    }
}

// MARK: - Errors

public enum VoiceSessionError: LocalizedError {
    case sessionInProgress
    case notRecording
    case permissionDenied
    case noAudioRecorded
    case transcriptionFailed
    
    public var errorDescription: String? {
        switch self {
        case .sessionInProgress:
            return "A voice session is already in progress"
        case .notRecording:
            return "No recording in progress"
        case .permissionDenied:
            return "Required permissions not granted"
        case .noAudioRecorded:
            return "No audio was recorded"
        case .transcriptionFailed:
            return "Transcription failed"
        }
    }
}
