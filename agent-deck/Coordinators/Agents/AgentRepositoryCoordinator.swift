import Foundation
import Observation

@MainActor
@Observable
final class AgentRepositoryCoordinator {
    weak var host: AgentRepositoryHost?

    func attach(host: AgentRepositoryHost) {
        self.host = host
    }

    func agentIsEnabledGlobally(_ agent: AgentRecord) -> Bool {
        host?.appSettings.defaultAgentNames.contains(agent.name) ?? false
    }

    func agent(_ agent: AgentRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        guard let host else { return false }
        return host.projectPreference(for: project.path).assignedAgentNames.contains(agent.name)
    }

    func assignedProjects(for agent: AgentRecord) -> [DiscoveredProject] {
        guard let host else { return [] }
        return host.enabledProjects.filter { self.agent(agent, isEnabledFor: $0) }
    }

    func setAgent(_ agent: AgentRecord, enabled: Bool, for project: DiscoveredProject) throws {
        guard let host else { return }
        host.setAssignedAgent(agent.name, assigned: enabled, for: project.path)
        host.applyProjectPreferenceChanges()
        host.reconcileSnapshotsFromPreferences()
    }

    func enableAgentGlobally(_ agent: AgentRecord) throws {
        guard let host else { return }
        guard host.setDefaultAgent(agent.name, enabled: true) else { return }
        host.publishSettings()
        host.refreshAgents(scanAllProjects: false)
    }

    func disableAgentGlobally(_ agent: AgentRecord) throws {
        guard let host else { return }
        guard host.setDefaultAgent(agent.name, enabled: false) else { return }
        host.publishSettings()
        host.refreshAgents(scanAllProjects: false)
    }

    func moveAgentToLibrary(_ agent: AgentRecord) throws {
        guard let host else { return }
        _ = try ensureLibraryAgent(for: agent)
        host.refreshAgents(scanAllProjects: false)
    }

    /// Custom and library agents own a real file that can be removed. Builtin and
    /// package agents are read-only — they are disabled or overridden, not deleted.
    func canDeleteAgent(_ agent: AgentRecord) -> Bool {
        switch agent.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func deleteAgent(_ agent: AgentRecord) throws {
        guard canDeleteAgent(agent) else { throw CocoaError(.fileWriteNoPermission) }
        guard let host else { return }

        try removeAgentReferences(named: agent.name)
        let fileURL = URL(fileURLWithPath: agent.filePath).standardizedFileURL
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        host.refreshAgents(scanAllProjects: true)
    }

    private func removeAgentReferences(named agentName: String) throws {
        guard let host else { return }
        _ = host.setDefaultAgent(agentName, enabled: false)
        host.publishSettings()

        for projectPath in host.assignedProjectPaths {
            host.setAssignedAgent(agentName, assigned: false, for: projectPath)
        }
        host.applyProjectPreferenceChanges()
    }

    private func ensureLibraryAgent(for agent: AgentRecord) throws -> URL {
        let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/agent-library/agents", isDirectory: true)
        let libraryURL = libraryRoot.appendingPathComponent("\(agent.name).md")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: libraryURL.path) { return libraryURL }

        let sourceURL = URL(fileURLWithPath: agent.filePath)
        if agent.source.kind == .global {
            try fileManager.moveItem(at: sourceURL, to: libraryURL)
        } else if agent.source.kind == .library {
            return sourceURL
        } else {
            try fileManager.copyItem(at: sourceURL, to: libraryURL)
        }
        return libraryURL
    }
}
