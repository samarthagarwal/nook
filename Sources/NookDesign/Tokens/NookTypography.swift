import SwiftUI

/// Nook typography — three roles, no drift.
///
/// | Role    | Spec                         | iOS implementation        |
/// |---------|------------------------------|---------------------------|
/// | Display | Newsreader 400 (Google Fonts) | New York via `.serif`     |
/// | UI      | System sans                  | SF Pro via `.default`     |
/// | Mono    | IBM Plex Mono                | SF Mono via `.monospaced` |
///
/// Display is for headings and the brand mark artwork. The app icon and onboarding
/// logo are raster assets set in Newsreader; on device, heading text uses New York
/// as the bundled serif substitute.
public enum NookTypography {
    // MARK: - Display (Newsreader 400 → New York)

    public static let heroDisplay = display(46)
    public static let titleXL = display(34)
    public static let tabRootTitle = display(32)
    public static let detailTitle = display(26)
    public static let sheetTitle = display(24)
    public static let display21 = display(21)
    public static let cardTitleSerif = display(19)

    /// Display tracking from `design-tokens.json` (em → points at given size).
    public static let heroDisplayTracking: CGFloat = -0.69   // -0.015em @ 46pt
    public static let titleXLTracking: CGFloat = -0.34       // -0.01em @ 34pt
    public static let tabRootTitleTracking: CGFloat = -0.32   // -0.01em @ 32pt

    // MARK: - UI (SF Pro)

    public static let buttonLabel = ui(16, weight: .medium)
    public static let assistantBody = ui(15)
    public static let userBubble = ui(14.5)
    public static let rowTitle = ui(14.5, weight: .medium)
    public static let body = ui(13.5)
    public static let cardSub = ui(12.5)
    public static let meta = ui(11.5)

    // MARK: - Mono (IBM Plex Mono → SF Mono)

    public static let eyebrow = mono(10, weight: .medium)
    public static let badge = mono(10.5)
    public static let badgeMedium = mono(10.5, weight: .medium)
    public static let fileName = mono(12.5)
    public static let fileNameLg = mono(14)
    public static let code = mono(11.5)
    public static let tabLabel = mono(10.5)
    public static let tabLabelActive = mono(10.5, weight: .medium)

    // MARK: - Factories

    public static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .serif)
    }

    public static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .default)
    }

    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }
}

public struct NookEyebrowModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .font(NookTypography.eyebrow)
            .tracking(1.3)
            .textCase(.uppercase)
    }
}

public struct NookHeroDisplayModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .font(NookTypography.heroDisplay)
            .tracking(NookTypography.heroDisplayTracking)
    }
}

extension View {
    public func nookEyebrow() -> some View {
        modifier(NookEyebrowModifier())
    }

    public func nookHeroDisplay() -> some View {
        modifier(NookHeroDisplayModifier())
    }
}
