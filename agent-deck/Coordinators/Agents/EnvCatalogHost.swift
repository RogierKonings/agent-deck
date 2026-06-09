import Foundation

@MainActor
protocol EnvCatalogHost: AnyObject {
    var selectedProjectPath: String? { get }

    func refreshAfterEnvFileChange(sourceKind: ResourceScopeKind, filePath: String)
}
