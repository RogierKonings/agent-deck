import Foundation

// MARK: - Resource catalog host

extension AppViewModel: ResourceCatalogHost {
    func catalogFilteredAgents() -> [EffectiveAgentRecord] {
        agentUniverse.filteredAgents()
    }
}

// MARK: - Resource catalog view/API compatibility

extension AppViewModel {
    func warnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        resourceCatalog.warnings(for: agent)
    }
}
