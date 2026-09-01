import SwiftUI
import NookDesign

public enum NookTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case knowledge = "Knowledge"
    case skills = "Skills"
    case connect = "Connect"
    case memory = "Memory"
    
    public var id: String { rawValue }
}

public struct NookTabBar: View {
    @Binding public var selectedTab: NookTab
    
    public init(selectedTab: Binding<NookTab>) {
        self._selectedTab = selectedTab
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(NookTab.allCases) { tab in
                Button(action: {
                    selectedTab = tab
                }) {
                    VStack(spacing: 4) {
                        // 5pt active ink dot above label
                        Circle()
                            .fill(selectedTab == tab ? NookColors.ink : Color.clear)
                            .frame(width: 5, height: 5)
                        
                        Text(tab.rawValue)
                            .font(selectedTab == tab ? NookTypography.tabLabelActive : NookTypography.tabLabel)
                            .foregroundColor(selectedTab == tab ? NookColors.ink : NookColors.ink40)
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
