import Foundation

@MainActor
protocol AgentUniverseHost: AnyObject {
    func startupSnapshot(forProjectPath path: String) -> ScanSnapshot
    func agentCatalog(forProjectPath path: String?) -> [AgentRecord]
    func projectEffectiveAgents(forProjectPath path: String) -> [EffectiveAgentRecord]?
    var globalEffectiveAgents: [EffectiveAgentRecord] { get }
    var selectedSnapshotProjectRoot: String? { get }
}
