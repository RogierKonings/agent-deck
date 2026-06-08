import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class SkillRepositoryCoordinator {
    weak var host: SkillRepositoryHost?
    private let syncService: SkillRepositorySyncService

    private(set) var isCheckingAllSkillUpdates = false
    private(set) var isUpdatingAllSkillRepositories = false
    var skillBatchActionMessage: String?

    init(syncService: SkillRepositorySyncService) {
        self.syncService = syncService
    }

    func attach(host: SkillRepositoryHost) {
        self.host = host
    }

    // MARK: - Local external skill folders

    /// The folder the skill-import picker opens to: the selected project's
    /// `.pi/skills` folder, or pi's global skills folder when no project is
    /// selected. Falls back to a parent that exists so the open panel always
    /// lands on a real directory; nothing is created on disk.
    var suggestedExternalSkillsDirectoryURL: URL {
        host?.suggestedExternalSkillsDirectoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func chooseExternalSkillsDirectory(startingAt url: URL? = nil, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Skills Folder"
        panel.message = "Choose a skill root or a folder to search recursively for SKILL.md files you want to add to the \(AppBrand.displayName) skill catalog."
        panel.directoryURL = url ?? suggestedExternalSkillsDirectoryURL

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            DispatchQueue.main.async {
                guard response == .OK,
                      let selectedURL = panel.url?.standardizedFileURL else {
                    completion(nil)
                    return
                }
                completion(selectedURL)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func importExternalSkills(_ candidates: [ExternalSkillCandidate]) throws -> SkillImportResult {
        var importedNames: [String] = []
        var skippedNames: [String] = []
        var importedPaths: [String] = []
        let existingPaths = host?.externalSkillPaths ?? []

        for candidate in candidates {
            let sourcePath = URL(fileURLWithPath: candidate.sourceRootPath).standardizedFileURL.path
            if existingPaths.contains(sourcePath) {
                skippedNames.append(candidate.name)
                continue
            }
            importedPaths.append(sourcePath)
            importedNames.append(candidate.name)
        }

        if host?.addExternalSkillPaths(importedPaths) == true {
            host?.publishImportedSkillRepositorySettings()
        }
        host?.refreshSkillCatalog()
        if let firstImported = importedNames.first {
            host?.selectImportedSkill(named: firstImported)
        }
        return SkillImportResult(importedNames: importedNames, skippedNames: skippedNames)
    }

    // MARK: - Remote skill repositories

    /// The synced repository whose clone contains `skill`, if any.
    func importedRepository(for skill: SkillRecord) -> ImportedSkillRepository? {
        (host?.importedSkillRepositories ?? []).first { $0.contains(skillFilePath: skill.filePath) }
    }

    /// Resolve a pasted GitHub / skills.sh URL, clone it for discovery (or
    /// reuse an existing clone when the repo is already imported), and list
    /// its skills.
    func prepareRemoteSkillImport(
        from rawInput: String,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> RemoteSkillImportContext {
        let source = try SkillRepositorySyncService.resolveSource(from: rawInput)
        let existing = (host?.importedSkillRepositories ?? []).first {
            $0.owner.caseInsensitiveCompare(source.owner) == .orderedSame
                && $0.repo.caseInsensitiveCompare(source.repo) == .orderedSame
        }

        if let existing {
            let clonePath = URL(fileURLWithPath: existing.clonePath, isDirectory: true)
            let candidates = try await syncService.listSkills(inCloneAt: clonePath, progress: progress)
            return RemoteSkillImportContext(
                source: source,
                clonePath: clonePath,
                resolvedRef: existing.ref,
                headCommit: existing.lastSyncedCommit,
                candidates: candidates,
                existingRepository: existing
            )
        }

        let clonePath = SkillRepositorySyncService.cloneDirectoryURL(owner: source.owner, repo: source.repo)
        let info = try await syncService.cloneForDiscovery(source, into: clonePath)
        let candidates = try await syncService.listSkills(inCloneAt: clonePath, progress: progress)
        return RemoteSkillImportContext(
            source: source,
            clonePath: clonePath,
            resolvedRef: info.resolvedRef,
            headCommit: info.headCommit,
            candidates: candidates,
            existingRepository: nil
        )
    }

    /// Sparse-check-out the selected skills, register their roots in the
    /// catalog, and record (or extend) the synced-repository entry.
    func importRemoteSkills(
        context: RemoteSkillImportContext,
        selectedCandidates: [RemoteSkillCandidate]
    ) async throws -> SkillImportResult {
        guard !selectedCandidates.isEmpty else {
            return SkillImportResult(importedNames: [], skippedNames: [])
        }

        try await syncService.checkout(
            selectedCandidates,
            inCloneAt: context.clonePath,
            additive: context.existingRepository != nil
        )

        let rootPaths = selectedCandidates.map { skillRootPath(for: $0, clonePath: context.clonePath) }
        host?.addExternalSkillPaths(rootPaths)

        var syncedDirectories = Set(context.existingRepository?.syncedSkillRelativePaths ?? [])
        syncedDirectories.formUnion(selectedCandidates.map(\.repoRelativeDirectory))

        let record = ImportedSkillRepository(
            id: context.existingRepository?.id ?? UUID(),
            remoteURL: context.source.remoteURL,
            owner: context.source.owner,
            repo: context.source.repo,
            ref: context.resolvedRef,
            clonePath: context.clonePath.standardizedFileURL.path,
            syncedSkillRelativePaths: syncedDirectories.sorted(),
            lastSyncedCommit: context.headCommit,
            lastSyncedDate: Date(),
            lastCheckedDate: context.existingRepository?.lastCheckedDate,
            latestKnownRemoteCommit: context.existingRepository?.latestKnownRemoteCommit
        )
        host?.upsertImportedSkillRepository(record)
        host?.publishImportedSkillRepositorySettings()

        host?.refreshSkillCatalog()
        if let firstName = selectedCandidates.first?.name {
            host?.selectImportedSkill(named: firstName)
        }
        return SkillImportResult(importedNames: selectedCandidates.map(\.name), skippedNames: [])
    }

    /// Delete a discovery clone the user fetched but never imported from.
    func discardDiscoveryClone(_ context: RemoteSkillImportContext) {
        guard context.isFreshClone else { return }
        let path = context.clonePath.standardizedFileURL.path
        let isReferenced = (host?.importedSkillRepositories ?? []).contains {
            URL(fileURLWithPath: $0.clonePath).standardizedFileURL.path == path
        }
        guard !isReferenced else { return }
        try? FileManager.default.removeItem(at: context.clonePath)
    }

    private func skillRootPath(for candidate: RemoteSkillCandidate, clonePath: URL) -> String {
        let root = candidate.isWholeRepository
            ? clonePath
            : clonePath.appendingPathComponent(candidate.repoRelativeDirectory, isDirectory: true)
        return root.standardizedFileURL.path
    }

    /// Manual "Check for Updates": a network-only `git ls-remote`. The result
    /// is recorded so the skill detail can show an "update available" badge.
    @discardableResult
    func checkSkillRepositoryForUpdate(_ repository: ImportedSkillRepository) async throws -> SkillRepositoryUpdateStatus {
        let status = try await syncService.checkForUpdate(
            remoteURL: repository.remoteURL,
            ref: repository.ref,
            syncedCommit: repository.lastSyncedCommit
        )
        var updated = repository
        updated.lastCheckedDate = Date()
        switch status {
        case .upToDate:
            updated.latestKnownRemoteCommit = repository.lastSyncedCommit
        case let .updateAvailable(remoteCommit):
            updated.latestKnownRemoteCommit = remoteCommit
        }
        host?.upsertImportedSkillRepository(updated)
        host?.publishImportedSkillRepositorySettings()
        return status
    }

    /// Fetch and fast-forward a synced repository. Returns `.conflicts` when an
    /// in-place edit collides with an upstream change for the caller to resolve.
    func updateSkillRepository(_ repository: ImportedSkillRepository) async throws -> SkillRepositoryUpdateOutcome {
        let outcome = try await syncService.update(
            cloneAt: URL(fileURLWithPath: repository.clonePath, isDirectory: true),
            ref: repository.ref
        )
        applyUpdateOutcome(outcome, to: repository)
        return outcome
    }

    /// Apply an update after the user chose Keep Mine / Take Remote per file.
    func resolveSkillRepositoryUpdate(
        _ repository: ImportedSkillRepository,
        resolutions: [String: SkillConflictResolution]
    ) async throws -> SkillRepositoryUpdateOutcome {
        let outcome = try await syncService.resolveConflicts(
            cloneAt: URL(fileURLWithPath: repository.clonePath, isDirectory: true),
            ref: repository.ref,
            resolutions: resolutions
        )
        applyUpdateOutcome(outcome, to: repository)
        return outcome
    }

    private func applyUpdateOutcome(_ outcome: SkillRepositoryUpdateOutcome, to repository: ImportedSkillRepository) {
        // Reconcile the stored record to the clone's real HEAD for both a fresh
        // fast-forward and the "already up to date" case. The latter matters when
        // the clone advanced earlier but the record was left stale — otherwise the
        // "update available" badge sticks even though there's nothing to pull.
        let resolvedCommit: String
        let didChangeFiles: Bool
        switch outcome {
        case let .updated(newCommit):
            resolvedCommit = newCommit
            didChangeFiles = true
        case let .alreadyUpToDate(commit):
            resolvedCommit = commit
            didChangeFiles = false
        case .conflicts:
            return
        }

        var updated = repository
        let commitChanged = updated.lastSyncedCommit != resolvedCommit
        updated.lastSyncedCommit = resolvedCommit
        updated.latestKnownRemoteCommit = resolvedCommit
        if commitChanged { updated.lastSyncedDate = Date() }
        updated.lastCheckedDate = Date()
        host?.upsertImportedSkillRepository(updated)
        host?.publishImportedSkillRepositorySettings()
        if didChangeFiles { host?.refreshSkillCatalog() }
    }

    /// Synced repositories a manual check has flagged as having an upstream update.
    var skillRepositoriesWithKnownUpdates: [ImportedSkillRepository] {
        (host?.importedSkillRepositories ?? []).filter(\.hasKnownUpdate)
    }

    /// Run a manual update check across every synced skill repository.
    func checkAllSkillRepositoriesForUpdates() async {
        guard !isCheckingAllSkillUpdates, !isUpdatingAllSkillRepositories else { return }
        let repositories = host?.importedSkillRepositories ?? []
        guard !repositories.isEmpty else { return }

        isCheckingAllSkillUpdates = true
        defer { isCheckingAllSkillUpdates = false }

        var failures = 0
        for repository in repositories {
            do { _ = try await checkSkillRepositoryForUpdate(repository) }
            catch { failures += 1 }
        }

        let updateCount = skillRepositoriesWithKnownUpdates.count
        if failures > 0 {
            skillBatchActionMessage = "Checked \(repositories.count) skill repositor\(repositories.count == 1 ? "y" : "ies"). \(updateCount) ha\(updateCount == 1 ? "s" : "ve") an update available. \(failures) could not be checked."
        } else if updateCount == 0 {
            skillBatchActionMessage = "All synced skills are up to date."
        }
        // When updates were found and nothing failed, the per-row badges show
        // the result — no alert needed.
    }

    /// Apply updates to every synced repository a check has flagged. Repositories
    /// whose local edits conflict with upstream are skipped and reported so the
    /// user can resolve them one at a time.
    func updateAllSkillRepositoriesWithKnownUpdates() async {
        guard !isUpdatingAllSkillRepositories, !isCheckingAllSkillUpdates else { return }
        let targets = skillRepositoriesWithKnownUpdates
        guard !targets.isEmpty else { return }

        isUpdatingAllSkillRepositories = true
        defer { isUpdatingAllSkillRepositories = false }

        var updated = 0
        var conflicted = 0
        var failed = 0
        for target in targets {
            // Re-read the record — an earlier iteration may have mutated settings.
            guard let current = (host?.importedSkillRepositories ?? []).first(where: { $0.id == target.id }) else { continue }
            do {
                switch try await updateSkillRepository(current) {
                case .updated: updated += 1
                case .alreadyUpToDate: break
                case .conflicts: conflicted += 1
                }
            } catch {
                failed += 1
            }
        }

        var parts: [String] = []
        if updated > 0 {
            parts.append("Updated \(updated) skill\(updated == 1 ? "" : "s").")
        }
        if conflicted > 0 {
            parts.append("\(conflicted) skill\(conflicted == 1 ? " has" : "s have") local edits that conflict with the update — open each skill to resolve.")
        }
        if failed > 0 {
            parts.append("\(failed) skill\(failed == 1 ? "" : "s") could not be updated.")
        }
        skillBatchActionMessage = parts.isEmpty ? "No skills needed updating." : parts.joined(separator: "\n\n")
    }

    func readRemoteSkillFile(directory: String, inCloneAt clonePath: URL) async throws -> String {
        try await syncService.readSkillFile(directory: directory, inCloneAt: clonePath)
    }

    func unlistSkillFromSyncedRepository(_ skill: SkillRecord, deletionTargetURL: URL) {
        guard let repository = importedRepository(for: skill) else { return }
        let rootPath = deletionTargetURL.standardizedFileURL.path
        let cloneURL = URL(fileURLWithPath: repository.clonePath, isDirectory: true).standardizedFileURL

        var remaining = repository.syncedSkillRelativePaths
        remaining.removeAll { relativePath in
            let candidate = relativePath.isEmpty
                ? cloneURL.path
                : cloneURL.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL.path
            return candidate == rootPath
        }
        guard remaining != repository.syncedSkillRelativePaths else { return }

        if remaining.isEmpty {
            // Nothing left synced from this repository — fully un-register it so
            // it is no longer checked for updates, and drop its app-managed clone.
            host?.removeImportedSkillRepository(id: repository.id)
            try? FileManager.default.removeItem(at: cloneURL)
        } else {
            var updated = repository
            updated.syncedSkillRelativePaths = remaining
            host?.upsertImportedSkillRepository(updated)
            reconcileSparseCheckout(for: updated)
        }
        host?.publishImportedSkillRepositorySettings()
    }

    /// Keep Git's sparse-checkout patterns aligned with Agent Deck's tracked
    /// imported-skill set. This is best-effort because the user-facing removal
    /// already succeeded once settings were updated.
    private func reconcileSparseCheckout(for repository: ImportedSkillRepository) {
        let cloneURL = URL(fileURLWithPath: repository.clonePath, isDirectory: true)
        let directories = repository.syncedSkillRelativePaths.filter { !$0.isEmpty }
        Task { [syncService] in
            do {
                try await syncService.setSparseCheckout(directories, inCloneAt: cloneURL)
            } catch {
#if DEBUG
                NSLog("Failed to reconcile sparse checkout for imported skill repository %@: %@", repository.displayName, String(describing: error))
#endif
            }
        }
    }
}
