import AppKit
import Combine
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

extension PiAgentScreen {
    func updateStabilizedProcessingMessage(_ message: String?) {
        processingMessageUpdateTask?.cancel()
        processingMessageUpdateTask = nil

        guard let message else {
            stabilizedProcessingMessage = nil
            return
        }

        guard stabilizedProcessingMessage != nil else {
            stabilizedProcessingMessage = message
            return
        }

        processingMessageUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            stabilizedProcessingMessage = message
            processingMessageUpdateTask = nil
        }
    }

    var selectedSessionProcessingMessage: String? {
        guard let session = store.selectedSession,
              session.status.isActive,
              store.selectedUIRequest == nil else { return nil }

        if session.status == .starting { return "Starting Pi" }
        if session.isCompacting { return "Compacting context" }
        if let subagentMessage = runningSubagentsProcessingMessage(for: session) {
            return subagentMessage
        }

        // The RPC-derived activity knows exactly what Pi is doing this instant —
        // it distinguishes a running tool from a finished one and reasoning from
        // an empty turn-start placeholder, neither of which the transcript can.
        if let activity = store.processingActivity(for: session.id) {
            return processingMessage(for: activity)
        }

        // Fallback for a session that is active but has no live activity yet
        // (e.g. just reattached): infer from the last transcript entry.
        if let lastEntry = store.selectedTranscript.last {
            return processingMessage(after: lastEntry)
        }
        return "Working"
    }

    func processingMessage(for activity: PiAgentProcessingActivity) -> String {
        switch activity {
        case .preparing: return "Preparing response"
        case .reasoning: return "Reasoning"
        case .responding: return "Writing response"
        case let .runningTool(toolName, detail): return toolProcessingMessage(forToolName: toolName, detail: detail)
        case .awaitingModel: return "Working"
        case let .applyingConfigurationChange(summary): return "Changing \(summary)"
        }
    }

    func processingMessage(after entry: PiAgentTranscriptEntry) -> String? {
        switch entry.role {
        case .assistant:
            return entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Preparing response" : "Writing response"
        case .error, .stderr:
            return "Working"
        case .tool:
            if entry.text.localizedCaseInsensitiveContains("waiting for user input") { return nil }
            return toolProcessingMessage(for: entry)
        case .status:
            return statusProcessingMessage(for: entry)
        case .user:
            switch entry.title {
            case "Steering": return "Applying your steering"
            case "Queued follow-up": return "Queued follow-up"
            default: return "Processing your message"
            }
        case .thinking:
            return "Reasoning"
        case .raw:
            return "Working"
        }
    }

    func statusProcessingMessage(for entry: PiAgentTranscriptEntry) -> String? {
        switch entry.title {
        case "Input Sent": return "Processing your response"
        case "Input Needed": return nil
        case "Retry": return "Retrying request"
        case "Compaction": return "Compacting context"
        case "Deck Agent Requested": return "Starting Deck agent"
        case "Parallel Deck Agents Requested": return "Starting parallel run"
        case "Supervisor Response Routed": return "Routing response"
        case "System Prompt Captured": return "Preparing context"
        case "Process Ended", "Stopped": return nil
        default: return "Processing update"
        }
    }

    func toolProcessingMessage(for entry: PiAgentTranscriptEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.hasPrefix("Tool:") else { return "Running tool" }
        let toolName = title.dropFirst("Tool:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return toolProcessingMessage(forToolName: toolName)
    }

    /// Turns a raw Pi tool name (and, when available, its target) into a
    /// human phrase: `edit` + `PiAgentViews.swift` → "Editing PiAgentViews.swift".
    /// Unknown tools fall back to their de-underscored name so a new Pi tool
    /// still reads acceptably without a code change.
    func toolProcessingMessage(forToolName toolName: String, detail: String? = nil) -> String {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil
        switch name {
        case "bash": return target.map { "Running \($0)" } ?? "Running a command"
        case "read": return target.map { "Reading \($0)" } ?? "Reading a file"
        case "edit": return target.map { "Editing \($0)" } ?? "Editing a file"
        case "write": return target.map { "Writing \($0)" } ?? "Writing a file"
        case "web_search": return target.map { "Searching the web for \($0)" } ?? "Searching the web"
        case "code_search": return target.map { "Searching the code for \($0)" } ?? "Searching the code"
        case "get_search_content", "fetch_content": return "Fetching a page"
        case "update_session_plan", "set_session_plan": return "Updating the plan"
        case "managed_subagent": return "Starting Deck agent"
        case "managed_parallel": return "Starting parallel agents"
        case "ask_user": return "Waiting for your input"
        case "agent_deck_memory_write", "agent_deck_memory_mark_stale": return "Updating memory"
        case "list_supervisor_requests", "answer_supervisor_request": return "Coordinating Deck agents"
        case "": return "Running tool"
        default: return "Running \(name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    func runningSubagentsProcessingMessage(for session: PiAgentSessionRecord) -> String? {
        let agentNames = runningSubagentNames(for: session)
        guard !agentNames.isEmpty else { return nil }
        let prefix = agentNames.count == 1 ? "Running agent" : "Running agents"
        return "\(prefix): \(formattedRunningAgentList(agentNames))"
    }

    func runningSubagentNames(for session: PiAgentSessionRecord) -> [String] {
        var names: [String] = []
        for run in store.subagentRuns(for: session.id) where run.status.isActive {
            if run.mode == .parallel, let children = run.children, !children.isEmpty {
                names.append(contentsOf: children
                    .filter { $0.status.isActive }
                    .sorted { $0.index < $1.index }
                    .map(\.agentName))
            } else if let child = run.child, child.status.isActive {
                names.append(child.agentName)
            } else {
                names.append(run.agentName)
            }
        }
        return names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func formattedRunningAgentList(_ names: [String]) -> String {
        let uniqueNames = names.reduce(into: [String]()) { result, name in
            if !result.contains(name) { result.append(name) }
        }
        guard uniqueNames.count > 3 else { return uniqueNames.joined(separator: ", ") }
        return uniqueNames.prefix(3).joined(separator: ", ") + " +\(uniqueNames.count - 3) more"
    }

    func scheduleTranscriptCacheUpdate() {
        guard let session = store.selectedSession else {
            transcriptCache.scheduleUpdate(sessionID: nil, revision: 0, rawEntries: [])
            return
        }

        // Hydrate the selected transcript before updating the render cache. Small
        // transcripts decode synchronously here (instant, no spinner); large ones are
        // handed to the background loader and return an empty snapshot so the
        // "Loading transcript" card shows instead of hitching the main thread.
        let entries = store.transcriptForCacheUpdate(session.id)
        transcriptCache.scheduleUpdate(
            sessionID: session.id,
            revision: store.selectedTranscriptRevision,
            rawEntries: entries
        )
    }

    func requestSelectedTranscriptLoadAfterViewUpdate() {
        Task { @MainActor in
            await Task.yield()
            store.requestSelectedTranscriptLoad()
        }
    }

    func requestSubagentTranscriptLoadAfterViewUpdate(runID: UUID) {
        Task { @MainActor in
            await Task.yield()
            store.requestSubagentTranscriptLoad(for: runID)
        }
    }

    func resetTranscriptAutoScroll() {
        transcriptPinnedState.isPinned = true
    }

    func beginTranscriptAutoScrollTurn() {
        resetTranscriptAutoScroll()
    }

    func requestTranscriptBottomScroll() {
        transcriptBottomScrollRequest &+= 1
    }
}
