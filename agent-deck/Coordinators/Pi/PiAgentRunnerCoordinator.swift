import Foundation
import Observation
import SwiftUI

// MARK: - Pi Agent runner (RPC, messaging, model/thinking controls)

@MainActor
@Observable
final class PiAgentRunnerCoordinator {
    weak var host: PiAgentRunnerHost?

    let runner: PiAgentRunnerService

    private let sessionStore: PiAgentSessionStore
    private let workspace: PiAgentWorkspaceState
    private let titleGenerator: PiSessionTitleGenerationService

    init(
        sessionStore: PiAgentSessionStore,
        workspace: PiAgentWorkspaceState,
        titleGenerator: PiSessionTitleGenerationService
    ) {
        self.sessionStore = sessionStore
        self.workspace = workspace
        self.titleGenerator = titleGenerator
        self.runner = PiAgentRunnerService(store: sessionStore)
    }

    func attach(host: PiAgentRunnerHost) {
        self.host = host
        let brand = AppBrand.displayName
        runner.onTurnFinished = { [weak host] sessionID in
            Task { @MainActor in host?.onTurnFinished(sessionID) }
        }
        runner.onManagedSubagentRequest = { [weak host] sessionID, request, completion in
            Task { @MainActor in
                await host?.runManagedSubagent(parentSessionID: sessionID, request: request, completion: completion)
            }
        }
        runner.onManagedParallelRequest = { [weak host] sessionID, request, completion in
            Task { @MainActor in
                await host?.runManagedParallel(parentSessionID: sessionID, request: request, completion: completion)
            }
        }
        runner.onSupervisorRequestsList = { [weak host] sessionID in
            host?.supervisorRequestsList(parentSessionID: sessionID) ?? "[]"
        }
        runner.onSupervisorRequestAnswer = { [weak host] sessionID, requestID, response in
            host?.answerSupervisorRequest(parentSessionID: sessionID, requestID: requestID, response: response)
                ?? "\(brand) could not route the supervisor response."
        }
        runner.onSessionPlanSet = { [weak self] sessionID, request in
            self?.applySessionPlan(sessionID: sessionID, request: request)
                ?? "\(brand) could not update the session plan."
        }
        runner.onSessionPlanUpdate = { [weak self] sessionID, request in
            self?.applySessionPlanUpdate(sessionID: sessionID, request: request)
                ?? "\(brand) could not update the session plan."
        }
        runner.nativeSubagentCatalogProvider = { [weak host] session in
            host?.resolveNativeSubagentCatalogPrompt(for: session)
        }
        runner.parentSkillArgumentsProvider = { [weak host] projectURL in
            try host?.resolveParentSkillArguments(for: projectURL) ?? []
        }
        runner.parentPromptTemplateArgumentsProvider = { [weak host] projectURL in
            try host?.resolveParentPromptTemplateArguments(for: projectURL) ?? []
        }
        runner.parentMemoryAppendPromptsProvider = { [weak host] session, initialPrompt in
            try await host?.resolveParentMemoryAppendPrompts(for: session, initialPrompt: initialPrompt) ?? []
        }
        runner.boundAgentProvider = { [weak host] session in
            host?.resolveBoundAgent(for: session)
        }
        runner.boundAgentSkillArgumentsProvider = { [weak host] agent in
            try host?.resolveBoundAgentSkillArguments(for: agent) ?? []
        }
        runner.onMemoryWrite = { [weak host] sessionID, request in
            await host?.handleMemoryWrite(sessionID: sessionID, request: request)
                ?? "\(brand) memory is not available."
        }
        runner.onMemoryRecall = { [weak host] sessionID, request in
            await host?.handleMemoryRecall(sessionID: sessionID, request: request)
                ?? "\(brand) memory is not available."
        }
        runner.onMemoryReinforce = { [weak host] sessionID, request in
            await host?.handleMemoryReinforce(sessionID: sessionID, request: request)
                ?? "\(brand) memory is not available."
        }
        runner.onMemoryUpdate = { [weak host] sessionID, request in
            await host?.handleMemoryUpdate(sessionID: sessionID, request: request)
                ?? "\(brand) memory is not available."
        }
        runner.onMemoryDelete = { [weak host] sessionID, request in
            await host?.handleMemoryDelete(sessionID: sessionID, request: request)
                ?? "\(brand) memory is not available."
        }
        runner.onMemoryMarkStale = { [weak host] sessionID, request in
            await host?.handleMemoryMarkStale(sessionID: sessionID, request: request)
                ?? "\(brand) memory is not available."
        }
        runner.onMemorySearch = { [weak host] sessionID, request in
            await host?.handleMemorySearch(sessionID: sessionID, request: request)
                ?? "\(brand) memory is not available."
        }
    }

