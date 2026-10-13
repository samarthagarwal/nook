import AVFoundation
import Foundation
import Speech

/// Live speech-to-text transcription using Apple's Speech framework.
/// Provides real-time transcription with audio level metering.
public final class LiveTranscriber: ObservableObject, @unchecked Sendable {
    
    public enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case preparing
        case transcribing
        case finishing
        case error(String)
    }
    
    public enum PermissionStatus: Sendable {
        case granted
        case denied
        case undetermined
    }
    
    public struct AudioLevel: Sendable, Equatable {
        public let average: Float  // 0.0 to 1.0
        public let peak: Float     // 0.0 to 1.0
        
        public init(average: Float, peak: Float) {
            self.average = average
            self.peak = peak
        }
    }
    
    // MARK: - Published State
    
    @Published public private(set) var state: State = .idle
    @Published public private(set) var transcript: String = ""
    @Published public private(set) var audioLevel: AudioLevel = AudioLevel(average: 0, peak: 0)
    @Published public private(set) var duration: TimeInterval = 0
    
    /// True while partial results are being updated
    @Published public private(set) var isPartial: Bool = false
    
    // MARK: - Private Properties
    
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var startTime: Date?
    private var durationTimer: Timer?
    
    // Audio level processing
    private var recentLevels: [Float] = []
    private let levelSmoothingCount = 5
    
    public init(locale: Locale = .current) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }
    
    // MARK: - Permissions
    
    /// Requests both microphone and speech recognition permissions.
    @MainActor
    public func requestPermissions() async -> Bool {
        state = .requestingPermission
        
        // Request microphone permission
        let micGranted = await requestMicrophonePermission()
        guard micGranted else {
            state = .error("Microphone permission denied")
            return false
        }
        
        // Request speech recognition permission
        let speechGranted = await requestSpeechPermission()
        guard speechGranted else {
            state = .error("Speech recognition permission denied")
            return false
        }
        
        state = .idle
        return true
    }
    
    private func requestMicrophonePermission() async -> Bool {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
        #else
        return await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        #endif
    }
    
    private func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    public var microphonePermissionStatus: PermissionStatus {
        #if os(macOS)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
        #else
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
        #endif
    }
    
    public var speechPermissionStatus: PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
    
    public var hasPermissions: Bool {
        microphonePermissionStatus == .granted && speechPermissionStatus == .granted
    }
    
    // MARK: - Transcription Control
    
    /// Starts live transcription. Returns immediately, updates `transcript` as speech is recognized.
    @MainActor
    public func startTranscription() async throws {
        guard state == .idle else {
            throw LiveTranscriberError.alreadyTranscribing
        }
        
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw LiveTranscriberError.speechRecognizerUnavailable
        }
        
        if !hasPermissions {
            let granted = await requestPermissions()
            if !granted {
                throw LiveTranscriberError.permissionDenied
            }
        }
        
        state = .preparing
        transcript = ""
        isPartial = false
        duration = 0
        startTime = Date()
        
        // Configure audio session and start engine on background
        try await Task.detached { [self] in
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            
            // Create recognition request
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = true  // Privacy: on-device only
            
            // For iOS 16+, enable automatic punctuation
            if #available(iOS 16.0, macOS 13.0, *) {
                request.addsPunctuation = true
            }
            
            await MainActor.run {
                self.recognitionRequest = request
            }
            
            // Get the audio input node
            let inputNode = self.audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            // Install tap for audio data
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                // Send audio to speech recognizer
                request.append(buffer)
                
                // Calculate audio level
                self?.processAudioLevel(buffer: buffer)
            }
            
            // Start the audio engine
            self.audioEngine.prepare()
            try self.audioEngine.start()
            
            // Start recognition task
            let task = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    self?.handleRecognitionResult(result: result, error: error)
                }
            }
            
            await MainActor.run {
                self.recognitionTask = task
            }
        }.value
        
        state = .transcribing
        startDurationTimer()
    }
    
    /// Stops transcription and returns the final transcript.
    @MainActor
    @discardableResult
    public func stopTranscription() -> String {
        stopDurationTimer()
        
        // Stop the audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // End the recognition request
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        // Clean up
        recognitionRequest = nil
        recognitionTask = nil
        
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        
        let finalTranscript = transcript
        state = .idle
        audioLevel = AudioLevel(average: 0, peak: 0)
        isPartial = false
        
        return finalTranscript
    }
    
    /// Discards the current transcription.
    @MainActor
    public func cancel() {
        _ = stopTranscription()
        transcript = ""
        duration = 0
    }
    
    // MARK: - Private Methods
    
    @MainActor
    private func handleRecognitionResult(result: SFSpeechRecognitionResult?, error: Error?) {
        if let error = error {
            // Ignore cancellation errors
            let nsError = error as NSError
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                // "Retry" error - user stopped too quickly, ignore
                return
            }
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 209 {
                // Recognition was cancelled, ignore
                return
            }
            
            print("[LiveTranscriber] Recognition error: \(error)")
            state = .error(error.localizedDescription)
            return
        }
        
        guard let result = result else { return }
        
        // Update transcript with best transcription
        transcript = result.bestTranscription.formattedString
        isPartial = !result.isFinal
        
        if result.isFinal {
            state = .finishing
        }
    }
    
    private func processAudioLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        
        var sum: Float = 0
        var peak: Float = 0
        
        for i in 0..<frameCount {
            let sample = abs(channelData[i])
            sum += sample
            if sample > peak {
                peak = sample
            }
        }
        
        let average = sum / Float(frameCount)
        
        // Smooth the levels
        recentLevels.append(average)
        if recentLevels.count > levelSmoothingCount {
            recentLevels.removeFirst()
        }
        let smoothedAverage = recentLevels.reduce(0, +) / Float(recentLevels.count)
        
        // Normalize to 0-1 range (speech typically peaks around 0.1-0.3)
        let normalizedAverage = min(1.0, smoothedAverage * 5)
        let normalizedPeak = min(1.0, peak * 3)
        
        Task { @MainActor [weak self] in
            self?.audioLevel = AudioLevel(average: normalizedAverage, peak: normalizedPeak)
        }
    }
    
    @MainActor
    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.startTime else { return }
                self.duration = Date().timeIntervalSince(start)
            }
        }
    }
    
    @MainActor
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}

// MARK: - Errors

public enum LiveTranscriberError: LocalizedError {
    case alreadyTranscribing
    case notTranscribing
    case permissionDenied
    case speechRecognizerUnavailable
    
    public var errorDescription: String? {
        switch self {
        case .alreadyTranscribing:
            return "Transcription is already in progress"
        case .notTranscribing:
            return "No transcription in progress"
        case .permissionDenied:
            return "Microphone or speech recognition permission denied"
        case .speechRecognizerUnavailable:
            return "Speech recognizer is not available"
        }
    }
}
