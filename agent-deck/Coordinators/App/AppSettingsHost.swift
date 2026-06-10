import Foundation

/// Side effects `AppSettingsCoordinator` delegates to the app shell after persisting settings.
struct AppSettingsSideEffects: OptionSet, Sendable {
    let rawValue: UInt

    static let syncOpenAIFastConfig = Self(rawValue: 1 << 0)
    static let reconfigureIdleParking = Self(rawValue: 1 << 1)
    static let refreshProjectsRoot = Self(rawValue: 1 << 2)
    static let applyActiveTheme = Self(rawValue: 1 << 3)
    static let applyMarkdownHighlighting = Self(rawValue: 1 << 4)
    static let applyAppIcon = Self(rawValue: 1 << 5)
    static let syncSubagentsNewSessionStore = Self(rawValue: 1 << 6)

    static let standard: Self = [.syncOpenAIFastConfig, .reconfigureIdleParking]
}

@MainActor
protocol AppSettingsHost: AnyObject {
    var appSettings: AppSettings { get set }
    var foundationAutomationModel: AvailableModel? { get }
    func applySettingsSideEffects(_ effects: AppSettingsSideEffects)
    func resolvedActiveTheme() -> Theme
}
