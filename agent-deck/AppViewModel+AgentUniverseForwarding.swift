import Foundation

// MARK: - Agent universe host

extension AppViewModel: AgentUniverseHost {
    func projectEffectiveAgents(forProjectPath path: String) -> [EffectiveAgentRecord]? {
        allProjectSnapshots[path]?.effectiveAgents
    }

    var globalEffectiveAgents: [EffectiveAgentRecord] { globalSnapshot.effectiveAgents }

    var selectedSnapshotProjectRoot: String? { snapshot.projectRoot }

    func agentWarnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        resourceCatalog.warnings(for: agent)
    }
}

// MARK: - Agent universe view/API compatibility

extension AppViewModel {
    func boundAgent(for session: PiAgentSessionRecord) -> EffectiveAgentRecord? {
        agentUniverse.boundAgent(for: session)
    }

    func boundAgentSkillArguments(for agent: EffectiveAgentRecord) throws -> [String] {
        try agentUniverse.boundAgentSkillArguments(for: agent)
    }

    func selectableAgentUniverse(forProjectPath path: String) -> [EffectiveAgentRecord] {
        agentUniverse.selectableAgentUniverse(forProjectPath: path)
    }

    func clearAgentUniverseCache() {
        agentUniverse.clearCache()
    }

    func catalogAgents(for session: PiAgentSessionRecord) -> [EffectiveAgentRecord] {
        agentUniverse.catalogAgents(for: session)
    }

    func sessionHasSelectableAgents(_ session: PiAgentSessionRecord) -> Bool {
        agentUniverse.sessionHasSelectableAgents(session)
    }

    func agentCatalog(forProjectPath projectPath: String?) -> [AgentRecord] {
        agentUniverse.agentCatalog(forProjectPath: projectPath)
    }

    func computeAllDisplayAgents() -> [EffectiveAgentRecord] {
        agentUniverse.computeAllDisplayAgents()
    }

    var filteredAgents: [EffectiveAgentRecord] {
        agentUniverse.filteredAgents()
    }

    var allVisibleAgentRecords: [AgentRecord] {
        agentUniverse.allVisibleAgentRecords()
    }
}
