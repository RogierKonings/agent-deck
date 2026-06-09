import Foundation

@MainActor
protocol AgentDraftHost: AnyObject {
    var selectedProjectPath: String? { get }

    func resolveProjectPath(containing filePath: String) -> String?
    func applyEffectiveAgentConfigPatch(originalName: String, newConfig: AgentConfig, filePath: String?)
    func applyBuiltinOverridePatch(
        agentName: String,
        scope: AgentEditingTarget.OverrideScope,
        overrideValues: [String: Any]?
    )
    func rebuildWarningCachesAfterAgentDraftSave()
    func refreshAfterAgentDraftChange(_ draft: AgentEditorDraft)
    func refreshGloballyAfterAgentDraftSave(silentlyReconcile: Bool)
    func refreshAfterProjectScopedAgentDraftSave(projectPath: String)
    func defaultCustomScope(for agent: EffectiveAgentRecord) -> AgentEditingTarget.CustomAgentScope
    func duplicatedName(for name: String) -> String
}
