import Foundation

// MARK: - GitHub view/API compatibility

extension AppViewModel: GitHubWorkspaceHost {
    var gitHubBoardCacheLifetime: TimeInterval {
        TimeInterval(gitHubBoardCacheLifetimeMinutes * 60)
    }

    func refreshCatalog(includeModels: Bool, scanAllProjects: Bool, extraProjectPathsToScan: Set<String>, silentlyReconcile: Bool) {
        refresh(
            includeModels: includeModels,
            scanAllProjects: scanAllProjects,
            extraProjectPathsToScan: extraProjectPathsToScan,
            silentlyReconcile: silentlyReconcile
        )
    }

    func runShellScriptInTerminal(named: String, body: String) {
        openTerminalShellScript(named: named, body: body)
    }
}

// MARK: - GitHub view/API compatibility

extension AppViewModel {
    var githubConnectionState: GitHubConnectionState {
        get { github.githubConnectionState }
        set { github.githubConnectionState = newValue }
    }

    var githubIssueStateFilter: GitHubIssueStateFilter {
        get { github.githubIssueStateFilter }
        set { github.githubIssueStateFilter = newValue }
    }

    var githubCloseReasonFilter: GitHubIssueCloseReason? {
        get { github.githubCloseReasonFilter }
        set { github.githubCloseReasonFilter = newValue }
    }

    var githubAuthorFilter: String? {
        get { github.githubAuthorFilter }
        set { github.githubAuthorFilter = newValue }
    }

    var githubAssigneeFilter: String? {
        get { github.githubAssigneeFilter }
        set { github.githubAssigneeFilter = newValue }
    }

    var githubTypeFilter: String? {
        get { github.githubTypeFilter }
        set { github.githubTypeFilter = newValue }
    }

    var githubLabelFilters: Set<String> {
        get { github.githubLabelFilters }
        set { github.githubLabelFilters = newValue }
    }

    var githubProjectBoardRevision: Int { github.githubProjectBoardRevision }
    var githubProjectBoard: GitHubBoardSnapshot? { github.githubProjectBoard }
    var githubLastError: String? { github.githubLastError }
    var githubIsLoadingProjectBoard: Bool { github.githubIsLoadingProjectBoard }
    var githubSelectedWorkItem: GitHubWorkItem? { github.githubSelectedWorkItem }
    var githubVisibleBoardItems: [GitHubWorkItem] { github.githubVisibleBoardItems }
    var githubAvailableTypes: [String] { github.githubAvailableTypes }
    var githubAvailableLabels: [GitHubLabel] { github.githubAvailableLabels }
    var githubAvailableAuthors: [String] { github.githubAvailableAuthors }
    var githubAvailableAssignees: [String] { github.githubAvailableAssignees }
    var githubIsRefreshingEverything: Bool { github.githubIsRefreshingEverything }
    var githubLastStatusCheckAt: Date? { github.githubLastStatusCheckAt }
    var githubIsLoadingIssueDetail: Bool { github.githubIsLoadingIssueDetail }
    var githubIssueDetail: GitHubIssueDetail? { github.githubIssueDetail }
    var githubIsClosingIssue: Bool { github.githubIsClosingIssue }
    var githubCommentDraft: String {
        get { github.githubCommentDraft }
        set { github.githubCommentDraft = newValue }
    }

    var githubIsSubmittingComment: Bool { github.githubIsSubmittingComment }
    var githubCommitMessage: String {
        get { github.githubCommitMessage }
        set { github.githubCommitMessage = newValue }
    }

    var githubIsCommitting: Bool { github.githubIsCommitting }
    var githubIsPushing: Bool { github.githubIsPushing }
    var githubComposerIssueItems: [GitHubWorkItem] { github.githubComposerIssueItems }

    func connectGitHubUsingCLI() {
        github.connectGitHubUsingCLI()
    }

    func prepareGitHubScreen() async {
        await github.prepareGitHubScreen()
    }

    func refreshProjectBoard(force: Bool = false) {
        github.refreshProjectBoard(force: force)
    }

    func commitChanges() {
        github.commitChanges()
    }

    func pushCurrentBranch() {
        github.pushCurrentBranch()
    }

    func closeIssue(_ item: GitHubWorkItem, reason: GitHubIssueCloseReason = .completed) {
        github.closeIssue(item, reason: reason)
    }

    func selectWorkItem(_ item: GitHubWorkItem) {
        github.selectWorkItem(item)
    }

    func submitComment() {
        github.submitComment()
    }

    func closeSelectedIssue(reason: GitHubIssueCloseReason = .completed) {
        github.closeSelectedIssue(reason: reason)
    }

    func reopenIssue(_ item: GitHubWorkItem) {
        github.reopenIssue(item)
    }

    func resetIssueFilters() {
        github.resetIssueFilters()
    }

    func selectIssueReference(_ reference: GitHubIssueReference) {
        github.selectIssueReference(reference)
    }

    func openGitHubSetupInTerminal() {
        github.openGitHubSetupInTerminal()
    }

    func filteredBoardItems(from board: GitHubBoardSnapshot?) -> [GitHubWorkItem] {
        github.filteredBoardItems(from: board)
    }

    func fetchPiAgentIssueAttachment(for item: GitHubWorkItem, completion: @escaping (Result<PiAgentIssueAttachment, Error>) -> Void) {
        github.fetchPiAgentIssueAttachment(for: item, completion: completion)
    }
}
