import AppKit

/// User-pickable Dock icon.
///
/// macOS has no first-class alternate-icon API (`UIApplication
/// .setAlternateIconName(_:)` is iOS-only). The supported macOS path is to
/// assign `NSApplication.applicationIconImage` at runtime — that updates the
/// Dock and menu-bar icon for the running app. The Finder file icon is
/// unchanged; the override has to be re-applied on each launch.
///
/// The variants ship as Icon Composer `.icon` files under the app target and
/// are compiled into `Assets.car` because the target has
/// `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES`. They are then
/// addressable by their filename via `NSImage(named:)`.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case classic = "agent-deck-icon"
    case alternate = "agent-deck-icon-alt"

    var id: String { rawValue }

    /// Asset-catalog name (the `.icon` filename without its extension).
    var assetName: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return "Default"
        case .alternate: return "Alternate"
        }
    }

    static let `default`: AppIconChoice = .classic

    static func choice(forStoredName name: String?) -> AppIconChoice {
        guard let name else { return .default }
        if let match = AppIconChoice(rawValue: name) { return match }

        // Old builds exposed four numbered alternate icons. If a user had one
        // selected, preserve the preference by mapping it to the remaining
        // alternate icon instead of silently reverting to default.
        if name.hasPrefix("agent-deck-icon-alt-") { return .alternate }
        return .default
    }

    /// Apply a choice to the running app. Setting `applicationIconImage` to
    /// `nil` reverts to the bundle's primary icon (the
    /// `ASSETCATALOG_COMPILER_APPICON_NAME` defined in the build settings).
    @MainActor
    static func apply(_ choice: AppIconChoice) {
        if choice == .default {
            NSApp?.applicationIconImage = nil
        } else if let image = NSImage(named: choice.assetName) {
            NSApp?.applicationIconImage = image
        }
    }
}
