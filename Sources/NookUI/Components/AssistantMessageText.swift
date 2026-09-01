import SwiftUI
import NookDesign

/// Renders assistant chat text with lightweight Markdown formatting.
public struct AssistantMessageText: View {
    private let content: String

    public init(_ content: String) {
        self.content = content
    }

    public var body: some View {
        Group {
            if let attributed = parsedMarkdown {
                Text(attributed)
            } else {
                Text(content)
            }
        }
        .font(NookTypography.assistantBody)
        .foregroundColor(NookColors.ink)
        .lineSpacing(5)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
    }

    private var parsedMarkdown: AttributedString? {
        try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full
            )
        )
    }
}
