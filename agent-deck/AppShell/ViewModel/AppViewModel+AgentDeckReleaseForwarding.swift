import Foundation

// MARK: - Agent Deck release host

extension AppViewModel: AgentDeckReleaseHost {
    var selectedReleaseSession: PiAgentSessionRecord? {
        piAgentSessionStore.selectedSession
    }

    func gitHubRemoteName(forProjectPath path: String) -> String? {
        projectByPath[path]?.gitHubRemote?.nameWithOwner
    }

    func defaultReleaseModel() -> AvailableModel? {
        defaultPiAgentModel()
    }

    func appendReleaseSucceededStatus(sessionID: UUID, tag: String) {
        piAgentSessionStore.append(.init(
            sessionID: sessionID,
            role: .status,
            title: "Release Pushed",
            text: "Tagged and pushed \(tag). CI build is now running."
        ))
    }
}

// MARK: - Agent Deck release view/API compatibility

extension AppViewModel {
    var agentDeckReleaseService: ReleaseService { agentDeckRelease.service }

    var shouldShowAgentDeckReleaseAction: Bool { agentDeckRelease.shouldShowReleaseAction }

    var agentDeckReleaseProjectURL: URL? { agentDeckRelease.releaseProjectURL }

    func generateAgentDeckReleaseNotes(version: String, sinceTag: String?) async throws -> String {
        try await agentDeckRelease.generateReleaseNotes(version: version, sinceTag: sinceTag)
    }

    func recordAgentDeckReleaseSucceeded(tag: String) {
        agentDeckRelease.recordReleaseSucceeded(tag: tag)
    }
}