    func stopAll(recordTranscript: Bool) {
        runner.stopAll(recordTranscript: recordTranscript)
    }

    func configureIdleParking(timeout: TimeInterval?) {
        runner.configureIdleParking(timeout: timeout)
    }

    func rehydrateTranscript(session: PiAgentSessionRecord) {
        runner.rehydrateTranscriptFromSessionFileIfNeeded(session)
    }

    func stop(sessionID: UUID, recordTranscript: Bool = true) {
        runner.stop(sessionID: sessionID, recordTranscript: recordTranscript)
    }

    func isRunning(sessionID: UUID) -> Bool {
        runner.isRunning(sessionID: sessionID)
    }

    func startProjectSession(project: DiscoveredProject, initialInstruction: String) {
        runner.startProjectSession(project: project, initialInstruction: initialInstruction)
    }

    func resume(session: PiAgentSessionRecord, initialPrompt: String? = nil) {
        if let initialPrompt {
            runner.resume(session: session, initialPrompt: initialPrompt)
        } else {
            runner.resume(session: session)
        }
    }

    func sendMessage(
        _ text: String,
        mode: PiAgentInputMode,
        transcriptText: String? = nil,
        images: [PiAgentImageAttachment] = [],
        pasteAttachments: [PiAgentPasteAttachment] = [],
        issueAttachment: PiAgentIssueAttachment? = nil
    ) {
        guard let session = sessionStore.selectedSession else { return }
        let visibleText = (transcriptText ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveText: String
        if let issueAttachment {
            effectiveText = PiIssuePromptBuilder.rpcMessage(
                userText: text,
                issue: issueAttachment,
                projectName: session.projectName,
                projectPath: session.worktreePath ?? session.projectPath
            )
        } else {
            effectiveText = text
        }
        if images.isEmpty, visibleText == "/compact" || visibleText.hasPrefix("/compact ") {
            let instructions = visibleText.hasPrefix("/compact ") ? String(visibleText.dropFirst("/compact ".count)) : nil
            runner.compact(session: session, customInstructions: instructions)
            return
        }
        scheduleTitleGenerationIfNeeded(
            for: session,
            firstMessage: visibleText.isEmpty ? effectiveText.trimmingCharacters(in: .whitespacesAndNewlines) : visibleText
        )
        if !runner.isRunning(sessionID: session.id), mode == .prompt {
            runner.resume(
                session: session,
                initialPrompt: effectiveText,
                transcriptText: transcriptText,
                images: images,
                pasteAttachments: pasteAttachments,
                issueAttachment: issueAttachment
            )
            return
        }
        runner.send(
            effectiveText,
            mode: mode,
            to: session.id,
            transcriptText: transcriptText,
            images: images,
            pasteAttachments: pasteAttachments,
            issueAttachment: issueAttachment
        )
    }

    func applySessionPlan(sessionID: UUID, request: PiSessionPlanSetBridgeRequest) -> String {
        let plan = sessionStore.setSessionPlan(sessionID: sessionID, items: request.items)
        scheduleTitleUpdateIfNeeded(sessionID: sessionID, plan: plan)
        let rows = plan.items.map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "Session plan set with \(plan.items.count) item(s)."
        }
        return "Session plan set (`\(plan.id.uuidString)`). Use these item ids for updates:\n\(text)"
    }

