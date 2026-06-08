import Foundation
import Observation

@MainActor
@Observable
final class PromptRepositoryCoordinator {
    weak var host: PromptRepositoryHost?

    func attach(host: PromptRepositoryHost) {
        self.host = host
    }

    func prompt(_ prompt: PromptTemplateRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        guard let host else { return false }
        return host.projectPreference(for: project.path).assignedPromptTemplateNames.contains(prompt.name)
    }

    func assignedProjects(for prompt: PromptTemplateRecord) -> [DiscoveredProject] {
        guard let host else { return [] }
        return host.enabledProjects.filter { self.prompt(prompt, isEnabledFor: $0) }
    }

    func promptIsEnabledGlobally(_ prompt: PromptTemplateRecord) -> Bool {
        host?.appSettings.defaultPromptTemplateNames.contains(prompt.name) ?? false
    }

    func setPrompt(_ prompt: PromptTemplateRecord, enabled: Bool, for project: DiscoveredProject) throws {
        guard let host else { return }
        host.setAssignedPromptTemplate(prompt.name, assigned: enabled, for: project.path)
        host.applyProjectPreferenceChanges()
        host.reconcileSnapshotsFromPreferences()
        host.selectPromptTemplate(named: prompt.name)
    }

    func enablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        guard let host else { return }
        guard host.setDefaultPromptTemplate(prompt.name, enabled: true) else { return }
        host.publishSettings()
        host.refreshPrompts(scanAllProjects: false)
    }

    func disablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        guard let host else { return }
        guard host.setDefaultPromptTemplate(prompt.name, enabled: false) else { return }
        host.publishSettings()
        host.refreshPrompts(scanAllProjects: false)
    }

    func bundledPromptIsDisabled(_ prompt: PromptTemplateRecord) -> Bool {
        guard let host else { return false }
        return prompt.source.kind == .builtin && host.appSettings.disabledBundledPromptNames.contains(prompt.name)
    }

    func setBundledPromptDisabled(_ isDisabled: Bool, for prompt: PromptTemplateRecord) {
        guard let host, prompt.source.kind == .builtin else { return }
        guard host.setBundledPromptDisabled(prompt.name, isDisabled: isDisabled) else { return }
        host.publishSettings()
        host.refreshPrompts(scanAllProjects: false)
    }

    func movePromptToLibrary(_ prompt: PromptTemplateRecord) throws {
        guard let host else { return }
        _ = try ensureLibraryPrompt(for: prompt)
        host.refreshPrompts(scanAllProjects: false)
    }

    func canDeletePrompt(_ prompt: PromptTemplateRecord) -> Bool {
        switch prompt.source.kind {
        case .package:
            return false
        case .builtin, .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func deletePrompt(_ prompt: PromptTemplateRecord) throws {
        guard canDeletePrompt(prompt) else { throw CocoaError(.fileWriteNoPermission) }
        guard let host else { return }

        if prompt.discoveryKind == .externalReference {
            try removePromptReferences(named: prompt.name)
            _ = host.removeExternalPromptPaths([prompt.filePath])
            host.publishSettings()
        } else {
            try removePromptReferences(named: prompt.name)
            let fileURL = URL(fileURLWithPath: prompt.filePath).standardizedFileURL
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            try host.replacePromptSettingsPaths(oldURLs: [fileURL], newURL: nil)
            host.publishSettings()
        }

        host.markPromptPendingDeletion(prompt)
        host.selectFirstVisiblePromptTemplate()
        host.refreshPrompts(scanAllProjects: true)
    }

    private func removePromptReferences(named promptName: String) throws {
        guard let host else { return }
        _ = host.setDefaultPromptTemplate(promptName, enabled: false)
        host.publishSettings()

        for projectPath in host.assignedProjectPaths {
            host.setAssignedPromptTemplate(promptName, assigned: false, for: projectPath)
        }
        host.applyProjectPreferenceChanges()
    }

    private func ensureLibraryPrompt(for prompt: PromptTemplateRecord) throws -> URL {
        let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/prompt-library", isDirectory: true)
        let libraryURL = libraryRoot.appendingPathComponent("\(prompt.name).md")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: libraryURL.path) { return libraryURL }

        let sourceURL = URL(fileURLWithPath: prompt.filePath)
        if prompt.source.kind == .global {
            try fileManager.moveItem(at: sourceURL, to: libraryURL)
        } else if prompt.source.kind == .library {
            return sourceURL
        } else {
            try fileManager.copyItem(at: sourceURL, to: libraryURL)
        }
        return libraryURL
    }
}
