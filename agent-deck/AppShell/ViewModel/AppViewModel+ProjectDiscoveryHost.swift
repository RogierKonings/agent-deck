import Foundation

extension AppViewModel: ProjectDiscoveryHost {
    func invalidatePendingProjectRefresh() {
        refreshCoordinator.invalidatePendingRefresh()
    }

    func refreshAfterProjectDiscovery(
        includeModels: Bool,
        scanAllProjects: Bool,
        extraProjectPathsToScan: Set<String>
    ) {
        refresh(
            includeModels: includeModels,
            scanAllProjects: scanAllProjects,
            extraProjectPathsToScan: extraProjectPathsToScan
        )
    }

    func resetGitHubProjectScopedState() {
        github.resetProjectScopedState()
    }

    func onSelectedProjectPathChanged() {
        clearAgentUniverseCache()
    }

    func removeProjectSnapshot(for path: String) {
        allProjectSnapshots.removeValue(forKey: path)
    }

    func setSnapshotToAggregate() {
        snapshot = makeAggregateSnapshot()
    }
}
