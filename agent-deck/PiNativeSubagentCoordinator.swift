import AppKit
import Foundation
import Observation

@MainActor
private final class NativeSubagentCompletionGate {
    private(set) var isCompleted = false

    func complete(_ body: () -> Void) {
        guard !isCompleted else { return }
        isCompleted = true
        body()
    }
}

@MainActor
private final class NativeParallelGraphScheduler {
    let id = UUID()
    let parentSession: PiAgentSessionRecord
    let graphRunID: UUID
    let tasks: [(agentName: String, task: String)]
    let concurrency: Int
    let useWorktreeIsolation: Bool
    let completion: ((PiSubagentRunRecord) -> Void)?
    var nextIndex = 0
    var active = 0
    var completed = 0
    var failed = false

    init(
        parentSession: PiAgentSessionRecord,
        graphRunID: UUID,
        tasks: [(agentName: String, task: String)],
        concurrency: Int,
        useWorktreeIsolation: Bool,
        completion: ((PiSubagentRunRecord) -> Void)?
    ) {
        self.parentSession = parentSession
        self.graphRunID = graphRunID
        self.tasks = tasks
        self.concurrency = concurrency
        self.useWorktreeIsolation = useWorktreeIsolation
        self.completion = completion
    }
}

// MARK: - Native subagent orchestration

@MainActor
@Observable
final class PiNativeSubagentCoordinator {
    weak var host: PiNativeSubagentHost?

    private let sessionStore: PiAgentSessionStore
    private let worktreeService: PiSubagentWorktreeService
    @ObservationIgnored private lazy var runner = PiSubagentRunService(store: sessionStore)
    @ObservationIgnored private var nativeParallelSchedulersByID: [UUID: NativeParallelGraphScheduler] = [:]
    @ObservationIgnored private var artifactCleanupTask: Task<Void, Never>?

    init(sessionStore: PiAgentSessionStore, worktreeService: PiSubagentWorktreeService) {
        self.sessionStore = sessionStore
        self.worktreeService = worktreeService
    }

