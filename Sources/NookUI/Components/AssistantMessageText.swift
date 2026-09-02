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
        .onChange(of: content) { _, newValue in
            Self.logRenderPipeline(newValue)
        }
        .onAppear {
            Self.logRenderPipeline(content)
        }
    }

    private var parsedMarkdown: AttributedString? {
        // `.full` parses lists/paragraphs but collapses single newlines between list
        // items (see NookTextDebug: "scopeSingle-vendor"). Inline + preserve whitespace
        // keeps chat line breaks while still applying **bold**, *italic*, `code`.
        try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )
    }

    private static func logRenderPipeline(_ text: String) {
        guard !text.isEmpty else { return }
        NookTextDebug.log("UI raw content", text: text)
        do {
            let attributed = try AttributedString(
                markdown: text,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )
            let plain = String(attributed.characters)
            NookTextDebug.log("UI after Markdown→plain", text: plain)
            print("[NookTextDebug] UI markdown parse: ok runs=\(attributed.runs.count) syntax=inlineOnlyPreservingWhitespace")
        } catch {
            print("[NookTextDebug] UI markdown parse FAILED: \(error)")
        }
    }
}
