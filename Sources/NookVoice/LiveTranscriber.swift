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
    
    /// Accumulated finalized transcript segments (when user pauses, segments finalize)
    private var finalizedSegments: String = ""
    
    /// Flag to ignore late callbacks during shutdown
    private var isStopping: Bool = false
    
    // Audio level processing
    private var recentLevels: [Float] = []
    private let levelSmoothingCount = 5
    
    // Buffer for early audio before recognizer is ready
    private var earlyAudioBuffers: [AVAudioPCMBuffer] = []
    private var isRecognizerReady = false
    
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
    public func startTranscription() async throws {
        // Check state on main actor
        let currentState = await MainActor.run { state }
        guard currentState == .idle else {
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
        
        await MainActor.run {
            state = .preparing
            transcript = ""
            finalizedSegments = ""
            currentSegmentText = ""
            isPartial = false
            isStopping = false
            duration = 0
            startTime = Date()
        }
        
        // Reset early audio buffer
        earlyAudioBuffers = []
        isRecognizerReady = false
        
        // Configure audio session OFF main thread
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        
        // Get the audio input node and start capturing IMMEDIATELY
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        // Install tap FIRST to capture audio while recognizer initializes
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            if self.isRecognizerReady {
                // Recognizer ready - send directly
                self.recognitionRequest?.append(buffer)
            } else {
                // Buffer early audio (keep last ~2 seconds at 44.1kHz)
                self.earlyAudioBuffers.append(buffer)
                // Limit buffer size (~86 buffers = ~2 sec at 1024 samples/buffer, 44.1kHz)
                if self.earlyAudioBuffers.count > 100 {
                    self.earlyAudioBuffers.removeFirst()
                }
            }
            
            // Calculate audio level
            self.processAudioLevel(buffer: buffer)
        }
        
        // Start audio engine IMMEDIATELY to begin capturing
        audioEngine.prepare()
        try audioEngine.start()
        
        // Now create and start the recognition request (this may take time for on-device model)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true  // Privacy: on-device only
        
        // For iOS 16+, enable automatic punctuation
        if #available(iOS 16.0, macOS 13.0, *) {
            request.addsPunctuation = true
        }
        
        // Store request
        self.recognitionRequest = request
        
        // Feed buffered audio to recognizer
        for buffer in earlyAudioBuffers {
            request.append(buffer)
        }
        earlyAudioBuffers.removeAll()
        isRecognizerReady = true
        
        // Start recognition task
        let task = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            // Extract values before crossing actor boundary
            let transcriptText = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let errorDesc = error?.localizedDescription
            
            Task { @MainActor [weak self] in
                self?.handleRecognitionResultValues(
                    transcript: transcriptText,
                    isFinal: isFinal,
                    error: errorDesc
                )
            }
        }
        
        self.recognitionTask = task
        
        await MainActor.run {
            self.state = .transcribing
            self.startDurationTimer()
        }
    }
    
    /// Stops transcription and returns the final transcript.
    @discardableResult
    public func stopTranscription() -> String {
        // Mark stopping to ignore late callbacks
        isStopping = true
        
        // Stop the audio engine (can be called from any thread)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        // End the recognition request
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        // Build final transcript including any unfinalized current segment
        let finalTranscript: String
        if Thread.isMainThread {
            finalTranscript = MainActor.assumeIsolated {
                // Ensure we capture everything: finalized + current segment
                if self.finalizedSegments.isEmpty {
                    return self.currentSegmentText.isEmpty ? self.transcript : self.currentSegmentText
                } else if self.currentSegmentText.isEmpty {
                    return self.finalizedSegments
                } else {
                    return self.finalizedSegments + " " + self.currentSegmentText
                }
            }
        } else {
            // Off main thread - just use the transcript property
            finalTranscript = transcript
        }
        
        recognitionRequest = nil
        recognitionTask = nil
        
        // Deactivate audio session on background thread to avoid blocking UI
        #if os(iOS)
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        
        // Update state synchronously if on main thread, otherwise async
        // NOTE: Keep isStopping = true to block late callbacks - only reset in startTranscription
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.stopDurationTimer()
                self.state = .idle
                self.audioLevel = AudioLevel(average: 0, peak: 0)
                self.isPartial = false
            }
        } else {
            Task { @MainActor in
                self.stopDurationTimer()
                self.state = .idle
                self.audioLevel = AudioLevel(average: 0, peak: 0)
                self.isPartial = false
            }
        }
        
        return finalTranscript
    }
    
    /// Discards the current transcription. Must be called from MainActor.
    @MainActor
    public func cancel() {
        // Stop everything
        isStopping = true
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        
        // Deactivate audio session on background thread to avoid blocking UI
        #if os(iOS)
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
        
        // Reset all state synchronously (we're on MainActor)
        // Keep isStopping = true to ignore any late callbacks - only reset when starting new transcription
        stopDurationTimer()
        state = .idle
        transcript = ""
        finalizedSegments = ""
        currentSegmentText = ""
        audioLevel = AudioLevel(average: 0, peak: 0)
        isPartial = false
        duration = 0
        earlyAudioBuffers.removeAll()
        isRecognizerReady = false
        // NOTE: intentionally NOT resetting isStopping here - it will be reset in startTranscription
    }
    
    // MARK: - Private Methods
    
    /// Tracks the current segment's running text (before isFinal)
    private var currentSegmentText: String = ""
    
    @MainActor
    private func handleRecognitionResultValues(transcript: String?, isFinal: Bool, error: String?) {
        // Ignore callbacks during shutdown
        if isStopping { return }
        
        if let error = error {
            // Ignore cancellation errors (check by message content since we only have string)
            if error.contains("216") || error.contains("209") || error.contains("cancel") {
                return
            }
            state = .error(error)
            return
        }
        
        guard let newText = transcript, !newText.isEmpty else {
            return
        }
        
        // Detect new segment: text suddenly gets MUCH shorter (user paused, Apple started fresh)
        // Apple may revise text mid-stream (add punctuation), so don't use hasPrefix
        // A new segment is when we drop to <20% of current length AND current was substantial
        let isNewSegment = currentSegmentText.count > 20 && 
                           newText.count < currentSegmentText.count / 3
        
        if isNewSegment {
            // Apple started fresh - save what we had as finalized FIRST
            if finalizedSegments.isEmpty {
                finalizedSegments = currentSegmentText
            } else {
                finalizedSegments = finalizedSegments + " " + currentSegmentText
            }
            currentSegmentText = ""
        }
        
        // Update current segment (Apple may revise, so always take latest)
        currentSegmentText = newText
        
        // Build combined transcript
        let combined: String
        if finalizedSegments.isEmpty {
            combined = newText
        } else {
            combined = finalizedSegments + " " + newText
        }
        
        self.transcript = combined
        isPartial = !isFinal
        
        if isFinal {
            // This segment is done - but DON'T clear everything
            // Just update finalizedSegments to include this final result
            // The final text should be added to finalized if it's not already part of it
            if !finalizedSegments.contains(newText) {
                if finalizedSegments.isEmpty {
                    finalizedSegments = newText
                } else {
                    // Check if newText is already the end of our combined transcript
                    // (it might be a duplicate of currentSegmentText we just processed)
                    if !combined.hasSuffix(newText + " " + newText) {
                        // Not a duplicate, this is fine
                    }
                }
            }
            // DON'T clear currentSegmentText here - the next partial will handle it
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
