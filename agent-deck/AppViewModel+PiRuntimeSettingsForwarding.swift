import Foundation

// MARK: - Pi runtime settings host

extension AppViewModel: PiRuntimeSettingsHost {
    func reportPiRuntimeSettingsWriteError(_ message: String) {
        github.githubLastError = message
    }
}

// MARK: - Pi runtime settings view/API compatibility

extension AppViewModel {
    var piRuntimeSettingsRevision: Int { piRuntime.settingsRevision }

    func readPiRuntimeDefaults() -> (provider: String?, model: String?, thinkingLevel: String?) {
        piRuntime.readDefaults()
    }

    func setDefaultPiAgentModel(_ model: AvailableModel?) {
        piRuntime.setDefaultModel(model)
    }

    func setDefaultPiAgentThinkingLevel(_ level: String) {
        piRuntime.setDefaultThinkingLevel(level)
    }
}
