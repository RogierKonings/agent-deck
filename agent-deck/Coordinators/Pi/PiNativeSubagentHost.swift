import Foundation

/// Dynamic context and side effects `PiNativeSubagentCoordinator` delegates to the app shell.
@MainActor
protocol PiNativeSubagentHost: AnyObject {
    func catalogAgents(for session: PiAgentSessionRecord) -> [EffectiveAgentRecord]
    func startupSnapshot(forProjectPath path: String) -> ScanSnapshot
    func skillCatalog(forProjectPath projectPath: String) -> [SkillRecord]
    var nativeSubagentDelegationPolicyInstructions: String { get }

    func resolveChildMemoryArguments(for parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, task: String) async -> [String]
    func performSubagentMemoryWrite(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryWriteBridgeRequest) -> String
    func performSubagentMemoryRecall(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryRecallBridgeRequest) async -> String
    func performSubagentMemoryReinforce(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryReinforceBridgeRequest) -> String
    func performSubagentMemoryUpdate(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryUpdateBridgeRequest) -> String
    func performSubagentMemoryDelete(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryDeleteBridgeRequest) -> String
    func performSubagentMemoryMarkStale(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryStaleBridgeRequest) async -> String
    func performSubagentMemorySearch(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemorySearchBridgeRequest) async -> String
}
