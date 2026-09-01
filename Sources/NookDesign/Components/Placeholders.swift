import SwiftUI

public struct ImagePlaceholderView: View {
    private let fileName: String?
    
    public init(fileName: String? = nil) {
        self.fileName = fileName
    }
    
    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(hex: "#E6E1D8"),
                            Color(hex: "#DCD6CB"),
                            Color(hex: "#E6E1D8")
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            
            if let fileName = fileName {
                Text(fileName)
                    .font(.system(size: 9.5, weight: .regular, design: .monospaced))
                    .foregroundColor(NookColors.ink62)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(NookColors.surface.opacity(0.85))
                    .cornerRadius(4)
                    .padding(6)
            }
        }
        .cornerRadius(NookRadius.card)
    }
}

public struct DocumentPagePlaceholderView: View {
    private let highlightedText: String
    private let contextText: String
    
    public init(highlightedText: String, contextText: String) {
        self.highlightedText = highlightedText
        self.contextText = contextText
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Highlighted passage
            Text(highlightedText)
                .font(.system(size: 13, weight: .regular, design: .default))
                .lineSpacing(6)
                .foregroundColor(NookColors.ink)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(NookColors.citationHighlight)
                )
            
            // Surrounding context
            Text(contextText)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundColor(NookColors.ink30)
                .lineSpacing(4)
            
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(hex: "#F1EEE6"),
                    Color(hex: "#EDE9E0")
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .cornerRadius(NookRadius.card)
        .overlay(
            RoundedRectangle(cornerRadius: NookRadius.card)
                .strokeBorder(NookColors.hairlineStrong, lineWidth: 1)
        )
    }
}
