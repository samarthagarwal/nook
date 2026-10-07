import Foundation
import Combine

/// Processes audio levels into waveform visualization data.
/// Maintains a rolling buffer of audio levels for smooth waveform display.
@MainActor
public final class AudioLevelMeter: ObservableObject {
    
    /// A single bar in the waveform visualization.
    public struct WaveformBar: Identifiable, Equatable, Sendable {
        public let id: Int
        public let level: Float  // 0.0 to 1.0
        
        public init(id: Int, level: Float) {
            self.id = id
            self.level = level
        }
    }
    
    /// Current waveform bars for visualization.
    @Published public private(set) var bars: [WaveformBar] = []
    
    /// Current instantaneous level.
    @Published public private(set) var currentLevel: Float = 0
    
    /// Peak level (with decay).
    @Published public private(set) var peakLevel: Float = 0
    
    private let barCount: Int
    private let smoothingFactor: Float
    private let peakDecayRate: Float
    private var levelHistory: [Float] = []
    private var peakHoldTime: TimeInterval = 0
    private var lastUpdateTime: Date = Date()
    
    /// Creates an audio level meter.
    /// - Parameters:
    ///   - barCount: Number of bars in the waveform visualization.
    ///   - smoothingFactor: Smoothing applied to level changes (0-1, higher = smoother).
    ///   - peakDecayRate: How quickly the peak indicator decays (per second).
    public init(barCount: Int = 12, smoothingFactor: Float = 0.7, peakDecayRate: Float = 2.0) {
        self.barCount = barCount
        self.smoothingFactor = smoothingFactor
        self.peakDecayRate = peakDecayRate
        self.bars = (0..<barCount).map { WaveformBar(id: $0, level: 0) }
        self.levelHistory = Array(repeating: 0, count: barCount)
    }
    
    /// Updates the meter with a new audio level.
    /// - Parameter level: The audio level from AudioRecorder (0-1).
    public func update(with level: AudioRecorder.AudioLevel) {
        let now = Date()
        let deltaTime = now.timeIntervalSince(lastUpdateTime)
        lastUpdateTime = now
        
        // Smooth the current level
        let targetLevel = level.average
        currentLevel = currentLevel + (targetLevel - currentLevel) * smoothingFactor
        
        // Update peak with decay
        if level.peak > peakLevel {
            peakLevel = level.peak
            peakHoldTime = 0.5  // Hold peak for 0.5 seconds
        } else if peakHoldTime > 0 {
            peakHoldTime -= deltaTime
        } else {
            peakLevel = max(0, peakLevel - Float(deltaTime) * peakDecayRate)
        }
        
        // Shift history and add new level
        levelHistory.removeFirst()
        levelHistory.append(currentLevel)
        
        // Update bars
        bars = levelHistory.enumerated().map { index, historyLevel in
            WaveformBar(id: index, level: historyLevel)
        }
    }
    
    /// Resets the meter to zero.
    public func reset() {
        currentLevel = 0
        peakLevel = 0
        levelHistory = Array(repeating: 0, count: barCount)
        bars = (0..<barCount).map { WaveformBar(id: $0, level: 0) }
    }
    
    /// Generates animated idle bars (subtle movement when not recording).
    public func setIdleAnimation() {
        let idleBars = (0..<barCount).map { index in
            // Create subtle wave pattern
            let phase = Float(index) / Float(barCount) * .pi * 2
            let level = (sin(phase + Float(Date().timeIntervalSince1970) * 2) + 1) * 0.05
            return WaveformBar(id: index, level: level)
        }
        bars = idleBars
    }
}

// MARK: - Waveform Style Configuration

public extension AudioLevelMeter {
    
    /// Configuration for waveform visualization appearance.
    struct WaveformStyle: Sendable {
        public let barWidth: CGFloat
        public let barSpacing: CGFloat
        public let minBarHeight: CGFloat
        public let maxBarHeight: CGFloat
        public let cornerRadius: CGFloat
        
        public init(
            barWidth: CGFloat = 3,
            barSpacing: CGFloat = 2,
            minBarHeight: CGFloat = 4,
            maxBarHeight: CGFloat = 32,
            cornerRadius: CGFloat = 1.5
        ) {
            self.barWidth = barWidth
            self.barSpacing = barSpacing
            self.minBarHeight = minBarHeight
            self.maxBarHeight = maxBarHeight
            self.cornerRadius = cornerRadius
        }
        
        /// Default style for chat composer (compact).
        public static let chatCompact = WaveformStyle(
            barWidth: 2,
            barSpacing: 1.5,
            minBarHeight: 3,
            maxBarHeight: 20,
            cornerRadius: 1
        )
        
        /// Default style for knowledge recording sheet (full).
        public static let knowledgeFull = WaveformStyle(
            barWidth: 4,
            barSpacing: 3,
            minBarHeight: 4,
            maxBarHeight: 40,
            cornerRadius: 2
        )
    }
}
