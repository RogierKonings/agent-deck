import Foundation

// MARK: - Subagent runs

enum PiSubagentRunMode: String, Codable, Hashable {
    case single
    case parallel

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = value == Self.single.rawValue ? .single : .parallel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum PiSubagentWorktreeStatus: String, Codable, Hashable, CaseIterable, Identifiable {
    case none
    case active
    case patchReady
    case applied
    case discarded
    case failed

    var id: String { rawValue }
}

struct PiSubagentGraphEdgeRecord: Identifiable, Codable, Hashable {
    var id: String
    var fromChildID: UUID
    var toChildID: UUID
}

enum PiSubagentExpectedOutcome: String, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    case reportOnly
    case editFilesInWorktree
    case writeProjectFile
    case directProjectWrites

    nonisolated var id: String { rawValue }

    nonisolated var displayName: String {
        switch self {
        case .reportOnly: return "Report only"
        case .editFilesInWorktree: return "Edit files in worktree"
        case .writeProjectFile: return "Write/update project file"
        case .directProjectWrites: return "Direct project writes"
        }
    }
}

struct PiSubagentChildRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var runID: UUID
    var index: Int
    var agentName: String
    var task: String?
    var status: PiSubagentRunStatus
    var model: String?
    var expectedOutcome: PiSubagentExpectedOutcome?
    var requestedOutputPath: String?
    var allowOverwrite: Bool?
    var readFirstPaths: [String]?
    var currentTool: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var toolCount: Int?
    var durationMs: Int?
    var artifactDirectory: String?
    var sessionFile: String?
    var outputPath: String?
    var worktreePath: String?
    var launchCommand: String?
    var executionRunID: UUID?
    var summary: String?
    var error: String?
    var dependencies: [UUID]?
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
}

struct PiSubagentRunRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var parentSessionID: UUID
    var mode: PiSubagentRunMode
    var status: PiSubagentRunStatus
    var agentName: String
    var task: String
    var model: String?
    var thinking: String?
    var expectedOutcome: PiSubagentExpectedOutcome?
    var requestedOutputPath: String?
    var allowOverwrite: Bool?
    var readFirstPaths: [String]?
    var tools: [String]
    var skills: [String]
    var concurrencyLimit: Int?
    var worktreePolicy: String?
    var aggregateSummary: String?
    var artifactDirectory: String
    var outputPath: String?
    var worktreePath: String?
    var parentRepoPath: String?
    var baseCommit: String?
    var isWorktreeIsolated: Bool?
    var worktreeStatus: PiSubagentWorktreeStatus?
    var worktreePatchPath: String?
    var childSessionID: UUID?
    var childPiSessionFile: String?
    var launchCommand: String?
    var summary: String?
    var error: String?
    var child: PiSubagentChildRecord?
    /// Always stored in `index`-ascending order. All constructors build via
    /// `tasks.enumerated().map { index, _ in ... index: index }` and mutators
    /// only ever update children in place — never insert out-of-order. View
    /// code reads `children` directly without re-sorting.
    var children: [PiSubagentChildRecord]?
    var graphEdges: [PiSubagentGraphEdgeRecord]?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var durationMs: Int?
}

extension PiSubagentRunRecord {
    static func failedPlaceholder(parentSessionID: UUID, agentName: String, task: String, error: String) -> PiSubagentRunRecord {
        let now = Date()
        return PiSubagentRunRecord(
            id: UUID(),
            parentSessionID: parentSessionID,
            mode: .single,
            status: .failed,
            agentName: agentName,
            task: task,
            model: nil,
            thinking: nil,
            expectedOutcome: nil,
            requestedOutputPath: nil,
            allowOverwrite: nil,
            readFirstPaths: nil,
            tools: [],
            skills: [],
            concurrencyLimit: nil,
            worktreePolicy: nil,
            aggregateSummary: nil,
            artifactDirectory: "",
            outputPath: nil,
            worktreePath: nil,
            parentRepoPath: nil,
            baseCommit: nil,
            isWorktreeIsolated: nil,
            worktreeStatus: nil,
            worktreePatchPath: nil,
            childSessionID: nil,
            childPiSessionFile: nil,
            launchCommand: nil,
            summary: nil,
            error: error,
            child: nil,
            children: nil,
            graphEdges: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: now,
            durationMs: 0
        )
    }
}