    func applySessionPlanUpdate(sessionID: UUID, request: PiSessionPlanUpdateBridgeRequest) -> String {
        guard let plan = sessionStore.updateSessionPlan(sessionID: sessionID, updates: request.updates) else {
            return "No current session plan exists. Call set_session_plan first."
        }
        let rows = plan.items.map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "Session plan updated."
        }
        return "Session plan updated (`\(plan.id.uuidString)`):\n\(text)"
    }

    func scheduleTitleUpdateIfNeeded(sessionID: UUID, plan: PiSessionPlanRecord) {
        guard host?.autoUpdateSessionTitles == true,
              host?.autoGenerateSessionTitles == true,
              !plan.items.isEmpty,
              !workspace.isTitleGenerating(for: sessionID),
              let session = sessionStore.sessions.first(where: { $0.id == sessionID }),
              !session.title.hasPrefix("Draft ·"),
              !session.isTitleUserEdited,
              let latestUserMessage = sessionStore.transcript(for: sessionID)
                .filter({ $0.role == .user })
                .max(by: { $0.timestamp < $1.timestamp })?
                .text
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !latestUserMessage.isEmpty,
              let model = host?.titleGenerationModel() else { return }

        workspace.markTitleGenerating(sessionID)
        let projectURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectURL)
        titleGenerator.updateTitle(
            currentTitle: session.title,
            latestUserMessage: latestUserMessage,
            planItems: plan.items,
            model: model,
            projectURL: projectURL,
            environment: environment
        ) { [weak self] result in
            guard let self else { return }
            self.workspace.unmarkTitleGenerating(sessionID)
            guard case let .success(title) = result,
                  title.caseInsensitiveCompare("KEEP") != .orderedSame else { return }
            guard let current = self.sessionStore.sessions.first(where: { $0.id == sessionID }),
                  !current.title.hasPrefix("Draft ·"),
                  !current.isTitleUserEdited,
                  current.title.caseInsensitiveCompare(title) != .orderedSame else { return }
            withAnimation(.snappy(duration: 0.26)) {
                self.sessionStore.applyGeneratedTitle(sessionID, title: title)
            }
            self.runner.syncSessionName(for: sessionID, force: true)
        }
    }

    func compactSelectedSession(customInstructions: String? = nil) {
        guard let session = sessionStore.selectedSession else { return }
        runner.compact(session: session, customInstructions: customInstructions)
    }

    func forkSession(from entry: PiAgentTranscriptEntry) {
        guard entry.role == .user else { return }
        let transcript = sessionStore.transcript(for: entry.sessionID)
        let userEntries = transcript.filter { $0.role == .user }
        guard let index = userEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        runner.fork(
            sessionID: entry.sessionID,
            userMessageText: entry.text,
            userMessageIndex: index
        )
    }

    func forkSessionAsAgentChat(from entry: PiAgentTranscriptEntry, agent: EffectiveAgentRecord) {
        guard entry.role == .user else { return }
        guard agent.resolved.disabled != true else {
            host?.reportSurfaceError("Agent '\(agent.name)' is disabled.")
            return
        }
        guard let parent = sessionStore.sessions.first(where: { $0.id == entry.sessionID }) else { return }
        host?.showAgentSidebar()
        host?.ensureModelCatalogLoaded()
        _ = sessionStore.forkSessionAsAgentChat(
            from: parent,
            agent: agent,
            composerSeed: entry.text
        )
    }

    func refreshControlsForSelectedSession() {
        host?.refreshModelCatalog()
        guard let sessionID = sessionStore.selectedSession?.id else { return }
        runner.refreshPiControls(sessionID: sessionID)
    }

    func renameSession(_ id: UUID, title: String) {
        sessionStore.renameSession(id, title: title)
        runner.syncSessionName(for: id)
    }

    func resumeSelectedSession() {
        guard let session = sessionStore.selectedSession else { return }
        host?.showAgentSidebar()
        host?.acknowledgeSession(session.id)
        runner.resume(session: session)
    }

    func setModelForSelectedSession(provider: String?, modelID: String?) {
        guard let session = sessionStore.selectedSession else { return }
        runner.setModel(sessionID: session.id, provider: provider, modelID: modelID)
        if let currentLevel = session.thinkingLevel {
            let fallback = defaultModel()
            let levels = supportedThinkingLevels(
                session: session,
                provider: provider ?? session.modelProvider ?? fallback?.provider,
                modelID: modelID ?? session.model ?? fallback?.model
            )
            if !levels.contains(currentLevel == "none" ? "off" : currentLevel) {
                runner.setThinkingLevel(sessionID: session.id, level: levels.first ?? "off")
            }
        }
    }

    func cycleModelForSelectedSession() {
        guard let session = sessionStore.selectedSession else { return }
        let options = modelOptions()
        guard !options.isEmpty else { return }
        let fallback = defaultModel()
        let currentProvider = session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider
        let currentModel = session.modelOverrideID ?? session.model ?? fallback?.model
        let currentIndex = options.firstIndex { $0.provider == currentProvider && $0.id == currentModel } ?? -1
        let next = options[(currentIndex + 1 + options.count) % options.count]
        setModelForSelectedSession(provider: next.provider, modelID: next.id)
    }

    func setThinkingLevelForSelectedSession(_ level: String) {
        guard let session = sessionStore.selectedSession else { return }
        let normalized = level == "none" ? "off" : level
        let fallback = defaultModel()
        let levels = supportedThinkingLevels(
            session: session,
            provider: session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider,
            modelID: session.modelOverrideID ?? session.model ?? fallback?.model
        )
        guard levels.contains(normalized) else {
            sessionStore.updateSession(session.id) { record in
                record.lastError = "Thinking level '\(level)' is not available for the selected model."
            }
            return
        }
        runner.setThinkingLevel(sessionID: session.id, level: normalized)
    }

    func cycleThinkingLevelForSelectedSession() {
        guard let session = sessionStore.selectedSession else { return }
        let fallback = defaultModel()
        let levels = supportedThinkingLevels(
            session: session,
            provider: session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider,
            modelID: session.modelOverrideID ?? session.model ?? fallback?.model
        )
        guard !levels.isEmpty else { return }
        let current = (session.thinkingLevel ?? defaultThinkingLevel(for: levels)) == "none"
            ? "off"
            : (session.thinkingLevel ?? defaultThinkingLevel(for: levels))
        let currentIndex = levels.firstIndex(of: current) ?? -1
        let next = levels[(currentIndex + 1 + levels.count) % levels.count]
        runner.setThinkingLevel(sessionID: session.id, level: next)
    }

    func defaultModel() -> AvailableModel? {
        _ = host?.piRuntimeSettingsRevision
        let defaults = host?.piRuntimeDefaults() ?? (provider: nil, model: nil, thinkingLevel: nil)
        let candidateModels = host?.enabledAvailableModels ?? []
        if let provider = defaults.provider, let model = defaults.model {
            return candidateModels.first { $0.provider == provider && $0.model == model }
                ?? candidateModels.first { $0.model == model }
                ?? candidateModels.first
        }
        if let model = defaults.model {
            return candidateModels.first { $0.identifier == model || $0.model == model } ?? candidateModels.first
        }
        return candidateModels.first
    }

    func defaultThinkingLevel(for levels: [String]) -> String {
        _ = host?.piRuntimeSettingsRevision
        let normalized = host?.piRuntimeDefaults().thinkingLevel ?? "medium"
        if levels.contains(normalized) { return normalized }
        if levels.contains("medium") { return "medium" }
        return levels.first ?? "off"
    }

    func piRuntimeDefaultThinkingLevel() -> String {
        _ = host?.piRuntimeSettingsRevision
        return host?.piRuntimeDefaults().thinkingLevel ?? "medium"
    }

    func supportedThinkingLevels(session: PiAgentSessionRecord, provider: String?, modelID: String?) -> [String] {
        if let provider, let modelID {
            if let cached = host?.enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                if !cached.supportedThinkingLevels.isEmpty { return cached.supportedThinkingLevels }
                return cached.supportsThinking ? [] : ["off"]
            }
        }
        return []
    }

    func respondToUIRequest(_ request: PiAgentUIRequest, value: String) {
        runner.respondToExtensionUI(sessionID: request.sessionID, requestID: request.id, value: value)
    }

    func respondToFreeformUIRequest(_ request: PiAgentUIRequest, sentinel: String, value: String) {
        runner.respondToFreeformExtensionUI(sessionID: request.sessionID, requestID: request.id, sentinel: sentinel, value: value)
    }

    func confirmUIRequest(_ request: PiAgentUIRequest, confirmed: Bool) {
        runner.confirmExtensionUI(sessionID: request.sessionID, requestID: request.id, confirmed: confirmed)
    }

    func cancelUIRequest(_ request: PiAgentUIRequest) {
        runner.cancelExtensionUI(sessionID: request.sessionID, requestID: request.id)
    }

    func startAgentSession(agent: EffectiveAgentRecord, project: DiscoveredProject, initialInstruction: String?) {
        guard agent.resolved.disabled != true else {
            host?.reportSurfaceError("Agent '\(agent.name)' is disabled.")
            return
        }
        host?.showAgentSidebar()
        host?.ensureModelCatalogLoaded()
        runner.startAgentSession(agent: agent, project: project, initialInstruction: initialInstruction)
    }

    func rebindAgent(sessionID: UUID, to agent: EffectiveAgentRecord) {
        guard let existing = sessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        guard existing.kind == .agent else { return }
        sessionStore.updateSession(sessionID) { record in
            record.agentName = agent.name
            record.title = "Chat · \(agent.name)"
            record.lastError = nil
            record.status = .draft
        }
        guard let refreshed = sessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        runner.resume(session: refreshed)
    }

    // MARK: - Private

    private func scheduleTitleGenerationIfNeeded(for session: PiAgentSessionRecord, firstMessage: String) {
        let trimmedMessage = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host?.autoGenerateSessionTitles == true,
              !trimmedMessage.isEmpty,
              session.title.hasPrefix("Draft ·"),
              !session.isTitleUserEdited,
              !workspace.isTitleGenerating(for: session.id),
              sessionStore.transcript(for: session.id).filter({ $0.role == .user }).isEmpty,
              let model = host?.titleGenerationModel() else { return }

        workspace.markTitleGenerating(session.id)
        let projectURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectURL)
        titleGenerator.generateTitle(
            for: trimmedMessage,
            model: model,
            projectURL: projectURL,
            environment: environment
        ) { [weak self] result in
            guard let self else { return }
            self.workspace.unmarkTitleGenerating(session.id)
            guard case let .success(title) = result else { return }
            guard let current = self.sessionStore.sessions.first(where: { $0.id == session.id }),
                  current.title.hasPrefix("Draft ·"),
                  !current.isTitleUserEdited else { return }
            withAnimation(.snappy(duration: 0.26)) {
                self.sessionStore.applyGeneratedTitle(session.id, title: title)
            }
            self.runner.syncSessionName(for: session.id, force: true)
        }
    }

    private func modelOptions() -> [PiAgentModelOption] {
        let disabled = host?.disabledModelIdentifiers() ?? []
        return (host?.enabledAvailableModels ?? [])
            .filter { !disabled.contains($0.identifier) }
            .map { model in
                PiAgentModelOption(
                    provider: model.provider,
                    id: model.model,
                    name: nil,
                    contextWindow: Int(model.contextWindow),
                    maxOutput: Int(model.maxOutput),
                    supportsThinking: model.supportsThinking,
                    supportedThinkingLevels: model.supportedThinkingLevels,
                    supportsImages: model.supportsImages
                )
            }
    }
}
