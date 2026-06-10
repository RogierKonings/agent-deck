import Foundation

@MainActor
protocol SkillCatalogHost: AnyObject {
    var appSettings: AppSettings { get }
    var enabledProjects: [DiscoveredProject] { get }
    var assignedProjectPaths: [String] { get }
    var selectedProjectPath: String? { get }
    var effectiveAgents: [EffectiveAgentRecord] { get }
    var standardizedExternalSkillPaths: Set<String> { get }

    func projectPreference(for path: String) -> ProjectPreference
    func setAssignedSkill(_ name: String, assigned: Bool, for projectPath: String)
    func applyProjectPreferenceChanges()
    func reconcileSnapshotsFromPreferences()
    @discardableResult
    func setDefaultSkill(_ name: String, enabled: Bool) -> Bool
    @discardableResult
    func setBundledSkillDisabled(_ name: String, isDisabled: Bool) -> Bool
    @discardableResult
    func removeExternalSkillPaths(_ paths: [String]) -> Bool
    func publishSettings()
    func refreshSkills(scanAllProjects: Bool, silentlyReconcile: Bool)
    func selectSkill(named name: String)
    func markSkillPendingDeletion(_ skill: SkillRecord)
    func selectFirstVisibleSkill()
    func unlistSkillFromSyncedRepository(_ skill: SkillRecord, deletionTargetURL: URL)
    func removeSkillFromAgentDrafts(named skillName: String) throws
    func setSkillOnAgent(_ skill: SkillRecord, enabled: Bool, for agent: EffectiveAgentRecord) throws
}
