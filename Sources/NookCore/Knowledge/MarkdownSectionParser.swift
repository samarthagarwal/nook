import Foundation

enum MarkdownSectionParser {
    static func sections(from markdown: String) -> [(pageOrSection: String, text: String)] {
        var parsed: [(pageOrSection: String, text: String)] = []
        var currentTitle = "Document"
        var currentLines: [String] = []

        for line in markdown.components(separatedBy: .newlines) {
            if let heading = headingTitle(from: line) {
                if !currentLines.isEmpty {
                    parsed.append((currentTitle, currentLines.joined(separator: "\n")))
                }
                currentTitle = heading
                currentLines = []
            } else {
                currentLines.append(line)
            }
        }

        if !currentLines.isEmpty || parsed.isEmpty {
            parsed.append((currentTitle, currentLines.joined(separator: "\n")))
        }

        return parsed.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func headingTitle(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }

        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#" {
            index = trimmed.index(after: index)
        }
        while index < trimmed.endIndex, trimmed[index].isWhitespace {
            index = trimmed.index(after: index)
        }

        let title = String(trimmed[index...]).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
