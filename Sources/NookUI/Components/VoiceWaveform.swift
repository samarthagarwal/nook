import SwiftUI
import NookDesign
import NookVoice

/// Animated waveform visualization for voice recording.
public struct VoiceWaveform: View {
    let bars: [AudioLevelMeter.WaveformBar]
    let style: AudioLevelMeter.WaveformStyle
    let accentColor: Color
    
    public init(
        bars: [AudioLevelMeter.WaveformBar],
        style: AudioLevelMeter.WaveformStyle = .chatCompact,
        accentColor: Color = NookColors.local
    ) {
        self.bars = bars
        self.style = style
        self.accentColor = accentColor
    }
    
    public var body: some View {
        HStack(alignment: .center, spacing: style.barSpacing) {
            ForEach(bars) { bar in
                RoundedRectangle(cornerRadius: style.cornerRadius)
                    .fill(accentColor)
                    .frame(
                        width: style.barWidth,
                        height: barHeight(for: bar.level)
                    )
                    .animation(.easeOut(duration: 0.1), value: bar.level)
            }
        }
    }
    
    private func barHeight(for level: Float) -> CGFloat {
        let normalizedLevel = CGFloat(max(0, min(1, level)))
        return style.minBarHeight + (style.maxBarHeight - style.minBarHeight) * normalizedLevel
    }
}

/// Compact waveform for the chat composer (fewer bars, smaller).
public struct CompactVoiceWaveform: View {
    @ObservedObject var levelMeter: AudioLevelMeter
    
    public init(levelMeter: AudioLevelMeter) {
        self.levelMeter = levelMeter
    }
    
    public var body: some View {
        VoiceWaveform(
            bars: levelMeter.bars,
            style: .chatCompact,
            accentColor: NookColors.local
        )
        .frame(height: 24)
    }
}

#Preview {
    VStack(spacing: 20) {
        // Static preview with sample bars
        VoiceWaveform(
            bars: (0..<20).map { i in
                AudioLevelMeter.WaveformBar(
                    id: i,
                    level: Float.random(in: 0.1...0.8)
                )
            },
            style: .chatCompact
        )
        .padding()
        .background(NookColors.surface)
        .cornerRadius(12)
        
        VoiceWaveform(
            bars: (0..<15).map { i in
                AudioLevelMeter.WaveformBar(
                    id: i,
                    level: Float.random(in: 0.2...0.9)
                )
            },
            style: .knowledgeFull
        )
        .padding()
        .background(NookColors.surface)
        .cornerRadius(12)
    }
    .padding()
    .background(NookColors.paper)
}
