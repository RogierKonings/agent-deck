import Foundation
import Observation

@MainActor
@Observable
final class ComposerSlashCoordinator {
    weak var host: ComposerSlashHost?

    func attach(host: ComposerSlashHost) {
        self.host = host
    }

    /// Names of the skills actually loaded into the parent session for
    /// `projectPath`: global defaults ∪ project-assigned. This is the exact set
    /// `parentSkillArguments` launches the orchestrator with — the single source
    /// of truth shared by the composer `/` browser's `isActive` flag and the
    /// session-resources popover, so neither recomputes it independently.
    func activeParentSkillNames(forProjectPath projectPath: String?) -> Set<String> {
        guard let host else { return [] }
        var names = host.defaultSkillNames
        if let path = projectPath ?? host.selectedProjectPath {
            names.formUnion(host.projectPreference(for: path).assignedSkillNames)
        }
        return names
    }

    /// The resolved `SkillRecord`s actually available to the parent session for
    /// `projectPath` — the active names above, resolved against the same
    /// disabled-bundled-filtered catalog the launch path uses, deduped by name.
    func activeParentSkills(forProjectPath projectPath: String?) -> [SkillRecord] {
        guard let host else { return [] }
        let scopedPath = projectPath ?? host.selectedProjectPath
        let activeNames = activeParentSkillNames(forProjectPath: scopedPath)
        let catalog: [SkillRecord]
        if let path = scopedPath {
            catalog = host.skillCatalogForProjectPath(path)
        } else {
            catalog = host.globalSkillCatalog()
        }
        var seenName = Set<String>()
        return catalog
            .filter { activeNames.contains($0.name) }
            .filter { seenName.insert($0.name).inserted }
    }

    /// Prompt-template analogue of `activeParentSkillNames`: the templates the
    /// parent session is launched with (`parentPromptTemplateArguments`).
    func activeParentPromptTemplateNames(forProjectPath projectPath: String?) -> Set<String> {
        guard let host else { return [] }
        var names = host.defaultPromptTemplateNames
        if let path = projectPath ?? host.selectedProjectPath {
            names.formUnion(host.projectPreference(for: path).assignedPromptTemplateNames)
        }
        return names
    }

    /// The resolved `PromptTemplateRecord`s actually available to the parent
    /// session for `projectPath`, deduped by name. Shared by the `/` browser's
    /// `isActive` flag and the session-resources popover.
    func activeParentPromptTemplates(forProjectPath projectPath: String?) -> [PromptTemplateRecord] {
        guard let host else { return [] }
        let scopedPath = projectPath ?? host.selectedProjectPath
        let activeNames = activeParentPromptTemplateNames(forProjectPath: scopedPath)
        let catalog: [PromptTemplateRecord]
        if let path = scopedPath {
            catalog = host.promptTemplateCatalog(forProjectPath: path)
        } else {
            catalog = host.allVisiblePromptTemplateRecords
        }
        var seenName = Set<String>()
        return catalog
            .filter { activeNames.contains($0.name) }
            .filter { seenName.insert($0.name).inserted }
    }

    /// Materializes the full universe of Skills, Prompts, and Commands the
    /// composer's `/` browser can show. Pure in-memory: walks already-cached
    /// scan snapshots + the command catalog. Build once when the panel opens
    /// and hold the result in `@State` — never call inside a SwiftUI `body`,
    /// since command library discovery touches the filesystem.
    func slashUniverse(forProjectPath projectPath: String?) -> SlashUniverse {
        guard let host else { return .empty }
        let scopedPath = projectPath ?? host.selectedProjectPath

        let skillRecords: [SkillRecord]
        if let path = scopedPath {
            skillRecords = host.skillCatalogForProjectPath(path)
        } else {
            skillRecords = host.globalSkillCatalog()
        }
        let activeSkillNames = activeParentSkillNames(forProjectPath: scopedPath)
        let disabledBundledSkillNames = host.disabledBundledSkillNames
        var seenSkillName = Set<String>()
        let skills = skillRecords
            .filter { !($0.source.kind == .builtin && disabledBundledSkillNames.contains($0.name)) }
            .filter { seenSkillName.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { record in
                SlashItem(
                    id: "skill:\(record.id)",
                    kind: .skill,
                    displayName: record.name,
                    description: record.description?.isEmpty == false ? record.description : nil,
                    scopeLabel: record.source.displayName,
                    isActive: activeSkillNames.contains(record.name),
                    payload: .skill(name: record.name, body: record.body)
                )
            }

        let promptRecords: [PromptTemplateRecord]
        if let path = scopedPath {
            promptRecords = host.promptTemplateCatalog(forProjectPath: path)
        } else {
            promptRecords = host.allVisiblePromptTemplateRecords
        }
        let activePromptNames = activeParentPromptTemplateNames(forProjectPath: scopedPath)
        let disabledBundledPromptNames = host.disabledBundledPromptNames
        var seenPromptName = Set<String>()
        let prompts = promptRecords
            .filter { !($0.source.kind == .builtin && disabledBundledPromptNames.contains($0.name)) }
            .filter { seenPromptName.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { record in
                SlashItem(
                    id: "prompt:\(record.id)",
                    kind: .prompt,
                    displayName: record.name,
                    description: record.description.isEmpty ? nil : record.description,
                    scopeLabel: record.source.displayName,
                    isActive: activePromptNames.contains(record.name),
                    payload: .prompt(name: record.name, body: record.body)
                )
            }

        let commands = PiInjectedCommandCatalog.all
            .filter { PiInjectedCommandCatalog.isEnabled($0, settings: host.slashCommandSettings) }
            .sorted { $0.slashName.localizedStandardCompare($1.slashName) == .orderedAscending }
            .map { command in
                SlashItem(
                    id: "command:\(command.id)",
                    kind: .command,
                    displayName: command.title,
                    description: command.description.isEmpty ? nil : command.description,
                    scopeLabel: command.source == .builtIn ? "Built-in" : "Library",
                    isActive: true,
                    payload: .command(slashName: command.slashName, commandID: command.id)
                )
            }

        return SlashUniverse(skills: skills, prompts: prompts, commands: commands)
    }
}
