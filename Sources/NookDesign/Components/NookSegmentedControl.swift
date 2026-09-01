import SwiftUI

public struct NookSegmentedControl: View {
    private let options: [String]
    @Binding private var selectedIndex: Int
    
    public init(options: [String], selectedIndex: Binding<Int>) {
        self.options = options
        self._selectedIndex = selectedIndex
    }
    
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<options.count, id: \.self) { index in
                Button(action: {
                    selectedIndex = index
                }) {
                    Text(options[index])
                        .font(NookTypography.body)
                        .foregroundColor(selectedIndex == index ? NookColors.ink : NookColors.ink62)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if selectedIndex == index {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(NookColors.surface)
                                        .nookSegmentShadow()
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .frame(minHeight: 36)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.05))
        )
    }
}
