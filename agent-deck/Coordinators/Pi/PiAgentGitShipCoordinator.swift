import Foundation
import Observation

// MARK: - Pi Agent git ship (commit / push / merge)

@MainActor
@Observable
final class PiAgentGitShipCoordinator {
    weak var host: PiAgentGitShipHost?

    private let sessionStore: PiAgentSessionStore
    private let workspace: PiAgentWorkspaceState
    private let gitRepositoryService: GitRepositoryService
    private let shipService: PiAgentShipService
    private let sessionWorktreeService: PiAgentSessionWorktreeService

    init(
        sessionStore: PiAgentSessionStore,
        workspace: PiAgentWorkspaceState,
        gitRepositoryService: GitRepositoryService,
        shipService: PiAgentShipService,
        sessionWorktreeService: PiAgentSessionWorktreeService
    ) {
        self.sessionStore = sessionStore
        self.workspace = workspace
        self.gitRepositoryService = gitRepositoryService
        self.shipService = shipService
        self.sessionWorktreeService = sessionWorktreeService
    }

    var shouldShowGitActions: Bool {
        host?.piAgentCommitMessageModel() != nil
    }

    var shouldShowCommitSelectedSession: Bool {
        guard shouldShowGitActions,
              let session = sessionStore.selectedSession,
              let changes = host?.repositoryChangesEntry(for: session.repositoryRoot)?.snapshot else { return false }
        return changes.conflicted.isEmpty
            && (!changes.staged.isEmpty || !changes.unstaged.isEmpty || !changes.untracked.isEmpty)
    }

    var shouldShowPushSelectedSession: Bool {
        guard shouldShowGitActions,
              let session = sessionStore.selectedSession,
              let changes = host?.repositoryChangesEntry(for: session.repositoryRoot)?.snapshot else { return false }
        return changes.aheadCount > 0
    }

    var canCommitSelectedSession: Bool {
        guard shouldShowCommitSelectedSession,
              let session = sessionStore.selectedSession else { return false }
        return workspace.gitAutomationAction == nil && !session.status.isActive
    }

    var canPushSelectedSession: Bool {
        guard shouldShowPushSelectedSession,
              let session = sessionStore.selectedSession else { return false }
        return workspace.gitAutomationAction == nil && !session.status.isActive
    }

    var canCommitAndPushSelectedSession: Bool { canCommitSelectedSession }

    var shouldShowMergeSelectedSession: Bool {
        guard shouldShowGitActions,
              let session = sessionStore.selectedSession else { return false }
        return session.worktreePath != nil && session.branchName != nil && session.sourceBranch != nil
    }

    var canMergeSelectedSession: Bool {
        guard shouldShowMergeSelectedSession,
              let session = sessionStore.selectedSession,
              workspace.gitAutomationAction == nil,
              !session.status.isActive,
              let changes = host?.repositoryChangesEntry(for: session.repositoryRoot)?.snapshot else { return false }

        let hasUncommittedChanges = !changes.unstaged.isEmpty || !changes.untracked.isEmpty || !changes.conflicted.isEmpty || !changes.staged.isEmpty
        let hasCommittedBranchChanges = host?.repositoryChangesEntry(for: session.repositoryRoot)?.hasMergeableBranchChanges == true
        return hasUncommittedChanges || hasCommittedBranchChanges
    }

    func prepareRepoChangesForSelectedSession(force: Bool = false) {
        host?.refreshSelectedSessionRepoChanges(force: force)
    }

    func commitSelectedSession() {
        shipSelectedSession(pushAfterCommit: false)
    }

    func commitAndPushSelectedSession() {
        shipSelectedSession(pushAfterCommit: true)
    }

    func pushSelectedSession() {
        guard let session = sessionStore.selectedSession else { return }
        let sessionID = session.id
        let branchName = session.branchName ?? "current branch"
        let projectURL = URL(fileURLWithPath: session.repositoryRoot, isDirectory: true)
        workspace.setGitAutomationAction(.push)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await gitRepositoryService.pushCurrentBranch(in: projectURL)
                await MainActor.run {
                    self.workspace.setGitAutomationAction(nil)
                    self.sessionStore.append(.init(sessionID: sessionID, role: .status, title: "Push Completed", text: "Pushed \(branchName)"))
                    self.prepareRepoChangesForSelectedSession(force: true)
                }
            } catch {
                await MainActor.run {
                    self.workspace.setGitAutomationAction(nil)
                    self.sessionStore.append(.init(sessionID: sessionID, role: .error, title: "Push Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedSession(force: true)
                }
            }
        }
    }

