import SwiftUI

public enum NookTypography {
    // Serif / Display (New York / Newsreader)
    public static let heroDisplay = Font.system(size: 46, weight: .regular, design: .serif)
    public static let titleXL = Font.system(size: 34, weight: .regular, design: .serif)
    public static let tabRootTitle = Font.system(size: 32, weight: .regular, design: .serif)
    public static let detailTitle = Font.system(size: 26, weight: .regular, design: .serif)
    public static let sheetTitle = Font.system(size: 24, weight: .regular, design: .serif)
    public static let display21 = Font.system(size: 21, weight: .regular, design: .serif)
    public static let cardTitleSerif = Font.system(size: 19, weight: .regular, design: .serif)
    
    // UI / Body (SF Pro)
    public static let buttonLabel = Font.system(size: 16, weight: .medium, design: .default)
    public static let assistantBody = Font.system(size: 15, weight: .regular, design: .default)
    public static let userBubble = Font.system(size: 14.5, weight: .regular, design: .default)
    public static let rowTitle = Font.system(size: 14.5, weight: .medium, design: .default)
    public static let body = Font.system(size: 13.5, weight: .regular, design: .default)
    public static let cardSub = Font.system(size: 12.5, weight: .regular, design: .default)
    public static let meta = Font.system(size: 11.5, weight: .regular, design: .default)
    
    // Mono (SF Mono / IBM Plex Mono)
    public static let eyebrow = Font.system(size: 10, weight: .medium, design: .monospaced)
    public static let badge = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let badgeMedium = Font.system(size: 10.5, weight: .medium, design: .monospaced)
    public static let fileName = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    public static let fileNameLg = Font.system(size: 14, weight: .regular, design: .monospaced)
    public static let code = Font.system(size: 11.5, weight: .regular, design: .monospaced)
    public static let tabLabel = Font.system(size: 10.5, weight: .regular, design: .monospaced)
    public static let tabLabelActive = Font.system(size: 10.5, weight: .medium, design: .monospaced)
}

public struct NookEyebrowModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .font(NookTypography.eyebrow)
            .tracking(1.3)
            .textCase(.uppercase)
    }
}

extension View {
    public func nookEyebrow() -> some View {
        self.modifier(NookEyebrowModifier())
    }
}