    func attach(host: PiNativeSubagentHost) {
        self.host = host
        runner.childMemoryArgumentsProvider = { [weak host] parentSession, agent, task in
            await host?.resolveChildMemoryArguments(for: parentSession, agent: agent, task: task) ?? []
        }
        runner.onMemoryWrite = { [weak host] parentSessionID, runID, agentName, request in
            host?.performSubagentMemoryWrite(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
                ?? "\(AppBrand.displayName) memory is not available."
        }
        runner.onMemoryRecall = { [weak host] parentSessionID, runID, agentName, request in
            await host?.performSubagentMemoryRecall(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
                ?? "\(AppBrand.displayName) memory is not available."
        }
        runner.onMemoryReinforce = { [weak host] parentSessionID, runID, agentName, request in
            host?.performSubagentMemoryReinforce(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
                ?? "\(AppBrand.displayName) memory is not available."
        }
        runner.onMemoryUpdate = { [weak host] parentSessionID, runID, agentName, request in
            host?.performSubagentMemoryUpdate(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
                ?? "\(AppBrand.displayName) memory is not available."
        }
        runner.onMemoryDelete = { [weak host] parentSessionID, runID, agentName, request in
            host?.performSubagentMemoryDelete(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
                ?? "\(AppBrand.displayName) memory is not available."
        }
        runner.onMemoryMarkStale = { [weak host] parentSessionID, runID, agentName, request in
            await host?.performSubagentMemoryMarkStale(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
                ?? "\(AppBrand.displayName) memory is not available."
        }
        runner.onMemorySearch = { [weak host] parentSessionID, runID, agentName, request in
            await host?.performSubagentMemorySearch(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request)
                ?? "\(AppBrand.displayName) memory is not available."
        }
    }

    func stopAll(recordTranscript: Bool) {
        artifactCleanupTask?.cancel()
        artifactCleanupTask = nil
        runner.stopAll(recordTranscript: recordTranscript)
        nativeParallelSchedulersByID.removeAll()
    }

    func cleanupOrphanedArtifacts(retentionDays: Int = 30) {
        let referencedArtifactPaths = Set(sessionStore.subagentRunsBySessionID.values.flatMap { runs in
            runs.map(\.artifactDirectory).filter { !$0.isEmpty }
        })
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        artifactCleanupTask?.cancel()
        artifactCleanupTask = Task.detached {
            let fileManager = FileManager.default
            let appSupport = URL.applicationSupportDirectory
            let runsDirectory = appSupport
                .appendingPathComponent("\(AppBrand.displayName)", isDirectory: true)
                .appendingPathComponent("Subagent Runs", isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: runsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
            ) else { return }
            for url in entries {
                if Task.isCancelled { return }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory == true,
                      !referencedArtifactPaths.contains(url.path),
                      (values?.contentModificationDate ?? .distantFuture) < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }

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
        guard let session = sessionStore.selectedSession else { return }
        Task { @MainActor [weak self] in
            await self?.runNativeSubagent(
                parentSession: session,
                agentName: agentName,
                task: task,
                useWorktreeIsolation: useWorktreeIsolation,
                allowDirectProjectWrites: allowDirectProjectWrites,
                expectedOutcome: expectedOutcome,
                requestedOutputPath: requestedOutputPath,
                allowOverwrite: allowOverwrite,
                readFirstPaths: readFirstPaths,
                completion: nil
            )
        }
    }

    func runNativeParallel(
        agentTasks: [(agentName: String, task: String)],
        concurrency: Int = 4,
        useWorktreeIsolation: Bool = false
    ) {
        guard let session = sessionStore.selectedSession else { return }
        Task { @MainActor [weak self] in
            await self?.runNativeParallel(
                parentSession: session,
                agentTasks: agentTasks,
                concurrency: concurrency,
                useWorktreeIsolation: useWorktreeIsolation,
                completion: nil
            )
        }
    }

    func runManagedNativeSubagent(
        parentSessionID: UUID,
        request: PiManagedSubagentBridgeRequest,
        completion: @escaping (String) -> Void
    ) async {
        guard let session = sessionStore.sessions.first(where: { $0.id == parentSessionID }) else {
            completion("\(AppBrand.displayName) could not find the parent session.")
            return
        }
        guard session.subagentsEnabled else {
            completion("Deck agents are disabled for this \(AppBrand.displayName) session.")
            return
        }
        let continueRunID = request.continueSubagentID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if request.continueSubagentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, continueRunID == nil {
            completion("Invalid continueSubagentID `\(request.continueSubagentID ?? "")`. Use the Deck agent ID shown on the Deck agent card.")
            return
        }
        let useWorktreeIsolation = false
        let agent = host?.catalogAgents(for: session).first { $0.name == request.agent.trimmingCharacters(in: .whitespacesAndNewlines) }
        let expectedOutcome: PiSubagentExpectedOutcome = agent?.resolved.defaultExpectedOutcome ?? .reportOnly
        let allowDirectProjectWrites = expectedOutcome == .directProjectWrites
        let gate = NativeSubagentCompletionGate()
        var timeoutTask: Task<Void, Never>?
        let launchedRun = await runNativeSubagent(
            parentSession: session,
            agentName: request.agent,
            task: request.task,
            continueRunID: continueRunID,
            useWorktreeIsolation: useWorktreeIsolation,
            allowDirectProjectWrites: allowDirectProjectWrites,
            expectedOutcome: expectedOutcome,
            requestedOutputPath: nil,
            allowOverwrite: false,
            readFirstPaths: request.reads ?? []
        ) { run in
            timeoutTask?.cancel()
            gate.complete {
                let status = run.status == .completed ? "completed" : run.status.rawValue
                let summary = run.summary ?? run.error ?? "No summary returned."
                let isPersistedRun = self.sessionStore.subagentRuns(for: parentSessionID).contains { $0.id == run.id }
                let idLine = isPersistedRun ? "\nDeck agent ID: \(run.id.uuidString)" : ""
                completion("Deck agent \(run.agentName) \(status).\(idLine)\n\n\(summary)")
            }
        }
        if launchedRun.status.isActive, !gate.isCompleted {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30 * 60))
                await MainActor.run {
                    guard let self else { return }
                    gate.complete {
                        self.runner.stop(runID: launchedRun.id, parentSessionID: parentSessionID)
                        completion("Deck agent \(launchedRun.agentName) timed out after 30 minutes waiting for a result.")
                    }
                }
            }
        }
    }

    func runManagedNativeParallel(
        parentSessionID: UUID,
        request: PiManagedParallelBridgeRequest,
        completion: @escaping (String) -> Void
    ) async {
        guard let session = sessionStore.sessions.first(where: { $0.id == parentSessionID }) else {
            completion("\(AppBrand.displayName) could not find the parent session.")
            return
        }
        guard session.subagentsEnabled else {
            completion("Deck agents are disabled for this \(AppBrand.displayName) session.")
            return
        }
        let tasks = request.tasks.map { (agentName: $0.agent, task: $0.task) }
        let useWorktreeIsolation = request.worktree == true
        await runNativeParallel(
            parentSession: session,
            agentTasks: tasks,
            concurrency: request.concurrency ?? 4,
            useWorktreeIsolation: useWorktreeIsolation
        ) { run in
            let status = run.status == .completed ? "completed" : run.status.rawValue
            completion("Deck agent parallel run \(status).\n\n\(run.summary ?? run.error ?? "No summary returned.")")
        }
    }

    func catalogPrompt(for session: PiAgentSessionRecord) -> String? {
        let agents = (host?.catalogAgents(for: session) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !agents.isEmpty else { return nil }
        let lines = agents.map { agent in
            let routing = (agent.resolved.whenToUse ?? agent.resolved.description).trimmingCharacters(in: .whitespacesAndNewlines)
            let tools = (agent.resolved.tools ?? []).isEmpty ? "default tools" : "tools: \((agent.resolved.tools ?? []).joined(separator: ", "))"
            let outcome = agent.resolved.defaultExpectedOutcome?.displayName ?? "Report only"
            return "- \(agent.name): \(routing.isEmpty ? "Use when this specialist fits the requested task." : routing) [default outcome: \(outcome); \(tools)]"
        }
        let continuableRuns = sessionStore.subagentRuns(for: session.id)
            .filter { $0.mode == .single && !$0.status.isActive && $0.childPiSessionFile?.isEmpty == false }
            .prefix(6)
            .map { run in
                "- \(run.id.uuidString) \(run.agentName) — \(run.status.rawValue) — latest task: \(String(run.task.prefix(120)))"
            }
        let continuableSection = continuableRuns.isEmpty ? "" : "\n\nRecent continuable Deck agents:\n\(continuableRuns.joined(separator: "\n"))"
        let policyInstructions = host?.nativeSubagentDelegationPolicyInstructions ?? ""
        return """
        \(AppBrand.displayName) orchestration (parent session):
        - App tools: `ask_user`, `set_session_plan`, `update_session_plan`, `managed_subagent`, `managed_parallel`, `list_supervisor_requests`, `answer_supervisor_request`.
        - Deck agents are separate child Pi sessions that \(AppBrand.displayName) launches and supervises. The only way to delegate to one is the `managed_subagent` or `managed_parallel` tool — they are not Pi slash commands, model-internal delegation, or hidden reasoning. If you do not call those tools, no delegation happens.
        \(policyInstructions)
        - Use `ask_user` for one focused user decision when requirements are ambiguous or preference-dependent.
        - For multi-step work, keep a short parent-owned visible plan with `set_session_plan` and `update_session_plan`.
        - If you delegate planning to `planner`, convert its returned implementation plan into `set_session_plan` before implementation unless the user only asked for a report. Planner text alone does not update the visible \(AppBrand.displayName) plan.
        - Update the visible plan when steps start, complete, block, skip, or materially change.
        - Deck agent runs start fresh by default. Do not assume a later `managed_subagent` call remembers an earlier child run.
        - The tool result and Deck agent card show a stable Deck agent ID. For a direct follow-up to a previous child, pass that ID as `continueSubagentID` so Agent Deck resumes the same child session and updates the same card.
        - If starting fresh for follow-up work, pass a compact continuity packet: prior findings/status, what changed, relevant files/artifact paths, and exact expected output.
        - Prefer fresh runs for independent work; prefer continuation for direct refinement, re-review, debugging, or answering a child-specific follow-up.

        Available Deck agents:
        \(lines.joined(separator: "\n"))\(continuableSection)
        """
    }

    func pendingSupervisorRequestsJSON(parentSessionID: UUID) -> String {
        let rows = sessionStore.supervisorRequests(for: parentSessionID)
            .filter { $0.status == .pending }
            .map { request -> [String: String] in
                [
                    "requestID": request.id,
                    "kind": request.kind.rawValue,
                    "title": request.title,
                    "message": request.message,
                    "runID": request.runID.uuidString
                ]
            }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    func answerSupervisorRequest(parentSessionID: UUID, requestID: String, response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Supervisor response is empty." }
        guard sessionStore.supervisorRequests(for: parentSessionID).contains(where: { $0.id == requestID && $0.status == .pending }) else {
            return "No pending supervisor request found for id `\(requestID)`."
        }
        runner.respondToSupervisorRequest(requestID, parentSessionID: parentSessionID, response: trimmed)
        return "Supervisor response sent to child request `\(requestID)`."
    }

    func stopNativeSubagent(runID: UUID, parentSessionID: UUID) {
        if let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }), run.children?.isEmpty == false {
            stopNativeSubagentGraph(runID: runID, parentSessionID: parentSessionID)
            return
        }
        runner.stop(runID: runID, parentSessionID: parentSessionID)
    }

    func stopNativeSubagentGraph(runID: UUID, parentSessionID: UUID) {
        guard let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        for child in run.children ?? [] where child.status.isActive {
            if let executionRunID = child.executionRunID {
                runner.stop(runID: executionRunID, parentSessionID: parentSessionID)
            }
        }
        let completedAt = Date()
        sessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.status = .stopped
            run.completedAt = completedAt
            run.durationMs = max(0, Int((completedAt.timeIntervalSince(run.createdAt) * 1000).rounded()))
            if var children = run.children {
                for index in children.indices where children[index].status.isActive || children[index].status == .queued {
                    children[index].status = .stopped
                    children[index].updatedAt = completedAt
                    children[index].completedAt = completedAt
                    children[index].durationMs = max(0, Int((completedAt.timeIntervalSince(children[index].createdAt) * 1000).rounded()))
                }
                run.children = children
            }
        }
        sessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Graph Stopped", text: "Stopped graph run \(runID.uuidString)."))
    }

    func stopNativeSubagentGraphChild(graphRunID: UUID, childID: UUID, parentSessionID: UUID) {
        guard let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == graphRunID }),
              let child = (run.children ?? []).first(where: { $0.id == childID }) else { return }
        if let executionRunID = child.executionRunID, child.status.isActive {
            runner.stop(runID: executionRunID, parentSessionID: parentSessionID)
        }
        let completedAt = Date()
        sessionStore.updateSubagentRun(graphRunID, parentSessionID: parentSessionID) { run in
            guard var children = run.children, let index = children.firstIndex(where: { $0.id == childID }) else { return }
            children[index].status = .stopped
            children[index].updatedAt = completedAt
            children[index].completedAt = completedAt
            children[index].durationMs = max(0, Int((completedAt.timeIntervalSince(children[index].createdAt) * 1000).rounded()))
            run.children = children
        }
        sessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Child Stopped", text: "Stopped \(child.agentName)."))
    }

    func retryNativeSubagentGraphChild(graphRunID: UUID, childID: UUID, parentSessionID: UUID) {
        guard let parentSession = sessionStore.sessions.first(where: { $0.id == parentSessionID }),
              let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == graphRunID }),
              let children = run.children,
              let childIndex = children.firstIndex(where: { $0.id == childID }) else { return }
        sessionStore.updateSubagentRun(graphRunID, parentSessionID: parentSessionID) { run in
            run.status = .running
            run.error = nil
            guard var children = run.children else { return }
            children[childIndex].status = .running
            children[childIndex].summary = nil
            children[childIndex].error = nil
            children[childIndex].completedAt = nil
            children[childIndex].durationMs = nil
            children[childIndex].executionRunID = nil
            run.children = children
        }
        let child = children[childIndex]
        let isolated = run.worktreePolicy == "isolated-per-child"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let childRun = await self.runNativeSubagent(
                parentSession: parentSession,
                agentName: child.agentName,
                task: child.task ?? run.task,
                useWorktreeIsolation: isolated,
                expectedOutcome: isolated ? .editFilesInWorktree : (child.expectedOutcome ?? .reportOnly),
                requestedOutputPath: child.requestedOutputPath,
                allowOverwrite: child.allowOverwrite == true
            ) { [weak self] childResult in
                guard let self else { return }
                self.updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSessionID, index: childIndex, childResult: childResult)
                self.recomputeNativeGraphCompletion(graphRunID, parentSessionID: parentSessionID)
            }
            self.updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSessionID, index: childIndex, childResult: childRun)
        }
    }

    func openNativeSubagentWorktreePatch(runID: UUID, parentSessionID: UUID) {
        guard let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let patch = try await worktreeService.preparePatch(for: run)
                await MainActor.run {
                    sessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                        run.worktreeStatus = .patchReady
                        run.worktreePatchPath = patch.patchPath
                    }
                    sessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Worktree Patch Ready", text: "\(patch.changedFiles.count) changed file(s).\n\n\(patch.patchPath)"))
                    NSWorkspace.shared.open(URL(fileURLWithPath: patch.patchPath))
                }
            } catch {
                await MainActor.run { recordSubagentWorktreeError(error, runID: runID, parentSessionID: parentSessionID) }
            }
        }
    }

    func applyNativeSubagentWorktreePatch(runID: UUID, parentSessionID: UUID) {
        guard let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let patch = try await worktreeService.applyPatch(for: run)
                await MainActor.run {
                    sessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                        run.worktreeStatus = .applied
                        run.worktreePatchPath = patch.patchPath
                    }
                    sessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Worktree Applied", text: "Applied \(patch.changedFiles.count) changed file(s) from the isolated worktree.\n\nPatch: \(patch.patchPath)"))
                }
            } catch {
                await MainActor.run { recordSubagentWorktreeError(error, runID: runID, parentSessionID: parentSessionID) }
            }
        }
    }

    func discardNativeSubagentWorktree(runID: UUID, parentSessionID: UUID) {
        if let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }), run.status.isActive {
            runner.stop(runID: runID, parentSessionID: parentSessionID)
        }
        guard let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await worktreeService.discardWorktree(for: run)
                await MainActor.run {
                    sessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                        run.worktreeStatus = .discarded
                    }
                    sessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Deck Agent Worktree Discarded", text: "Removed isolated worktree for run \(runID.uuidString). Artifacts were kept."))
                }
            } catch {
                await MainActor.run { recordSubagentWorktreeError(error, runID: runID, parentSessionID: parentSessionID) }
            }
        }
    }

    func respondToSubagentSupervisorRequest(_ requestID: String, parentSessionID: UUID, response: String) {
        runner.respondToSupervisorRequest(requestID, parentSessionID: parentSessionID, response: response)
    }

    func cancelSubagentSupervisorRequest(_ requestID: String, parentSessionID: UUID) {
        runner.cancelSupervisorRequest(requestID, parentSessionID: parentSessionID)
    }

    // MARK: - Private launch helpers

    @discardableResult
    private func runNativeSubagent(
        parentSession: PiAgentSessionRecord,
        agentName: String,
        task: String,
        continueRunID: UUID? = nil,
        useWorktreeIsolation: Bool,
        allowDirectProjectWrites: Bool = false,
        expectedOutcome: PiSubagentExpectedOutcome = .reportOnly,
        requestedOutputPath: String? = nil,
        allowOverwrite: Bool = false,
        readFirstPaths: [String] = [],
        completion: ((PiSubagentRunRecord) -> Void)?
    ) async -> PiSubagentRunRecord {
        guard parentSession.subagentsEnabled else {
            let message = "Deck agents are disabled for this session."
            sessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agents Disabled", text: message))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: message)
            completion?(placeholder)
            return placeholder
        }
        let snapshot = host?.startupSnapshot(forProjectPath: parentSession.projectPath) ?? .empty
        guard let agent = host?.catalogAgents(for: parentSession).first(where: { $0.name == agentName }) else {
            let message = "No enabled agent named \(agentName) was found for this session."
            sessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agent Not Found", text: message))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: message)
            completion?(placeholder)
            return placeholder
        }
        if let validationError = validateNativeSubagentOutcome(
            parentSession: parentSession,
            expectedOutcome: expectedOutcome,
            requestedOutputPath: requestedOutputPath,
            allowOverwrite: allowOverwrite,
            allowDirectProjectWrites: allowDirectProjectWrites
        ) {
            sessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agent Output Policy", text: validationError))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: validationError)
            completion?(placeholder)
            return placeholder
        }
        return await runNativeSubagent(
            parentSession: parentSession,
            agent: agent,
            snapshot: snapshotWithSkillCatalog(snapshot, projectPath: parentSession.projectPath),
            task: task,
            continueRunID: continueRunID,
            useWorktreeIsolation: useWorktreeIsolation,
            expectedOutcome: expectedOutcome,
            requestedOutputPath: requestedOutputPath,
            allowOverwrite: allowOverwrite,
            readFirstPaths: readFirstPaths,
            completion: completion
        )
    }

    private func snapshotWithSkillCatalog(_ base: ScanSnapshot, projectPath: String) -> ScanSnapshot {
        ScanSnapshot(
            projectRoot: base.projectRoot,
            builtinAgents: base.builtinAgents,
            globalAgents: base.globalAgents,
            projectAgents: base.projectAgents,
            legacyProjectAgents: base.legacyProjectAgents,
            effectiveAgents: base.effectiveAgents,
            libraryAgents: base.libraryAgents,
            skills: host?.skillCatalog(forProjectPath: projectPath) ?? [],
            librarySkills: [],
            promptTemplates: base.promptTemplates,
            libraryPromptTemplates: base.libraryPromptTemplates,
            settings: base.settings,
            envKeys: base.envKeys,
            warnings: base.warnings
        )
    }

    @discardableResult
    private func runNativeSubagent(
        parentSession: PiAgentSessionRecord,
        agent: EffectiveAgentRecord,
        snapshot: ScanSnapshot,
        task: String,
        continueRunID: UUID? = nil,
        useWorktreeIsolation: Bool,
        expectedOutcome: PiSubagentExpectedOutcome = .reportOnly,
        requestedOutputPath: String? = nil,
        allowOverwrite: Bool = false,
        readFirstPaths: [String] = [],
        completion: ((PiSubagentRunRecord) -> Void)?
    ) async -> PiSubagentRunRecord {
        do {
            return try await runner.runSingle(
                parentSession: parentSession,
                agent: agent,
                snapshot: snapshot,
                task: task,
                continueRunID: continueRunID,
                useWorktreeIsolation: useWorktreeIsolation,
                expectedOutcome: expectedOutcome,
                requestedOutputPath: requestedOutputPath,
                allowOverwrite: allowOverwrite,
                readFirstPaths: readFirstPaths,
                onCompletion: completion
            )
        } catch {
            sessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Deck Agent Launch Failed", text: error.localizedDescription))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agent.name, task: task, error: error.localizedDescription)
            completion?(placeholder)
            return placeholder
        }
    }

    private func runNativeParallel(
        parentSession: PiAgentSessionRecord,
        agentTasks: [(agentName: String, task: String)],
        concurrency: Int,
        useWorktreeIsolation: Bool,
        completion: ((PiSubagentRunRecord) -> Void)?
    ) async {
        let tasks = agentTasks
            .map { ($0.agentName.trimmingCharacters(in: .whitespacesAndNewlines), $0.task.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.0.isEmpty && !$0.1.isEmpty }
        guard !tasks.isEmpty else { return }
        let now = Date()
        let runID = UUID()
        let artifactDirectory = nativeGraphArtifactDirectory(for: runID)
        let defaultOutcomeByAgent = nativeSubagentDefaultOutcomes(parentSession: parentSession, agentNames: tasks.map(\.0))
        let childRecords = tasks.enumerated().map { index, item in
            let expectedOutcome = useWorktreeIsolation ? PiSubagentExpectedOutcome.editFilesInWorktree : (defaultOutcomeByAgent[item.0] ?? .reportOnly)
            return PiSubagentChildRecord(
                id: UUID(), runID: runID, index: index, agentName: item.0, task: item.1,
                status: .queued, model: nil,
                expectedOutcome: expectedOutcome, requestedOutputPath: nil, allowOverwrite: false,
                currentTool: nil, inputTokens: nil, outputTokens: nil, totalTokens: nil, toolCount: nil, durationMs: nil,
                artifactDirectory: nil, sessionFile: nil, outputPath: nil, worktreePath: nil, launchCommand: nil, executionRunID: nil,
                summary: nil, error: nil, dependencies: nil, completedAt: nil, createdAt: now, updatedAt: now
            )
        }
        let limit = max(1, min(concurrency, tasks.count))
        let run = nativeGraphRun(
            id: runID,
            parentSession: parentSession,
            mode: .parallel,
            title: "Parallel",
            task: "\(tasks.count) parallel Deck agent task(s)",
            artifactDirectory: artifactDirectory,
            children: childRecords,
            edges: [],
            concurrency: limit,
            worktreeIsolation: useWorktreeIsolation
        )
        sessionStore.upsertSubagentRun(run)
        sessionStore.append(.init(
            sessionID: parentSession.id,
            role: .status,
            title: "Parallel Deck Agents Started",
            text: "Deck agent ID: \(run.id.uuidString)\n\nStarted \(tasks.count) task(s), concurrency \(limit).",
            rawJSON: nativeSubagentCardPayload(for: run)
        ))
        let scheduler = NativeParallelGraphScheduler(
            parentSession: parentSession,
            graphRunID: runID,
            tasks: tasks.map { (agentName: $0.0, task: $0.1) },
            concurrency: limit,
            useWorktreeIsolation: useWorktreeIsolation,
            completion: completion
        )
        nativeParallelSchedulersByID[scheduler.id] = scheduler
        await pumpNativeParallelScheduler(scheduler)
    }

    private func pumpNativeParallelScheduler(_ scheduler: NativeParallelGraphScheduler) async {
        if scheduler.completed == scheduler.tasks.count {
            let run = sessionStore.subagentRuns(for: scheduler.parentSession.id).first(where: { $0.id == scheduler.graphRunID })
            let summaries = (run?.children ?? []).map { "- \($0.agentName): \($0.summary ?? $0.error ?? $0.status.rawValue)" }.joined(separator: "\n")
            finishNativeGraphRun(
                scheduler.graphRunID,
                parentSessionID: scheduler.parentSession.id,
                status: scheduler.failed ? .failed : .completed,
                summary: summaries,
                completion: scheduler.completion
            )
            nativeParallelSchedulersByID[scheduler.id] = nil
            return
        }
        while scheduler.active < scheduler.concurrency && scheduler.nextIndex < scheduler.tasks.count {
            let index = scheduler.nextIndex
            scheduler.nextIndex += 1
            scheduler.active += 1
            let item = scheduler.tasks[index]
            let expectedOutcome = scheduler.useWorktreeIsolation
                ? PiSubagentExpectedOutcome.editFilesInWorktree
                : nativeSubagentDefaultOutcome(parentSession: scheduler.parentSession, agentName: item.agentName)
            let allowDirectProjectWrites = expectedOutcome == .directProjectWrites
            updateNativeGraphChild(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, index: index) { $0.status = .running }
            let childRun = await runNativeSubagent(
                parentSession: scheduler.parentSession,
                agentName: item.agentName,
                task: item.task,
                useWorktreeIsolation: scheduler.useWorktreeIsolation,
                allowDirectProjectWrites: allowDirectProjectWrites,
                expectedOutcome: expectedOutcome
            ) { [weak self, weak scheduler] childResult in
                guard let self, let scheduler else { return }
                self.updateNativeGraphChildFromRun(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, index: index, childResult: childResult)
                scheduler.active = max(0, scheduler.active - 1)
                scheduler.completed += 1
                scheduler.failed = scheduler.failed || childResult.status != .completed
                Task { @MainActor [weak self, weak scheduler] in
                    guard let self, let scheduler else { return }
                    await self.pumpNativeParallelScheduler(scheduler)
                }
            }
            updateNativeGraphChildFromRun(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, index: index, childResult: childRun)
        }
    }

    private func nativeSubagentDefaultOutcome(parentSession: PiAgentSessionRecord, agentName: String) -> PiSubagentExpectedOutcome {
        nativeSubagentDefaultOutcomes(parentSession: parentSession, agentNames: [agentName])[agentName] ?? .reportOnly
    }

    private func nativeSubagentDefaultOutcomes(parentSession: PiAgentSessionRecord, agentNames: [String]) -> [String: PiSubagentExpectedOutcome] {
        let requestedNames = Set(agentNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        guard !requestedNames.isEmpty else { return [:] }
        return Dictionary(uniqueKeysWithValues: (host?.catalogAgents(for: parentSession) ?? []).compactMap { agent in
            guard requestedNames.contains(agent.name), let outcome = agent.resolved.defaultExpectedOutcome else { return nil }
            return (agent.name, outcome)
        })
    }

    private func validateNativeSubagentOutcome(
        parentSession: PiAgentSessionRecord,
        expectedOutcome: PiSubagentExpectedOutcome,
        requestedOutputPath: String?,
        allowOverwrite: Bool,
        allowDirectProjectWrites: Bool
    ) -> String? {
        switch expectedOutcome {
        case .reportOnly, .editFilesInWorktree:
            return nil
        case .directProjectWrites:
            return allowDirectProjectWrites ? nil : "Direct project writes require explicit approval."
        case .writeProjectFile:
            let trimmedPath = requestedOutputPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedPath.isEmpty else { return "Write/update project file requires a project-relative output path." }
            guard !trimmedPath.hasPrefix("/") && !trimmedPath.contains("..") else { return "Output path must be project-relative and cannot contain `..`." }
            let rootURL = URL(fileURLWithPath: parentSession.worktreePath ?? parentSession.projectPath)
            let outputURL = rootURL.appendingPathComponent(trimmedPath).standardizedFileURL
            let rootPath = rootURL.standardizedFileURL.path.hasSuffix("/") ? rootURL.standardizedFileURL.path : rootURL.standardizedFileURL.path + "/"
            guard (outputURL.path + (outputURL.hasDirectoryPath ? "/" : "")).hasPrefix(rootPath) else { return "Output path must stay inside the project." }
            if FileManager.default.fileExists(atPath: outputURL.path), !allowOverwrite {
                return "`\(trimmedPath)` already exists. Enable overwrite or choose another output path."
            }
            return nil
        }
    }

    private func nativeGraphRun(
        id: UUID,
        parentSession: PiAgentSessionRecord,
        mode: PiSubagentRunMode,
        title: String,
        task: String,
        artifactDirectory: URL,
        children: [PiSubagentChildRecord],
        edges: [PiSubagentGraphEdgeRecord],
        concurrency: Int,
        worktreeIsolation: Bool
    ) -> PiSubagentRunRecord {
        PiSubagentRunRecord(
            id: id, parentSessionID: parentSession.id, mode: mode, status: .running,
            agentName: title, task: task,
            model: nil, thinking: nil, expectedOutcome: worktreeIsolation ? .editFilesInWorktree : .reportOnly, requestedOutputPath: nil, allowOverwrite: false, tools: [], skills: [],
            concurrencyLimit: concurrency, worktreePolicy: worktreeIsolation ? "isolated-per-child" : "parent", aggregateSummary: nil,
            artifactDirectory: artifactDirectory.path, outputPath: artifactDirectory.appendingPathComponent("summary.md").path,
            worktreePath: nil, parentRepoPath: parentSession.worktreePath ?? parentSession.projectPath, baseCommit: nil,
            isWorktreeIsolated: false, worktreeStatus: PiSubagentWorktreeStatus.none, worktreePatchPath: nil,
            childSessionID: nil, childPiSessionFile: nil, launchCommand: nil, summary: nil, error: nil,
            child: nil, children: children, graphEdges: edges, createdAt: Date(), updatedAt: Date(), completedAt: nil, durationMs: nil
        )
    }

    private func finishNativeGraphRun(
        _ runID: UUID,
        parentSessionID: UUID,
        status: PiSubagentRunStatus,
        summary: String,
        completion: ((PiSubagentRunRecord) -> Void)?
    ) {
        let completedAt = Date()
        sessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.status = status
            run.summary = summary
            run.aggregateSummary = summary
            run.completedAt = completedAt
            run.durationMs = max(0, Int((completedAt.timeIntervalSince(run.createdAt) * 1000).rounded()))
            if status == .failed { run.error = summary }
        }
        if let outputPath = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID })?.outputPath {
            try? summary.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        sessionStore.append(.init(
            sessionID: parentSessionID,
            role: status == .completed ? .status : .error,
            title: status == .completed ? "Deck Agent Graph Completed" : "Deck Agent Graph Failed",
            text: summary
        ))
        if let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) {
            completion?(run)
        }
    }

    private func updateNativeGraphChild(
        _ runID: UUID,
        parentSessionID: UUID,
        index: Int,
        mutate: (inout PiSubagentChildRecord) -> Void
    ) {
        sessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            guard var children = run.children, children.indices.contains(index) else { return }
            mutate(&children[index])
            children[index].updatedAt = Date()
            run.children = children
        }
    }

    private func updateNativeGraphChildFromRun(
        _ graphRunID: UUID,
        parentSessionID: UUID,
        index: Int,
        childResult: PiSubagentRunRecord
    ) {
        updateNativeGraphChild(graphRunID, parentSessionID: parentSessionID, index: index) { child in
            child.status = childResult.status
            child.executionRunID = childResult.id
            child.artifactDirectory = childResult.artifactDirectory
            child.outputPath = childResult.outputPath
            child.worktreePath = childResult.worktreePath
            child.launchCommand = childResult.launchCommand
            child.summary = childResult.summary
            child.error = childResult.error
            child.completedAt = childResult.completedAt
            child.durationMs = childResult.durationMs
        }
    }

    private func recomputeNativeGraphCompletion(_ graphRunID: UUID, parentSessionID: UUID) {
        guard let run = sessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == graphRunID }),
              let children = run.children else { return }
        guard !children.contains(where: { $0.status.isActive || $0.status == .queued }) else { return }
        let summary = children.map { "- \($0.agentName): \($0.summary ?? $0.error ?? $0.status.rawValue)" }.joined(separator: "\n")
        finishNativeGraphRun(
            graphRunID,
            parentSessionID: parentSessionID,
            status: children.allSatisfy { $0.status == .completed } ? .completed : .failed,
            summary: summary,
            completion: nil
        )
    }

    private func nativeSubagentCardPayload(for run: PiSubagentRunRecord) -> String? {
        let artifactDirectory = run.artifactDirectory
        let payload: [String: Any] = [
            "type": "agent_deck_subagent_card",
            "runID": run.id.uuidString,
            "agent": run.agentName,
            "artifactDirectory": artifactDirectory,
            "turnIndex": run.child?.index ?? 0,
            "authoredSystemPromptPath": URL(fileURLWithPath: artifactDirectory).appendingPathComponent("system-prompt.md").path,
            "finalSystemPromptPath": URL(fileURLWithPath: artifactDirectory).appendingPathComponent("final-system-prompt.md").path
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func nativeGraphArtifactDirectory(for runID: UUID) -> URL {
        let appSupport = URL.applicationSupportDirectory
        let directory = appSupport
            .appendingPathComponent("\(AppBrand.displayName)", isDirectory: true)
            .appendingPathComponent("Subagent Runs", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func recordSubagentWorktreeError(_ error: Error, runID: UUID, parentSessionID: UUID) {
        let message = error.localizedDescription
        sessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.worktreeStatus = .failed
            run.error = [run.error, message].compactMap { $0 }.joined(separator: "\n")
        }
        sessionStore.append(.init(sessionID: parentSessionID, role: .error, title: "Deck Agent Worktree Failed", text: message))
    }
}
