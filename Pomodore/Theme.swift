import SwiftUI

extension Phase {
    var accent: Color { isBreak ? .basil : .tomato }
}

extension Color {
    static let tomato = dynamic(light: 0xC4_3F_2C, dark: 0xE8_60_4A)
    static let basil = dynamic(light: 0x3F_7F_57, dark: 0x62_B5_85)

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: Int) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
