import AppKit
import SwiftUI

enum DashboardTheme: String, CaseIterable, Identifiable, Sendable {
    case darkMinimal
    case slate
    case violet

    var id: String { rawValue }
    var title: String {
        switch self {
        case .darkMinimal: "Dark Minimal"
        case .slate: "Slate"
        case .violet: "Violet"
        }
    }

    static var current: Self {
        UserDefaults.standard.string(forKey: "dashboardTheme").flatMap(Self.init(rawValue:)) ?? .darkMinimal
    }

    func palette(isDark: Bool) -> Palette {
        switch (self, isDark) {
        case (.darkMinimal, true): Palette(background: "151619", card: "202126", elevated: "292B31", separator: "34363D", primary: "F2F2F4", secondary: "A0A3AD", muted: "717580", track: "34363D")
        case (.darkMinimal, false): Palette(background: "F6F7F9", card: "FFFFFF", elevated: "ECEEF1", separator: "E2E4E9", primary: "202127", secondary: "676B75", muted: "9296A0", track: "E2E4E9")
        case (.slate, true): Palette(background: "141A21", card: "1D2630", elevated: "283541", separator: "354451", primary: "F0F4F7", secondary: "A4B0BB", muted: "758391", track: "354451")
        case (.slate, false): Palette(background: "F1F5F8", card: "FFFFFF", elevated: "E7EEF3", separator: "D7E1E8", primary: "1D2A35", secondary: "5D6D7A", muted: "8998A4", track: "D7E1E8")
        case (.violet, true): Palette(background: "18151E", card: "231E2B", elevated: "2D2637", separator: "3C3448", primary: "F5F0FA", secondary: "AFA4BC", muted: "7D718A", track: "3C3448")
        case (.violet, false): Palette(background: "F7F4FA", card: "FFFFFF", elevated: "EEE8F4", separator: "DFD5E8", primary: "2A2332", secondary: "6F6478", muted: "94899D", track: "DFD5E8")
        }
    }

    struct Palette {
        let background, card, elevated, separator, primary, secondary, muted, track: String
    }
}

enum UsageTheme {
    private static var isDark: Bool {
        switch UserDefaults.standard.string(forKey: "appearance")?.lowercased() {
        case "light": return false
        case "dark": return true
        default: break
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    private static var palette: DashboardTheme.Palette { DashboardTheme.current.palette(isDark: isDark) }

    static var background: Color { color(palette.background) }
    static var card: Color { color(palette.card) }
    static var elevated: Color { color(palette.elevated) }
    static var separator: Color { color(palette.separator) }
    static var primaryText: Color { color(palette.primary) }
    static var secondaryText: Color { color(palette.secondary) }
    static var mutedText: Color { color(palette.muted) }
    static var track: Color { color(palette.track) }
    static let codex = adaptive(dark: "55B8A6", light: "218B7E")
    static let claude = adaptive(dark: "D99A76", light: "B77450")
    static let gemini = adaptive(dark: "AB87EA", light: "7952BD")
    static let antigravity = adaptive(dark: "82A9F5", light: "4C73C5")
    static let grok = adaptive(dark: "C0C3CC", light: "525660")
    static let warning = adaptive(dark: "E4AD55", light: "BD8124")
    static let critical = adaptive(dark: "EB6A6A", light: "CD4747")

    static func provider(_ provider: Provider) -> Color {
        switch provider {
        case .codex: codex
        case .claude: claude
        case .gemini: gemini
        case .antigravity: antigravity
        case .grok: grok
        default: secondaryText
        }
    }

    private static func color(_ hex: String) -> Color {
        let value = Int(hex, radix: 16) ?? 0
        return Color(.sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255, blue: Double(value & 0xff) / 255, opacity: 1)
    }

    private static func adaptive(dark: String, light: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            let value = Int(hex, radix: 16) ?? 0
            return NSColor(
                calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1
            )
        })
    }
}
