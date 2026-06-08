import Foundation
import Observation

@MainActor
@Observable
final class ProjectServerCoordinator {
    weak var host: ProjectServerHost?

    let service = ProjectServerService()

    func attach(host: ProjectServerHost) {
        self.host = host
    }

    func terminateAll() {
        service.terminateAll()
    }

    /// Whether the dev-server toolbar control should appear for the selected
    /// session: its project has a detectable dev server, or one is already
    /// running for it. Hidden for projects with no dev server (e.g. a Swift app)
    /// so the toolbar doesn't offer a control that can only report "none found".
    var shouldShowControls: Bool {
        guard let path = host?.selectedSessionProjectPath else { return false }
        if service.currentServer(forProjectPath: path) != nil { return true }
        return service.hasDetectedCommands(forProjectPath: path) == true
    }

    func start(for session: PiAgentSessionRecord, command: ServerCommand) {
        service.start(command: command, projectPath: session.projectPath, projectName: session.projectName)
        host?.appendProjectServerStatus(sessionID: session.id, title: "Dev Server Started", text: "Started dev server.")
    }

    func stop(for session: PiAgentSessionRecord, server: RunningServer) {
        service.stop(server)
        host?.appendProjectServerStatus(sessionID: session.id, title: "Dev Server Stopped", text: "Stopped dev server.")
    }

    func restart(for session: PiAgentSessionRecord, server: RunningServer) {
        service.restart(server)
        host?.appendProjectServerStatus(sessionID: session.id, title: "Dev Server Restarted", text: "Restarted dev server.")
    }
}
