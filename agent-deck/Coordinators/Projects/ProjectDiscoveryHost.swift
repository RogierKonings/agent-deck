import Foundation

/// Side effects `ProjectDiscoveryState` delegates back to the app shell.
@MainActor
protocol ProjectDiscoveryHost: AnyObject {
    func invalidatePendingProjectRefresh()
    func refreshAfterProjectDiscovery(
        includeModels: Bool,
        scanAllProjects: Bool,
        extraProjectPathsToScan: Set<String>
    )
    func resetGitHubProjectScopedState()
    func onSelectedProjectPathChanged()
    func removeProjectSnapshot(for path: String)
    func setSnapshotToAggregate()
}
