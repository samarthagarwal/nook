import SwiftUI
import NookDesign
import NookCore

/// Renders assistant chat text with Markdown while preserving block structure
/// (headings / lists / paragraphs stay on separate lines).
public struct AssistantMessageText: View {
    private let content: String

    public init(_ content: String) {
        self.content = content
    }

    public var body: some View {
        let blocks = Self.parseBlocks(content)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .foregroundColor(NookColors.ink)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .lineSpacing(3)
        case .paragraph(let text):
            inlineText(text)
                .font(NookTypography.assistantBody)
                .lineSpacing(5)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(NookTypography.assistantBody)
                            .foregroundColor(NookColors.ink55)
                        inlineText(item)
                            .font(NookTypography.assistantBody)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(NookTypography.assistantBody)
                            .foregroundColor(NookColors.ink55)
                            .frame(minWidth: 18, alignment: .trailing)
                        inlineText(item)
                            .font(NookTypography.assistantBody)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func inlineText(_ text: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 20, weight: .semibold)
        case 2: return .system(size: 18, weight: .semibold)
        default: return .system(size: 16, weight: .semibold)
        }
    }

    // MARK: - Block parsing

    private enum MarkdownBlock {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bulletList([String])
        case numberedList([String])
    }

    private static func parseBlocks(_ raw: String) -> [MarkdownBlock] {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var bulletItems: [String] = []
        var numberedItems: [String] = []

        func flushParagraph() {
            let text = paragraphLines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            paragraphLines.removeAll(keepingCapacity: true)
            guard !text.isEmpty else { return }
            blocks.append(.paragraph(text))
        }

        func flushBullets() {
            guard !bulletItems.isEmpty else { return }
            blocks.append(.bulletList(bulletItems))
            bulletItems.removeAll(keepingCapacity: true)
        }

        func flushNumbers() {
            guard !numberedItems.isEmpty else { return }
            blocks.append(.numberedList(numberedItems))
            numberedItems.removeAll(keepingCapacity: true)
        }

        func flushLists() {
            flushBullets()
            flushNumbers()
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                flushLists()
                continue
            }

            if let heading = matchHeading(trimmed) {
                flushParagraph()
                flushLists()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if let item = matchBullet(trimmed) {
                flushParagraph()
                flushNumbers()
                bulletItems.append(item)
                continue
            }

            if let item = matchNumbered(trimmed) {
                flushParagraph()
                flushBullets()
                numberedItems.append(item)
                continue
            }

            // Continuation of a list item (indented wrap).
            if !bulletItems.isEmpty, line.hasPrefix("  ") || line.hasPrefix("\t") {
                let last = bulletItems.removeLast()
                bulletItems.append(last + " " + trimmed)
                continue
            }
            if !numberedItems.isEmpty, line.hasPrefix("  ") || line.hasPrefix("\t") {
                let last = numberedItems.removeLast()
                numberedItems.append(last + " " + trimmed)
                continue
            }

            flushLists()
            paragraphLines.append(line)
        }

        flushParagraph()
        flushLists()
        return blocks
    }

    private static func matchHeading(_ line: String) -> (level: Int, text: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^(#{1,6})\s+(.+)$"#) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              match.numberOfRanges == 3,
              let hashes = Range(match.range(at: 1), in: line),
              let text = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return (String(line[hashes]).count, String(line[text]))
    }

    private static func matchBullet(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^([-*+])\s+(.+)$"#) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let text = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return String(line[text])
    }

    private static func matchNumbered(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^(\d+)\.\s+(.+)$"#) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let text = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return String(line[text])
    }
}
