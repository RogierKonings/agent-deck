import Foundation

// MARK: - Agent draft view/API compatibility

extension AppViewModel {
    func makeAgentDraft(
        for agent: EffectiveAgentRecord,
        preferredOverrideScope: AgentEditingTarget.OverrideScope? = nil
    ) -> AgentEditorDraft? {
        agentDraft.makeAgentDraft(for: agent, preferredOverrideScope: preferredOverrideScope)
    }

    func saveAgentDrafts(_ pairs: [(draft: AgentEditorDraft, agent: EffectiveAgentRecord)]) throws {
        try agentDraft.saveAgentDrafts(pairs)
    }

    func saveAgentDraft(_ draft: AgentEditorDraft, for agent: EffectiveAgentRecord) throws {
        try agentDraft.saveAgentDraft(draft, for: agent)
    }

    func setAgentDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord) throws {
        try agentDraft.setAgentDisabled(isDisabled, for: agent)
    }

    func makeNewAgentDraft(scope: AgentEditingTarget.CustomAgentScope) -> AgentEditorDraft {
        agentDraft.makeNewAgentDraft(scope: scope)
    }

    func makeDuplicateAgentDraft(
        from agent: EffectiveAgentRecord,
        scope: AgentEditingTarget.CustomAgentScope? = nil
    ) -> AgentEditorDraft {
        agentDraft.makeDuplicateAgentDraft(from: agent, scope: scope)
    }

    func makeReplacementAgentDraft(
        from agent: EffectiveAgentRecord,
        scope: AgentEditingTarget.CustomAgentScope
    ) -> AgentEditorDraft {
        agentDraft.makeReplacementAgentDraft(from: agent, scope: scope)
    }

    func saveNewAgentDraft(_ draft: AgentEditorDraft) throws {
        try agentDraft.saveNewAgentDraft(draft)
    }
}
