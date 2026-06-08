import Foundation

// MARK: - Pi Agent runner host

extension AppViewModel: PiAgentRunnerHost {
    func onTurnFinished(_ sessionID: UUID) {
        piSessions.handleTurnFinished(sessionID)
    }

    func runManagedSubagent(
        parentSessionID: UUID,
        request: PiManagedSubagentBridgeRequest,
        completion: @escaping (String) -> Void
    ) async {
        await runManagedNativeSubagent(parentSessionID: parentSessionID, request: request, completion: completion)
    }

    func runManagedParallel(
        parentSessionID: UUID,
        request: PiManagedParallelBridgeRequest,
        completion: @escaping (String) -> Void
    ) async {
        await runManagedNativeParallel(parentSessionID: parentSessionID, request: request, completion: completion)
    }

    func supervisorRequestsList(parentSessionID: UUID) -> String {
        pendingSupervisorRequestsJSON(parentSessionID: parentSessionID)
    }

    func answerSupervisorRequest(parentSessionID: UUID, requestID: String, response: String) -> String {
        answerSupervisorRequestFromParentAgent(parentSessionID: parentSessionID, requestID: requestID, response: response)
    }

    func applySessionPlan(sessionID: UUID, request: PiSessionPlanSetBridgeRequest) -> String {
        setSessionPlanFromParentAgent(sessionID: sessionID, request: request)
    }

    func applySessionPlanUpdate(sessionID: UUID, request: PiSessionPlanUpdateBridgeRequest) -> String {
        updateSessionPlanFromParentAgent(sessionID: sessionID, request: request)
    }

    func resolveNativeSubagentCatalogPrompt(for session: PiAgentSessionRecord) -> String? {
        nativeSubagentCatalogPrompt(for: session)
    }

    func resolveParentSkillArguments(for projectURL: URL) throws -> [String] {
        try parentSkillArguments(for: projectURL)
    }

    func resolveParentPromptTemplateArguments(for projectURL: URL) throws -> [String] {
        try parentPromptTemplateArguments(for: projectURL)
    }

    func resolveParentMemoryAppendPrompts(for session: PiAgentSessionRecord, initialPrompt: String?) async throws -> [String] {
        try await parentMemoryAppendPrompts(for: session, initialPrompt: initialPrompt)
    }

    func resolveBoundAgent(for session: PiAgentSessionRecord) -> EffectiveAgentRecord? {
        boundAgent(for: session)
    }

    func resolveBoundAgentSkillArguments(for agent: EffectiveAgentRecord) throws -> [String] {
        try boundAgentSkillArguments(for: agent)
    }

    func handleMemoryWrite(sessionID: UUID, request: AgentMemoryWriteBridgeRequest) -> String {
        handleParentMemoryWrite(sessionID: sessionID, request: request)
    }

    func handleMemoryRecall(sessionID: UUID, request: AgentMemoryRecallBridgeRequest) async -> String {
        await handleParentMemoryRecall(sessionID: sessionID, request: request)
    }

    func handleMemoryReinforce(sessionID: UUID, request: AgentMemoryReinforceBridgeRequest) -> String {
        handleParentMemoryReinforce(sessionID: sessionID, request: request)
    }

    func handleMemoryUpdate(sessionID: UUID, request: AgentMemoryUpdateBridgeRequest) -> String {
        handleParentMemoryUpdate(sessionID: sessionID, request: request)
    }

    func handleMemoryDelete(sessionID: UUID, request: AgentMemoryDeleteBridgeRequest) -> String {
        handleParentMemoryDelete(sessionID: sessionID, request: request)
    }

    func handleMemoryMarkStale(sessionID: UUID, request: AgentMemoryStaleBridgeRequest) async -> String {
        await handleParentMemoryMarkStale(sessionID: sessionID, request: request)
    }

    func handleMemorySearch(sessionID: UUID, request: AgentMemorySearchBridgeRequest) async -> String {
        await handleParentMemorySearch(sessionID: sessionID, request: request)
    }

    func disabledModelIdentifiers() -> Set<String> { appSettings.disabledModelIdentifiers }

    func piRuntimeDefaults() -> (provider: String?, model: String?, thinkingLevel: String?) {
        piRuntime.readDefaults()
    }

