import Foundation

// MARK: - Pi Agent git ship host

extension AppViewModel: PiAgentGitShipHost {
    var keepWorktreeAfterMerge: Bool {
        appSettings.piAgentSessionsKeepWorktreeAfterMerge
    }

    func repositoryChangesEntry(for projectPath: String) -> RepositoryChangesCacheEntry? {
        github.repositoryChangesEntry(for: projectPath)
    }

    func refreshSelectedSessionRepoChanges(force: Bool) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let repoRoot = session.repositoryRoot
        github.refreshRepositoryChanges(
            forProjectPath: repoRoot,
            preservingDiffSelection: true,
            force: force,
            activeContextIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.piAgentSessionStore.selectedSession?.repositoryRoot == repoRoot
                    || self.selectedDiscoveredProject?.path == repoRoot
            }
        )
    }
}

// MARK: - Pi Agent git ship view/API compatibility

extension AppViewModel {
    var shouldShowPiAgentGitActions: Bool { piGitShip.shouldShowGitActions }

    var shouldShowCommitSelectedPiAgentSession: Bool { piGitShip.shouldShowCommitSelectedSession }
    var shouldShowPushSelectedPiAgentSession: Bool { piGitShip.shouldShowPushSelectedSession }
    var canCommitSelectedPiAgentSession: Bool { piGitShip.canCommitSelectedSession }
    var canPushSelectedPiAgentSession: Bool { piGitShip.canPushSelectedSession }
    var canCommitAndPushSelectedPiAgentSession: Bool { piGitShip.canCommitAndPushSelectedSession }
    var shouldShowMergeSelectedPiAgentSession: Bool { piGitShip.shouldShowMergeSelectedSession }
    var canMergeSelectedPiAgentSession: Bool { piGitShip.canMergeSelectedSession }

    func commitSelectedPiAgentSession() { piGitShip.commitSelectedSession() }
    func commitAndPushSelectedPiAgentSession() { piGitShip.commitAndPushSelectedSession() }
    func pushSelectedPiAgentSession() { piGitShip.pushSelectedSession() }
    func mergeSelectedPiAgentSession() { piGitShip.mergeSelectedSession() }

    func prepareRepoChangesForSelectedPiAgentSession(force: Bool = false) {
        piGitShip.prepareRepoChangesForSelectedSession(force: force)
    }
}
