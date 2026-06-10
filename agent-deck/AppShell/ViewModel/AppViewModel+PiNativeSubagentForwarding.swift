import Foundation

// MARK: - Native subagent host

extension AppViewModel: PiNativeSubagentHost {
    var nativeSubagentDelegationPolicyInstructions: String {
        appSettings.nativeSubagentDelegationPolicy.promptInstructions
    }

    func skillCatalog(forProjectPath projectPath: String) -> [SkillRecord] {
        skillCatalogForProjectPath(projectPath)
    }

    func resolveChildMemoryArguments(for parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, task: String) async -> [String] {
        await childMemoryArguments(for: parentSession, agent: agent, task: task)
    }

    func performSubagentMemoryWrite(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryWriteBridgeRequest) async -> String {
        await handleSubagentMemoryWrite(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func performSubagentMemoryRecall(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryRecallBridgeRequest) async -> String {
        await handleSubagentMemoryRecall(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func performSubagentMemoryReinforce(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryReinforceBridgeRequest) async -> String {
        await handleSubagentMemoryReinforce(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func performSubagentMemoryUpdate(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryUpdateBridgeRequest) async -> String {
        await handleSubagentMemoryUpdate(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func performSubagentMemoryDelete(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryDeleteBridgeRequest) async -> String {
        await handleSubagentMemoryDelete(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func performSubagentMemoryMarkStale(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryStaleBridgeRequest) async -> String {
        await handleSubagentMemoryMarkStale(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }

    func performSubagentMemorySearch(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemorySearchBridgeRequest) async -> String {
        await handleSubagentMemorySearch(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
    }
}

// MARK: - Native subagent view/API compatibility

extension AppViewModel {
    func runNativeSubagent(
        agentName: String,
        task: String,
        useWorktreeIsolation: Bool = false,
        allowDirectProjectWrites: Bool = false,
        expectedOutcome: PiSubagentExpectedOutcome = .reportOnly,
        requestedOutputPath: String? = nil,
        allowOverwrite: Bool = false,
        readFirstPaths: [String] = []
    ) {
        piSubagents.runNativeSubagent(
            agentName: agentName,
            task: task,
            useWorktreeIsolation: useWorktreeIsolation,
            allowDirectProjectWrites: allowDirectProjectWrites,
            expectedOutcome: expectedOutcome,
            requestedOutputPath: requestedOutputPath,
            allowOverwrite: allowOverwrite,
            readFirstPaths: readFirstPaths
        )
    }

    func runNativeParallel(
        agentTasks: [(agentName: String, task: String)],
        concurrency: Int = 4,
        useWorktreeIsolation: Bool = false
    ) {
        piSubagents.runNativeParallel(agentTasks: agentTasks, concurrency: concurrency, useWorktreeIsolation: useWorktreeIsolation)
    }

    func runManagedNativeSubagent(parentSessionID: UUID, request: PiManagedSubagentBridgeRequest, completion: @escaping (String) -> Void) async {
        await piSubagents.runManagedNativeSubagent(parentSessionID: parentSessionID, request: request, completion: completion)
    }

    func runManagedNativeParallel(parentSessionID: UUID, request: PiManagedParallelBridgeRequest, completion: @escaping (String) -> Void) async {
        await piSubagents.runManagedNativeParallel(parentSessionID: parentSessionID, request: request, completion: completion)
    }

    func nativeSubagentCatalogPrompt(for session: PiAgentSessionRecord) -> String? {
        piSubagents.catalogPrompt(for: session)
    }

    func pendingSupervisorRequestsJSON(parentSessionID: UUID) -> String {
        piSubagents.pendingSupervisorRequestsJSON(parentSessionID: parentSessionID)
    }

    func answerSupervisorRequestFromParentAgent(parentSessionID: UUID, requestID: String, response: String) -> String {
        piSubagents.answerSupervisorRequest(parentSessionID: parentSessionID, requestID: requestID, response: response)
    }

    func stopNativeSubagent(runID: UUID, parentSessionID: UUID) {
        piSubagents.stopNativeSubagent(runID: runID, parentSessionID: parentSessionID)
    }

    func stopNativeSubagentGraph(runID: UUID, parentSessionID: UUID) {
        piSubagents.stopNativeSubagentGraph(runID: runID, parentSessionID: parentSessionID)
    }

    func stopNativeSubagentGraphChild(graphRunID: UUID, childID: UUID, parentSessionID: UUID) {
        piSubagents.stopNativeSubagentGraphChild(graphRunID: graphRunID, childID: childID, parentSessionID: parentSessionID)
    }

    func retryNativeSubagentGraphChild(graphRunID: UUID, childID: UUID, parentSessionID: UUID) {
        piSubagents.retryNativeSubagentGraphChild(graphRunID: graphRunID, childID: childID, parentSessionID: parentSessionID)
    }

    func openNativeSubagentWorktreePatch(runID: UUID, parentSessionID: UUID) {
        piSubagents.openNativeSubagentWorktreePatch(runID: runID, parentSessionID: parentSessionID)
    }

    func applyNativeSubagentWorktreePatch(runID: UUID, parentSessionID: UUID) {
        piSubagents.applyNativeSubagentWorktreePatch(runID: runID, parentSessionID: parentSessionID)
    }

    func discardNativeSubagentWorktree(runID: UUID, parentSessionID: UUID) {
        piSubagents.discardNativeSubagentWorktree(runID: runID, parentSessionID: parentSessionID)
    }

    func respondToSubagentSupervisorRequest(_ requestID: String, parentSessionID: UUID, response: String) {
        piSubagents.respondToSubagentSupervisorRequest(requestID, parentSessionID: parentSessionID, response: response)
    }

    func cancelSubagentSupervisorRequest(_ requestID: String, parentSessionID: UUID) {
        piSubagents.cancelSubagentSupervisorRequest(requestID, parentSessionID: parentSessionID)
    }
}
