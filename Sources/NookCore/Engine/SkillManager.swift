import Foundation

public actor SkillManager {
    private var skills: [Skill]
    
    public init() {
        self.skills = [
            Skill(
                id: "meeting-prep",
                name: "Meeting Prep",
                desc: "Pull the last thread and today's calendar into a short brief.",
                group: .builtIn,
                isEnabled: true,
                importedMeta: "Built in · instructions only, nothing executable.",
                skillMdContent: """
                # Meeting Prep Skill
                When asked to prepare for a meeting or what is on the calendar:
                1. Call calendar.search with window only — today, or tomorrow / next_7_days if they ask. Do not pass query.
                2. Use any MEMORY excerpts for recent discussion with those attendees.
                3. Return a short brief: time, who, what is still open, what to decide.
                Do not invent meetings that are not in the tool result.
                """,
                permissions: [
                    SkillPermission(tool: "calendar.search", what: "Read your calendar", isGranted: true),
                    SkillPermission(tool: "memory.search", what: "Search past conversations", isGranted: true)
                ]
            ),
        ]
    }
    
    public func getAllSkills() -> [Skill] {
        return skills
    }

    public func enabledSkills() -> [Skill] {
        skills.filter(\.isEnabled)
    }

    public func replaceSkill(_ updated: Skill) {
        guard let index = skills.firstIndex(where: { $0.id == updated.id }) else { return }
        skills[index] = updated
    }
    
    public func getSkill(id: String) -> Skill? {
        return skills.first { $0.id == id }
    }
    
    public func toggleSkill(id: String) {
        if let index = skills.firstIndex(where: { $0.id == id }) {
            skills[index].isEnabled.toggle()
        }
    }
    
    public func setPermission(skillId: String, permissionId: String, isGranted: Bool) {
        if let skillIndex = skills.firstIndex(where: { $0.id == skillId }),
           let permIndex = skills[skillIndex].permissions.firstIndex(where: { $0.id == permissionId }) {
            skills[skillIndex].permissions[permIndex].isGranted = isGranted
        }
    }
    
    /// Progressive disclosure: Injects only name and description until selected
    public func getSkillSummariesForPrompt() -> String {
        return skills
            .filter { $0.isEnabled }
            .map { "- \($0.name): \($0.desc)" }
            .joined(separator: "\n")
    }
}
