import SwiftUI

public enum NookRadius {
    public static let tag: CGFloat = 6
    public static let chip: CGFloat = 8
    public static let chipLg: CGFloat = 9
    public static let row: CGFloat = 11
    public static let card: CGFloat = 12
    public static let cardLg: CGFloat = 13
    public static let button: CGFloat = 14
    public static let pill: CGFloat = 19
    public static let pillLg: CGFloat = 20
    public static let sheet: CGFloat = 22
    public static let toggleTrack: CGFloat = 26
}

public enum NookSpacing {
    public static let s3: CGFloat = 3
    public static let s5: CGFloat = 5
    public static let s6: CGFloat = 6
    public static let s7: CGFloat = 7
    public static let s8: CGFloat = 8
    public static let s9: CGFloat = 9
    public static let s10: CGFloat = 10
    public static let s11: CGFloat = 11
    public static let s12: CGFloat = 12
    public static let s14: CGFloat = 14
    public static let s16: CGFloat = 16
    public static let s18: CGFloat = 18
    public static let s20: CGFloat = 20
    public static let s22: CGFloat = 22
    public static let s26: CGFloat = 26
    public static let s36: CGFloat = 36
    public static let s44: CGFloat = 44
}

public struct NookCardShadow: ViewModifier {
    public func body(content: Content) -> some View {
        content.shadow(color: Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.04), radius: 2, x: 0, y: 1)
    }
}

public struct NookSheetShadow: ViewModifier {
    public func body(content: Content) -> some View {
        content.shadow(color: Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.28), radius: 50, x: 0, y: 20)
    }
}

public struct NookToastShadow: ViewModifier {
    public func body(content: Content) -> some View {
        content.shadow(color: Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.25), radius: 30, x: 0, y: 12)
    }
}

public struct NookSegmentShadow: ViewModifier {
    public func body(content: Content) -> some View {
        content.shadow(color: Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.08), radius: 2, x: 0, y: 1)
    }
}

extension View {
    public func nookCardShadow() -> some View {
        self.modifier(NookCardShadow())
    }
    public func nookSheetShadow() -> some View {
        self.modifier(NookSheetShadow())
    }
    public func nookToastShadow() -> some View {
        self.modifier(NookToastShadow())
    }
    public func nookSegmentShadow() -> some View {
        self.modifier(NookSegmentShadow())
    }
}