    func refreshModelCatalog() {
        refreshModels()
    }

    var autoGenerateSessionTitles: Bool { appSettings.autoGeneratePiAgentSessionTitles }
    var autoUpdateSessionTitles: Bool { appSettings.autoUpdatePiAgentSessionTitles }

    func titleGenerationModel() -> AvailableModel? {
        piAgentTitleGenerationModel()
    }

    func reportSurfaceError(_ message: String) {
        piAgentRunnerSurfaceError(message: message)
    }

    func acknowledgeSession(_ id: UUID) {
        piSessions.acknowledgeSession(id)
    }
}

// MARK: - Pi Agent runner view/API compatibility

extension AppViewModel {
    func sendPiAgentMessage(
        _ text: String,
        mode: PiAgentInputMode,
        transcriptText: String? = nil,
        images: [PiAgentImageAttachment] = [],
        pasteAttachments: [PiAgentPasteAttachment] = [],
        issueAttachment: PiAgentIssueAttachment? = nil
    ) {
        piRunner.sendMessage(
            text,
            mode: mode,
            transcriptText: transcriptText,
            images: images,
            pasteAttachments: pasteAttachments,
            issueAttachment: issueAttachment
        )
    }

    func compactSelectedPiAgentSession(customInstructions: String? = nil) {
        piRunner.compactSelectedSession(customInstructions: customInstructions)
    }

    func forkPiAgentSession(from entry: PiAgentTranscriptEntry) {
        piRunner.forkSession(from: entry)
    }

    func forkPiAgentSessionAsAgentChat(from entry: PiAgentTranscriptEntry, agent: EffectiveAgentRecord) {
        piRunner.forkSessionAsAgentChat(from: entry, agent: agent)
    }

    func refreshPiAgentControlsForSelectedSession() {
        piRunner.refreshControlsForSelectedSession()
    }

    func renamePiAgentSession(_ id: UUID, title: String) {
        piRunner.renameSession(id, title: title)
    }

    func resumeSelectedPiAgentSession() {
        piRunner.resumeSelectedSession()
    }

    func setPiAgentModelForSelectedSession(provider: String?, modelID: String?) {
        piRunner.setModelForSelectedSession(provider: provider, modelID: modelID)
    }

    func cyclePiAgentModelForSelectedSession() {
        piRunner.cycleModelForSelectedSession()
    }

    func setPiAgentThinkingLevelForSelectedSession(_ level: String) {
        piRunner.setThinkingLevelForSelectedSession(level)
    }

    func cyclePiAgentThinkingLevelForSelectedSession() {
        piRunner.cycleThinkingLevelForSelectedSession()
    }

    func defaultPiAgentModel() -> AvailableModel? {
        piRunner.defaultModel()
    }

    func defaultPiAgentThinkingLevel(for levels: [String]) -> String {
        piRunner.defaultThinkingLevel(for: levels)
    }

    func piRuntimeDefaultThinkingLevel() -> String {
        piRunner.piRuntimeDefaultThinkingLevel()
    }

    func respondToPiAgentUIRequest(_ request: PiAgentUIRequest, value: String) {
        piRunner.respondToUIRequest(request, value: value)
    }

    func respondToPiAgentFreeformUIRequest(_ request: PiAgentUIRequest, sentinel: String, value: String) {
        piRunner.respondToFreeformUIRequest(request, sentinel: sentinel, value: value)
    }

    func confirmPiAgentUIRequest(_ request: PiAgentUIRequest, confirmed: Bool) {
        piRunner.confirmUIRequest(request, confirmed: confirmed)
    }

    func cancelPiAgentUIRequest(_ request: PiAgentUIRequest) {
        piRunner.cancelUIRequest(request)
    }

    func startAgentSession(agent: EffectiveAgentRecord, project: DiscoveredProject, initialInstruction: String?) {
        piRunner.startAgentSession(agent: agent, project: project, initialInstruction: initialInstruction)
    }

    func rebindAgent(sessionID: UUID, to agent: EffectiveAgentRecord) {
        piRunner.rebindAgent(sessionID: sessionID, to: agent)
    }
}
