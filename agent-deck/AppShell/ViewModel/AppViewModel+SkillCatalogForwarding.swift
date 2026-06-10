import Foundation

// MARK: - Skill catalog host

extension AppViewModel: SkillCatalogHost {
    var effectiveAgents: [EffectiveAgentRecord] { snapshot.effectiveAgents }

    func setAssignedSkill(_ name: String, assigned: Bool, for projectPath: String) {
        projects.setAssignedSkill(name, assigned: assigned, for: projectPath)
    }

    func setDefaultSkill(_ name: String, enabled: Bool) -> Bool {
        settings.controller.setDefaultSkill(name, enabled: enabled)
    }

    func setBundledSkillDisabled(_ name: String, isDisabled: Bool) -> Bool {
        settings.controller.setBundledSkillDisabled(name, isDisabled: isDisabled)
    }

    func removeExternalSkillPaths(_ paths: [String]) -> Bool {
        settings.controller.removeExternalSkillPaths(Set(paths))
    }

    func refreshSkills(scanAllProjects: Bool, silentlyReconcile: Bool) {
        refresh(includeModels: false, scanAllProjects: scanAllProjects, silentlyReconcile: silentlyReconcile)
    }

    func selectSkill(named name: String) {
        selectedSkillID = allVisibleSkillRecords.first { $0.name == name }?.id ?? selectedSkillID
    }

    func selectFirstVisibleSkill() {
        selectedSkillID = allVisibleSkillRecords.first?.id
    }

    func unlistSkillFromSyncedRepository(_ skill: SkillRecord, deletionTargetURL: URL) {
        skillRepositories.unlistSkillFromSyncedRepository(skill, deletionTargetURL: deletionTargetURL)
    }
}

// MARK: - Skill catalog view/API compatibility

extension AppViewModel {
    func bundledSkillIsDisabled(_ skill: SkillRecord) -> Bool {
        skillCatalog.bundledSkillIsDisabled(skill)
    }

    func setBundledSkillDisabled(_ isDisabled: Bool, for skill: SkillRecord) {
        skillCatalog.setBundledSkillDisabled(isDisabled, for: skill)
    }

    func addSkillToSelectedProject(_ skill: SkillRecord) throws {
        try skillCatalog.addSkillToSelectedProject(skill)
    }

    func removeSkillFromSelectedProject(_ skill: SkillRecord) throws {
        try skillCatalog.removeSkillFromSelectedProject(skill)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for project: DiscoveredProject) throws {
        try skillCatalog.setSkill(skill, enabled: enabled, for: project)
    }

    func skill(_ skill: SkillRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        skillCatalog.skill(skill, isEnabledFor: project)
    }

    func assignedProjects(for skill: SkillRecord) -> [DiscoveredProject] {
        skillCatalog.assignedProjects(for: skill)
    }

    func skill(_ skill: SkillRecord, isAssignedTo agent: EffectiveAgentRecord) -> Bool {
        skillCatalog.skill(skill, isAssignedTo: agent)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        try skillCatalog.setSkill(skill, enabled: enabled, for: agent)
    }

    func assignedAgents(for skillRecord: SkillRecord) -> [EffectiveAgentRecord] {
        skillCatalog.assignedAgents(for: skillRecord)
    }

    func enableSkillGlobally(_ skill: SkillRecord) throws {
        try skillCatalog.enableSkillGlobally(skill)
    }

    func disableSkillGlobally(_ skill: SkillRecord) throws {
        try skillCatalog.disableSkillGlobally(skill)
    }

    func canDeleteSkill(_ skill: SkillRecord) -> Bool {
        skillCatalog.canDeleteSkill(skill)
    }

    func deleteSkill(_ skill: SkillRecord) throws {
        try skillCatalog.deleteSkill(skill)
    }

    func deleteSkills(_ skills: [SkillRecord]) -> [String] {
        skillCatalog.deleteSkills(skills)
    }

    func isImportedSkill(_ skill: SkillRecord) -> Bool {
        skillCatalog.isImportedSkill(skill)
    }

    func removeSkillFromCatalog(_ skill: SkillRecord) throws {
        try skillCatalog.removeSkillFromCatalog(skill)
    }

    func removeSkillsFromCatalog(_ skills: [SkillRecord]) -> [String] {
        skillCatalog.removeSkillsFromCatalog(skills)
    }

    func skillIsEnabledGlobally(_ skill: SkillRecord) -> Bool {
        skillCatalog.skillIsEnabledGlobally(skill)
    }

    func moveSkillToGlobalCatalog(_ skill: SkillRecord) throws {
        try skillCatalog.moveSkillToGlobalCatalog(skill)
    }

    func skillIsEnabledForSelectedProject(_ skill: SkillRecord) -> Bool {
        skillCatalog.skillIsEnabledForSelectedProject(skill)
    }
}
