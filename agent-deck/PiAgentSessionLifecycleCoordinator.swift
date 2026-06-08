import AppKit
import Foundation
import Observation
import UserNotifications

// MARK: - Pi Agent session lifecycle (selection, notifications, worktrees)

@MainActor
@Observable
final class PiAgentSessionLifecycleCoordinator {
    weak var host: PiAgentSessionLifecycleHost?

    private let sessionStore: PiAgentSessionStore
    private let sessionWorktreeService: PiAgentSessionWorktreeService
    private var pendingNotificationTasks: [UUID: Task<Void, Never>] = [:]

    init(
        sessionStore: PiAgentSessionStore,
        sessionWorktreeService: PiAgentSessionWorktreeService
    ) {
        self.sessionStore = sessionStore
        self.sessionWorktreeService = sessionWorktreeService
    }

    // MARK: - Open / create / start

    func openForSelectedProject() {
        guard let host else { return }
        host.showAgentSidebar()
        let project = host.projectContext()
        if sessionStore.selectedSession?.projectPath != project.path {
            let existing = sessionStore.sessions.first { $0.projectPath == project.path && $0.kind == .project }
            if let existing {
                selectSession(existing.id)
                host.ensureModelCatalogLoaded()
            } else {
                let created = sessionStore.createSession(
                    kind: .project,
                    title: "Project agent · \(project.name)",
                    project: project,
                    repository: project.gitHubRemote?.nameWithOwner
                )
                provisionWorktreeFireAndForget(for: created.id, project: project)
                host.ensureModelCatalogLoaded()
            }
        } else {
            acknowledgeVisibleSelectedSession()
        }
    }

    func createDraftForSelectedProject() {
        guard let host else { return }
        createDraft(for: host.projectContext())
    }

    func createDraft(for project: DiscoveredProject) {
        guard let host else { return }
        host.showAgentSidebar()
        let created = sessionStore.createSession(
            kind: .project,
            title: "Draft · \(project.name)",
            project: project,
            repository: project.gitHubRemote?.nameWithOwner
        )
        provisionWorktreeFireAndForget(for: created.id, project: project)
        host.ensureModelCatalogLoaded()
    }

    func startForSelectedProject(initialInstruction: String) {
        guard let host else { return }
        guard let project = host.selectedDiscoveredProject else {
            host.reportGitHubError("Select a project before starting Pi Agent.")
            host.showAgentSidebar()
            return
        }
        host.showAgentSidebar()

        if host.sessionsUseWorktree, project.isGitRepository {
            let title = initialInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").first.map(String.init) ?? "Project agent · \(project.name)"
            let session = sessionStore.createSession(
                kind: .project,
                title: title.isEmpty ? "New Agent Session" : String(title.prefix(80)),
                project: project,
                repository: project.gitHubRemote?.nameWithOwner
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.provisionWorktreeIfEnabled(for: session.id, project: project)
                guard let refreshed = self.sessionStore.sessions.first(where: { $0.id == session.id }) else { return }
                let prompt = PiIssuePromptBuilder.projectPrompt(project: project, initialInstruction: initialInstruction)
                self.host?.resumeSession(refreshed, initialPrompt: prompt)
            }
            return
        }

        host.startProjectSession(project: project, initialInstruction: initialInstruction)
    }

    func startForIssue(_ detail: GitHubIssueDetail) {
        guard let host else { return }
        guard let project = host.selectedDiscoveredProject else {
            host.reportGitHubError("Select the local project for this issue before starting Pi Agent.")
            return
        }
        host.showAgentSidebar()
        let created = sessionStore.createSession(
            kind: .issue,
            title: detail.item.title,
            project: project,
            repository: detail.item.repository,
            issueNumber: detail.item.number,
            issueURL: detail.item.url
        )
        provisionWorktreeFireAndForget(for: created.id, project: project)
        host.ensureModelCatalogLoaded()
        host.setPendingIssueLaunch(
            composerText: PiIssuePromptBuilder.issueDraft(detail: detail, project: project),
            attachment: PiAgentIssueAttachment(detail: detail)
        )
    }

