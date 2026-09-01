import SwiftUI
import NookDesign

public struct ToastOverlay: View {
    let message: String
    
    public init(message: String) {
        self.message = message
    }
    
    public var body: some View {
        Text(message)
            .font(NookTypography.body)
            .foregroundColor(NookColors.inkOnDark)
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: NookRadius.card)
                    .fill(NookColors.ink)
            )
            .nookToastShadow()
            .padding(.horizontal, 20)
            .padding(.bottom, 104) // Placed right above the tab bar
    }
}

public struct ThinkingDotsView: View {
    @State private var phase = 0
    
    public init() {}
    
    public var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(NookColors.ink.opacity(0.25))
                .frame(width: 6, height: 6)
            Circle()
                .fill(NookColors.ink.opacity(0.18))
                .frame(width: 6, height: 6)
            Circle()
                .fill(NookColors.ink.opacity(0.11))
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: NookRadius.chip)
                .fill(NookColors.surface)
        )
    }
}
