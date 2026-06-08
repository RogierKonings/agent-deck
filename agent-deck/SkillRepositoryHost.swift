import Foundation

/// Dynamic context and side effects `SkillRepositoryCoordinator` delegates to the app shell.
@MainActor
protocol SkillRepositoryHost: AnyObject {
    var importedSkillRepositories: [ImportedSkillRepository] { get }
    func addExternalSkillPaths(_ paths: [String])
    func upsertImportedSkillRepository(_ record: ImportedSkillRepository)
    func removeImportedSkillRepository(id: UUID)
    func publishImportedSkillRepositorySettings()
    func refreshSkillCatalog()
    func selectImportedSkill(named: String)
}