    func startForWorkItem(_ item: GitHubWorkItem) {
        guard let host else { return }
        guard host.hasAuthenticatedGitHubSession else {
            host.reportGitHubError("Connect GitHub first.")
            return
        }
        guard host.selectedDiscoveredProject != nil else {
            host.reportGitHubError("Select the local project for this issue before starting Pi Agent.")
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let detail = try await host.fetchIssueDetail(for: item)
                await MainActor.run {
                    self.startForIssue(detail)
                }
            } catch {
                await MainActor.run {
                    host.reportGitHubError(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Selection / navigation

    func openAgentScreen() {
        host?.showAgentSidebar()
        if sessionStore.selectedSession?.id != nil {
            host?.ensureModelCatalogLoaded()
        }
        host?.prepareRepoChanges(force: false)
        acknowledgeVisibleSelectedSession()
    }

    func selectSession(_ id: UUID) {
        sessionStore.select(id)
        host?.showAgentSidebar()
        host?.ensureModelCatalogLoaded()
        host?.prepareRepoChanges(force: false)
        acknowledgeSession(id)
    }

    func rehydrateTranscriptIfNeeded(_ sessionID: UUID?) {
        guard let sessionID,
              let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        host?.rehydrateTranscript(session: session)
    }

    func selectAdjacentSession(offset: Int) {
        let sessions = host?.scopedSessionsInOrder() ?? sessionStore.sessions
        guard !sessions.isEmpty else { return }
        let currentID = sessionStore.selectedSessionID
        let currentIndex = sessions.firstIndex { $0.id == currentID } ?? 0
        let count = sessions.count
        let nextIndex = ((currentIndex + offset) % count + count) % count
        selectSession(sessions[nextIndex].id)
    }

    func selectNextSession() { selectAdjacentSession(offset: 1) }
    func selectPreviousSession() { selectAdjacentSession(offset: -1) }

    var canNavigateSessions: Bool {
        (host?.scopedSessionsInOrder() ?? sessionStore.sessions).count > 1
    }

    // MARK: - Attention / notifications

    func acknowledgeVisibleSelectedSession() {
        guard let sessionID = sessionStore.selectedSession?.id,
              host?.isSessionActuallyVisible(sessionID) == true else { return }
        acknowledgeSession(sessionID)
    }

    func acknowledgeSession(_ id: UUID) {
        pendingNotificationTasks[id]?.cancel()
        pendingNotificationTasks[id] = nil
        sessionStore.updateSession(id) { $0.needsAttention = false }
        let identifier = notificationIdentifier(for: id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func handleTurnFinished(_ sessionID: UUID) {
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        if host?.isSessionActuallyVisible(sessionID) == true {
            acknowledgeSession(sessionID)
            if host?.shouldShowGitActions == true,
               sessionStore.selectedSession?.id == sessionID {
                host?.prepareRepoChanges(force: true)
            }
            return
        }

        guard !session.needsAttention else { return }
        sessionStore.updateSession(sessionID) { record in
            record.status = .idle
            record.needsAttention = true
        }
        scheduleCompletionNotification(for: sessionID)
    }

    func cancelAllPendingNotifications() {
        for task in pendingNotificationTasks.values {
            task.cancel()
        }
        pendingNotificationTasks.removeAll()
    }

    func cancelPendingNotifications(for sessionIDs: Set<UUID>) {
        for sessionID in sessionIDs {
            pendingNotificationTasks[sessionID]?.cancel()
            pendingNotificationTasks.removeValue(forKey: sessionID)
        }
    }

    func configureIdleParking() {
        host?.configureIdleParking(timeout: host?.idleParkingTimeout)
    }

    // MARK: - Stop / delete

    func stopSelectedSession() {
        guard let sessionID = sessionStore.selectedSession?.id else { return }
        host?.stopRunningSession(sessionID, recordTranscript: true)
        host?.refreshRepoChangesAfterStop()
    }

    func isSessionRunning(_ sessionID: UUID) -> Bool {
        host?.isRunning(sessionID) ?? false
    }

    func deleteSession(_ sessionID: UUID) {
        deleteSessions([sessionID])
    }

    func deleteSessions(_ sessionIDs: Set<UUID>) {
        for sessionID in sessionIDs where host?.isRunning(sessionID) == true {
            host?.stopRunningSession(sessionID, recordTranscript: false)
        }

        cancelPendingNotifications(for: sessionIDs)

        let worktreeCleanups: [(worktreePath: String, projectPath: String, branchName: String?, sourceBranch: String?)] = sessionIDs.compactMap { id in
            guard let session = sessionStore.sessions.first(where: { $0.id == id }),
                  let worktreePath = session.worktreePath else { return nil }
            return (worktreePath, session.projectPath, session.branchName, session.sourceBranch)
        }

        sessionStore.deleteSessions(sessionIDs)

        for cleanup in worktreeCleanups {
            let projectURL = URL(fileURLWithPath: cleanup.projectPath, isDirectory: true)
            Task { [weak self] in
                try? await self?.sessionWorktreeService.removeWorktree(
                    worktreePath: cleanup.worktreePath,
                    projectURL: projectURL,
                    branchName: cleanup.branchName,
                    sourceBranch: cleanup.sourceBranch,
                    deleteBranch: true,
                    force: true
                )
            }
        }
    }

    // MARK: - Worktrees

    func provisionWorktreeIfEnabled(for sessionID: UUID, project: DiscoveredProject) async {
        guard host?.sessionsUseWorktree == true else { return }
        guard project.isGitRepository else {
            sessionStore.append(.init(sessionID: sessionID, role: .status, title: "Worktree Skipped", text: "Worktree isolation is enabled, but the project is not a git repository. Running in the project root."))
            return
        }
        do {
            let creation = try await sessionWorktreeService.createWorktree(for: sessionID, projectURL: project.url)
            sessionStore.updateSession(sessionID) { record in
                record.worktreePath = creation.worktreePath
                record.branchName = creation.branchName
                record.sourceBranch = creation.sourceBranch
            }
            sessionStore.append(.init(sessionID: sessionID, role: .status, title: "Worktree Ready", text: "Created branch `\(creation.branchName)` off `\(creation.sourceBranch)` in an isolated worktree."))
        } catch {
            sessionStore.append(.init(sessionID: sessionID, role: .error, title: "Worktree Setup Failed", text: "Could not create a session worktree: \(error.localizedDescription). The session will run in the project root."))
        }
    }

    // MARK: - Private

    private func provisionWorktreeFireAndForget(for sessionID: UUID, project: DiscoveredProject) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.provisionWorktreeIfEnabled(for: sessionID, project: project)
        }
    }

    private func scheduleCompletionNotification(for sessionID: UUID) {
        pendingNotificationTasks[sessionID]?.cancel()
        let delay = UInt64((host?.notificationDelay ?? 300) * 1_000_000_000)
        pendingNotificationTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.sendCompletionNotificationIfNeeded(for: sessionID)
            }
        }
    }

    private func sendCompletionNotificationIfNeeded(for sessionID: UUID) {
        pendingNotificationTasks[sessionID] = nil
        guard let session = sessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        guard session.needsAttention,
              host?.isSessionActuallyVisible(sessionID) != true,
              host?.shouldSendSystemNotification() == true else { return }
        sendCompletionNotification(for: session)
    }

    private func sendCompletionNotification(for session: PiAgentSessionRecord) {
        Task { @MainActor [weak self] in
            guard let self, let host else { return }

            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                guard granted else { return }

                let content = UNMutableNotificationContent()
                content.title = "Pi Agent needs review"
                content.body = session.displayTitle
                content.userInfo = [
                    "sessionID": session.id.uuidString,
                    "windowID": host.windowID.uuidString
                ]

                let request = UNNotificationRequest(
                    identifier: self.notificationIdentifier(for: session.id),
                    content: content,
                    trigger: nil
                )

                try await UNUserNotificationCenter.current().add(request)
                self.sessionStore.updateSession(session.id) { record in
                    record.lastNotificationAt = Date()
                }
            } catch {
                return
            }
        }
    }

    private func notificationIdentifier(for sessionID: UUID) -> String {
        "pi-agent-\(sessionID.uuidString)"
    }
}
