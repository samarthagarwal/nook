import SwiftUI

public struct NookPrimaryButton: View {
    private let title: String
    private let action: () -> Void
    private let isEnabled: Bool
    
    public init(title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(NookTypography.buttonLabel)
                .foregroundColor(NookColors.inkOnDark)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: NookRadius.button)
                        .fill(isEnabled ? NookColors.ink : NookColors.ink40)
                )
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
    }
}

public struct NookSecondaryButton: View {
    private let title: String
    private let action: () -> Void
    
    public init(title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(NookTypography.body)
                .foregroundColor(NookColors.ink70)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: NookRadius.cardLg)
                        .strokeBorder(Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

public struct NookIconButton: View {
    private let systemName: String
    private let isPrimary: Bool
    private let action: () -> Void
    
    public init(systemName: String, isPrimary: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName
        self.isPrimary = isPrimary
        self.action = action
    }
    
    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(isPrimary ? NookColors.inkOnDark : NookColors.ink)
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(isPrimary ? NookColors.ink : NookColors.fill)
                )
                .contentShape(Circle())
        }
        .frame(minWidth: 44, minHeight: 44) // 44pt accessible hit target
        .buttonStyle(.plain)
    }
}
