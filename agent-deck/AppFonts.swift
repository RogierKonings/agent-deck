import AppKit
import Foundation
import SwiftUI

enum AppFonts {
    static let kemcoPixelBold = "KemcoPixelBold"

    static func registerBundledFonts() {
        // Intentionally disabled for startup reliability. On macOS 26, CoreText's
        // CTFontManagerRegisterFontsForURL can raise an Objective-C exception
        // while constructing its CFError for this bundled font, before Swift can
        // inspect or recover from the error. The font accessor below safely falls
        // back to the system bold font when Kemco is unavailable.
    }

    static func kemcoPixelBold(size: CGFloat) -> Font {
        if let font = NSFont(name: kemcoPixelBold, size: size) {
            return Font(font)
        }
        return .system(size: size, weight: .bold)
    }
}
