import Foundation

/// Side effects and app context `PiAgentRunnerCoordinator` delegates to the app shell.
@MainActor
protocol PiAgentRunnerHost: AnyObject {
    func onTurnFinished(_ sessionID: UUID)

    func runManagedSubagent(
        parentSessionID: UUID,
        request: PiManagedSubagentBridgeRequest,
        completion: @escaping (String) -> Void
    ) async

    func runManagedParallel(
        parentSessionID: UUID,
        request: PiManagedParallelBridgeRequest,
        completion: @escaping (String) -> Void
    ) async

    func supervisorRequestsList(parentSessionID: UUID) -> String
    func answerSupervisorRequest(parentSessionID: UUID, requestID: String, response: String) -> String

    func resolveNativeSubagentCatalogPrompt(for session: PiAgentSessionRecord) -> String?
    func resolveParentSkillArguments(for projectURL: URL) throws -> [String]
    func resolveParentPromptTemplateArguments(for projectURL: URL) throws -> [String]
    func resolveParentMemoryAppendPrompts(for session: PiAgentSessionRecord, initialPrompt: String?) async throws -> [String]
    func resolveBoundAgent(for session: PiAgentSessionRecord) -> EffectiveAgentRecord?
    func resolveBoundAgentSkillArguments(for agent: EffectiveAgentRecord) throws -> [String]

    func handleMemoryWrite(sessionID: UUID, request: AgentMemoryWriteBridgeRequest) async -> String
    func handleMemoryRecall(sessionID: UUID, request: AgentMemoryRecallBridgeRequest) async -> String
    func handleMemoryReinforce(sessionID: UUID, request: AgentMemoryReinforceBridgeRequest) async -> String
    func handleMemoryUpdate(sessionID: UUID, request: AgentMemoryUpdateBridgeRequest) async -> String
    func handleMemoryDelete(sessionID: UUID, request: AgentMemoryDeleteBridgeRequest) async -> String
    func handleMemoryMarkStale(sessionID: UUID, request: AgentMemoryStaleBridgeRequest) async -> String
    func handleMemorySearch(sessionID: UUID, request: AgentMemorySearchBridgeRequest) async -> String

    var piRuntimeSettingsRevision: Int { get }
    var enabledAvailableModels: [AvailableModel] { get }
    func disabledModelIdentifiers() -> Set<String>
    func piRuntimeDefaults() -> (provider: String?, model: String?, thinkingLevel: String?)
    func ensureModelCatalogLoaded()
    func refreshModelCatalog()

    var autoGenerateSessionTitles: Bool { get }
    var autoUpdateSessionTitles: Bool { get }
    func titleGenerationModel() -> AvailableModel?

    func reportSurfaceError(_ message: String)
    func showAgentSidebar()
    func acknowledgeSession(_ id: UUID)
}
