import Foundation

/// Coordinates a complete voice input session with live transcription.
/// Uses Apple's Speech framework for real-time on-device transcription.
@MainActor
public final class VoiceSession: ObservableObject {
    
    public enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case recording          // Live transcription in progress
        case reviewing(String)  // User reviewing final transcript
        case error(String)
        
        public var isActive: Bool {
            switch self {
            case .recording: return true
            default: return false
            }
        }
    }
    
    // MARK: - Published State
    
    @Published public private(set) var state: State = .idle
    
    /// Guard flag to prevent concurrent start attempts
    private var isStartingRecording: Bool = false
    
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var audioLevel: LiveTranscriber.AudioLevel = .init(average: 0, peak: 0)
    
    /// Live transcript that updates as user speaks
    @Published public private(set) var liveTranscript: String = ""
    
    /// True while receiving partial (non-final) results
    @Published public private(set) var isPartialResult: Bool = false
    
    // MARK: - Private
    
    private let transcriber: LiveTranscriber
    
    public init(transcriber: LiveTranscriber = LiveTranscriber()) {
        self.transcriber = transcriber
        setupBindings()
    }
    
    // MARK: - Permissions
    
    /// Checks and requests permissions (microphone + speech recognition).
    public func requestPermissions() async -> Bool {
        state = .requestingPermission
        
        let granted = await transcriber.requestPermissions()
        if !granted {
            state = .error("Permissions denied")
            return false
        }
        
        state = .idle
        return true
    }
    
    public var hasPermissions: Bool {
        transcriber.hasPermissions
    }
    
    // MARK: - Recording Control
    
    /// Starts live voice recording with real-time transcription.
    public func startRecording() async throws {
        // If already recording or starting, silently succeed (idempotent)
        if state == .recording || isStartingRecording {
            return
        }
        
        guard state == .idle else {
            throw VoiceSessionError.sessionInProgress
        }
        
        // Set flags IMMEDIATELY to prevent multiple calls
        isStartingRecording = true
        state = .recording
        
        if !hasPermissions {
            let granted = await requestPermissions()
            if !granted {
                state = .idle
                isStartingRecording = false
                throw VoiceSessionError.permissionDenied
            }
        }
        
        // Reset state
        liveTranscript = ""
        duration = 0
        
        // Start transcription off main thread to avoid audio session blocking
        do {
            try await Task.detached { [transcriber] in
                try await transcriber.startTranscription()
            }.value
            isStartingRecording = false
        } catch {
            state = .idle
            isStartingRecording = false
            throw error
        }
    }
    
    /// Stops recording and returns the final transcript.
    /// After calling this, the session is in `.reviewing` state.
    @discardableResult
    public func stopRecording() -> String {
        guard state == .recording else { return "" }
        
        // Get transcript synchronously (stopTranscription handles threading internally)
        let finalTranscript = transcriber.stopTranscription()
        
        // Update state synchronously (we're on MainActor)
        liveTranscript = finalTranscript
        state = .reviewing(finalTranscript)
        
        return finalTranscript
    }
    
    /// Confirms the transcript and returns to idle.
    /// - Returns: The final transcript text.
    public func confirmTranscript() -> String? {
        guard case .reviewing(let text) = state else { return nil }
        state = .idle
        liveTranscript = ""
        return text
    }
    
    /// Discards the current recording/transcript.
    public func discardRecording() {
        transcriber.cancel()
        liveTranscript = ""
        duration = 0
        state = .idle
        isStartingRecording = false
    }
    
    /// Resets the session to idle state.
    public func reset() {
        discardRecording()
    }
    
    // MARK: - Private
    
    private func setupBindings() {
        // Bind transcriber state
        transcriber.$transcript
            .assign(to: &$liveTranscript)
        
        transcriber.$audioLevel
            .assign(to: &$audioLevel)
        
        transcriber.$duration
            .assign(to: &$duration)
        
        transcriber.$isPartial
            .assign(to: &$isPartialResult)
    }
}

// MARK: - Errors

public enum VoiceSessionError: LocalizedError {
    case sessionInProgress
    case notRecording
    case permissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .sessionInProgress:
            return "A voice session is already in progress"
        case .notRecording:
            return "No recording in progress"
        case .permissionDenied:
            return "Required permissions not granted"
        }
    }
}
