import SwiftUI

public enum NookToggleStyle {
    case local
    case external
}

public struct NookToggle: View {
    @Binding private var isOn: Bool
    private let style: NookToggleStyle
    private let accessibilityLabel: String
    
    public init(
        isOn: Binding<Bool>,
        style: NookToggleStyle = .local,
        accessibilityLabel: String = "Toggle setting"
    ) {
        self._isOn = isOn
        self.style = style
        self.accessibilityLabel = accessibilityLabel
    }
    
    private var activeColor: Color {
        switch style {
        case .local:
            return NookColors.local
        case .external:
            return NookColors.external
        }
    }
    
    public var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: NookRadius.toggleTrack)
                    .fill(isOn ? activeColor : NookColors.toggleOff)
                    .frame(width: 44, height: 26)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 20, height: 20)
                    .padding(3)
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
            }
            .frame(width: 44, height: 44) // Accessible hit target
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}
