import Foundation

/// Debug helpers for whitespace / newline issues in assistant text.
public enum NookTextDebug {
    /// Makes whitespace visible in console logs (`·` = space, `\\n` = newline).
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count * 2)
        for ch in text {
            switch ch {
            case "\\": out += "\\\\"
            case "\r": out += "\\r"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case " ": out += "·"
            case "\u{00A0}": out += "\\u{00A0}"
            case "\u{2028}": out += "\\u{2028}"
            case "\u{2029}": out += "\\u{2029}"
            default: out.append(ch)
            }
        }
        return out
    }

    public static func stats(_ text: String) -> String {
        let newlines = text.filter { $0 == "\n" }.count
        let spaces = text.filter { $0 == " " }.count
        let crs = text.filter { $0 == "\r" }.count
        let tabs = text.filter { $0 == "\t" }.count
        return "len=\(text.count) newlines=\(newlines) spaces=\(spaces) cr=\(crs) tabs=\(tabs)"
    }

    /// Spots like `end.Start` / `wordWord` that look like a missing break/space.
    public static func suspiciousJoins(_ text: String) -> [String] {
        guard text.count >= 2 else { return [] }
        var hits: [String] = []
        let chars = Array(text)
        for i in 0..<(chars.count - 1) {
            let a = chars[i]
            let b = chars[i + 1]
            let letterDigit = { (c: Character) -> Bool in c.isLetter || c.isNumber }
            let looksJoined =
                (a.isPunctuation && b.isLetter)
                || (letterDigit(a) && b.isUppercase && a.isLowercase)
            guard looksJoined else { continue }
            let start = max(0, i - 12)
            let end = min(chars.count, i + 14)
            let snippet = String(chars[start..<end])
            hits.append("'\(escape(snippet))'")
            if hits.count >= 8 { break }
        }
        return hits
    }

    public static func log(_ label: String, text: String) {
        let joins = suspiciousJoins(text)
        print("[NookTextDebug] \(label) · \(stats(text))")
        print("[NookTextDebug] \(label) escaped: \(escape(text))")
        if joins.isEmpty {
            print("[NookTextDebug] \(label) suspiciousJoins: none")
        } else {
            print("[NookTextDebug] \(label) suspiciousJoins: \(joins.joined(separator: ", "))")
        }
    }
}
