import Foundation

/// Explicit Skill invocation — slash command or a chat-scoped selection.
/// Skills are never inferred from ordinary chat text.
public enum SkillActivation {
    public struct Invocation: Equatable, Sendable {
        public let skill: Skill
        public let remainder: String
    }

    public static func grantedToolNames(for skill: Skill?) -> Set<String> {
        Set((skill?.permissions ?? []).filter(\.isGranted).map(\.tool))
    }

    public static func grantedToolNames(for skills: [Skill]) -> Set<String> {
        Set(skills.flatMap { grantedToolNames(for: $0) })
    }

    public static func skill(id: String?, in skills: [Skill]) -> Skill? {
        guard let id else { return nil }
        return skills.first { $0.id == id }
    }

    /// `/meeting-prep what's on today` or `/Meeting Prep what's on today`.
    public static func parseInvocation(_ text: String, skills: [Skill]) -> Invocation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = String(trimmed.dropFirst())
        guard !body.isEmpty else { return nil }

        var best: (skill: Skill, matched: Int)?
        for skill in skills {
            for candidate in commandTokens(for: skill) {
                guard body.count >= candidate.count,
                      body.lowercased().hasPrefix(candidate.lowercased()) else { continue }
                let after = body.dropFirst(candidate.count)
                if after.isEmpty || after.first?.isWhitespace == true, candidate.count >= (best?.matched ?? 0) {
                    best = (skill, candidate.count)
                }
            }
        }
        guard let best else { return nil }
        let remainder = String(body.dropFirst(best.matched))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Invocation(skill: best.skill, remainder: remainder)
    }

    /// Completions while the field is still a `/` token (no remainder yet).
    public static func autocomplete(prefix: String, skills: [Skill]) -> [Skill] {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return [] }
        if let invoked = parseInvocation(trimmed, skills: skills), !invoked.remainder.isEmpty {
            return []
        }
        let token = String(trimmed.dropFirst()).lowercased()
        return skills.filter { skill in
            token.isEmpty
                || skill.id.lowercased().hasPrefix(token)
                || skill.name.lowercased().hasPrefix(token)
                || slug(skill.name).hasPrefix(token)
        }
    }

    public static func commandTokens(for skill: Skill) -> [String] {
        [skill.id, slug(skill.name), skill.name]
    }

    public static func slashCommand(for skill: Skill) -> String {
        "/\(skill.id)"
    }

    private static func slug(_ name: String) -> String {
        name.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}
