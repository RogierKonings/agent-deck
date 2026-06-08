import Foundation
import Observation

@MainActor
@Observable
final class SkillCatalogCoordinator {
    weak var host: SkillCatalogHost?

    func attach(host: SkillCatalogHost) {
        self.host = host
    }

    func bundledSkillIsDisabled(_ skill: SkillRecord) -> Bool {
        guard let host else { return false }
        return skill.source.kind == .builtin && host.appSettings.disabledBundledSkillNames.contains(skill.name)
    }

    func setBundledSkillDisabled(_ isDisabled: Bool, for skill: SkillRecord) {
        guard let host, skill.source.kind == .builtin else { return }
        guard host.setBundledSkillDisabled(skill.name, isDisabled: isDisabled) else { return }
        host.publishSettings()
        host.refreshSkills(scanAllProjects: false, silentlyReconcile: false)
    }

    func addSkillToSelectedProject(_ skill: SkillRecord) throws {
        guard let host, let selectedProjectPath = host.selectedProjectPath else {
            throw CocoaError(.fileNoSuchFile)
        }
        try setSkill(skill, enabled: true, forProjectPath: selectedProjectPath)
    }

    func removeSkillFromSelectedProject(_ skill: SkillRecord) throws {
        guard let host, let selectedProjectPath = host.selectedProjectPath else {
            throw CocoaError(.fileNoSuchFile)
        }
        try setSkill(skill, enabled: false, forProjectPath: selectedProjectPath)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for project: DiscoveredProject) throws {
        try setSkill(skill, enabled: enabled, forProjectPath: project.path)
    }

    func skill(_ skill: SkillRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        guard let host else { return false }
        return host.projectPreference(for: project.path).assignedSkillNames.contains(skill.name)
    }

    func assignedProjects(for skill: SkillRecord) -> [DiscoveredProject] {
        guard let host else { return [] }
        return host.enabledProjects.filter { self.skill(skill, isEnabledFor: $0) }
    }

    func skill(_ skill: SkillRecord, isAssignedTo agent: EffectiveAgentRecord) -> Bool {
        agent.resolved.skills.contains(skill.name)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        guard let host else { return }
        try host.setSkillOnAgent(skill, enabled: enabled, for: agent)
    }

    func assignedAgents(for skillRecord: SkillRecord) -> [EffectiveAgentRecord] {
        guard let host else { return [] }
        return host.effectiveAgents.filter { skill(skillRecord, isAssignedTo: $0) }
    }

    func enableSkillGlobally(_ skill: SkillRecord) throws {
        guard let host else { return }
        if skill.source.kind == .project || skill.source.kind == .legacyProject {
            try moveSkillToGlobalDirectory(skill)
        }
        guard host.setDefaultSkill(skill.name, enabled: true) else {
            host.refreshSkills(scanAllProjects: true, silentlyReconcile: false)
            host.selectSkill(named: skill.name)
            return
        }
        host.publishSettings()
        host.refreshSkills(scanAllProjects: true, silentlyReconcile: false)
        host.selectSkill(named: skill.name)
    }

    func disableSkillGlobally(_ skill: SkillRecord) throws {
        guard let host else { return }
        guard host.setDefaultSkill(skill.name, enabled: false) else { return }
        host.publishSettings()
        host.refreshSkills(scanAllProjects: false, silentlyReconcile: false)
    }

