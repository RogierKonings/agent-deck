import Foundation

// MARK: - Agent universe host

extension AppViewModel: AgentUniverseHost {
    func projectEffectiveAgents(forProjectPath path: String) -> [EffectiveAgentRecord]? {
        allProjectSnapshots[path]?.effectiveAgents
    }

    var globalEffectiveAgents: [EffectiveAgentRecord] { globalSnapshot.effectiveAgents }

    var selectedSnapshotProjectRoot: String? { snapshot.projectRoot }
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
}
