import Foundation

// MARK: - Project server host

extension AppViewModel: ProjectServerHost {
    var selectedSessionProjectPath: String? {
        piAgentSessionStore.selectedSession?.projectPath
    }

    func appendProjectServerStatus(sessionID: UUID, title: String, text: String) {
        piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: title, text: text))
    }
}

// MARK: - Project server view/API compatibility

extension AppViewModel {
    var projectServerService: ProjectServerService { projectServer.service }

    var shouldShowProjectServerControls: Bool { projectServer.shouldShowControls }

    func startProjectServer(for session: PiAgentSessionRecord, command: ServerCommand) {
        projectServer.start(for: session, command: command)
    }

    func stopProjectServer(for session: PiAgentSessionRecord, server: RunningServer) {
        projectServer.stop(for: session, server: server)
    }

    func restartProjectServer(for session: PiAgentSessionRecord, server: RunningServer) {
        projectServer.restart(for: session, server: server)
    }
}
