import Foundation

@MainActor
protocol CatalogAutoRefreshHost: AnyObject {
    var isShutdown: Bool { get }
    func fallbackWatchedURLs() -> [URL]
    func triggerCatalogRefresh(includeModels: Bool)
}
