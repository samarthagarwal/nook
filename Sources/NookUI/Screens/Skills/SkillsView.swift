import SwiftUI
import NookDesign
import NookCore

public struct SkillsView: View {
    @ObservedObject public var state: ObservableSkillManager
    public let onSelectSkill: (Skill) -> Void
    public let onImportSkill: () -> Void
    
    public init(
        state: ObservableSkillManager,
        onSelectSkill: @escaping (Skill) -> Void,
        onImportSkill: @escaping () -> Void
    ) {
        self.state = state
        self.onSelectSkill = onSelectSkill
        self.onImportSkill = onImportSkill
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Skills")
                    .font(NookTypography.tabRootTitle)
                    .foregroundColor(NookColors.ink)
                
                Spacer()
                
                Button(action: onImportSkill) {
                    Text("Import")
                        .font(NookTypography.rowTitle)
                        .foregroundColor(NookColors.local)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)
            
            // Intro
            HStack {
                Text("A Skill teaches Nook a way of working. It can ask for tools, but never grants itself any.")
                    .font(NookTypography.body)
                    .foregroundColor(NookColors.ink62)
                    .lineSpacing(4)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            
            // Groups
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    groupSection(title: "Built in", skills: state.skills.filter { $0.group == .builtIn })
                    groupSection(title: "Imported", skills: state.skills.filter { $0.group == .imported })
                    groupSection(title: "Yours", skills: state.skills.filter { $0.group == .yours })
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
    
    private func groupSection(title: String, skills: [Skill]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .nookEyebrow()
                .foregroundColor(NookColors.ink40)
            
            VStack(spacing: 8) {
                ForEach(skills) { skill in
                    Button(action: {
                        onSelectSkill(skill)
                    }) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(skill.name)
                                    .font(NookTypography.rowTitle)
                                    .foregroundColor(NookColors.ink)
                                
                                Text(skill.desc)
                                    .font(NookTypography.cardSub)
                                    .foregroundColor(NookColors.ink62)
                                    .lineLimit(2)
                            }
                            
                            Spacer()
                            
                            // State badge: ON = local on localSoft, OFF = ink40 on fill
                            Text(skill.isEnabled ? "ON" : "OFF")
                                .font(NookTypography.badge)
                                .foregroundColor(skill.isEnabled ? NookColors.local : NookColors.ink40)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: NookRadius.tag)
                                        .fill(skill.isEnabled ? NookColors.localSoft : NookColors.fill)
                                )
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: NookRadius.card)
                                .fill(NookColors.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: NookRadius.card)
                                .strokeBorder(NookColors.hairline, lineWidth: 1)
                        )
                        .nookCardShadow()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

public struct SkillDetailView: View {
    @State public var skill: Skill
    public let onBack: () -> Void
    public let onToggleSkill: (Skill) -> Void
    
    public init(skill: Skill, onBack: @escaping () -> Void, onToggleSkill: @escaping (Skill) -> Void) {
        self._skill = State(initialValue: skill)
        self.onBack = onBack
        self.onToggleSkill = onToggleSkill
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .medium))
                        Text("Skills")
                            .font(NookTypography.body)
                    }
                    .foregroundColor(NookColors.ink45)
                }
                .buttonStyle(.plain)
                
                Text(skill.name)
                    .font(NookTypography.detailTitle)
                    .foregroundColor(NookColors.ink)
                    .padding(.top, 4)
                
                Text(skill.importedMeta)
                    .font(NookTypography.meta)
                    .foregroundColor(NookColors.ink45)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // SKILL.MD Card
                    VStack(alignment: .leading, spacing: 6) {
                        Text("INSTRUCTIONS · SKILL.MD")
                            .nookEyebrow()
                            .foregroundColor(NookColors.ink40)
                        
                        Text(skill.skillMdContent)
                            .font(NookTypography.code)
                            .foregroundColor(NookColors.ink)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: NookRadius.row)
                                    .fill(NookColors.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: NookRadius.row)
                                    .strokeBorder(NookColors.hairline, lineWidth: 1)
                            )
                        
                        Text("Plain instructions. No code runs.")
                            .font(NookTypography.meta)
                            .foregroundColor(NookColors.ink45)
                    }
                    
                    // Wants Access To Toggles (Defaulting OFF per rule)
                    if !skill.permissions.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("WANTS ACCESS TO")
                                .nookEyebrow()
                                .foregroundColor(NookColors.ink40)
                            
                            VStack(spacing: 8) {
                                ForEach(skill.permissions.indices, id: \.self) { idx in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.permissions[idx].tool)
                                                .font(NookTypography.fileName)
                                                .foregroundColor(NookColors.ink)
                                            
                                            Text(skill.permissions[idx].what)
                                                .font(NookTypography.meta)
                                                .foregroundColor(NookColors.ink55)
                                        }
                                        
                                        Spacer()
                                        
                                        NookToggle(
                                            isOn: $skill.permissions[idx].isGranted,
                                            style: .local,
                                            accessibilityLabel: "Grant \(skill.permissions[idx].tool)"
                                        )
                                    }
                                    .padding(12)
                                    .background(
                                        RoundedRectangle(cornerRadius: NookRadius.row)
                                            .fill(NookColors.surface)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: NookRadius.row)
                                            .strokeBorder(NookColors.hairline, lineWidth: 1)
                                    )
                                }
                            }
                            
                            Text("The Skill asked for these. Nothing is granted until you switch it on, and you can revoke any of them later.")
                                .font(NookTypography.meta)
                                .foregroundColor(NookColors.ink45)
                                .lineSpacing(3)
                        }
                    }
                    
                    // Toggle Enable Button
                    NookPrimaryButton(title: skill.isEnabled ? "Turn off Skill" : "Turn on Skill") {
                        skill.isEnabled.toggle()
                        onToggleSkill(skill)
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
        }
        .background(NookColors.paper.ignoresSafeArea())
    }
}

@MainActor
public final class ObservableSkillManager: ObservableObject {
    @Published public var skills: [Skill] = []
    private let manager: SkillManager
    
    public init(manager: SkillManager) {
        self.manager = manager
        Task {
            let sk = await manager.getAllSkills()
            self.skills = sk
        }
    }
    
    public func updateSkill(_ updated: Skill) {
        if let idx = skills.firstIndex(where: { $0.id == updated.id }) {
            skills[idx] = updated
        }
    }
}
