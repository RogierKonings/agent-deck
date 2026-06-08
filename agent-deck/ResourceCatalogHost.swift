import Foundation

@MainActor
protocol ResourceCatalogHost: AnyObject {
    var snapshot: ScanSnapshot { get }
    var selectedDiscoveredProject: DiscoveredProject? { get }
    var allVisibleSkillRecords: [SkillRecord] { get }
    var allVisiblePromptTemplateRecords: [PromptTemplateRecord] { get }

    func computeAllDisplayAgents() -> [EffectiveAgentRecord]
    func filteredAgents() -> [EffectiveAgentRecord]
    func assignedProjects(for agent: AgentRecord) -> [DiscoveredProject]
    func assignedAgents(for skill: SkillRecord) -> [EffectiveAgentRecord]
    func skillIsEnabledGlobally(_ skill: SkillRecord) -> Bool
    func skill(_ skill: SkillRecord, isEnabledFor project: DiscoveredProject) -> Bool
}
