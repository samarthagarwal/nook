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
    
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioFileURL: URL?
    private var startTime: Date?
    private var durationTimer: Timer?
    
    // Thread-safe wrapper for audio file writing (accessed from audio thread)
    private var audioFileWriter: AudioFileWriter?
    
    // Holder for callbacks that can be updated after recording starts
    private let callbackHolder = AudioCallbackHolder()
    
    /// The audio format of the current recording (available after startRecording)
    public private(set) var currentFormat: AVAudioFormat?
    
    /// Callback for audio buffers (used by LiveTranscriber) - called on audio thread!
    public var onAudioBuffer: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get { callbackHolder.bufferCallback }
        set { callbackHolder.bufferCallback = newValue }
    }
    
    /// Callback for audio level updates (used for waveform visualization)
    public var onAudioLevel: (@Sendable (AudioLevel) -> Void)? {
        get { callbackHolder.levelCallback }
        set { callbackHolder.levelCallback = newValue }
    }
    
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
        
        // Configure audio session for recording (iOS only)
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try audioSession.setActive(true)
        #endif
        
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        
        // Validate format
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioRecorderError.invalidAudioFormat
        }
        
        var fileURL: URL? = nil
        var writer: AudioFileWriter? = nil
        
        if saveToFile {
            // Create temporary file for recording
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "nook_recording_\(UUID().uuidString).m4a"
            fileURL = tempDir.appendingPathComponent(fileName)
            
            // Create audio file with AAC encoding for smaller size
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            
            let audioFile = try AVAudioFile(forWriting: fileURL!, settings: settings)
            writer = AudioFileWriter(file: audioFile)
            audioFileURL = fileURL
        }
        
        self.audioFileWriter = writer
        
        // Capture the callback holder (not the callbacks themselves) so updates are visible
        let holder = self.callbackHolder
        
        // Install tap on input node - this callback runs on the audio thread!
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, writer, holder] buffer, time in
            // Write to file directly on audio thread (thread-safe)
            writer?.write(buffer)
            
            // Call buffer callback directly on audio thread (SFSpeechAudioBufferRecognitionRequest.append is thread-safe)
            // Access through holder so callback updates after startRecording() are visible
            holder.bufferCallback?(buffer, time)
            
            // Calculate level and send to MainActor for UI
            let level = Self.calculateAudioLevel(buffer)
            holder.levelCallback?(level)
            
            // Update UI on MainActor
            Task { @MainActor [weak self] in
                self?.audioLevel = level
            }
        }
        
        engine.prepare()
        try engine.start()
        
        self.audioEngine = engine
        self.inputNode = input
        self.currentFormat = format
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
        
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        
        // Deactivate audio session (iOS only)
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        
        let url = audioFileURL
        
        // Reset state
        audioEngine = nil
        inputNode = nil
        audioFileWriter = nil
        audioFileURL = nil
        currentFormat = nil
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
        audioEngine?.pause()
        stopDurationTimer()
        state = .paused
    }
    
    /// Resumes recording after pause.
    public func resumeRecording() throws {
        guard state == .paused else { return }
        try audioEngine?.start()
        startDurationTimer()
        state = .recording
    }
    
    // MARK: - Private
    
    /// Calculate audio level from buffer - static so it can be called from audio thread
    private nonisolated static func calculateAudioLevel(_ buffer: AVAudioPCMBuffer) -> AudioLevel {
        guard let channelData = buffer.floatChannelData else {
            return AudioLevel(average: 0, peak: 0)
        }
        
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(
            from: 0,
            to: Int(buffer.frameLength),
            by: buffer.stride
        ).map { channelDataValue[$0] }
        
        let sum = channelDataValueArray.reduce(0) { $0 + abs($1) }
        let average = sum / Float(buffer.frameLength)
        let peak = channelDataValueArray.map { abs($0) }.max() ?? 0
        
        // Normalize to 0-1 range (assuming typical audio levels)
        let normalizedAverage = min(average * 2, 1.0)
        let normalizedPeak = min(peak, 1.0)
        
        return AudioLevel(average: normalizedAverage, peak: normalizedPeak)
    }
    
    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, let start = self.startTime else { return }
                self.duration = Date().timeIntervalSince(start)
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

// MARK: - AudioFileWriter

/// Thread-safe wrapper for AVAudioFile writing.
/// Can be safely called from the audio thread.
final class AudioFileWriter: @unchecked Sendable {
    private let file: AVAudioFile
    private let lock = NSLock()
    
    init(file: AVAudioFile) {
        self.file = file
    }
    
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? file.write(from: buffer)
    }
}

// MARK: - AudioCallbackHolder

/// Holds audio callbacks as a reference type so they can be updated after capture.
/// Thread-safe for access from audio thread.
final class AudioCallbackHolder: @unchecked Sendable {
    private let lock = NSLock()
    
    private var _bufferCallback: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var _levelCallback: (@Sendable (AudioRecorder.AudioLevel) -> Void)?
    
    var bufferCallback: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _bufferCallback
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _bufferCallback = newValue
        }
    }
    
    var levelCallback: (@Sendable (AudioRecorder.AudioLevel) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _levelCallback
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _levelCallback = newValue
        }
    }
}
