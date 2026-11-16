import SwiftUI
import UIKit

/// Light or dark, chosen in Settings.
enum AppTheme: String, CaseIterable {
    case light, dark

    static let storageKey = "theme"

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }
}

/// Colors from the mockup: light grey ground, near-black ink, and one red
/// accent (#C5050C) for recording and destructive actions. Each one follows
/// the color scheme.
enum Palette {
    static let bg = Color(light: 0xF9FAFB, dark: 0x0A0A0A)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1A1A1A)
    static let text = Color(light: 0x212121, dark: 0xE6E6E6)
    static let soft = Color(light: 0x444444, dark: 0xCCCCCC)
    static let muted = Color(light: 0x695F5E, dark: 0xB3B3B3)
    static let line = Color(light: 0xD4D4D5, dark: 0x303030)
    static let lineStrong = Color(light: 0xBEBEBF, dark: 0x404040)
    static let ink = Color(light: 0x1B1C1D, dark: 0xE6E6E6)
    static let onInk = Color(light: 0xFFFFFF, dark: 0x0A0A0A)
    static let red = Color(light: 0xC5050C, dark: 0xC5050C)
    static let green = Color(light: 0x1F8A5B, dark: 0x3DBE84)
    static let off = Color(light: 0x999999, dark: 0x555555)
    static let track = Color(light: 0xEDEDED, dark: 0x262626)
    static let band = Color(light: 0xE6E6E6, dark: 0x2A2A2A)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension Font {
    /// Monospaced, for codes and numbers.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}
