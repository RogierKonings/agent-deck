import Foundation
import Observation

// MARK: - GitHub workspace state

@MainActor
@Observable
final class GitHubWorkspace {
    weak var host: GitHubWorkspaceHost?

    var githubConnectionState: GitHubConnectionState = .checking
    var githubIssueStateFilter: GitHubIssueStateFilter = .open
    var githubCloseReasonFilter: GitHubIssueCloseReason?
    var githubAuthorFilter: String?
    var githubAssigneeFilter: String?
    var githubTypeFilter: String?
    var githubLabelFilters: Set<String> = []
    var githubAggregateBoard: GitHubBoardSnapshot?
    var githubProjectBoard: GitHubBoardSnapshot? {
        didSet { githubProjectBoardRevision &+= 1 }
    }
    private(set) var githubProjectBoardRevision: Int = 0
    var githubRepositoryChanges: RepositoryChangesSnapshot?
    var githubRepositoryChangesProjectPath: String?
    var githubSelectedChangePaths: Set<String> = []
    var githubSelectedDiffFilePath: String?
    var githubSelectedDiffKind: GitDiffKind?
    var githubSelectedDiffText: String?
    var githubCommitMessage = ""
    var githubCommitDescription = ""
    var githubSelectedWorkItem: GitHubWorkItem?
    var githubIssueDetail: GitHubIssueDetail?
    var githubCommentDraft = ""
    var githubIsLoadingAggregateBoard = false
    var githubIsLoadingProjectBoard = false
    var githubIsLoadingRepositoryChanges = false
    var githubIsLoadingIssueDetail = false
    var githubIsSubmittingComment = false
    var githubIsClosingIssue = false
    var githubIsCommitting = false
    var githubIsPushing = false
    var githubIsRefreshingEverything = false
    var githubLastError: String?
    var githubLastStatusCheckAt: Date?

    private var session: GitHubSession?
    private var githubProjectBoardRequestID = 0
    private var githubRepositoryChangesRequestID = 0
    private var githubDiffRequestID = 0
    private var githubIssueDetailRequestID = 0
    private var githubDiffCache: [GitDiffCacheKey: String] = [:]
    private var githubDiffCacheOrder: [GitDiffCacheKey] = []
    private let githubDiffCacheLimit = 64
    private let repositoryChangesCacheLifetime: TimeInterval = 5
    private var repositoryChangesCache: [String: RepositoryChangesCacheEntry] = [:]
    private var githubProjectBoardCacheKey: String?
    private var githubProjectBoardFetchedAt: Date?

    private let gitHubAuthService: GitHubAuthService
    let gitRepositoryService: GitRepositoryService

    init(
        gitHubAuthService: GitHubAuthService = GitHubCLIAuthService(),
        gitRepositoryService: GitRepositoryService = GitRepositoryService()
    ) {
        self.gitHubAuthService = gitHubAuthService
        self.gitRepositoryService = gitRepositoryService
    }

    private var selectedGitHubProject: DiscoveredProject? { host?.selectedGitHubProject }
    private var selectedDiscoveredProject: DiscoveredProject? { host?.selectedDiscoveredProject }
    private var gitHubProjects: [DiscoveredProject] { host?.gitHubProjects ?? [] }
    private var discoveredProjects: [DiscoveredProject] { host?.discoveredProjects ?? [] }
    private var selectedProjectPath: String? {
        get { host?.selectedProjectPath }
        set { host?.selectedProjectPath = newValue }
    }
    private var gitHubBoardCacheLifetime: TimeInterval {
        host?.gitHubBoardCacheLifetime ?? 300
    }

    private func setSelectedProject(_ url: URL?) {
        host?.setSelectedProject(url)
    }

    func repositoryChangesEntry(for projectPath: String) -> RepositoryChangesCacheEntry? {
        repositoryChangesCache[projectPath]
    }

    var authenticatedSession: GitHubSession? { session }

    func refreshGitHubStatus() async {
        githubConnectionState = .checking
        githubLastError = nil

        let state = await gitHubAuthService.loadStatus()
        switch state {
        case let .available(account):
            if session?.account == account {
                githubConnectionState = .connected(account)
            } else {
                session = nil
                githubConnectionState = .available(account)
            }
        case let .connected(account):
            githubConnectionState = .connected(account)
        default:
            session = nil
            githubConnectionState = state
        }

        githubLastStatusCheckAt = Date()
    }

    func connectGitHubUsingCLI() {
        Task { [weak self] in
            guard let self else { return }
            await connectGitHubUsingCLIIfNeeded(forceReconnect: true)
        }
    }

