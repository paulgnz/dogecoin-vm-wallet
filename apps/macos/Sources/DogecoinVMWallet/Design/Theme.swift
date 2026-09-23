import SwiftUI
import AppKit

/// The colours of metaldoge.com: navy ink, Dogecoin gold, DogecoinVM teal.
enum Theme {
    static let ink = Color(light: 0x16233A, dark: 0xE7ECF2)
    static let inkSoft = Color(light: 0x4A576B, dark: 0xA3AFC0)
    static let coin = Color(light: 0xB8912A, dark: 0xD4AB45)
    static let coinInk = Color(light: 0x7D5F10, dark: 0xE2C46D)
    static let coinWash = Color(light: 0xF4ECD6, dark: 0x2A2A24)
    static let vm = Color(light: 0x1D6F6A, dark: 0x4FB3A9)
    static let vmInk = Color(light: 0x1D6F6A, dark: 0x7FD0C7)
    static let vmWash = Color(light: 0xD9ECE9, dark: 0x1B3438)
    static let band = Color(hex: 0xF2B33D)
    static let bad = Color(light: 0xB3261E, dark: 0xFF9B92)

    static let mono = Font.system(.body, design: .monospaced)

    static func color(for network: Network) -> Color { network == .dogecoin ? coin : vm }
    static func ink(for network: Network) -> Color { network == .dogecoin ? coinInk : vmInk }
    static func wash(for network: Network) -> Color { network == .dogecoin ? coinWash : vmWash }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// A colour that follows the system's light or dark appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
