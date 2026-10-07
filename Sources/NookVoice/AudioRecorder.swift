import AVFoundation
import Foundation
#if os(macOS)
import AVFoundation
#endif

/// Captures audio from the microphone using AVAudioEngine.
/// Provides audio buffers for both live transcription and final processing.
@MainActor
public final class AudioRecorder: ObservableObject {
    
    public enum State: Equatable, Sendable {
        case idle
        case recording
        case paused
        case error(String)
    }
    
    public enum PermissionStatus: Sendable {
        case granted
        case denied
        case undetermined
    }
    
    public struct AudioLevel: Sendable {
        public let average: Float  // 0.0 to 1.0
        public let peak: Float     // 0.0 to 1.0
    }
    
    @Published public private(set) var state: State = .idle
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var audioLevel: AudioLevel = AudioLevel(average: 0, peak: 0)
    
    private var simpleRecorder: AVAudioRecorder?
    private var audioFileURL: URL?
    private var startTime: Date?
    private var durationTimer: Timer?
    
    public init() {}
    
    // MARK: - Public API
    
    /// Requests microphone permission.
    /// Returns true if granted, false otherwise.
    public func requestPermission() async -> Bool {
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
    
    /// Checks current microphone permission status.
    public var permissionStatus: PermissionStatus {
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
    
    /// Starts recording audio.
    /// - Parameter saveToFile: If true, audio is saved to a temporary file for WhisperKit processing.
    /// - Returns: URL of the audio file if saveToFile is true.
    public func startRecording(saveToFile: Bool = true) throws -> URL? {
        guard state == .idle || state == .paused else {
            throw AudioRecorderError.alreadyRecording
        }
        
        // Configure audio session for recording on iOS
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .default, options: [])
        try audioSession.setActive(true)
        #endif
        
        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "nook_recording_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        // Recording settings - AAC for smaller file size, good quality for speech
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        // Use AVAudioRecorder - simpler API, handles threading internally
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = true
        
        guard recorder.record() else {
            throw AudioRecorderError.permissionDenied
        }
        
        self.simpleRecorder = recorder
        self.audioFileURL = fileURL
        self.startTime = Date()
        self.state = .recording
        
        // Start duration timer
        startDurationTimer()
        
        return fileURL
    }
    
    /// Stops recording and returns the audio file URL if recording to file.
    @discardableResult
    public func stopRecording() -> URL? {
        guard state == .recording || state == .paused else { return nil }
        
        stopDurationTimer()
        
        simpleRecorder?.stop()
        
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
        
        let url = audioFileURL
        
        // Reset state
        simpleRecorder = nil
        audioFileURL = nil
        startTime = nil
        duration = 0
        state = .idle
        
        return url
    }
    
    /// Discards the current recording without saving.
    public func discardRecording() {
        let url = stopRecording()
        
        // Delete the temporary file
        if let url = url {
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    /// Pauses recording (if supported).
    public func pauseRecording() {
        guard state == .recording else { return }
        simpleRecorder?.pause()
        stopDurationTimer()
        state = .paused
    }
    
    /// Resumes recording after pause.
    public func resumeRecording() throws {
        guard state == .paused else { return }
        simpleRecorder?.record()
        startDurationTimer()
        state = .recording
    }
    
    // MARK: - Private
    
    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.startTime else { return }
                self.duration = Date().timeIntervalSince(start)
                
                // Update audio level from AVAudioRecorder metering
                if let recorder = self.simpleRecorder {
                    recorder.updateMeters()
                    let avgPower = recorder.averagePower(forChannel: 0)
                    let peakPower = recorder.peakPower(forChannel: 0)
                    // Convert dB to 0-1 range (dB is typically -160 to 0)
                    let normalizedAvg = max(0, (avgPower + 50) / 50)
                    let normalizedPeak = max(0, (peakPower + 50) / 50)
                    self.audioLevel = AudioLevel(average: normalizedAvg, peak: normalizedPeak)
                }
            }
        }
    }
    
    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}

// MARK: - Errors

public enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case invalidAudioFormat
    case permissionDenied
    
    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress"
        case .notRecording:
            return "No recording in progress"
        case .invalidAudioFormat:
            return "Invalid audio format from microphone"
        case .permissionDenied:
            return "Microphone permission denied"
        }
    }
}
