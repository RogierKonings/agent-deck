import Foundation

@MainActor
protocol ModelCatalogHost: AnyObject {
    func availableModelsDidUpdate()
}
