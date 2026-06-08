import Foundation

// MARK: - Pi terminal host

extension AppViewModel: PiTerminalHost {
    var piAgentTerminalApplicationPath: String? { appSettings.piAgentTerminalApplicationPath }

    func onTerminalResumeOpened(forSessionID id: UUID) {
        piSessions.acknowledgeSession(id)
    }
}

// MARK: - Pi terminal view/API compatibility

extension AppViewModel {
    var canOpenSelectedPiAgentSessionInTerminal: Bool {
        piTerminal.canOpenSelectedSessionInTerminal
    }

    func openPiSelfUpdateInTerminal() {
        piTerminal.openPiSelfUpdateInTerminal()
    }

    func openPiInstallInTerminal() {
        piTerminal.openPiInstallInTerminal()
    }

    func openTerminalShellScript(named: String, body: String) {
        piTerminal.openShellScript(named: named, body: body)
    }

    func openSelectedPiAgentSessionInTerminal() {
        piTerminal.openSelectedSessionInTerminal()
    }
}
