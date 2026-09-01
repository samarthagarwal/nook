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
                When asked to prepare for an upcoming meeting:
                1. Look up events on today's calendar using calendar.search.
                2. Find recent conversations mentioning meeting attendees using memory.search.
                3. Summarize key open discussion items in 3-4 bullet points.
                """,
                permissions: [
                    SkillPermission(tool: "calendar.search", what: "Read your calendar", isGranted: true),
                    SkillPermission(tool: "memory.search", what: "Search past conversations", isGranted: true)
                ]
            ),
            Skill(
                id: "weekly-review",
                name: "Weekly Review",
                desc: "Summarise the week from chats and Knowledge you name.",
                group: .builtIn,
                isEnabled: false,
                importedMeta: "Built in · instructions only, nothing executable.",
                skillMdContent: """
                # Weekly Review Skill
                Generate a weekly digest across selected knowledge collections and chat transcripts.
                """,
                permissions: [
                    SkillPermission(tool: "documents.search", what: "Search collections you tick", isGranted: false),
                    SkillPermission(tool: "memory.search", what: "Search prior chat history", isGranted: false)
                ]
            ),
            Skill(
                id: "competitive-teardown",
                name: "Competitive Teardown",
                desc: "A structured way to read a rival's product docs.",
                group: .imported,
                isEnabled: false,
                importedMeta: "Imported 2 minutes ago · instructions only, nothing executable.",
                skillMdContent: """
                # Competitive Teardown Skill
                Evaluate competitor documentation against internal requirements:
                - Extract claims, pricing tiers, and API capabilities.
                - Cross-reference with our spec documents in Knowledge.
                - Highlight gaps and strategic differentiators.
                """,
                permissions: [
                    SkillPermission(tool: "documents.search", what: "Search collections you tick below", isGranted: false),
                    SkillPermission(tool: "calendar.search", what: "Read your calendar", isGranted: false),
                    SkillPermission(tool: "calendar.create_event", what: "Create events", isGranted: false)
                ]
            ),
            Skill(
                id: "receipt-filing",
                name: "Receipt Filing",
                desc: "Read a receipt photo, file it, name the category.",
                group: .yours,
                isEnabled: true,
                importedMeta: "Created by you · instructions only, nothing executable.",
                skillMdContent: """
                # Receipt Filing Skill
                When an image of a receipt is provided:
                1. Extract vendor name, date, total amount, and currency.
                2. Categorize expense (e.g. Travel, Meals, Office).
                3. Propose a structured summary for filing into Knowledge.
                """,
                permissions: []
            )
        ]
    }
    
    public func getAllSkills() -> [Skill] {
        return skills
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
