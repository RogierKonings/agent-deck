import Foundation

// MARK: - Agent repository host

extension AppViewModel: AgentRepositoryHost {
    var assignedProjectPaths: [String] {
        Array(projectPreferencesByPath.keys)
    }

    func setAssignedAgent(_ name: String, assigned: Bool, for projectPath: String) {
        projects.setAssignedAgent(name, assigned: assigned, for: projectPath)
    }

    func setDefaultAgent(_ name: String, enabled: Bool) -> Bool {
        settings.controller.setDefaultAgent(name, enabled: enabled)
    }

    func publishSettings() {
        settings.publish()
    }

    func refreshAgents(scanAllProjects: Bool) {
        refresh(includeModels: false, scanAllProjects: scanAllProjects)
    }
}

// MARK: - Agent repository view/API compatibility

extension AppViewModel {
    func agentIsEnabledGlobally(_ agent: AgentRecord) -> Bool {
        agentRepository.agentIsEnabledGlobally(agent)
    }

    func agent(_ agent: AgentRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        agentRepository.agent(agent, isEnabledFor: project)
    }

    func assignedProjects(for agent: AgentRecord) -> [DiscoveredProject] {
        agentRepository.assignedProjects(for: agent)
    }

    func setAgent(_ agent: AgentRecord, enabled: Bool, for project: DiscoveredProject) throws {
        try agentRepository.setAgent(agent, enabled: enabled, for: project)
    }

    func enableAgentGlobally(_ agent: AgentRecord) throws {
        try agentRepository.enableAgentGlobally(agent)
    }

    func disableAgentGlobally(_ agent: AgentRecord) throws {
        try agentRepository.disableAgentGlobally(agent)
    }

    func moveAgentToLibrary(_ agent: AgentRecord) throws {
        try agentRepository.moveAgentToLibrary(agent)
    }

    func canDeleteAgent(_ agent: AgentRecord) -> Bool {
        agentRepository.canDeleteAgent(agent)
    }

    func deleteAgent(_ agent: AgentRecord) throws {
        try agentRepository.deleteAgent(agent)
    }
}
