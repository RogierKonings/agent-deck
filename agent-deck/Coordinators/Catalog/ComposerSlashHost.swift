import Foundation

@MainActor
protocol ComposerSlashHost: AnyObject {
    var selectedProjectPath: String? { get }
    var defaultSkillNames: Set<String> { get }
    var defaultPromptTemplateNames: Set<String> { get }
    var disabledBundledSkillNames: Set<String> { get }
    var disabledBundledPromptNames: Set<String> { get }
    var slashCommandSettings: AppSettings { get }

    func projectPreference(for path: String) -> ProjectPreference
    func skillCatalogForProjectPath(_ projectPath: String) -> [SkillRecord]
    func globalSkillCatalog() -> [SkillRecord]
    func promptTemplateCatalog(forProjectPath projectPath: String) -> [PromptTemplateRecord]
    var allVisiblePromptTemplateRecords: [PromptTemplateRecord] { get }
}
