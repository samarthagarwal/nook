import SwiftUI
import NookDesign

/// Displays text with the last portion rendered as "tentative" (pale/faded).
/// Used during live transcription to show unconfirmed words.
public struct TentativeText: View {
    let finalizedText: String
    let tentativeText: String
    let font: Font
    let finalizedColor: Color
    let tentativeColor: Color
    
    public init(
        finalizedText: String,
        tentativeText: String,
        font: Font = NookTypography.userBubble,
        finalizedColor: Color = NookColors.ink,
        tentativeColor: Color = NookColors.ink40
    ) {
        self.finalizedText = finalizedText
        self.tentativeText = tentativeText
        self.font = font
        self.finalizedColor = finalizedColor
        self.tentativeColor = tentativeColor
    }
    
    public var body: some View {
        // Use Text concatenation for inline styling
        (
            Text(finalizedText)
                .foregroundColor(finalizedColor) +
            Text(tentativeText)
                .foregroundColor(tentativeColor)
        )
        .font(font)
    }
}

/// Displays the full transcript with automatic tentative word detection.
public struct LiveTranscriptText: View {
    let transcript: String
    let tentativeWordCount: Int
    let font: Font
    
    public init(
        transcript: String,
        tentativeWordCount: Int = 2,
        font: Font = NookTypography.userBubble
    ) {
        self.transcript = transcript
        self.tentativeWordCount = tentativeWordCount
        self.font = font
    }
    
    public var body: some View {
        let (finalized, tentative) = splitTranscript()
        TentativeText(
            finalizedText: finalized,
            tentativeText: tentative,
            font: font
        )
    }
    
    private func splitTranscript() -> (String, String) {
        let words = transcript.split(separator: " ", omittingEmptySubsequences: true)
        guard words.count > tentativeWordCount else {
            // All words are tentative
            return ("", transcript)
        }
        
        let splitIndex = words.count - tentativeWordCount
        let finalizedWords = words.prefix(splitIndex)
        let tentativeWords = words.suffix(tentativeWordCount)
        
        let finalized = finalizedWords.joined(separator: " ")
        let tentative = (finalized.isEmpty ? "" : " ") + tentativeWords.joined(separator: " ")
        
        return (finalized, tentative)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 20) {
        TentativeText(
            finalizedText: "Which of those has the least owner on it ",
            tentativeText: "right now,"
        )
        
        LiveTranscriptText(
            transcript: "Which of those has the least owner on it right now, and who should I",
            tentativeWordCount: 2
        )
        
        LiveTranscriptText(
            transcript: "Hello world",
            tentativeWordCount: 2
        )
    }
    .padding()
    .background(NookColors.paper)
}
