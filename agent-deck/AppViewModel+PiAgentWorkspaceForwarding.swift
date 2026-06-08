import Foundation

// MARK: - Pi Agent workspace view/API compatibility

extension AppViewModel {
    var showPiAgentAttentionOnly: Bool {
        get { piWorkspace.showAttentionOnly }
        set { piWorkspace.showAttentionOnly = newValue }
    }

    var piAgentTitleGeneratingSessionIDs: Set<UUID> { piWorkspace.titleGeneratingSessionIDs }
    var piAgentPendingComposerText: String? { piWorkspace.pendingComposerText }
    var piAgentPendingIssueAttachment: PiAgentIssueAttachment? { piWorkspace.pendingIssueAttachment }
    var piAgentGitAutomationAction: PiAgentGitAutomationAction? { piWorkspace.gitAutomationAction }

    func consumePendingPiAgentComposerText() -> String? {
        piWorkspace.consumePendingComposerText()
    }

    func consumePendingPiAgentIssueAttachment() -> PiAgentIssueAttachment? {
        piWorkspace.consumePendingIssueAttachment()
    }

    var piAgentNeedsAttentionCount: Int { piWorkspace.needsAttentionCount }
    var piAgentRunningSessionCount: Int { piWorkspace.runningSessionCount }

    func piAgentSessionIsWorking(_ session: PiAgentSessionRecord) -> Bool {
        piWorkspace.sessionIsWorking(session)
    }

    func scopedPiAgentSessionsInOrder() -> [PiAgentSessionRecord] {
        piWorkspace.scopedSessionsInOrder(selectedProjectPath: selectedProjectPath)
    }
}
