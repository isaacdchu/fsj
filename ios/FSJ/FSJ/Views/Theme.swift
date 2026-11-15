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

/// Colors from the mockup: ice grey ground, ink, and rink red only while
/// recording or for destructive actions. Each one follows the color scheme.
enum Palette {
    static let bg = Color(light: 0xF3F5F7, dark: 0x0D1217)
    static let surface = Color(light: 0xFFFFFF, dark: 0x161D24)
    static let text = Color(light: 0x10161D, dark: 0xE8EDF1)
    static let soft = Color(light: 0x3C4651, dark: 0xC3CCD4)
    static let muted = Color(light: 0x5A6672, dark: 0x93A0AC)
    static let line = Color(light: 0xDDE3E8, dark: 0x26303A)
    static let lineStrong = Color(light: 0xC9D1D8, dark: 0x36424E)
    static let ink = Color(light: 0x10161D, dark: 0xE8EDF1)
    static let onInk = Color(light: 0xFFFFFF, dark: 0x0D1217)
    static let red = Color(light: 0xC8372D, dark: 0xD9483A)
    static let green = Color(light: 0x1F8A5B, dark: 0x3DBE84)
    static let off = Color(light: 0xA3AEB8, dark: 0x4E5A66)
    static let track = Color(light: 0xEBEFF2, dark: 0x222B34)
    static let band = Color(light: 0xE3E8EC, dark: 0x2A3540)
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
