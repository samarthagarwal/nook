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
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(NookColors.ink.opacity(opacity(for: index)))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: NookRadius.chip)
                .fill(NookColors.surface)
        )
        .accessibilityLabel("Thinking")
        .onReceive(Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()) { _ in
            phase = (phase + 1) % 3
        }
    }

    private func opacity(for index: Int) -> Double {
        index == phase ? 0.45 : (index == (phase + 2) % 3 ? 0.22 : 0.12)
    }
}