    func mergeSelectedSession() {
        guard let session = sessionStore.selectedSession,
              let worktreePath = session.worktreePath,
              let branchName = session.branchName,
              let sourceBranch = session.sourceBranch else { return }
        guard let model = host?.piAgentCommitMessageModel() else {
            sessionStore.append(.init(sessionID: session.id, role: .error, title: "Merge Failed", text: PiAgentShipService.ShipError.noModel.localizedDescription))
            return
        }
        let sessionID = session.id
        let projectURL = URL(fileURLWithPath: session.projectPath, isDirectory: true)
        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: worktreeURL)
        let keepWorktreeAfterMerge = host?.keepWorktreeAfterMerge ?? false
        workspace.setGitAutomationAction(.merge)

        Task { [weak self] in
            guard let self else { return }
            do {
                do {
                    let message = try await self.performAutoCommit(workingURL: worktreeURL, model: model, environment: environment)
                    await MainActor.run {
                        self.sessionStore.append(.init(sessionID: sessionID, role: .status, title: "Committed Changes", text: "Committed `\(message.title)` on `\(branchName)` before merging."))
                    }
                } catch PiAgentShipService.ShipError.noChanges {
                    // Nothing to stage — proceed; the commits-ahead check below decides.
                }

                let ahead = try await self.gitRepositoryService.commitsAhead(branch: branchName, base: sourceBranch, in: projectURL)
                guard ahead > 0 else {
                    throw NSError(domain: "AgentDeckMerge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Nothing to merge: `\(branchName)` has no commits ahead of `\(sourceBranch)`. The worktree and branch were left in place."])
                }

                let parentClean = try await self.gitRepositoryService.isClean(in: projectURL)
                guard parentClean else {
                    throw NSError(domain: "AgentDeckMerge", code: 1, userInfo: [NSLocalizedDescriptionKey: "The project repository has uncommitted changes. Commit, stash, or discard them before merging."])
                }

                guard try await self.gitRepositoryService.hasBranch(sourceBranch, in: projectURL) else {
                    throw NSError(domain: "AgentDeckMerge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Source branch `\(sourceBranch)` no longer exists in the project."])
                }

                let parentBranch = try await self.gitRepositoryService.currentBranch(in: projectURL)
                if parentBranch != sourceBranch {
                    try await self.gitRepositoryService.checkoutBranch(sourceBranch, in: projectURL)
                }

