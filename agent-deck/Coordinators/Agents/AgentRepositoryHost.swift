import Foundation

@MainActor
protocol AgentRepositoryHost: AnyObject {
    var appSettings: AppSettings { get }
    var enabledProjects: [DiscoveredProject] { get }
    var assignedProjectPaths: [String] { get }

    func projectPreference(for path: String) -> ProjectPreference
    func setAssignedAgent(_ name: String, assigned: Bool, for projectPath: String)
    func applyProjectPreferenceChanges()
    func reconcileSnapshotsFromPreferences()
    @discardableResult
    func setDefaultAgent(_ name: String, enabled: Bool) -> Bool
    func publishSettings()
    func refreshAgents(scanAllProjects: Bool)
}
