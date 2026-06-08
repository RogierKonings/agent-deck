import Foundation
import Observation

// MARK: - Resource catalog warning caches

@MainActor
@Observable
final class ResourceCatalogState {
    private(set) var hasCompletedInitialRefresh = false
    private(set) var hasAgentWarnings = false
    private(set) var hasSkillWarnings = false
    private(set) var hasPromptWarnings = false
    private(set) var skillWarnings: [DiagnosticWarning] = []
    private(set) var promptWarnings: [DiagnosticWarning] = []
    private(set) var skillReferenceWarnings: [SkillReferenceWarning] = []
    private(set) var skillVisibilityIssuesByAgentID: [String: [AgentSkillVisibilityIssue]] = [:]
    private(set) var allDisplayAgents: [EffectiveAgentRecord] = []
    private(set) var displayAgentByID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
    private(set) var displayAgentsRevision: Int = 0
    private(set) var agentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]] = [:]
    private(set) var skillMetadataByID: [SkillRecord.ID: SkillListMetadata] = [:]
    private(set) var warningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]] = [:]

    func applyRebuild(
        allDisplayAgents: [EffectiveAgentRecord],
        skillWarnings: [DiagnosticWarning],
        promptWarnings: [DiagnosticWarning],
        skillVisibilityIssuesByAgentID: [String: [AgentSkillVisibilityIssue]],
        skillReferenceWarnings: [SkillReferenceWarning],
        agentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]],
        skillMetadataByID: [SkillRecord.ID: SkillListMetadata],
        warningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]],
        markInitialRefreshComplete: Bool
    ) {
        self.allDisplayAgents = allDisplayAgents
        displayAgentByID = Dictionary(uniqueKeysWithValues: allDisplayAgents.map { ($0.id, $0) })
        displayAgentsRevision &+= 1
        self.skillWarnings = skillWarnings
        self.promptWarnings = promptWarnings
        self.skillVisibilityIssuesByAgentID = skillVisibilityIssuesByAgentID
        self.skillReferenceWarnings = skillReferenceWarnings
        self.agentWarningsByID = agentWarningsByID
        self.skillMetadataByID = skillMetadataByID
        self.warningsBySkillID = warningsBySkillID
        hasSkillWarnings = !skillReferenceWarnings.isEmpty || !skillWarnings.isEmpty
        hasPromptWarnings = !promptWarnings.isEmpty
        hasAgentWarnings = agentWarningsByID.values.contains { !$0.isEmpty }
            || skillVisibilityIssuesByAgentID.values.contains { !$0.isEmpty }
        if markInitialRefreshComplete {
            hasCompletedInitialRefresh = true
        }
    }
}
