import SwiftUI
import NookDesign
import NookVoice

/// Voice input composer for chat - replaces the text field during recording.
/// Shows live transcript, waveform, timer, and cancel/confirm controls.
public struct VoiceComposer: View {
    @ObservedObject var session: VoiceSession
    @ObservedObject var levelMeter: AudioLevelMeter
    
    let onCancel: () -> Void
    let onConfirm: () -> Void
    
    @State private var isAnimating = false
    
    public init(
        session: VoiceSession,
        levelMeter: AudioLevelMeter,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.session = session
        self.levelMeter = levelMeter
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            // Status bar
            HStack {
                HStack(spacing: 6) {
                    // Pulsing recording indicator
                    Circle()
                        .fill(NookColors.local)
                        .frame(width: 8, height: 8)
                        .opacity(isAnimating ? 0.5 : 1.0)
                        .animation(
                            .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                            value: isAnimating
                        )
                    
                    Text("Listening")
                        .font(.system(size: 11, weight: .medium, design: .default))
                        .foregroundColor(NookColors.local)
                    
                    Text("·")
                        .foregroundColor(NookColors.ink40)
                    
                    Text("on device")
                        .font(.system(size: 11, weight: .regular, design: .default))
                        .foregroundColor(NookColors.ink45)
                }
                
                Spacer()
                
                // Timer
                Text(formattedDuration)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(NookColors.ink45)
            }
            .padding(.horizontal, 12)
            
            // Transcript field with blue border
            VStack(alignment: .leading, spacing: 4) {
                if session.liveTranscript.isEmpty {
                    Text("Listening...")
                        .font(NookTypography.userBubble)
                        .foregroundColor(NookColors.ink40)
                } else {
                    TentativeText(
                        finalizedText: session.finalizedText,
                        tentativeText: session.tentativeText,
                        font: NookTypography.userBubble
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.pill)
                    .fill(NookColors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookRadius.pill)
                    .strokeBorder(NookColors.local, lineWidth: 2)
            )
            
            // Controls: Cancel, Waveform, Confirm
            HStack(spacing: 12) {
                // Cancel button
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(NookColors.ink70)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(NookColors.fill))
                }
                .buttonStyle(.plain)
                
                // Waveform
                CompactVoiceWaveform(levelMeter: levelMeter)
                    .frame(maxWidth: .infinity)
                
                // Confirm button
                Button(action: onConfirm) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(NookColors.inkOnDark)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(NookColors.local))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(NookColors.paper)
        .onAppear {
            isAnimating = true
        }
    }
    
    private var formattedDuration: String {
        let minutes = Int(session.duration) / 60
        let seconds = Int(session.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// The "Ready to send" state after voice recording stops.
/// Shows the finalized transcript as editable text.
public struct VoiceComposerResult: View {
    @Binding var text: String
    let onSend: () -> Void
    let onDiscard: () -> Void
    
    public init(
        text: Binding<String>,
        onSend: @escaping () -> Void,
        onDiscard: @escaping () -> Void
    ) {
        self._text = text
        self.onSend = onSend
        self.onDiscard = onDiscard
    }
    
    public var body: some View {
        HStack(spacing: 8) {
            // Discard button (only show if text is not empty)
            Button(action: onDiscard) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(NookColors.ink70)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(NookColors.fill))
            }
            .buttonStyle(.plain)
            
            // Editable text field
            HStack {
                TextField(
                    "",
                    text: $text,
                    prompt: Text("Ask anything")
                        .font(NookTypography.userBubble)
                        .foregroundColor(NookColors.ink40),
                    axis: .vertical
                )
                .font(NookTypography.userBubble)
                .foregroundColor(NookColors.ink)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.pill)
                    .fill(NookColors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookRadius.pill)
                    .strokeBorder(NookColors.hairlineStrong, lineWidth: 1)
            )
            
            // Send button
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(NookColors.inkOnDark)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle()
                            .fill(text.isEmpty ? NookColors.ink40 : NookColors.ink)
                    )
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// Badge shown on sent messages that were dictated.
public struct DictatedBadge: View {
    public init() {}
    
    public var body: some View {
        HStack(spacing: 4) {
            PrivacyDot(accessibilityText: "Dictated on device")
            Text("Dictated · on device")
                .font(NookTypography.badge)
                .foregroundColor(NookColors.ink45)
        }
    }
}

#Preview("Voice Composer - Recording") {
    VStack {
        Spacer()
        
        // Simulated recording state
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(NookColors.local)
                        .frame(width: 8, height: 8)
                    
                    Text("Listening")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(NookColors.local)
                    
                    Text("·")
                        .foregroundColor(NookColors.ink40)
                    
                    Text("on device")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(NookColors.ink45)
                }
                
                Spacer()
                
                Text("0:04")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(NookColors.ink45)
            }
            .padding(.horizontal, 12)
            
            VStack(alignment: .leading) {
                TentativeText(
                    finalizedText: "Which of those has the least owner on it ",
                    tentativeText: "right now,"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.pill)
                    .fill(NookColors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: NookRadius.pill)
                    .strokeBorder(NookColors.local, lineWidth: 2)
            )
            
            HStack(spacing: 12) {
                Button(action: {}) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(NookColors.ink70)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(NookColors.fill))
                }
                .buttonStyle(.plain)
                
                // Static waveform preview
                VoiceWaveform(
                    bars: (0..<20).map { i in
                        AudioLevelMeter.WaveformBar(
                            id: i,
                            level: Float.random(in: 0.2...0.7)
                        )
                    },
                    style: .chatCompact
                )
                .frame(maxWidth: .infinity)
                
                Button(action: {}) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(NookColors.inkOnDark)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(NookColors.local))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(NookColors.paper)
    }
    .background(NookColors.paper)
}

#Preview("Dictated Badge") {
    VStack(alignment: .trailing, spacing: 8) {
        Text("Which of those has the least owner on it right now, and who should I chase first?")
            .font(NookTypography.userBubble)
            .foregroundColor(NookColors.inkOnDark)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(NookColors.ink)
            )
        
        DictatedBadge()
    }
    .padding()
    .background(NookColors.paper)
}