                let outcome = try await self.gitRepositoryService.merge(branch: branchName, in: projectURL)
                switch outcome {
                case .success:
                    if keepWorktreeAfterMerge {
                        await MainActor.run {
                            self.workspace.setGitAutomationAction(nil)
                            self.sessionStore.append(.init(
                                sessionID: sessionID,
                                role: .status,
                                title: "Merge Completed",
                                text: "Merged \(branchName) into \(sourceBranch)."
                            ))
                            self.prepareRepoChangesForSelectedSession(force: true)
                        }
                        return
                    }
                    await MainActor.run {
                        self.sessionStore.append(.init(sessionID: sessionID, role: .status, title: "Merge Completed", text: "Merged \(branchName) into \(sourceBranch)"))
                    }
                    let cleanupResult: Result<PiAgentBranchDeletionOutcome, Error>
                    do {
                        let outcome = try await self.sessionWorktreeService.removeWorktree(
                            worktreePath: worktreeURL.path,
                            projectURL: projectURL,
                            branchName: branchName,
                            sourceBranch: sourceBranch,
                            deleteBranch: true
                        )
                        cleanupResult = .success(outcome)
                    } catch {
                        cleanupResult = .failure(error)
                    }
                    await MainActor.run {
                        self.workspace.setGitAutomationAction(nil)
                        switch cleanupResult {
                        case .success(let cleanupOutcome):
                            self.sessionStore.updateSession(sessionID) { record in
                                record.worktreePath = nil
                                record.sourceBranch = nil
                                switch cleanupOutcome {
                                case .deleted, .skippedNoBranchName, .skippedNotRequested:
                                    record.branchName = nil
                                case .retainedUnmerged:
                                    break
                                }
                            }
                            switch cleanupOutcome {
                            case .deleted:
                                self.sessionStore.append(.init(sessionID: sessionID, role: .status, title: "Worktree Removed", text: "Removed worktree and deleted \(branchName)."))
                            case .skippedNoBranchName, .skippedNotRequested:
                                self.sessionStore.append(.init(sessionID: sessionID, role: .status, title: "Worktree Removed", text: "Removed worktree."))
                            case let .retainedUnmerged(reason):
                                self.sessionStore.append(.init(sessionID: sessionID, role: .error, title: "Branch Retained", text: "Merged into `\(sourceBranch)` and removed the worktree, but branch `\(branchName)` was not deleted: \(reason). Delete it manually with `git branch -D \(branchName)` once you've checked."))
                            }
                        case .failure(let cleanupError):
                            self.sessionStore.append(.init(sessionID: sessionID, role: .error, title: "Worktree Cleanup Failed", text: "The merge into `\(sourceBranch)` succeeded, but the worktree at `\(worktreeURL.path)` could not be cleaned up: \(cleanupError.localizedDescription)."))
                        }
                        self.prepareRepoChangesForSelectedSession(force: true)
                    }
                case let .conflict(status):
                    await MainActor.run {
                        self.workspace.setGitAutomationAction(nil)
                        self.sessionStore.append(.init(sessionID: sessionID, role: .error, title: "Merge Conflict", text: "Merge of `\(branchName)` into `\(sourceBranch)` left conflicts. Resolve them in the project, then commit.\n\n\(status)"))
                        self.prepareRepoChangesForSelectedSession(force: true)
                    }
                }
            } catch let skipError as NSError where skipError.domain == "AgentDeckMerge" && skipError.code == 3 {
                await MainActor.run {
                    self.workspace.setGitAutomationAction(nil)
                    self.sessionStore.append(.init(sessionID: sessionID, role: .error, title: "Merge Skipped", text: skipError.localizedDescription))
                    self.prepareRepoChangesForSelectedSession(force: true)
                }
            } catch {
                await MainActor.run {
                    self.workspace.setGitAutomationAction(nil)
                    self.sessionStore.append(.init(sessionID: sessionID, role: .error, title: "Merge Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedSession(force: true)
                }
            }
        }
    }

    // MARK: - Private

    private func shipSelectedSession(pushAfterCommit: Bool) {
        guard let session = sessionStore.selectedSession else { return }
        guard let model = host?.piAgentCommitMessageModel() else {
            sessionStore.append(.init(sessionID: session.id, role: .error, title: "Ship Failed", text: PiAgentShipService.ShipError.noModel.localizedDescription))
            return
        }

        let sessionID = session.id
        let projectURL = URL(fileURLWithPath: session.repositoryRoot, isDirectory: true)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectURL)
        workspace.setGitAutomationAction(pushAfterCommit ? .commitAndPush : .commit)

        Task { [weak self] in
            guard let self else { return }
            do {
                let message = try await self.performAutoCommit(workingURL: projectURL, model: model, environment: environment)
                if pushAfterCommit {
                    try await gitRepositoryService.pushCurrentBranch(in: projectURL)
                }

                await MainActor.run {
                    self.workspace.setGitAutomationAction(nil)
                    self.sessionStore.append(.init(sessionID: sessionID, role: .status, title: pushAfterCommit ? "Commit & Push Completed" : "Commit Completed", text: pushAfterCommit ? "Committed and pushed “\(message.title)”" : "Committed “\(message.title)”"))
                    self.prepareRepoChangesForSelectedSession(force: true)
                }
            } catch {
                await MainActor.run {
                    self.workspace.setGitAutomationAction(nil)
                    self.sessionStore.append(.init(sessionID: sessionID, role: .error, title: pushAfterCommit ? "Commit & Push Failed" : "Commit Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedSession(force: true)
                }
            }
        }
    }

    private func performAutoCommit(
        workingURL: URL,
        model: AvailableModel,
        environment: [String: String]
    ) async throws -> PiAgentShipService.CommitMessage {
        let before = try await gitRepositoryService.loadChanges(in: workingURL)
        if !before.conflicted.isEmpty { throw PiAgentShipService.ShipError.conflicts }
        if before.staged.isEmpty && before.unstaged.isEmpty && before.untracked.isEmpty {
            throw PiAgentShipService.ShipError.noChanges
        }

        try await gitRepositoryService.stageAll(in: workingURL)
        let status = try await gitRepositoryService.statusText(in: workingURL)
        let diff = try await gitRepositoryService.stagedDiffForCommitMessage(in: workingURL)
        let message = try await withCheckedThrowingContinuation { continuation in
            shipService.generateCommitMessage(status: status, diff: diff, model: model, projectURL: workingURL, environment: environment) { result in
                continuation.resume(with: result)
            }
        }
        try await gitRepositoryService.commit(message: message.title, description: message.body, in: workingURL)
        return message
    }
}
