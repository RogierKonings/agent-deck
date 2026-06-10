import Foundation

// MARK: - Transcript entries

enum PiAgentTranscriptRole: String, Codable, Hashable {
    case user
    case assistant
    case thinking
    case tool
    case status
    case error
    case stderr
    case raw
}

/// What Pi is doing *right now* during a live turn, derived from the RPC event
/// stream rather than from the last transcript entry. The transcript can only
/// say "the most recent thing that produced an entry"; it cannot tell a tool
/// that is still running apart from one that finished several seconds ago, and
/// it places the turn-start placeholder after streaming thinking. The runner
/// already handles every RPC event, so stamping the activity there is exact and
/// costs one dictionary write per event boundary.
enum PiAgentProcessingActivity: Equatable, Hashable {
    /// Turn started; model call in flight but nothing emitted yet.
    case preparing
    /// `thinking_delta` is streaming.
    case reasoning
    /// `text_delta` is streaming.
    case responding
    /// A tool is executing (between `tool_execution_start` and `…_end`).
    /// `detail` is the tool's target — a file name, command, or query —
    /// extracted from its arguments, or `nil` when there is nothing concise
    /// to show.
    case runningTool(name: String, detail: String?)
    /// A tool finished or a message ended; the next model call is in flight.
    case awaitingModel
    /// Pi is being relaunched because the user changed the model and/or
    /// thinking level. `summary` is the human-readable description shown in the
    /// processing bar (e.g. "thinking level to off", "model to opencode-go/kimi-k2.6").
    case applyingConfigurationChange(summary: String)
}

struct PiAgentUIRequest: Identifiable, Hashable {
    enum Method: String, Hashable {
        case select
        case multiSelect
        case confirm
        case input
        case editor
    }

    enum ResponseFormat: Hashable {
        case plain
        case nativeAsk
    }

    let id: String
    let sessionID: UUID
    let method: Method
    let title: String
    let message: String?
    let options: [String]
    let optionDescriptions: [String: String]
    let placeholder: String?
    let prefill: String?
    let allowsFreeform: Bool
    let allowsComment: Bool
    let responseFormat: ResponseFormat

    func nativeAskSelectionResponseValue(selections: [String], comment: String) -> String {
        let trimmedSelections = selections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var object: [String: Any] = [
            "kind": "selection",
            "selections": trimmedSelections
        ]
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedComment.isEmpty {
            object["comment"] = trimmedComment
        }
        return Self.jsonString(object)
    }

    func nativeAskFreeformResponseValue(_ text: String) -> String {
        Self.jsonString([
            "kind": "freeform",
            "text": text.trimmingCharacters(in: .whitespacesAndNewlines)
        ])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

struct PiAgentTranscriptEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var sessionID: UUID
    var role: PiAgentTranscriptRole
    var title: String
    var text: String
    var rawJSON: String?
    var timestamp: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        role: PiAgentTranscriptRole,
        title: String,
        text: String,
        rawJSON: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.title = title
        self.text = text
        self.rawJSON = rawJSON
        self.timestamp = timestamp
    }
}

extension PiAgentTranscriptEntry {
    /// A per-tool failure (titled `Tool: <name>`). Frequent and tied to a tool
    /// call, so it renders as a compact grouped row and honors the Errors toggle.
    var isToolError: Bool { role == .error && title.hasPrefix("Tool: ") }

    /// A fatal turn/model/provider error — Pi aborted the turn and produced no
    /// output. Rendered as a prominent card and always shown (even when the
    /// Errors toggle is off) so a turn that did nothing is never silent.
    var isModelError: Bool { role == .error && !isToolError }
}

/// Single source of truth for the four divider-style git events that the
/// toolbar appends to a session transcript. Keeps `isDividerStatus`, the
/// transcript filter, and the divider icon table in sync via one type.
enum PiAgentGitEventKind: CaseIterable {
    case commit
    case commitAndPush
    case push
    case merge

    var transcriptTitle: String {
        switch self {
        case .commit:        return "Commit Completed"
        case .commitAndPush: return "Commit & Push Completed"
        case .push:          return "Push Completed"
        case .merge:         return "Merge Completed"
        }
    }

    var icon: String {
        switch self {
        case .commit:                   return "checkmark.circle"
        case .push, .commitAndPush:     return "arrow.up.circle"
        case .merge:                    return "arrow.triangle.merge"
        }
    }

    static func from(title: String) -> PiAgentGitEventKind? {
        allCases.first { $0.transcriptTitle == title }
    }
}

struct PiAgentSessionGitActivity: Equatable {
    var lastCommit: Date?
    var lastPush: Date?
    var lastMerge: Date?

    var hasCommit: Bool { lastCommit != nil }
    var hasPush:   Bool { lastPush != nil }
    var hasMerge:  Bool { lastMerge != nil }

    static let none = PiAgentSessionGitActivity()
}

/// Hides the internal `agent-deck/` ref-namespace prefix from worktree branch
/// names in the UI. The prefix is still part of the actual git branch — it
/// keeps tool-managed branches from colliding with user branches inside the
/// same repo — but it's noise when shown next to an Agent Deck session.
func piAgentSessionDisplayBranchName(_ branch: String) -> String {
    let prefix = "agent-deck/"
    if branch.hasPrefix(prefix) {
        return String(branch.dropFirst(prefix.count))
    }
    return branch
}

func piAgentSessionGitActivity(from transcript: [PiAgentTranscriptEntry]) -> PiAgentSessionGitActivity {
    var out = PiAgentSessionGitActivity()
    for entry in transcript where entry.role == .status {
        guard let kind = PiAgentGitEventKind.from(title: entry.title) else { continue }
        let ts = entry.timestamp
        switch kind {
        case .commit:
            if (out.lastCommit ?? .distantPast) < ts { out.lastCommit = ts }
        case .commitAndPush:
            if (out.lastCommit ?? .distantPast) < ts { out.lastCommit = ts }
            if (out.lastPush  ?? .distantPast) < ts { out.lastPush  = ts }
        case .push:
            if (out.lastPush  ?? .distantPast) < ts { out.lastPush  = ts }
        case .merge:
            if (out.lastMerge ?? .distantPast) < ts { out.lastMerge = ts }
        }
    }
    return out
}
