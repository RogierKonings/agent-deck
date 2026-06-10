import Foundation

@MainActor
protocol PromptRepositoryHost: AnyObject {
    var appSettings: AppSettings { get }
    var enabledProjects: [DiscoveredProject] { get }
    var assignedProjectPaths: [String] { get }

    func projectPreference(for path: String) -> ProjectPreference
    func setAssignedPromptTemplate(_ name: String, assigned: Bool, for projectPath: String)
    func applyProjectPreferenceChanges()
    func reconcileSnapshotsFromPreferences()
    @discardableResult
    func setDefaultPromptTemplate(_ name: String, enabled: Bool) -> Bool
    @discardableResult
    func setBundledPromptDisabled(_ name: String, isDisabled: Bool) -> Bool
    @discardableResult
    func removeExternalPromptPaths(_ paths: [String]) -> Bool
    func publishSettings()
    func refreshPrompts(scanAllProjects: Bool)
    func replacePromptSettingsPaths(oldURLs: [URL], newURL: URL?) throws
    func selectPromptTemplate(named name: String)
    func markPromptPendingDeletion(_ prompt: PromptTemplateRecord)
    func selectFirstVisiblePromptTemplate()
}
