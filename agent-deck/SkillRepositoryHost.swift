import Foundation

/// Dynamic context and side effects `SkillRepositoryCoordinator` delegates to the app shell.
@MainActor
protocol SkillRepositoryHost: AnyObject {
    var importedSkillRepositories: [ImportedSkillRepository] { get }
    var externalSkillPaths: Set<String> { get }
    var suggestedExternalSkillsDirectoryURL: URL { get }
    @discardableResult
    func addExternalSkillPaths(_ paths: [String]) -> Bool
    func upsertImportedSkillRepository(_ record: ImportedSkillRepository)
    func removeImportedSkillRepository(id: UUID)
    func publishImportedSkillRepositorySettings()
    func refreshSkillCatalog()
    func selectImportedSkill(named: String)
}
