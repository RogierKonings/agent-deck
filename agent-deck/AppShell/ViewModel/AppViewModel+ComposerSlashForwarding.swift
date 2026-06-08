import Foundation

// MARK: - Composer slash host

extension AppViewModel: ComposerSlashHost {
    var defaultSkillNames: Set<String> { appSettings.defaultSkillNames }
    var defaultPromptTemplateNames: Set<String> { appSettings.defaultPromptTemplateNames }
    var disabledBundledSkillNames: Set<String> { appSettings.disabledBundledSkillNames }
    var disabledBundledPromptNames: Set<String> { appSettings.disabledBundledPromptNames }
    var slashCommandSettings: AppSettings { appSettings }

    func globalSkillCatalog() -> [SkillRecord] {
        var seen = Set<String>()
        return (globalSnapshot.skills + globalSnapshot.librarySkills).filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Composer slash view/API compatibility

extension AppViewModel {
    func activeParentSkillNames(forProjectPath projectPath: String?) -> Set<String> {
        composerSlash.activeParentSkillNames(forProjectPath: projectPath)
    }

    func activeParentSkills(forProjectPath projectPath: String?) -> [SkillRecord] {
        composerSlash.activeParentSkills(forProjectPath: projectPath)
    }

    func activeParentPromptTemplateNames(forProjectPath projectPath: String?) -> Set<String> {
        composerSlash.activeParentPromptTemplateNames(forProjectPath: projectPath)
    }

    func activeParentPromptTemplates(forProjectPath projectPath: String?) -> [PromptTemplateRecord] {
        composerSlash.activeParentPromptTemplates(forProjectPath: projectPath)
    }

    func slashUniverse(forProjectPath projectPath: String?) -> SlashUniverse {
        composerSlash.slashUniverse(forProjectPath: projectPath)
    }
}
