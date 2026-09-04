import Foundation

/// Maps a model-emitted tool name onto a registered tool.
///
/// Small on-device models routinely mangle names: reminder aliases, MCP
/// `server__tool` collapsed to `server_tool`, and `-` / `_` swaps
/// (`web_search-exa` vs Exa's real `web_search_exa`).
public enum ToolNameResolver {
    private static let aliases: [String: String] = [
        "reminder.create": RemindersCreateTool.toolName,
        "reminder": RemindersCreateTool.toolName,
        "reminders": RemindersCreateTool.toolName,
        "create.reminder": RemindersCreateTool.toolName,
        "calendar": CalendarSearchTool.toolName,
        "calendars.search": CalendarSearchTool.toolName,
    ]

    public static func resolve(_ requested: String, available: Set<String>) -> String? {
        let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if available.contains(trimmed) { return trimmed }
        let folded = trimmed.lowercased()
        if let exact = available.first(where: { $0.lowercased() == folded }) {
            return exact
        }
        if let alias = aliases[folded], available.contains(alias) {
            return alias
        }
        // Gemma may mangle the server prefix separator (`.` → `_` or dropped entirely)
        // or swap `-` / `_`. Fingerprint normalises all of these for matching.
        let requestedKey = fingerprint(folded)
        let fingerprintHits = available.filter { fingerprint($0) == requestedKey }
        if fingerprintHits.count == 1 {
            return fingerprintHits.first
        }
        // Suffix match: model emitted bare `tool_name` without the `server.` prefix,
        // or a different/abbreviated server prefix (e.g. `exa.web_search_exa` for `exa_ai.web_search_exa`).
        let suffixMatches = available.filter {
            let lower = $0.lowercased()
            let key = fingerprint(lower)
            return key.hasSuffix(".\(requestedKey)")
                || key.hasSuffix("_\(requestedKey)")
                || lower.hasSuffix(".\(folded)")
        }
        if suffixMatches.count == 1 { return suffixMatches.first }

        // Tool-part suffix match: compare just the tool name after the server separator.
        // Handles `exa.web_search_exa` → `exa_ai.web_search_exa` where only the prefix differs.
        if let dotIndex = folded.firstIndex(of: ".") {
            let requestedToolPart = fingerprint(String(folded[folded.index(after: dotIndex)...]))
            guard !requestedToolPart.isEmpty else { return nil }
            let toolPartMatches = available.filter {
                let lower = $0.lowercased()
                // Must have a server prefix (contain a separator) and same tool-name suffix.
                guard let sep = lower.firstIndex(of: ".") ?? lower.firstIndex(of: "_") else { return false }
                return fingerprint(String(lower[lower.index(after: sep)...])) == requestedToolPart
            }
            if toolPartMatches.count == 1 { return toolPartMatches.first }
        }
        return nil
    }

    /// Normalises a tool name for fuzzy matching:
    /// lowercased, hyphens→underscores, dot/double-underscore separators collapsed to `_`.
    static func fingerprint(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "__", with: "_")
    }
}
