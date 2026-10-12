import AppKit
import SwiftUI

enum UsageTheme {
    static let background = adaptive(dark: "151619", light: "F6F7F9")
    static let card = adaptive(dark: "202126", light: "FFFFFF")
    static let elevated = adaptive(dark: "292B31", light: "ECEEF1")
    static let separator = adaptive(dark: "34363D", light: "E2E4E9")
    static let primaryText = adaptive(dark: "F2F2F4", light: "202127")
    static let secondaryText = adaptive(dark: "A0A3AD", light: "676B75")
    static let mutedText = adaptive(dark: "717580", light: "9296A0")
    static let codex = adaptive(dark: "55B8A6", light: "218B7E")
    static let claude = adaptive(dark: "D99A76", light: "B77450")
    static let warning = adaptive(dark: "E4AD55", light: "BD8124")
    static let critical = adaptive(dark: "EB6A6A", light: "CD4747")
    static let track = adaptive(dark: "34363D", light: "E2E4E9")

    static func provider(_ provider: Provider) -> Color { provider == .codex ? codex : claude }

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
