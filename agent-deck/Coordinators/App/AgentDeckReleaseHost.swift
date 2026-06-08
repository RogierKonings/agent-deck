import Foundation

@MainActor
protocol AgentDeckReleaseHost: AnyObject {
    var selectedReleaseSession: PiAgentSessionRecord? { get }
    func gitHubRemoteName(forProjectPath path: String) -> String?
    func defaultReleaseModel() -> AvailableModel?
    func appendReleaseSucceededStatus(sessionID: UUID, tag: String)
}
