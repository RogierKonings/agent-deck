import Foundation

@MainActor
protocol ModelCatalogHost: AnyObject {
    var appSettings: AppSettings { get }
    func availableModelsDidUpdate()
}
