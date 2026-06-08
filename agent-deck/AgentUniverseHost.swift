import Foundation

@MainActor
protocol AgentUniverseHost: AnyObject {
    var snapshot: ScanSnapshot { get }
    var globalSnapshot: ScanSnapshot { get }
    var allProjectSnapshots: [String: ScanSnapshot] { get }
    var selectedProjectPath: String? { get }
    var selectedAgentFilter: AgentFilter { get }
    var projectPreferencesByPath: [String: ProjectPreference] { get }
    var cachedAllDisplayAgents: [EffectiveAgentRecord] { get }

    func startupSnapshot(forProjectPath path: String) -> ScanSnapshot
    func projectEffectiveAgents(forProjectPath path: String) -> [EffectiveAgentRecord]?
    func agentWarnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning]
    var globalEffectiveAgents: [EffectiveAgentRecord] { get }
    var selectedSnapshotProjectRoot: String? { get }
}
