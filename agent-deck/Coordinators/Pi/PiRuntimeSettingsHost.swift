import Foundation

@MainActor
protocol PiRuntimeSettingsHost: AnyObject {
    func reportPiRuntimeSettingsWriteError(_ message: String)
}
