import Foundation

/// Side effects and app context `PiAgentSessionLifecycleCoordinator` delegates to the app shell.
@MainActor
protocol PiAgentSessionLifecycleHost: AnyObject {
    var windowID: UUID { get }

    func showAgentSidebar()
    func isSessionActuallyVisible(_ sessionID: UUID) -> Bool
    func shouldSendSystemNotification() -> Bool

    func ensureModelCatalogLoaded()
    func prepareRepoChanges(force: Bool)
    func refreshRepoChangesAfterStop()
    var shouldShowGitActions: Bool { get }

    func scopedSessionsInOrder() -> [PiAgentSessionRecord]
    func projectContext() -> DiscoveredProject
    var selectedDiscoveredProject: DiscoveredProject? { get }

    func rehydrateTranscript(session: PiAgentSessionRecord)
    func stopRunningSession(_ sessionID: UUID, recordTranscript: Bool)
    func isRunning(_ sessionID: UUID) -> Bool
    func startProjectSession(project: DiscoveredProject, initialInstruction: String)
    func resumeSession(_ session: PiAgentSessionRecord, initialPrompt: String)
    func configureIdleParking(timeout: TimeInterval?)

    var sessionsUseWorktree: Bool { get }
    var notificationDelay: TimeInterval { get }
    var idleParkingTimeout: TimeInterval? { get }

    func reportGitHubError(_ message: String)
    var hasAuthenticatedGitHubSession: Bool { get }
    func fetchIssueDetail(for item: GitHubWorkItem) async throws -> GitHubIssueDetail
    func setPendingIssueLaunch(composerText: String, attachment: PiAgentIssueAttachment)
    func applyDefaultSubagentsEnabledForNewSessions(_ isEnabled: Bool)
}
