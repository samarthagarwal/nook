import SwiftUI

public enum NookColors {
    // Canvas & Surfaces
    public static let paper = Color(hex: "#F7F4EE")
    public static let surface = Color(hex: "#FDFCF9")
    public static let surfaceSunken = Color(hex: "#F4F1EA")
    public static let canvas = Color(hex: "#EDE8DF")
    
    // Inks (Text & Contrasts)
    public static let ink = Color(hex: "#1B1815")
    public static let inkOnDark = Color(hex: "#FBF9F5")
    
    // Opacity Variants of Ink: rgb(27, 24, 21)
    public static let ink70 = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.70)
    public static let ink62 = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.62)
    public static let ink55 = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.55)
    public static let ink45 = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.45)
    public static let ink40 = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.40)
    public static let ink30 = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.30)
    public static let ink25 = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.25)
    public static let ink18 = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.18)
    public static let ink11 = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.11)
    
    // Borders & Fills
    public static let hairline = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.09)
    public static let hairlineStrong = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.13)
    public static let fill = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.06)
    public static let toggleOff = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.14)
    public static let scrim = Color(red: 27/255.0, green: 24/255.0, blue: 21/255.0, opacity: 0.34)
    
    // Privacy Language Accents (Never use decoratively)
    // Blue = Local / On-Device
    public static let local = Color(hex: "#2F5D8A")
    public static let localSoft = Color(red: 47/255.0, green: 93/255.0, blue: 138/255.0, opacity: 0.10)
    public static let localHairline = Color(red: 47/255.0, green: 93/255.0, blue: 138/255.0, opacity: 0.35)
    public static let citationHighlight = Color(red: 47/255.0, green: 93/255.0, blue: 138/255.0, opacity: 0.14)
    
    // Ochre = External / Leaves Device
    public static let external = Color(hex: "#8C6239")
    public static let externalSoft = Color(red: 140/255.0, green: 98/255.0, blue: 57/255.0, opacity: 0.05)
    public static let externalHairline = Color(red: 140/255.0, green: 98/255.0, blue: 57/255.0, opacity: 0.35)
}

extension Color {
    public init(hex: String) {
        let cleanHex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleanHex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
