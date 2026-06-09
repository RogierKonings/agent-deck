import Foundation
import Observation

@MainActor
@Observable
final class AgentDraftCoordinator {
    weak var host: AgentDraftHost?
    private let persistence: AgentPersistence

    init(persistence: AgentPersistence) {
        self.persistence = persistence
    }

    func attach(host: AgentDraftHost) {
        self.host = host
    }

    func makeAgentDraft(
        for agent: EffectiveAgentRecord,
        preferredOverrideScope: AgentEditingTarget.OverrideScope? = nil
    ) -> AgentEditorDraft? {
        persistence.makeDraft(for: agent, preferredOverrideScope: preferredOverrideScope)
    }

    func saveAgentDrafts(_ pairs: [(draft: AgentEditorDraft, agent: EffectiveAgentRecord)]) throws {
        guard !pairs.isEmpty else { return }
        for pair in pairs {
            try persistence.save(pair.draft, original: pair.agent, projectRoot: host?.selectedProjectPath)
        }
        var needsGlobalRefresh = false
        var projectPaths: Set<String> = []
        var didPatchInMemory = false
        for pair in pairs {
            switch pair.draft.target {
            case .custom(.global), .custom(.library), .builtinOverride(.global):
                needsGlobalRefresh = true
            case .custom(.project):
                if let path = pair.draft.sourcePath.flatMap({ host?.resolveProjectPath(containing: $0) })
                    ?? host?.selectedProjectPath {
                    projectPaths.insert(path)
                }
            case .builtinOverride(.project):
                if let path = host?.selectedProjectPath {
                    projectPaths.insert(path)
                }
            }
            if case .custom = pair.draft.target, pair.draft.originalName == pair.draft.config.name {
                host?.applyEffectiveAgentConfigPatch(
                    originalName: pair.draft.originalName,
                    newConfig: pair.draft.config,
                    filePath: pair.draft.sourcePath
                )
                didPatchInMemory = true
            }
        }
        if didPatchInMemory {
            host?.rebuildWarningCachesAfterAgentDraftSave()
        }
        if needsGlobalRefresh {
            host?.refreshGloballyAfterAgentDraftSave(silentlyReconcile: didPatchInMemory)
        }
        for path in projectPaths {
            host?.refreshAfterProjectScopedAgentDraftSave(projectPath: path)
        }
    }

    func saveAgentDraft(_ draft: AgentEditorDraft, for agent: EffectiveAgentRecord) throws {
        try persistence.save(draft, original: agent, projectRoot: host?.selectedProjectPath)
        if case .custom = draft.target, draft.originalName == draft.config.name {
            host?.applyEffectiveAgentConfigPatch(
                originalName: draft.originalName,
                newConfig: draft.config,
                filePath: draft.sourcePath
            )
            host?.rebuildWarningCachesAfterAgentDraftSave()
        } else if case let .builtinOverride(scope) = draft.target,
                  let builtin = agent.builtin?.parsed,
                  let overrideValues = persistence.builtinOverrideValuesForTesting(base: builtin, edited: draft.config) {
            host?.applyBuiltinOverridePatch(
                agentName: agent.name,
                scope: scope,
                overrideValues: overrideValues
            )
        }
        host?.refreshAfterAgentDraftChange(draft)
    }

    func setAgentDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord) throws {
        let overrideScope: AgentEditingTarget.OverrideScope = host?.selectedProjectPath == nil ? .global : .project
        guard var draft = makeAgentDraft(for: agent, preferredOverrideScope: overrideScope) else { return }
        draft.config.disabled = isDisabled
        try saveAgentDraft(draft, for: agent)
    }

    func makeNewAgentDraft(scope: AgentEditingTarget.CustomAgentScope) -> AgentEditorDraft {
        let base = AgentConfig(
            name: "new-agent",
            description: "",
            whenToUse: nil,
            model: nil,
            fallbackModels: [],
            thinking: nil,
            systemPromptMode: "replace",
            inheritSkills: nil,
            disabled: nil,
            tools: ["read", "grep", "find", "ls", "bash"],
            mcpDirectTools: nil,
            extensions: nil,
            skills: [],
            output: nil,
            defaultExpectedOutcome: .reportOnly,
            defaultReads: nil,
            defaultProgress: nil,
            interactive: nil,
            maxSubagentDepth: nil,
            systemPrompt: "Describe the agent behavior here.",
            unknownFields: [:]
        )
        return persistence.makeNewDraft(scope: scope, base: base)
    }

    func makeDuplicateAgentDraft(
        from agent: EffectiveAgentRecord,
        scope: AgentEditingTarget.CustomAgentScope? = nil
    ) -> AgentEditorDraft {
        let targetScope = scope ?? host?.defaultCustomScope(for: agent) ?? .global
        var config = agent.winningRecord?.parsed ?? agent.resolved
        config.name = host?.duplicatedName(for: config.name) ?? "\(config.name)-copy"
        return persistence.makeNewDraft(scope: targetScope, base: config)
    }

    func makeReplacementAgentDraft(
        from agent: EffectiveAgentRecord,
        scope: AgentEditingTarget.CustomAgentScope
    ) -> AgentEditorDraft {
        var config: AgentConfig
        if scope == .global, agent.builtin != nil, agent.globalCustom == nil {
            config = makeAgentDraft(for: agent, preferredOverrideScope: .global)?.config ?? agent.resolved
        } else {
            config = agent.resolved
        }
        config.name = agent.name
        return persistence.makeNewDraft(scope: scope, base: config)
    }

    func saveNewAgentDraft(_ draft: AgentEditorDraft) throws {
        try persistence.saveNewCustomAgent(draft, projectRoot: host?.selectedProjectPath)
        host?.refreshAfterAgentDraftChange(draft)
    }
}
