import Foundation

// MARK: - Catalog auto-refresh host

extension AppViewModel: CatalogAutoRefreshHost {
    var isShutdown: Bool { didShutdown }

    func fallbackWatchedURLs() -> [URL] {
        AppRefreshService.watchedURLs(
            projects: selectedDiscoveredProject.map { [$0] } ?? [],
            snapshot: snapshot,
            externalSkillPaths: appSettings.externalSkillPaths,
            externalPromptPaths: appSettings.externalPromptPaths
        )
    }

    func triggerCatalogRefresh(includeModels: Bool) {
        refresh(includeModels: includeModels)
    }
}
