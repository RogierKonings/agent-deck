import Foundation
import Observation

// MARK: - Pi Agent composer chrome and session list metrics

@MainActor
@Observable
final class PiAgentWorkspaceState {
    private let sessionStore: PiAgentSessionStore

    var showAttentionOnly = false
    private(set) var titleGeneratingSessionIDs: Set<UUID> = []
    private(set) var pendingComposerText: String?
    private(set) var pendingIssueAttachment: PiAgentIssueAttachment?
    private(set) var gitAutomationAction: PiAgentGitAutomationAction?

    init(sessionStore: PiAgentSessionStore) {
        self.sessionStore = sessionStore
    }

    // MARK: - Pending composer / issue launch

    func setPendingIssueLaunch(composerText: String, attachment: PiAgentIssueAttachment) {
        pendingComposerText = composerText
        pendingIssueAttachment = attachment
    }

    func consumePendingComposerText() -> String? {
        guard let pending = pendingComposerText else { return nil }
        pendingComposerText = nil
        return pending
    }

    func consumePendingIssueAttachment() -> PiAgentIssueAttachment? {
        let pending = pendingIssueAttachment
        pendingIssueAttachment = nil
        return pending
    }

    // MARK: - Title generation spinner

    func isTitleGenerating(for sessionID: UUID) -> Bool {
        titleGeneratingSessionIDs.contains(sessionID)
    }

    func markTitleGenerating(_ sessionID: UUID) {
        titleGeneratingSessionIDs.insert(sessionID)
    }

    func unmarkTitleGenerating(_ sessionID: UUID) {
        titleGeneratingSessionIDs.remove(sessionID)
    }

    // MARK: - Git automation toolbar spinner

    func setGitAutomationAction(_ action: PiAgentGitAutomationAction?) {
        gitAutomationAction = action
    }

    // MARK: - Session list metrics

    var needsAttentionCount: Int {
        sessionStore.sessions.count(where: \.needsAttention)
    }

    var runningSessionCount: Int {
        sessionStore.sessions.filter { session in
            !session.needsAttention && sessionIsWorking(session)
        }.count
    }

    func sessionIsWorking(_ session: PiAgentSessionRecord) -> Bool {
        session.status.isActive || sessionHasActiveSubagent(session.id)
    }

    func scopedSessionsInOrder(selectedProjectPath: String?) -> [PiAgentSessionRecord] {
        guard let path = selectedProjectPath else { return sessionStore.sessions }
        return sessionStore.sessions.filter { $0.projectPath == path }
    }

    private func sessionHasActiveSubagent(_ sessionID: UUID) -> Bool {
        sessionStore.subagentRuns(for: sessionID).contains { $0.status.isActive }
    }
}
