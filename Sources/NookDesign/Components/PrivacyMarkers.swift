import SwiftUI

/// Non-negotiable two-accent privacy markers.
/// Local: Filled 5px dot in `#2F5D8A`
/// External: Hollow 6px ring with 1.5px border in `#8C6239`
public struct PrivacyDot: View {
    private let accessibilityText: String
    
    public init(accessibilityText: String = "Runs on device") {
        self.accessibilityText = accessibilityText
    }
    
    public var body: some View {
        Circle()
            .fill(NookColors.local)
            .frame(width: 5, height: 5)
            .accessibilityLabel(Text(accessibilityText))
    }
}

public struct PrivacyRing: View {
    private let accessibilityText: String
    
    public init(accessibilityText: String = "Leaves device") {
        self.accessibilityText = accessibilityText
    }
    
    public var body: some View {
        Circle()
            .strokeBorder(NookColors.external, lineWidth: 1.5)
            .frame(width: 6, height: 6)
            .accessibilityLabel(Text(accessibilityText))
    }
}

public struct ModelBadge: View {
    private let tierName: String
    
    public init(tierName: String = "Balanced") {
        self.tierName = tierName
    }
    
    public var body: some View {
        HStack(spacing: 5) {
            PrivacyDot(accessibilityText: "\(tierName) runs on device")
            Text("\(tierName) · on device")
                .font(NookTypography.badge)
                .foregroundColor(NookColors.ink70)
        }
    }
}
