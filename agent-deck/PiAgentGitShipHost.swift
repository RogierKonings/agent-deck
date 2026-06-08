import Foundation

/// Dynamic context and side effects `PiAgentGitShipCoordinator` delegates to the app shell.
@MainActor
protocol PiAgentGitShipHost: AnyObject {
    func piAgentCommitMessageModel() -> AvailableModel?
    func repositoryChangesEntry(for projectPath: String) -> RepositoryChangesCacheEntry?
    func refreshSelectedSessionRepoChanges(force: Bool)
    var keepWorktreeAfterMerge: Bool { get }
}
