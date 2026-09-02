import SwiftUI
import NookDesign

public enum NookTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case knowledge = "Knowledge"
    case skills = "Skills"
    case connect = "Connect"
    case memory = "Memory"
    
    public var id: String { rawValue }

    /// Small SF Symbol shown above the tab label.
    public var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .knowledge: return "book.closed"
        case .skills: return "sparkles"
        case .connect: return "link"
        case .memory: return "brain.head.profile"
        }
    }
}

public struct NookTabBar: View {
    @Binding public var selectedTab: NookTab
    
    public init(selectedTab: Binding<NookTab>) {
        self._selectedTab = selectedTab
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(NookTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button(action: {
                    selectedTab = tab
                }) {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundColor(isSelected ? NookColors.ink : NookColors.ink40)
                            .frame(height: 16)

                        Text(tab.rawValue)
                            .font(isSelected ? NookTypography.tabLabelActive : NookTypography.tabLabel)
                            .foregroundColor(isSelected ? NookColors.ink : NookColors.ink40)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44) // 44pt minimum hit target
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background {
            Color(red: 247/255.0, green: 244/255.0, blue: 238/255.0, opacity: 0.94)
                .background(.ultraThinMaterial)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(NookColors.hairline),
                    alignment: .top
                )
                .ignoresSafeArea(edges: .bottom)
        }
    }
}