    func connectGitHubUsingCLIIfNeeded(forceReconnect: Bool = false) async {
        if !forceReconnect, session != nil, githubConnectionState.isConnected {
            return
        }

        githubConnectionState = .checking
        githubLastError = nil

        do {
            let connectedSession = try await gitHubAuthService.connectUsingCLI()
            session = connectedSession
            githubConnectionState = .connected(connectedSession.account)
            githubLastStatusCheckAt = Date()
            resetConnectionScopedState()
        } catch {
            session = nil
            githubConnectionState = .failed(message: error.localizedDescription)
            githubLastError = error.localizedDescription
            githubLastStatusCheckAt = Date()
        }
    }

    func prepareGitHubScreen() async {
        if githubConnectionState.isConnected, session != nil {
            return
        }

        await refreshGitHubStatus()
        if case .available = githubConnectionState {
            await connectGitHubUsingCLIIfNeeded()
        }
    }

    var currentAccount: GitHubHostAccount? {
        githubConnectionState.account ?? authenticatedSession?.account
    }

    var shouldShowConnectionCard: Bool {
        currentAccount != nil || githubLastStatusCheckAt != nil || githubIsRefreshingEverything
    }

    func reportSurfaceError(_ message: String) {
        githubLastError = message
    }

    func refreshEverything() {
        guard !githubIsRefreshingEverything else { return }

        githubIsRefreshingEverything = true
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.githubIsRefreshingEverything = false
            }
            self.host?.refreshCatalog(
                includeModels: true,
                scanAllProjects: false,
                extraProjectPathsToScan: [],
                silentlyReconcile: false
            )
            await self.refreshGitHubStatus()
            if case .available = self.githubConnectionState {
                await self.connectGitHubUsingCLIIfNeeded()
            }
            if self.authenticatedSession != nil, self.githubConnectionState.isConnected {
                self.refreshProjectBoard(force: true)
            }
            if self.selectedDiscoveredProject?.isGitRepository == true {
                self.refreshRepositoryChanges(preservingDiffSelection: true)
            }
            if let selectedItem = self.githubSelectedWorkItem, self.authenticatedSession != nil {
                self.loadIssueDetail(for: selectedItem)
            }
        }
    }

    func ensureComposerIssuesLoaded() {
        Task { [weak self] in
            guard let self else { return }
            await self.prepareGitHubScreen()
            if self.selectedGitHubProject?.gitHubRemote != nil {
                self.refreshProjectBoard(force: false)
            } else if self.githubAggregateBoard == nil, !self.gitHubProjects.isEmpty {
                self.refreshAggregateBoard()
            }
        }
    }

    func disconnectGitHub() {
        let availableAccount = githubConnectionState.account ?? session?.account

        gitHubAuthService.disconnect()
        session = nil
        githubProjectBoardRequestID += 1
        githubRepositoryChangesRequestID += 1
        githubIssueDetailRequestID += 1
        githubAggregateBoard = nil
        githubProjectBoard = nil
        githubProjectBoardCacheKey = nil
        githubProjectBoardFetchedAt = nil
        githubRepositoryChanges = nil
        githubRepositoryChangesProjectPath = nil
        repositoryChangesCache.removeAll()
        githubSelectedChangePaths = []
        githubDiffCache.removeAll()
        githubDiffCacheOrder.removeAll()
        githubSelectedDiffFilePath = nil
        githubSelectedDiffKind = nil
        githubSelectedDiffText = nil
        githubSelectedWorkItem = nil
        githubIssueDetail = nil
        githubCommentDraft = ""
        githubIsLoadingAggregateBoard = false
        githubIsLoadingProjectBoard = false
        githubIsLoadingRepositoryChanges = false
        githubIsLoadingIssueDetail = false
        githubIsSubmittingComment = false
        githubIsClosingIssue = false
        githubLastError = nil
        githubConnectionState = availableAccount.map(GitHubConnectionState.available) ?? .disconnected
        githubLastStatusCheckAt = Date()
    }
    func refreshAggregateBoard() {
        guard let session = session else {
            githubLastError = "Connect GitHub first."
            githubAggregateBoard = nil
            return
        }

        let repos = gitHubProjects.compactMap(\.gitHubRemote)
        githubIsLoadingAggregateBoard = true
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let service = GitHubSearchService(apiClient: GitHubAPIClient(session: session))
                let snapshot = try await service.fetchAggregateIssues(
                    repos: repos,
                    state: self.githubIssueStateFilter,
                    closeReason: self.effectiveCloseReasonFilter
                )

                await MainActor.run {
                    self.githubAggregateBoard = snapshot
                    self.githubIsLoadingAggregateBoard = false
                }
            } catch {
                await MainActor.run {
                    self.githubAggregateBoard = nil
                    self.githubIsLoadingAggregateBoard = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func refreshProjectBoard(force: Bool = false) {
        guard let session = session else {
            githubIsLoadingProjectBoard = false
            githubLastError = "Connect GitHub first."
            githubProjectBoard = nil
            githubProjectBoardCacheKey = nil
            githubProjectBoardFetchedAt = nil
            return
        }

        guard let remote = selectedGitHubProject?.gitHubRemote else {
            githubIsLoadingProjectBoard = false
            githubLastError = nil
            githubProjectBoard = nil
            githubProjectBoardCacheKey = nil
            githubProjectBoardFetchedAt = nil
            return
        }

        let state = githubIssueStateFilter
        let closeReason = effectiveCloseReasonFilter
        let cacheKey = boardCacheKey(for: remote, state: state, closeReason: closeReason)
        if !force,
           githubProjectBoard != nil,
           githubProjectBoardCacheKey == cacheKey,
           !isGitHubBoardCacheStale(fetchedAt: githubProjectBoardFetchedAt) {
            return
        }

        githubProjectBoardRequestID += 1
        let requestID = githubProjectBoardRequestID
        githubIsLoadingProjectBoard = true
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let service = GitHubSearchService(apiClient: GitHubAPIClient(session: session))
                let snapshot = try await service.fetchRepositoryIssues(
                    repo: remote,
                    state: state,
                    closeReason: closeReason,
                    bypassCache: force
                )

                await MainActor.run {
                    guard self.githubProjectBoardRequestID == requestID,
                          host?.selectedGitHubProject?.gitHubRemote == remote,
                          self.githubIssueStateFilter == state,
                          self.effectiveCloseReasonFilter == closeReason else { return }

                    // Compute selection before publishing the board so the first
                    // render of boardContent already has a selection (avoids a
                    // "no-selection" layout pass that jumps the split divider).
                    let visibleItems = self.filteredBoardItems(from: snapshot)
                    let visibleItemIDs = Set(visibleItems.map(\.id))

                    if let selectedID = self.githubSelectedWorkItem?.id,
                       !visibleItemIDs.contains(selectedID) {
                        self.githubIssueDetailRequestID += 1
                        self.githubSelectedWorkItem = nil
                        self.githubIssueDetail = nil
                        self.githubCommentDraft = ""
                        self.githubIsLoadingIssueDetail = false
                        self.githubIsSubmittingComment = false
                    }

                    var autoSelectItem: GitHubWorkItem?
                    if self.githubSelectedWorkItem == nil, let first = visibleItems.first {
                        self.githubSelectedWorkItem = first
                        self.githubIssueDetail = nil
                        self.githubCommentDraft = ""
                        autoSelectItem = first
                    }

                    self.githubProjectBoard = snapshot
                    self.githubProjectBoardCacheKey = cacheKey
                    self.githubProjectBoardFetchedAt = Date()
                    self.githubIsLoadingProjectBoard = false

                    if let item = autoSelectItem {
                        self.loadIssueDetail(for: item, bypassCache: force)
                    } else if force, let selected = self.githubSelectedWorkItem {
                        // An explicit refresh should also pull fresh comments for
                        // the issue already open in the detail pane.
                        self.loadIssueDetail(for: selected, bypassCache: true)
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.githubProjectBoardRequestID == requestID,
                          host?.selectedGitHubProject?.gitHubRemote == remote,
                          self.githubIssueStateFilter == state,
                          self.effectiveCloseReasonFilter == closeReason else { return }

                    self.githubProjectBoard = nil
                    self.githubProjectBoardCacheKey = nil
                    self.githubProjectBoardFetchedAt = nil
                    self.githubIsLoadingProjectBoard = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    /// Applies the author, assignee, type, and label filters on top of the board
    /// snapshot. State is already applied server-side via `githubIssueStateFilter`.
    /// Uses `item.labelNameSet` (precomputed at snapshot time) so the
    /// label-disjoint check no longer allocates a fresh `Set` per item per call.
    func filteredBoardItems(from board: GitHubBoardSnapshot?) -> [GitHubWorkItem] {
        guard let board else { return [] }
        let author = githubAuthorFilter
        let assignee = githubAssigneeFilter
        let type = githubTypeFilter
        let labels = githubLabelFilters
        return board.allItems.filter { item in
            if let author, item.author != author { return false }
            if let assignee, !item.assignees.contains(assignee) { return false }
            if let type, item.type != type { return false }
            if !labels.isEmpty, labels.isDisjoint(with: item.labelNameSet) { return false }
            return true
        }
    }

    var githubVisibleBoardItems: [GitHubWorkItem] {
        filteredBoardItems(from: githubProjectBoard)
    }

    var githubComposerIssueItems: [GitHubWorkItem] {
        if let remote = selectedGitHubProject?.gitHubRemote {
            if let githubProjectBoard {
                return filteredBoardItems(from: githubProjectBoard)
            }
            if let githubAggregateBoard {
                let filtered = filteredBoardItems(from: githubAggregateBoard)
                return filtered.filter { $0.repository.caseInsensitiveCompare(remote.nameWithOwner) == .orderedSame }
            }
            return []
        }
        return filteredBoardItems(from: githubAggregateBoard)
    }

    var githubAvailableAuthors: [String] {
        guard let board = githubProjectBoard else { return [] }
        var seen: Set<String> = []
        var ordered: [String] = []
        for item in board.allItems {
            guard let author = item.author, !seen.contains(author) else { continue }
            seen.insert(author)
            ordered.append(author)
        }
        return ordered.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var githubAvailableAssignees: [String] {
        guard let board = githubProjectBoard else { return [] }
        var seen: Set<String> = []
        for item in board.allItems { seen.formUnion(item.assignees) }
        return seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var githubAvailableTypes: [String] {
        guard let board = githubProjectBoard else { return [] }
        var seen: Set<String> = []
        for item in board.allItems {
            if let type = item.type, !type.isEmpty { seen.insert(type) }
        }
        return seen.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var githubAvailableLabels: [GitHubLabel] {
        guard let board = githubProjectBoard else { return [] }
        var seen: Set<String> = []
        var ordered: [GitHubLabel] = []
        for item in board.allItems {
            for label in item.labels where seen.insert(label.name).inserted {
                ordered.append(label)
            }
        }
        return ordered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func resetIssueFilters() {
        githubAuthorFilter = nil
        githubAssigneeFilter = nil
        githubTypeFilter = nil
        githubLabelFilters = []
        githubCloseReasonFilter = nil
    }

    func refreshRepositoryChanges(preservingDiffSelection: Bool = false, force: Bool = true) {
        guard let project = selectedDiscoveredProject, project.isGitRepository else {
            githubRepositoryChangesRequestID += 1
            githubRepositoryChanges = nil
            githubRepositoryChangesProjectPath = nil
            githubSelectedChangePaths = []
            githubSelectedDiffFilePath = nil
            githubSelectedDiffKind = nil
            githubSelectedDiffText = nil
            githubIsLoadingRepositoryChanges = false
            githubLastError = nil
            return
        }

        refreshRepositoryChanges(
            forProjectPath: project.path,
            preservingDiffSelection: preservingDiffSelection,
            force: force,
            activeContextIsCurrent: { [weak self] in
                guard let self else { return false }
                return host?.selectedDiscoveredProject?.path == project.path
            }
        )
    }

    func loadDiff(for filePath: String, kind: GitDiffKind) {
        guard let project = selectedDiscoveredProject else { return }
        let cacheKey = GitDiffCacheKey(projectPath: project.path, filePath: filePath, kind: kind)
        if githubSelectedDiffFilePath == filePath,
           githubSelectedDiffKind == kind,
           githubSelectedDiffText != nil {
            return
        }

        githubDiffRequestID += 1
        let requestID = githubDiffRequestID
        githubSelectedDiffFilePath = filePath
        githubSelectedDiffKind = kind
        githubSelectedDiffText = cachedGithubDiff(for: cacheKey)
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let diff = try await gitRepositoryService.loadDiff(for: filePath, kind: kind, in: project.url)
                await MainActor.run {
                    guard self.githubDiffRequestID == requestID,
                          host?.selectedDiscoveredProject?.path == project.path,
                          self.githubSelectedDiffFilePath == filePath,
                          self.githubSelectedDiffKind == kind else { return }
                    let displayText = diff.isEmpty ? "No \(kind.rawValue.lowercased()) diff for this file." : diff
                    self.storeGithubDiff(displayText, for: cacheKey)
                    self.githubSelectedDiffText = displayText
                }
            } catch {
                await MainActor.run {
                    guard self.githubDiffRequestID == requestID,
                          host?.selectedDiscoveredProject?.path == project.path,
                          self.githubSelectedDiffFilePath == filePath,
                          self.githubSelectedDiffKind == kind else { return }
                    self.githubSelectedDiffText = nil
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func stage(_ filePath: String) {
        guard let project = selectedDiscoveredProject else { return }
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await gitRepositoryService.stage(filePath, in: project.url)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: project.path, filePath: filePath)
                    self.refreshRepositoryChanges(preservingDiffSelection: true)
                    self.loadDiff(for: filePath, kind: .staged)
                }
            } catch {
                await MainActor.run {
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func unstage(_ filePath: String) {
        guard let project = selectedDiscoveredProject else { return }
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await gitRepositoryService.unstage(filePath, in: project.url)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: project.path, filePath: filePath)
                    self.refreshRepositoryChanges(preservingDiffSelection: true)
                    self.loadDiff(for: filePath, kind: .unstaged)
                }
            } catch {
                await MainActor.run {
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func toggleChangeSelection(_ filePath: String) {
        if githubSelectedChangePaths.contains(filePath) {
            githubSelectedChangePaths.remove(filePath)
        } else {
            githubSelectedChangePaths.insert(filePath)
        }
    }

    func selectAllVisibleChanges() {
        guard let snapshot = githubRepositoryChanges else { return }
        githubSelectedChangePaths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
    }

    func clearSelectedChanges() {
        githubSelectedChangePaths.removeAll()
    }

    func stageSelectedChanges() {
        guard let project = selectedDiscoveredProject else { return }
        let paths = Array(githubSelectedChangePaths)
        guard !paths.isEmpty else { return }
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                for path in paths {
                    try await gitRepositoryService.stage(path, in: project.url)
                }
                await MainActor.run { self.refreshRepositoryChanges() }
            } catch {
                await MainActor.run { self.githubLastError = error.localizedDescription }
            }
        }
    }

    func unstageSelectedChanges() {
        guard let project = selectedDiscoveredProject else { return }
        let paths = Array(githubSelectedChangePaths)
        guard !paths.isEmpty else { return }
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                for path in paths {
                    try await gitRepositoryService.unstage(path, in: project.url)
                }
                await MainActor.run { self.refreshRepositoryChanges() }
            } catch {
                await MainActor.run { self.githubLastError = error.localizedDescription }
            }
        }
    }

    func stageAllChanges() {
        guard let project = selectedDiscoveredProject else { return }
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await gitRepositoryService.stageAll(in: project.url)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: project.path)
                    self.refreshRepositoryChanges(preservingDiffSelection: true)
                }
            } catch {
                await MainActor.run { self.githubLastError = error.localizedDescription }
            }
        }
    }

    func unstageAllChanges() {
        guard let project = selectedDiscoveredProject else { return }
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await gitRepositoryService.unstageAll(in: project.url)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: project.path)
                    self.refreshRepositoryChanges(preservingDiffSelection: true)
                }
            } catch {
                await MainActor.run { self.githubLastError = error.localizedDescription }
            }
        }
    }

    private func invalidateDiffCache(projectPath: String, filePath: String? = nil) {
        githubDiffCache = githubDiffCache.filter { entry in
            guard entry.key.projectPath == projectPath else { return true }
            guard let filePath else { return false }
            return entry.key.filePath != filePath
        }
        githubDiffCacheOrder.removeAll { key in
            guard key.projectPath == projectPath else { return false }
            guard let filePath else { return true }
            return key.filePath == filePath
        }
    }

    private func cachedGithubDiff(for key: GitDiffCacheKey) -> String? {
        guard let value = githubDiffCache[key] else { return nil }
        markGithubDiffCacheKeyUsed(key)
        return value
    }

    private func storeGithubDiff(_ value: String, for key: GitDiffCacheKey) {
        githubDiffCache[key] = value
        markGithubDiffCacheKeyUsed(key)
        while githubDiffCacheOrder.count > githubDiffCacheLimit, let oldest = githubDiffCacheOrder.first {
            githubDiffCacheOrder.removeFirst()
            githubDiffCache[oldest] = nil
        }
    }

    private func markGithubDiffCacheKeyUsed(_ key: GitDiffCacheKey) {
        githubDiffCacheOrder.removeAll { $0 == key }
        githubDiffCacheOrder.append(key)
    }

    func commitChanges() {
        guard let project = selectedDiscoveredProject else { return }
        let message = githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = githubCommitDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            githubLastError = "Enter a commit title first."
            return
        }

        githubIsCommitting = true
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await gitRepositoryService.commit(message: message, description: description, in: project.url)
                await MainActor.run {
                    self.githubCommitMessage = ""
                    self.githubCommitDescription = ""
                    self.githubIsCommitting = false
                    self.refreshRepositoryChanges()
                }
            } catch {
                await MainActor.run {
                    self.githubIsCommitting = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func pushCurrentBranch() {
        guard let project = selectedDiscoveredProject else { return }
        githubIsPushing = true
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await gitRepositoryService.pushCurrentBranch(in: project.url)
                await MainActor.run {
                    self.githubIsPushing = false
                    self.refreshRepositoryChanges()
                }
            } catch {
                await MainActor.run {
                    self.githubIsPushing = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func selectWorkItem(_ item: GitHubWorkItem) {
        githubSelectedWorkItem = item
        githubIssueDetail = nil
        githubCommentDraft = ""
        loadIssueDetail(for: item)
    }

    func selectIssueReference(_ reference: GitHubIssueReference) {
        if let matchingProject = discoveredProjects.first(where: {
            $0.gitHubRemote?.nameWithOwner.caseInsensitiveCompare(reference.repository) == .orderedSame
        }), selectedProjectPath != matchingProject.path {
            setSelectedProject(matchingProject.url)
        }

        if let existing = githubProjectBoard?.allItems.first(where: { $0.repository == reference.repository && $0.number == reference.number }) {
            selectWorkItem(existing)
            return
        }

        let item = GitHubWorkItem(
            id: "\(reference.repository)-\(reference.number)",
            number: reference.number,
            title: reference.title,
            repository: reference.repository,
            url: reference.url,
            isPullRequest: false,
            state: reference.state,
            stateReason: nil,
            type: reference.type,
            labels: [],
            assignees: [],
            author: nil,
            body: "",
            commentCount: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast,
            closedAt: nil,
            subIssuesSummary: nil,
            issueDependenciesSummary: nil
        )
        selectWorkItem(item)
    }

    func loadIssueDetail(for item: GitHubWorkItem, bypassCache: Bool = false) {
        guard let session = session else {
            githubIsLoadingIssueDetail = false
            githubLastError = "Connect GitHub first."
            return
        }

        githubIssueDetailRequestID += 1
        let requestID = githubIssueDetailRequestID
        githubIsLoadingIssueDetail = true
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let service = GitHubIssueService(apiClient: GitHubAPIClient(session: session))
                let detail = try await service.fetchDetail(for: item, bypassCache: bypassCache)
                await MainActor.run {
                    guard self.githubIssueDetailRequestID == requestID,
                          self.githubSelectedWorkItem == item else { return }

                    self.githubIssueDetail = detail
                    self.githubIsLoadingIssueDetail = false
                }
            } catch {
                await MainActor.run {
                    guard self.githubIssueDetailRequestID == requestID,
                          self.githubSelectedWorkItem == item else { return }

                    self.githubIssueDetail = nil
                    self.githubIsLoadingIssueDetail = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func fetchPiAgentIssueAttachment(for item: GitHubWorkItem, completion: @escaping (Result<PiAgentIssueAttachment, Error>) -> Void) {
        guard let session = session else {
            completion(.failure(GitHubAPIClient.APIError.requestFailed(statusCode: 0, message: "Connect GitHub first.")))
            return
        }

        Task { [weak self] in
            // Bail out early if the view model has been deallocated. The body
            // below doesn't reference `self`, so a boolean test is enough.
            guard self != nil else { return }
            do {
                let service = GitHubIssueService(apiClient: GitHubAPIClient(session: session))
                let detail = try await service.fetchDetail(for: item)
                await MainActor.run {
                    completion(.success(PiAgentIssueAttachment(detail: detail)))
                }
            } catch {
                await MainActor.run {
                    completion(.failure(error))
                }
            }
        }
    }
    func openGitHubSetupInTerminal() {
        let body = """
        if ! command -v gh >/dev/null 2>&1; then
          if command -v brew >/dev/null 2>&1; then
            brew install gh
          else
            echo "Homebrew not found. Install it from https://brew.sh or the GitHub CLI from https://cli.github.com."
          fi
        fi
        if command -v gh >/dev/null 2>&1; then
          gh auth login
        fi
        echo ""
        echo "Press any key to close."
        read -k 1
        """
        host?.runShellScriptInTerminal(named: "gh-setup", body: body)
    }

    /// Writes a one-shot `.command` script and opens it in Terminal. Shared by
    func refreshRepositoryChanges(
        forProjectPath projectPath: String,
        preservingDiffSelection: Bool,
        force: Bool,
        activeContextIsCurrent: @escaping @MainActor () -> Bool
    ) {
        performRepositoryChangesRefresh(
            forProjectPath: projectPath,
            preservingDiffSelection: preservingDiffSelection,
            force: force,
            activeContextIsCurrent: activeContextIsCurrent
        )
    }

    func refreshRepositoryChanges(forProjectPath projectPath: String, preservingDiffSelection: Bool = false, force: Bool = true) {
        performRepositoryChangesRefresh(
            forProjectPath: projectPath,
            preservingDiffSelection: preservingDiffSelection,
            force: force,
            activeContextIsCurrent: { [weak self] in
                guard let self else { return false }
                return host?.piAgentSessionStore.selectedSession?.projectPath == projectPath || host?.selectedDiscoveredProject?.path == projectPath
            }
        )
    }

    private func performRepositoryChangesRefresh(
        forProjectPath projectPath: String,
        preservingDiffSelection: Bool,
        force: Bool,
        activeContextIsCurrent: @escaping @MainActor () -> Bool
    ) {
        if !force, let entry = repositoryChangesCache[projectPath] {
            syncActiveRepositoryChanges(projectPath: projectPath, preservingDiffSelection: preservingDiffSelection)
            if entry.isLoading || !isRepositoryChangesCacheStale(entry) { return }
        }

        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        githubRepositoryChangesRequestID += 1
        let requestID = githubRepositoryChangesRequestID
        var entry = repositoryChangesCache[projectPath] ?? RepositoryChangesCacheEntry()
        entry.isLoading = true
        entry.error = nil
        entry.requestID = requestID
        repositoryChangesCache[projectPath] = entry

        if activeContextIsCurrent() {
            syncActiveRepositoryChanges(projectPath: projectPath, preservingDiffSelection: preservingDiffSelection)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await gitRepositoryService.loadChanges(in: projectURL)
                let mergeability = await self.mergeabilityState(forRepositoryPath: projectPath, repositoryURL: projectURL)
                await MainActor.run {
                    guard self.repositoryChangesCache[projectPath]?.requestID == requestID else { return }
                    self.repositoryChangesCache[projectPath] = RepositoryChangesCacheEntry(
                        snapshot: snapshot,
                        fetchedAt: Date(),
                        isLoading: false,
                        error: nil,
                        requestID: requestID,
                        mergeSourceBranch: mergeability?.sourceBranch,
                        mergeSessionBranch: mergeability?.sessionBranch,
                        hasMergeableBranchChanges: mergeability?.hasMergeableChanges
                    )
                    guard activeContextIsCurrent() else { return }
                    self.syncActiveRepositoryChanges(projectPath: projectPath, preservingDiffSelection: preservingDiffSelection)
                }
            } catch {
                await MainActor.run {
                    guard var entry = self.repositoryChangesCache[projectPath], entry.requestID == requestID else { return }
                    entry.isLoading = false
                    entry.error = error.localizedDescription
                    self.repositoryChangesCache[projectPath] = entry
                    guard activeContextIsCurrent() else { return }
                    self.syncActiveRepositoryChanges(projectPath: projectPath, preservingDiffSelection: preservingDiffSelection)
                }
            }
        }
    }

    private func mergeabilityState(forRepositoryPath projectPath: String, repositoryURL: URL) async -> (sourceBranch: String, sessionBranch: String, hasMergeableChanges: Bool)? {
        guard let session = await MainActor.run(body: { host?.piAgentSessionStore.selectedSession }),
              session.repositoryRoot == projectPath,
              let sourceBranch = session.sourceBranch,
              let sessionBranch = session.branchName else { return nil }

        let hasMergeableChanges = (try? await gitRepositoryService.isBranchAhead(sessionBranch, of: sourceBranch, in: repositoryURL)) ?? false
        return (sourceBranch, sessionBranch, hasMergeableChanges)
    }

    private func syncActiveRepositoryChanges(projectPath: String, preservingDiffSelection: Bool) {
        let entry = repositoryChangesCache[projectPath]
        githubRepositoryChanges = entry?.snapshot
        githubRepositoryChangesProjectPath = entry?.snapshot == nil ? nil : projectPath
        githubIsLoadingRepositoryChanges = entry?.isLoading == true
        githubLastError = entry?.error

        if !preservingDiffSelection {
            githubSelectedChangePaths = []
            githubSelectedDiffFilePath = nil
            githubSelectedDiffKind = nil
            githubSelectedDiffText = nil
        }

        guard let snapshot = entry?.snapshot else { return }
        let validPaths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
        if preservingDiffSelection {
            githubSelectedChangePaths = githubSelectedChangePaths.intersection(validPaths)
        }
    }

    private func isRepositoryChangesCacheStale(_ entry: RepositoryChangesCacheEntry) -> Bool {
        guard let fetchedAt = entry.fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > repositoryChangesCacheLifetime
    }

    func submitComment() {
        guard let item = githubSelectedWorkItem, let session = session else {
            githubLastError = "Select an issue or pull request first."
            return
        }

        let body = githubCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            githubLastError = "Enter a comment first."
            return
        }

        githubIsSubmittingComment = true
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let service = GitHubIssueService(apiClient: GitHubAPIClient(session: session))
                try await service.postComment(body: body, for: item)
                await MainActor.run {
                    guard self.githubSelectedWorkItem == item,
                          self.session == session else {
                        self.githubIsSubmittingComment = false
                        return
                    }

                    self.githubCommentDraft = ""
                    self.githubIsSubmittingComment = false
                    self.githubProjectBoardFetchedAt = nil
                    self.loadIssueDetail(for: item, bypassCache: true)
                }
            } catch {
                await MainActor.run {
                    guard self.githubSelectedWorkItem == item else {
                        self.githubIsSubmittingComment = false
                        return
                    }

                    self.githubIsSubmittingComment = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func closeSelectedIssue(reason: GitHubIssueCloseReason = .completed) {
        guard let item = githubSelectedWorkItem else {
            githubLastError = "Select an issue first."
            return
        }
        closeIssue(item, reason: reason)
    }

    func closeIssue(_ item: GitHubWorkItem, reason: GitHubIssueCloseReason = .completed) {
        setIssueState(item, open: false, reason: reason)
    }

    func reopenIssue(_ item: GitHubWorkItem) {
        setIssueState(item, open: true, reason: nil)
    }

    /// Closes or reopens an issue on GitHub and reconciles the cached board,
    /// selection, and open detail with the new state. `githubIsClosingIssue`
    /// doubles as the in-flight flag for both directions.
    private func setIssueState(_ item: GitHubWorkItem, open: Bool, reason: GitHubIssueCloseReason?) {
        guard let session = session else {
            githubLastError = "Connect GitHub first."
            return
        }
        githubIsClosingIssue = true
        githubLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let service = GitHubIssueService(apiClient: GitHubAPIClient(session: session))
                if open {
                    try await service.reopenIssue(item)
                } else {
                    try await service.closeIssue(item, reason: reason ?? .completed)
                }
                await MainActor.run {
                    self.githubIsClosingIssue = false
                    let updated = item.with(state: open ? "open" : "closed", closedAt: open ? nil : Date())
                    if let board = self.githubProjectBoard {
                        self.githubProjectBoard = board.replacing(updated)
                    }
                    if self.githubSelectedWorkItem?.id == updated.id {
                        self.githubSelectedWorkItem = updated
                    }
                    if let detail = self.githubIssueDetail, detail.item.id == updated.id {
                        self.githubIssueDetail = detail.with(state: updated.state, closedAt: updated.closedAt)
                    }
                    // Mark the board cache stale so the next user-initiated refresh
                    // re-syncs with the server.
                    self.githubProjectBoardFetchedAt = nil
                }
            } catch {
                await MainActor.run {
                    self.githubIsClosingIssue = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func resetConnectionScopedState() {
        githubProjectBoardRequestID += 1
        githubIssueDetailRequestID += 1
        githubAggregateBoard = nil
        githubProjectBoard = nil
        githubProjectBoardCacheKey = nil
        githubProjectBoardFetchedAt = nil
        githubSelectedWorkItem = nil
        githubIssueDetail = nil
        githubCommentDraft = ""
        githubIsLoadingAggregateBoard = false
        githubIsLoadingProjectBoard = false
        githubIsLoadingIssueDetail = false
        githubIsSubmittingComment = false
        githubIsClosingIssue = false
    }

    func resetProjectScopedState() {
        githubProjectBoardRequestID += 1
        githubRepositoryChangesRequestID += 1
        githubIssueDetailRequestID += 1
        githubProjectBoard = nil
        githubProjectBoardCacheKey = nil
        githubProjectBoardFetchedAt = nil
        githubRepositoryChanges = nil
        githubRepositoryChangesProjectPath = nil
        repositoryChangesCache.removeAll()
        githubSelectedChangePaths = []
        githubSelectedDiffFilePath = nil
        githubSelectedDiffKind = nil
        githubSelectedDiffText = nil
        githubCommitMessage = ""
        githubCommitDescription = ""
        githubSelectedWorkItem = nil
        githubIssueDetail = nil
        githubCommentDraft = ""
        githubIsLoadingProjectBoard = false
        githubIsLoadingRepositoryChanges = false
        githubIsLoadingIssueDetail = false
        githubIsSubmittingComment = false
        githubIsClosingIssue = false
        githubAuthorFilter = nil
        githubLabelFilters = []
    }

    private func boardCacheKey(for remote: GitHubRemote, state: GitHubIssueStateFilter, closeReason: GitHubIssueCloseReason?) -> String {
        let reasonPart = closeReason?.rawValue ?? "any"
        return "\(remote.host.lowercased())|\(remote.nameWithOwner.lowercased())|\(state.rawValue.lowercased())|\(reasonPart)"
    }

    /// The reason filter only applies server-side when the state filter is
    /// Closed — GitHub's `state_reason` is closed-only, and combining it with
    /// `is:open` would always return zero results.
    private var effectiveCloseReasonFilter: GitHubIssueCloseReason? {
        githubIssueStateFilter == .closed ? githubCloseReasonFilter : nil
    }

    private func isGitHubBoardCacheStale(fetchedAt: Date?) -> Bool {
        guard let fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) >= gitHubBoardCacheLifetime
    }

}
