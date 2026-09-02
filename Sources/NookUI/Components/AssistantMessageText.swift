import SwiftUI
import NookDesign
import NookCore

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
        // `.full` parses lists/paragraphs but collapses single newlines between list
        // items. Inline + preserve whitespace keeps chat line breaks while still
        // applying **bold**, *italic*, `code`.
        try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
    }
}