    func canDeleteSkill(_ skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func deleteSkill(_ skill: SkillRecord) throws {
        try performSkillDeletion(skill)
        host?.refreshSkills(scanAllProjects: true, silentlyReconcile: true)
    }

    func deleteSkills(_ skills: [SkillRecord]) -> [String] {
        var failed: [String] = []
        for skill in skills {
            do { try performSkillDeletion(skill) }
            catch { failed.append(skill.name) }
        }
        if skills.count > failed.count {
            host?.refreshSkills(scanAllProjects: true, silentlyReconcile: true)
        }
        return failed
    }

    func isImportedSkill(_ skill: SkillRecord) -> Bool {
        guard let host else { return false }
        let paths = host.standardizedExternalSkillPaths
        guard !paths.isEmpty else { return false }
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        if paths.contains(filePath) { return true }
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        return paths.contains(rootPath)
    }

    func removeSkillFromCatalog(_ skill: SkillRecord) throws {
        try performSkillCatalogRemoval(skill)
        host?.refreshSkills(scanAllProjects: true, silentlyReconcile: true)
    }

    func removeSkillsFromCatalog(_ skills: [SkillRecord]) -> [String] {
        var failed: [String] = []
        for skill in skills {
            do { try performSkillCatalogRemoval(skill) }
            catch { failed.append(skill.name) }
        }
        if skills.count > failed.count {
            host?.refreshSkills(scanAllProjects: true, silentlyReconcile: true)
        }
        return failed
    }

    func skillIsEnabledGlobally(_ skill: SkillRecord) -> Bool {
        host?.appSettings.defaultSkillNames.contains(skill.name) ?? false
    }

    func moveSkillToGlobalCatalog(_ skill: SkillRecord) throws {
        guard let host else { return }
        try moveSkillToGlobalDirectory(skill)
        host.refreshSkills(scanAllProjects: true, silentlyReconcile: false)
    }

    func skillIsEnabledForSelectedProject(_ skill: SkillRecord) -> Bool {
        guard let host, let selectedProjectPath = host.selectedProjectPath else { return false }
        return host.projectPreference(for: selectedProjectPath).assignedSkillNames.contains(skill.name)
    }

    private func setSkill(_ skill: SkillRecord, enabled: Bool, forProjectPath projectPath: String) throws {
        guard let host else { return }
        host.setAssignedSkill(skill.name, assigned: enabled, for: projectPath)
        host.applyProjectPreferenceChanges()
        host.reconcileSnapshotsFromPreferences()
        host.selectSkill(named: skill.name)
    }

    private func performSkillDeletion(_ skill: SkillRecord) throws {
        guard canDeleteSkill(skill) else { throw CocoaError(.fileWriteNoPermission) }
        guard let host else { return }

        let targetURL = skillDeletionTargetURL(for: skill)
        try removeSkillReferences(named: skill.name)
        try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
        removeExternalSkillCatalogReferences(for: skill, deletedTarget: targetURL)
        host.unlistSkillFromSyncedRepository(skill, deletionTargetURL: skillDeletionTargetURL(for: skill))

        host.markSkillPendingDeletion(skill)
        host.selectFirstVisibleSkill()
    }

    private func performSkillCatalogRemoval(_ skill: SkillRecord) throws {
        guard isImportedSkill(skill) else { throw CocoaError(.fileWriteNoPermission) }
        guard let host else { return }

        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let rootURL = skillDeletionTargetURL(for: skill).standardizedFileURL

        try removeSkillReferences(named: skill.name)

        let pathsToRemove = host.appSettings.externalSkillPaths.filter { rawPath in
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            return path == rootURL.path || path == fileURL.path
        }
        if host.removeExternalSkillPaths(Array(pathsToRemove)) {
            host.publishSettings()
        }
        host.unlistSkillFromSyncedRepository(skill, deletionTargetURL: skillDeletionTargetURL(for: skill))

        host.markSkillPendingDeletion(skill)
        host.selectFirstVisibleSkill()
    }

    private func removeSkillReferences(named skillName: String) throws {
        guard let host else { return }
        _ = host.setDefaultSkill(skillName, enabled: false)
        host.publishSettings()

        for projectPath in host.assignedProjectPaths {
            host.setAssignedSkill(skillName, assigned: false, for: projectPath)
        }
        host.applyProjectPreferenceChanges()
        try host.removeSkillFromAgentDrafts(named: skillName)
    }

    private func removeExternalSkillCatalogReferences(for skill: SkillRecord, deletedTarget: URL) {
        guard let host else { return }
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let deletedTargetPath = deletedTarget.standardizedFileURL.path
        let pathsToRemove = host.appSettings.externalSkillPaths.filter { rawPath in
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            return url.path == fileURL.path || url.path == deletedTargetPath
        }
        guard host.removeExternalSkillPaths(Array(pathsToRemove)) else { return }
        host.publishSettings()
    }

    private func moveSkillToGlobalDirectory(_ skill: SkillRecord) throws {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let sourceURL = skillMoveSourceURL(fileURL: fileURL)
        let destinationRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/skills", isDirectory: true)
            .standardizedFileURL
        let destinationURL = destinationRoot.appendingPathComponent(skill.name, isDirectory: true)

        guard !isSymbolicLink(sourceURL), !isSymbolicLink(fileURL) else {
            throw ResourceRenameError.unsupportedResource("Symlinked skills cannot be made Default safely in app. Move the real skill folder to ~/.pi/agent/skills instead.")
        }
        guard sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else { return }
        try ensureGlobalSkillDestinationAvailable(destinationURL, sourceURL: sourceURL)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true, attributes: nil)

        if fileURL.lastPathComponent == "SKILL.md" {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false, attributes: nil)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL.appendingPathComponent("SKILL.md"))
        }
    }

    private func skillDeletionTargetURL(for skill: SkillRecord) -> URL {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        if fileURL.lastPathComponent == "SKILL.md" {
            return fileURL.deletingLastPathComponent()
        }
        return fileURL
    }

    private func skillMoveSourceURL(fileURL: URL) -> URL {
        if fileURL.lastPathComponent == "SKILL.md" {
            return fileURL.deletingLastPathComponent().standardizedFileURL
        }
        return fileURL.standardizedFileURL
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true ||
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func ensureGlobalSkillDestinationAvailable(_ destinationURL: URL, sourceURL: URL) throws {
        let destination = destinationURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        guard destination.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true).standardizedFileURL.path + "/") else {
            throw ResourceRenameError.unsafePath(destination.path)
        }
        if pathExistsOrIsSymlink(destination), destination.path != source.path {
            throw ResourceRenameError.destinationExists(destination.path)
        }
    }

    private func pathExistsOrIsSymlink(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) { return true }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
