import Foundation

// MARK: - Skill repository host

extension AppViewModel: SkillRepositoryHost {
    var importedSkillRepositories: [ImportedSkillRepository] {
        appSettings.importedSkillRepositories
    }

    func addExternalSkillPaths(_ paths: [String]) {
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
}
