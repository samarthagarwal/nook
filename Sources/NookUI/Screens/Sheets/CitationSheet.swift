import SwiftUI
import NookDesign
import NookCore

public struct CitationSheet: View {
    public let citation: Citation
    public let onClose: () -> Void
    
    public init(citation: Citation, onClose: @escaping () -> Void) {
        self.citation = citation
        self.onClose = onClose
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(citation.sourceDocument)
                        .font(NookTypography.fileNameLg)
                        .foregroundColor(NookColors.ink)
                    
                    Text(citation.pageOrSection)
                        .font(NookTypography.meta)
                        .foregroundColor(NookColors.ink45)
                }
                
                Spacer()
                
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(NookColors.ink70)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(NookColors.fill))
                }
                .buttonStyle(.plain)
            }
            
            // Document Page Stand-in
            DocumentPagePlaceholderView(
                highlightedText: citation.passage,
                contextText: citation.surroundingContext
            )
            .frame(maxHeight: 280)
            
            // Footnote
            HStack(spacing: 6) {
                PrivacyDot(accessibilityText: "Retrieved locally")
                Text("Retrieved on device. The whole file was never put into the model's context.")
                    .font(NookTypography.meta)
                    .foregroundColor(NookColors.ink45)
            }
        }
        .padding(20)
        .background(NookColors.surface)
        .cornerRadius(NookRadius.sheet)
        .nookSheetShadow()
        .padding(10)
    }
}
