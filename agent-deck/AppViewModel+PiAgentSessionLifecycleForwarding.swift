import AppKit
import Foundation

// MARK: - Pi Agent session lifecycle host

extension AppViewModel: PiAgentSessionLifecycleHost {
    func showAgentSidebar() {
        selectedSidebarItem = .agent
    }

    func isSessionActuallyVisible(_ sessionID: UUID) -> Bool {
        NSApp.isActive
            && selectedSidebarItem == .agent
            && piAgentSessionStore.selectedSession?.id == sessionID
            && (NSApp.keyWindow?.isVisible ?? NSApp.mainWindow?.isVisible ?? false)
    }

    func shouldSendSystemNotification() -> Bool {
        !NSApp.isActive || !(NSApp.keyWindow?.isVisible ?? NSApp.mainWindow?.isVisible ?? false)
    }

    func ensureModelCatalogLoaded() {
        ensurePiAgentModelCatalogLoaded()
    }

    func prepareRepoChanges(force: Bool) {
        prepareRepoChangesForSelectedPiAgentSession(force: force)
    }

    func refreshRepoChangesAfterStop() {
        guard let session = piAgentSessionStore.selectedSession,
              selectedProjectPath == session.projectPath else { return }
        github.refreshRepositoryChanges(preservingDiffSelection: true)
        if session.repositoryRoot != session.projectPath {
            prepareRepoChangesForSelectedPiAgentSession(force: true)
        }
    }

    var shouldShowGitActions: Bool { shouldShowPiAgentGitActions }

    func scopedSessionsInOrder() -> [PiAgentSessionRecord] {
        scopedPiAgentSessionsInOrder()
    }

    func projectContext() -> DiscoveredProject {
        piAgentSessionProjectContext()
    }

    func rehydrateTranscript(session: PiAgentSessionRecord) {
        piRunner.rehydrateTranscript(session: session)
    }

    func stopRunningSession(_ sessionID: UUID, recordTranscript: Bool) {
        piRunner.stop(sessionID: sessionID, recordTranscript: recordTranscript)
    }

    func isRunning(_ sessionID: UUID) -> Bool {
        piRunner.isRunning(sessionID: sessionID)
    }

    func startProjectSession(project: DiscoveredProject, initialInstruction: String) {
        piRunner.startProjectSession(project: project, initialInstruction: initialInstruction)
    }

    func resumeSession(_ session: PiAgentSessionRecord, initialPrompt: String) {
        piRunner.resume(session: session, initialPrompt: initialPrompt)
    }

    func configureIdleParking(timeout: TimeInterval?) {
        piRunner.configureIdleParking(timeout: timeout)
    }

    var sessionsUseWorktree: Bool { appSettings.piAgentSessionsUseWorktree }

    var notificationDelay: TimeInterval {
        TimeInterval(piAgentNotificationDelayMinutes * 60)
    }

    var idleParkingTimeout: TimeInterval? {
        guard isPiAgentIdleParkingEnabled else { return nil }
        return TimeInterval(piAgentIdleParkingTimeoutMinutes * 60)
    }

    func reportGitHubError(_ message: String) {
        github.githubLastError = message
    }

    var hasAuthenticatedGitHubSession: Bool {
        github.authenticatedSession != nil
    }

    func fetchIssueDetail(for item: GitHubWorkItem) async throws -> GitHubIssueDetail {
        guard let session = github.authenticatedSession else {
            throw NSError(domain: "AgentDeckGitHub", code: 1, userInfo: [NSLocalizedDescriptionKey: "Connect GitHub first."])
        }
        let service = GitHubIssueService(apiClient: GitHubAPIClient(session: session))
        return try await service.fetchDetail(for: item, bypassCache: false)
    }

    func setPendingIssueLaunch(composerText: String, attachment: PiAgentIssueAttachment) {
        piWorkspace.setPendingIssueLaunch(composerText: composerText, attachment: attachment)
    }
}

// MARK: - Pi Agent session lifecycle view/API compatibility

extension AppViewModel {
    func openPiAgentForSelectedProject() { piSessions.openForSelectedProject() }
    func createPiAgentDraftForSelectedProject() { piSessions.createDraftForSelectedProject() }
    func createPiAgentDraft(for project: DiscoveredProject) { piSessions.createDraft(for: project) }
    func startPiAgentForSelectedProject(initialInstruction: String) { piSessions.startForSelectedProject(initialInstruction: initialInstruction) }
    func startPiAgentForIssue(_ detail: GitHubIssueDetail) { piSessions.startForIssue(detail) }
    func startPiAgentForWorkItem(_ item: GitHubWorkItem) { piSessions.startForWorkItem(item) }
    func openPiAgentScreen() { piSessions.openAgentScreen() }
    func selectPiAgentSession(_ id: UUID) { piSessions.selectSession(id) }
    func rehydratePiAgentTranscriptIfNeeded(_ sessionID: UUID?) { piSessions.rehydrateTranscriptIfNeeded(sessionID) }
    func selectAdjacentPiAgentSession(offset: Int) { piSessions.selectAdjacentSession(offset: offset) }
    func selectNextPiAgentSession() { piSessions.selectNextSession() }
    func selectPreviousPiAgentSession() { piSessions.selectPreviousSession() }
    var canNavigatePiAgentSessions: Bool { piSessions.canNavigateSessions }
    func acknowledgeVisibleSelectedPiAgentSession() { piSessions.acknowledgeVisibleSelectedSession() }
    func acknowledgePiAgentSession(_ id: UUID) { piSessions.acknowledgeSession(id) }
    func stopSelectedPiAgentSession() { piSessions.stopSelectedSession() }
    func isPiAgentSessionRunning(_ sessionID: UUID) -> Bool { piSessions.isSessionRunning(sessionID) }
    func deletePiAgentSession(_ sessionID: UUID) { piSessions.deleteSession(sessionID) }
    func deletePiAgentSessions(_ sessionIDs: Set<UUID>) { piSessions.deleteSessions(sessionIDs) }

    func provisionWorktreeIfEnabled(for sessionID: UUID, project: DiscoveredProject) async {
        await piSessions.provisionWorktreeIfEnabled(for: sessionID, project: project)
    }
}
