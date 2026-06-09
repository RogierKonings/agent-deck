import Foundation

// MARK: - Agent memory host

extension AppViewModel: AgentMemoryHost {
    var agentMemoryEnabled: Bool { appSettings.agentMemoryEnabled }
    var agentMemorySubagentsEnabled: Bool { appSettings.agentMemorySubagentsEnabled }
    var agentMemoryInjectionCharacterBudget: Int { appSettings.agentMemoryInjectionCharacterBudget }
    var agentMemoryShowTranscriptCards: Bool { appSettings.agentMemoryShowTranscriptCards }
    var selectedSessionID: UUID? { piAgentSessionStore.selectedSessionID }

    func session(for id: UUID) -> PiAgentSessionRecord? {
        piAgentSessionStore.sessions.first(where: { $0.id == id })
    }

    func updateSession(_ id: UUID, mutate: (inout PiAgentSessionRecord) -> Void) {
        piAgentSessionStore.updateSession(id, mutate: mutate)
    }

    func appendMemoryTranscriptEntry(_ entry: PiAgentTranscriptEntry) {
        piAgentSessionStore.append(entry)
    }

    func dreamReviewModel() -> AvailableModel? {
        defaultPiAgentModel() ?? foundationAutomationModel ?? automationAvailableModels.first
    }

    func dreamProjectURL() -> URL {
        if let selectedProjectPath,
           !selectedProjectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: selectedProjectPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    func dreamProcessEnvironment(for projectURL: URL) -> [String: String] {
        EnvRuntimeEnvironment().environment(projectRoot: projectURL)
    }

    func navigateToMemory(recordID: String, projectPath: String?) {
        if let projectPath, projectPath != selectedProjectPath {
            selectedProjectPath = projectPath
        }
        selectedSidebarItem = .memory
        selectedMemoryID = recordID
    }
}

// MARK: - Agent memory view/API compatibility

extension AppViewModel {
    var agentMemoryStore: AgentMemoryStore { memory.store }

    func createAgentMemory(title: String, content: String, reasoning: String, kind: AgentMemoryKind, scope: AgentMemoryScope, tags: [String], weight: Double, supersedes: String?) {
        memory.createAgentMemory(title: title, content: content, reasoning: reasoning, kind: kind, scope: scope, tags: tags, weight: weight, supersedes: supersedes)
    }

    func updateAgentMemory(id: String, title: String, content: String, reasoning: String, kind: AgentMemoryKind, scope: AgentMemoryScope, tags: [String], weight: Double, supersedes: String?) {
        memory.updateAgentMemory(id: id, title: title, content: content, reasoning: reasoning, kind: kind, scope: scope, tags: tags, weight: weight, supersedes: supersedes)
    }

    func setAgentMemoryStatus(_ id: String, status: AgentMemoryStatus) {
        memory.setAgentMemoryStatus(id, status: status)
    }

    func deleteAgentMemory(_ id: String) {
        memory.deleteAgentMemory(id)
    }

    func refreshAgentMemory() {
        memory.refreshAgentMemory()
    }

    var isDreamMemoryRunning: Bool { memory.isDreaming }
    var dreamMemoryProgress: String? { memory.dreamProgress }
    var dreamMemoryError: String? { memory.dreamError }
    var dreamMemoryResult: PiMemoryDreamCycleResult? { memory.dreamResult }
    var dreamMemoryApprovedProposalIDs: Set<String> {
        get { memory.dreamApprovedProposalIDs }
        set { memory.dreamApprovedProposalIDs = newValue }
    }

    func startDreamMemory() {
        memory.startDreamMemory()
    }

    func clearDreamMemoryResult() {
        memory.clearDreamMemoryResult()
    }

    func setDreamMemoryProposalApproved(id: String, isApproved: Bool) {
        memory.setDreamProposalApproved(id: id, isApproved: isApproved)
    }

    func proposeDreamMemory(memories: [AgentMemoryRecord], progress: @escaping @MainActor (String) -> Void) async throws -> PiMemoryDreamCycleResult {
        try await memory.proposeDreamMemory(memories: memories, progress: progress)
    }

    func applyDreamMemoryProposals(_ proposals: [PiMemoryDreamProposal]) {
        memory.applyDreamMemoryProposals(proposals)
    }

    func parentMemoryAppendPrompts(for session: PiAgentSessionRecord, initialPrompt: String?) async -> [String] {
        await memory.parentMemoryAppendPrompts(for: session, initialPrompt: initialPrompt)
    }

    func childMemoryArguments(for parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, task: String) async -> [String] {
        await memory.childMemoryArguments(for: parentSession, agent: agent, task: task)
    }

    func handleParentMemoryWrite(sessionID: UUID, request: AgentMemoryWriteBridgeRequest) -> String {
        memory.handleParentMemoryWrite(sessionID: sessionID, request: request)
    }

    func handleSubagentMemoryWrite(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryWriteBridgeRequest) -> String {
        memory.handleSubagentMemoryWrite(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func handleParentMemoryRecall(sessionID: UUID, request: AgentMemoryRecallBridgeRequest) async -> String {
        await memory.handleParentMemoryRecall(sessionID: sessionID, request: request)
    }

    func handleSubagentMemoryRecall(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryRecallBridgeRequest) async -> String {
        await memory.handleSubagentMemoryRecall(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func handleParentMemoryReinforce(sessionID: UUID, request: AgentMemoryReinforceBridgeRequest) -> String {
        memory.handleParentMemoryReinforce(sessionID: sessionID, request: request)
    }

    func handleSubagentMemoryReinforce(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryReinforceBridgeRequest) -> String {
        memory.handleSubagentMemoryReinforce(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func handleParentMemoryUpdate(sessionID: UUID, request: AgentMemoryUpdateBridgeRequest) -> String {
        memory.handleParentMemoryUpdate(sessionID: sessionID, request: request)
    }

    func handleSubagentMemoryUpdate(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryUpdateBridgeRequest) -> String {
        memory.handleSubagentMemoryUpdate(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func handleParentMemoryDelete(sessionID: UUID, request: AgentMemoryDeleteBridgeRequest) -> String {
        memory.handleParentMemoryDelete(sessionID: sessionID, request: request)
    }

    func handleSubagentMemoryDelete(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryDeleteBridgeRequest) -> String {
        memory.handleSubagentMemoryDelete(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func handleParentMemoryMarkStale(sessionID: UUID, request: AgentMemoryStaleBridgeRequest) async -> String {
        await memory.handleParentMemoryMarkStale(sessionID: sessionID, request: request)
    }

    func handleSubagentMemoryMarkStale(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryStaleBridgeRequest) async -> String {
        await memory.handleSubagentMemoryMarkStale(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func handleParentMemorySearch(sessionID: UUID, request: AgentMemorySearchBridgeRequest) async -> String {
        await memory.handleParentMemorySearch(sessionID: sessionID, request: request)
    }

    func handleSubagentMemorySearch(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemorySearchBridgeRequest) async -> String {
        await memory.handleSubagentMemorySearch(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }
}
