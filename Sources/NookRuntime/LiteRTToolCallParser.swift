import Foundation
import NookCore

/// Parses model-emitted tool calls from LiteRT output (JSON or fenced blocks).
enum LiteRTToolCallParser {
    struct ParsedCall: Sendable, Equatable {
        let name: String
        let arguments: ToolArguments
        let id: String
    }

    /// Returns tool calls found in assistant text, if any.
    static func parse(from text: String) -> [ParsedCall] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Gemma 4 native: <|tool_call>call:name{args}<tool_call|>
        let gemmaCalls = parseGemmaToolCalls(from: trimmed)
        if !gemmaCalls.isEmpty {
            return gemmaCalls
        }

        for candidate in candidateJSONStrings(in: trimmed) {
            if let calls = parseJSONObject(candidate) {
                return calls
            }
            if let repaired = repairTruncatedJSON(candidate),
               let calls = parseJSONObject(repaired) {
                return calls
            }
        }

        // Line-oriented fallback: tool: name / name: value
        if let call = parseLineOriented(trimmed) {
            return [call]
        }

        return []
    }

    /// Visible assistant text with tool-call markup removed.
    static func visibleText(from text: String) -> String {
        let stripped = stripToolCallMarkup(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return "" }
        // Still mostly/only a tool attempt after stripping → hide entirely.
        if looksLikeToolAttempt(stripped) {
            return ""
        }
        return stripped
    }

    /// Removes Gemma/OpenAI-style tool-call spans so leftover prose can be shown.
    static func stripToolCallMarkup(from text: String) -> String {
        var s = text

        // `<|tool_call>…<tool_call|>` / `<tool_call>…</tool_call>`
        let fencePatterns = [
            #"<\|tool_call\>[\s\S]*?<tool_call\|>"#,
            #"<\|tool_call\>[\s\S]*$"#,
            #"<tool_call\>[\s\S]*?</tool_call\>"#,
            #"<tool_call\>[\s\S]*$"#,
        ]
        for pattern in fencePatterns {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        // Bare `call:name{…}` (Gemma without fences).
        var searchIndex = s.startIndex
        while let callRange = s.range(of: "call:", range: searchIndex..<s.endIndex) {
            let nameStart = callRange.upperBound
            guard let (_, nameEnd) = gemmaToolName(in: s, start: nameStart) else {
                searchIndex = s.index(after: callRange.lowerBound)
                continue
            }
            guard nameEnd < s.endIndex, s[nameEnd] == "{" else {
                searchIndex = nameEnd > callRange.upperBound ? nameEnd : s.index(after: callRange.lowerBound)
                continue
            }
            if let argsBody = balancedBracesContent(in: s, openBraceAt: nameEnd),
               let close = s.index(nameEnd, offsetBy: argsBody.count + 2, limitedBy: s.endIndex) {
                s.replaceSubrange(callRange.lowerBound..<close, with: " ")
                searchIndex = callRange.lowerBound
            } else {
                // Truncated `call:name{…` — drop from here to end.
                s = String(s[..<callRange.lowerBound])
                break
            }
        }

        // Fenced JSON tool payloads.
        s = s.replacingOccurrences(
            of: #"```(?:json)?\s*\{[\s\S]*?"(?:name|tool_calls|function)"[\s\S]*?```"#,
            with: " ",
            options: .regularExpression
        )
        // Unfenced single JSON tool object occupying most of the reply.
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"),
           (trimmed.contains("\"tool_calls\"") || (trimmed.contains("\"name\"") && trimmed.contains("\"arguments\""))) {
            if parse(from: trimmed).isEmpty == false || looksLikeToolAttempt(trimmed) {
                return ""
            }
        }

        return s.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }

    /// True when the model clearly tried to emit a tool call (even if JSON is truncated).
    static func looksLikeToolAttempt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("tool_call") || lower.contains("<|tool_call") {
            return true
        }
        // Bare Gemma call — require call:name{ shape, not the English word "call:".
        if lower.range(of: #"call:[a-z0-9_.\- ]+\{"#, options: .regularExpression) != nil {
            return true
        }
        if lower.contains("\"tool_calls\"") || lower.contains("'tool_calls'") {
            return true
        }
        if trimmed.hasPrefix("```") && (lower.contains("\"arguments\"") || lower.contains("\"function\"") || lower.contains("\"name\"")) {
            return true
        }
        if lower.contains("\"function\"") && lower.contains("\"name\"") {
            return true
        }
        if lower.contains("\"name\"") && (lower.contains("\"arguments\"") || lower.contains("\"parameters\"")) {
            return true
        }
        if lower.hasPrefix("tool:") || lower.contains("\ntool:") {
            return true
        }
        return false
    }

    // MARK: - Gemma 4

    /// Parses `<|tool_call>call:name{args}<tool_call|>` and bare `call:name{args}`.
    static func parseGemmaToolCalls(from text: String) -> [ParsedCall] {
        var calls: [ParsedCall] = []
        var search = text.startIndex

        while search < text.endIndex {
            guard let callStart = text.range(of: "call:", range: search..<text.endIndex) else {
                break
            }
            // Prefer matches that sit inside a tool_call fence, but accept bare `call:`.
            let nameStart = callStart.upperBound
            guard nameStart < text.endIndex else { break }

            guard let (name, nameEnd) = gemmaToolName(in: text, start: nameStart),
                  nameEnd < text.endIndex, text[nameEnd] == "{" else {
                search = text.index(after: callStart.lowerBound)
                continue
            }

            guard let argsBody = balancedBracesContent(in: text, openBraceAt: nameEnd) else {
                search = text.index(after: nameEnd)
                continue
            }
            let arguments = parseGemmaArgumentList(argsBody)
            calls.append(
                ParsedCall(name: name, arguments: arguments, id: UUID().uuidString)
            )
            // Continue after the closing `}` of this call.
            if let close = text.index(nameEnd, offsetBy: argsBody.count + 2, limitedBy: text.endIndex) {
                search = close
            } else {
                break
            }
        }

        return calls
    }

    /// `calendar.search` or a skill-shaped `Meeting Prep` (spaces until `{`).
    private static func gemmaToolName(
        in text: String,
        start: String.Index
    ) -> (String, String.Index)? {
        var nameEnd = start
        while nameEnd < text.endIndex {
            let ch = text[nameEnd]
            if ch.isLetter || ch.isNumber || ch == "_" || ch == "." || ch == "-" || ch == " " {
                nameEnd = text.index(after: nameEnd)
            } else {
                break
            }
        }
        let name = String(text[start..<nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return (name, nameEnd)
    }

    /// Given index of `{`, returns the inner content up to the matching `}`.
    private static func balancedBracesContent(in text: String, openBraceAt: String.Index) -> String? {
        guard openBraceAt < text.endIndex, text[openBraceAt] == "{" else { return nil }
        var depth = 0
        var inQuote: Character?
        var escape = false
        var index = openBraceAt
        var innerStart: String.Index?

        while index < text.endIndex {
            let ch = text[index]
            if let quote = inQuote {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == quote {
                    inQuote = nil
                }
            } else if ch == "\"" || ch == "'" {
                inQuote = ch
            } else if text[index...].hasPrefix("<|\"|>") {
                // Gemma string delimiter — skip as a unit, then scan until close delimiter.
                let afterOpen = text.index(index, offsetBy: 5)
                if let close = text.range(of: "<|\"|>", range: afterOpen..<text.endIndex) {
                    index = close.upperBound
                    continue
                }
                return nil
            } else if ch == "{" {
                depth += 1
                if depth == 1 {
                    innerStart = text.index(after: index)
                }
            } else if ch == "}" {
                depth -= 1
                if depth == 0, let innerStart {
                    return String(text[innerStart..<index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// Parses `query:"…", n:3, flag:true` / Gemma `<|"|>…<|"|>` argument bodies.
    static func parseGemmaArgumentList(_ raw: String) -> ToolArguments {
        var arguments: ToolArguments = [:]
        var index = raw.startIndex

        func skipWhitespace() {
            while index < raw.endIndex, raw[index].isWhitespace {
                index = raw.index(after: index)
            }
        }

        while index < raw.endIndex {
            skipWhitespace()
            if index < raw.endIndex, raw[index] == "," {
                index = raw.index(after: index)
                skipWhitespace()
            }
            guard index < raw.endIndex else { break }

            let keyStart = index
            while index < raw.endIndex {
                let ch = raw[index]
                if ch.isLetter || ch.isNumber || ch == "_" {
                    index = raw.index(after: index)
                } else {
                    break
                }
            }
            let key = String(raw[keyStart..<index])
            skipWhitespace()
            guard !key.isEmpty, index < raw.endIndex, raw[index] == ":" else { break }
            index = raw.index(after: index) // :
            skipWhitespace()
            guard index < raw.endIndex else { break }

            let value: ToolJSONValue
            if raw[index...].hasPrefix("<|\"|>") {
                let afterOpen = raw.index(index, offsetBy: 5)
                if let close = raw.range(of: "<|\"|>", range: afterOpen..<raw.endIndex) {
                    value = .string(String(raw[afterOpen..<close.lowerBound]))
                    index = close.upperBound
                } else {
                    value = .string(String(raw[afterOpen...]))
                    index = raw.endIndex
                }
            } else if raw[index] == "\"" || raw[index] == "'" {
                let quote = raw[index]
                index = raw.index(after: index)
                let valueStart = index
                var escape = false
                while index < raw.endIndex {
                    let ch = raw[index]
                    if escape {
                        escape = false
                    } else if ch == "\\" {
                        escape = true
                    } else if ch == quote {
                        break
                    }
                    index = raw.index(after: index)
                }
                value = .string(String(raw[valueStart..<index]))
                if index < raw.endIndex { index = raw.index(after: index) }
            } else {
                let valueStart = index
                while index < raw.endIndex, raw[index] != "," {
                    index = raw.index(after: index)
                }
                let token = String(raw[valueStart..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                if token == "true" {
                    value = .bool(true)
                } else if token == "false" {
                    value = .bool(false)
                } else if let intVal = Int(token) {
                    value = .int(intVal)
                } else if let doubleVal = Double(token) {
                    value = .double(doubleVal)
                } else {
                    value = .string(token)
                }
            }
            arguments[key] = value
        }

        return arguments
    }

    // MARK: - Private

    private static func candidateJSONStrings(in text: String) -> [String] {
        var results: [String] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        results.append(trimmed)
        results.append(contentsOf: fenceCandidates(in: trimmed))
        if let object = firstJSONObject(in: trimmed) {
            results.append(object)
        } else if let partial = partialJSONObject(in: trimmed) {
            results.append(partial)
        }
        for fence in fenceCandidates(in: trimmed) {
            if let object = firstJSONObject(in: fence) {
                results.append(object)
            } else if let partial = partialJSONObject(in: fence) {
                results.append(partial)
            }
        }
        // Deduplicate while preserving order.
        var seen = Set<String>()
        return results.filter { seen.insert($0).inserted }
    }

    private static func parseJSONObject(_ raw: String) -> [ParsedCall]? {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let dict = object as? [String: Any] {
            if let calls = dict["tool_calls"] as? [[String: Any]] {
                let parsed = calls.compactMap(parseCall(_:))
                return parsed.isEmpty ? nil : parsed
            }
            if dict["name"] != nil
                || dict["tool"] != nil
                || (dict["function"] as? [String: Any]) != nil {
                return parseCall(dict).map { [$0] }
            }
        }

        if let array = object as? [[String: Any]] {
            let parsed = array.compactMap(parseCall(_:))
            return parsed.isEmpty ? nil : parsed
        }

        return nil
    }

    private static func parseCall(_ item: [String: Any]) -> ParsedCall? {
        let function = item["function"] as? [String: Any]
        let name = (function?["name"] as? String)
            ?? (item["name"] as? String)
            ?? (item["tool"] as? String)
        guard let name, !name.isEmpty else { return nil }

        let rawArgs = function?["arguments"]
            ?? function?["parameters"]
            ?? item["arguments"]
            ?? item["parameters"]
            ?? item["args"]
            ?? [:]
        let arguments = decodeArguments(rawArgs)
        let id = (item["id"] as? String) ?? UUID().uuidString
        return ParsedCall(name: name, arguments: arguments, id: id)
    }

    private static func decodeArguments(_ rawArgs: Any) -> ToolArguments {
        if let dict = rawArgs as? [String: Any] {
            return dict.mapValues { ToolJSONValue.from($0) }
        }
        if let string = rawArgs as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return dict.mapValues { ToolJSONValue.from($0) }
            }
            // Bare query string → common MCP search tools.
            if !trimmed.isEmpty {
                return ["query": .string(trimmed)]
            }
        }
        return [:]
    }

    /// `tool: tavily_search` / `query: …` style fallback for weaker models.
    private static func parseLineOriented(_ text: String) -> ParsedCall? {
        let lines = text
            .replacingOccurrences(of: "```", with: "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var name: String?
        var arguments: ToolArguments = [:]
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("tool:") || lower.hasPrefix("name:") {
                let value = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !value.isEmpty { name = value }
            } else if line.contains(":"),
                      let sep = line.firstIndex(of: ":") {
                let key = String(line[..<sep]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: sep)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !key.isEmpty, key.lowercased() != "tool", key.lowercased() != "name" else { continue }
                arguments[key] = .string(value)
            }
        }
        guard let name, !name.isEmpty else { return nil }
        if arguments.isEmpty { return nil }
        return ParsedCall(name: name, arguments: arguments, id: UUID().uuidString)
    }

    /// Contents of markdown fences, including unclosed opening fences.
    private static func fenceCandidates(in text: String) -> [String] {
        var results: [String] = []
        var search = text.startIndex
        while search < text.endIndex,
              let open = text.range(of: "```", range: search..<text.endIndex) {
            var contentStart = open.upperBound
            if let newline = text[contentStart...].firstIndex(of: "\n") {
                let meta = text[contentStart..<newline]
                if meta.count < 32, meta.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == " " }) {
                    contentStart = text.index(after: newline)
                }
            } else {
                while contentStart < text.endIndex, text[contentStart].isLetter || text[contentStart].isNumber {
                    contentStart = text.index(after: contentStart)
                }
            }

            let rest = text[contentStart...]
            if let close = rest.range(of: "```") {
                let body = String(rest[..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { results.append(body) }
                search = close.upperBound
            } else {
                let body = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty { results.append(body) }
                break
            }
        }
        return results
    }

    /// First complete top-level JSON object.
    private static func firstJSONObject(in text: String) -> String? {
        scanJSONObject(in: text, allowIncomplete: false)
    }

    /// From first `{` through end of text (for repair).
    private static func partialJSONObject(in text: String) -> String? {
        scanJSONObject(in: text, allowIncomplete: true)
    }

    private static func scanJSONObject(in text: String, allowIncomplete: Bool) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"":
                    inString = true
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        guard allowIncomplete, depth > 0 else { return nil }
        return String(text[start...])
    }

    /// Closes truncated JSON objects/arrays/strings enough for `JSONSerialization`.
    static func repairTruncatedJSON(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("{") else { return nil }
        var stack: [Character] = []
        var inString = false
        var escape = false

        for ch in trimmed {
            if inString {
                if escape {
                    escape = false
                } else if ch == "\\" {
                    escape = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            switch ch {
            case "\"":
                inString = true
            case "{", "[":
                stack.append(ch)
            case "}":
                if stack.last == "{" { stack.removeLast() }
            case "]":
                if stack.last == "[" { stack.removeLast() }
            default:
                break
            }
        }

        var repaired = trimmed
        if inString {
            repaired.append("\"")
        }
        // Drop a dangling comma before we close.
        while repaired.last.map({ ", \n\t".contains($0) }) == true {
            repaired.removeLast()
        }
        while let open = stack.popLast() {
            repaired.append(open == "{" ? "}" : "]")
        }
        guard repaired != trimmed else { return nil }
        return repaired
    }
}
