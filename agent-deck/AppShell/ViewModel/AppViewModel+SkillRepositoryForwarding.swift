import Foundation

// MARK: - Skill repository host

extension AppViewModel: SkillRepositoryHost {
    var importedSkillRepositories: [ImportedSkillRepository] {
        appSettings.importedSkillRepositories
    }

    var externalSkillPaths: Set<String> { appSettings.externalSkillPaths }

    /// The folder the skill-import picker opens to: the selected project's
    /// `.pi/skills` folder, or pi's global skills folder when no project is
    /// selected. Falls back to a parent that exists so the open panel always
    /// lands on a real directory; nothing is created on disk.
    var suggestedExternalSkillsDirectoryURL: URL {
        let fileManager = FileManager.default
        func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }

        if let projectURL = selectedDiscoveredProject?.url {
            let projectSkills = projectURL.appendingPathComponent(".pi/skills", isDirectory: true)
            return isDirectory(projectSkills) ? projectSkills : projectURL
        }

        let globalSkills = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/skills", isDirectory: true)
        return isDirectory(globalSkills) ? globalSkills : fileManager.homeDirectoryForCurrentUser
    }

    @discardableResult
    func addExternalSkillPaths(_ paths: [String]) -> Bool {
        settings.controller.addExternalSkillPaths(paths)
    }

    func upsertImportedSkillRepository(_ record: ImportedSkillRepository) {
        settings.controller.upsertImportedSkillRepository(record)
    }

    func removeImportedSkillRepository(id: UUID) {
        settings.controller.removeImportedSkillRepository(id: id)
    }

    func publishImportedSkillRepositorySettings() {
        settings.publish()
    }

    func refreshSkillCatalog() {
        refresh(includeModels: false, scanAllProjects: true)
    }

    func selectImportedSkill(named name: String) {
        selectedSkillID = allVisibleSkillRecords.first { $0.name == name }?.id ?? selectedSkillID
    }
}

// MARK: - Skill repository view/API compatibility

extension AppViewModel {
    var isCheckingAllSkillUpdates: Bool { skillRepositories.isCheckingAllSkillUpdates }
    var isUpdatingAllSkillRepositories: Bool { skillRepositories.isUpdatingAllSkillRepositories }

    var skillBatchActionMessage: String? {
        get { skillRepositories.skillBatchActionMessage }
        set { skillRepositories.skillBatchActionMessage = newValue }
    }

    var skillRepositoriesWithKnownUpdates: [ImportedSkillRepository] {
        skillRepositories.skillRepositoriesWithKnownUpdates
    }

    func importedRepository(for skill: SkillRecord) -> ImportedSkillRepository? {
        skillRepositories.importedRepository(for: skill)
    }

    func prepareRemoteSkillImport(
        from rawInput: String,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> RemoteSkillImportContext {
        try await skillRepositories.prepareRemoteSkillImport(from: rawInput, progress: progress)
    }

    func importRemoteSkills(
        context: RemoteSkillImportContext,
        selectedCandidates: [RemoteSkillCandidate]
    ) async throws -> SkillImportResult {
        try await skillRepositories.importRemoteSkills(context: context, selectedCandidates: selectedCandidates)
    }

    func discardDiscoveryClone(_ context: RemoteSkillImportContext) {
        skillRepositories.discardDiscoveryClone(context)
    }

    func checkSkillRepositoryForUpdate(_ repository: ImportedSkillRepository) async throws -> SkillRepositoryUpdateStatus {
        try await skillRepositories.checkSkillRepositoryForUpdate(repository)
    }

    func updateSkillRepository(_ repository: ImportedSkillRepository) async throws -> SkillRepositoryUpdateOutcome {
        try await skillRepositories.updateSkillRepository(repository)
    }

    func resolveSkillRepositoryUpdate(
        _ repository: ImportedSkillRepository,
        resolutions: [String: SkillConflictResolution]
    ) async throws -> SkillRepositoryUpdateOutcome {
        try await skillRepositories.resolveSkillRepositoryUpdate(repository, resolutions: resolutions)
    }

    func checkAllSkillRepositoriesForUpdates() async {
        await skillRepositories.checkAllSkillRepositoriesForUpdates()
    }

    func updateAllSkillRepositoriesWithKnownUpdates() async {
        await skillRepositories.updateAllSkillRepositoriesWithKnownUpdates()
    }

    func readRemoteSkillFile(directory: String, inCloneAt clonePath: URL) async throws -> String {
        try await skillRepositories.readRemoteSkillFile(directory: directory, inCloneAt: clonePath)
    }

    func chooseExternalSkillsDirectory(startingAt url: URL? = nil, completion: @escaping (URL?) -> Void) {
        skillRepositories.chooseExternalSkillsDirectory(startingAt: url, completion: completion)
    }

    func importExternalSkills(_ candidates: [ExternalSkillCandidate]) throws -> SkillImportResult {
        try skillRepositories.importExternalSkills(candidates)
    }
}
