import Foundation

/// Dynamic context and side effects `PiNativeSubagentCoordinator` delegates to the app shell.
@MainActor
protocol PiNativeSubagentHost: AnyObject {
    func catalogAgents(for session: PiAgentSessionRecord) -> [EffectiveAgentRecord]
    func startupSnapshot(forProjectPath path: String) -> ScanSnapshot
    func skillCatalog(forProjectPath projectPath: String) -> [SkillRecord]
    var nativeSubagentDelegationPolicyInstructions: String { get }

    func resolveChildMemoryArguments(for parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, task: String) async -> [String]
    func performSubagentMemoryWrite(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryWriteBridgeRequest) async -> String
    func performSubagentMemoryRecall(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryRecallBridgeRequest) async -> String
    func performSubagentMemoryReinforce(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryReinforceBridgeRequest) async -> String
    func performSubagentMemoryUpdate(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryUpdateBridgeRequest) async -> String
    func performSubagentMemoryDelete(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryDeleteBridgeRequest) async -> String
    func performSubagentMemoryMarkStale(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryStaleBridgeRequest) async -> String
    func performSubagentMemorySearch(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemorySearchBridgeRequest) async -> String
}
