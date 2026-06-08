import Foundation
import SwiftUI

// MARK: - Prompt repository host

extension AppViewModel: PromptRepositoryHost {
    func setAssignedPromptTemplate(_ name: String, assigned: Bool, for projectPath: String) {
        projects.setAssignedPromptTemplate(name, assigned: assigned, for: projectPath)
    }

    func setDefaultPromptTemplate(_ name: String, enabled: Bool) -> Bool {
        settings.controller.setDefaultPromptTemplate(name, enabled: enabled)
    }

    func setBundledPromptDisabled(_ name: String, isDisabled: Bool) -> Bool {
        settings.controller.setBundledPromptDisabled(name, isDisabled: isDisabled)
    }

    func removeExternalPromptPaths(_ paths: [String]) -> Bool {
        settings.controller.removeExternalPromptPaths(Set(paths))
    }

    func refreshPrompts(scanAllProjects: Bool) {
        refresh(includeModels: false, scanAllProjects: scanAllProjects)
    }

    func selectPromptTemplate(named name: String) {
        selectedCommandItemID = allVisiblePromptTemplateRecords.first { $0.name == name }?.id ?? selectedCommandItemID
    }

    func selectFirstVisiblePromptTemplate() {
        selectedCommandItemID = allVisiblePromptTemplateRecords.first?.id
    }
}

// MARK: - Prompt repository view/API compatibility

extension AppViewModel {
    func prompt(_ prompt: PromptTemplateRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        promptRepository.prompt(prompt, isEnabledFor: project)
    }

    func assignedProjects(for prompt: PromptTemplateRecord) -> [DiscoveredProject] {
        promptRepository.assignedProjects(for: prompt)
    }

    func promptIsEnabledGlobally(_ prompt: PromptTemplateRecord) -> Bool {
        promptRepository.promptIsEnabledGlobally(prompt)
    }

    func setPrompt(_ prompt: PromptTemplateRecord, enabled: Bool, for project: DiscoveredProject) throws {
        try promptRepository.setPrompt(prompt, enabled: enabled, for: project)
    }

    func enablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        try promptRepository.enablePromptGlobally(prompt)
    }

    func disablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        try promptRepository.disablePromptGlobally(prompt)
    }

    func bundledPromptIsDisabled(_ prompt: PromptTemplateRecord) -> Bool {
        promptRepository.bundledPromptIsDisabled(prompt)
    }

    func setBundledPromptDisabled(_ isDisabled: Bool, for prompt: PromptTemplateRecord) {
        promptRepository.setBundledPromptDisabled(isDisabled, for: prompt)
    }

    func movePromptToLibrary(_ prompt: PromptTemplateRecord) throws {
        try promptRepository.movePromptToLibrary(prompt)
    }

    func canDeletePrompt(_ prompt: PromptTemplateRecord) -> Bool {
        promptRepository.canDeletePrompt(prompt)
    }

    func deletePrompt(_ prompt: PromptTemplateRecord) throws {
        try promptRepository.deletePrompt(prompt)
    }
}
