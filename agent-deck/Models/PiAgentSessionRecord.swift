import Foundation

// MARK: - Session record

struct PiAgentSessionRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var kind: PiAgentSessionKind
    var title: String
    var projectPath: String
    var projectName: String
    var repository: String?
    var issueNumber: Int?
    var issueURL: URL?
    var piSessionFile: String?
    var piSessionId: String?
    var model: String?
    var modelProvider: String?
    var modelOverrideID: String?
    var modelOverrideProvider: String?
    var commandInvocations: [String]?
    var thinkingLevel: String?
    var launchCommand: String?
    var branchName: String?
    var worktreePath: String?
    var sourceBranch: String?
    var status: PiAgentRunStatus
    var lastError: String?
    var lastSummary: String?
    var needsAttention: Bool
    var isPinned: Bool
    var lastNotificationAt: Date?
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var totalTokens: Int?
    var toolCalls: Int?
    var toolResults: Int?
    var contextTokens: Int?
    var contextWindow: Int?
    var contextPercent: Double?
    var contextBreakdown: [PiAgentContextBreakdownItem]
    var cost: Double?
    var finalSystemPrompt: String?
    var finalSystemPromptCapturedAt: Date?
    var pendingSteeringMessages: [String]
    var pendingFollowUpMessages: [String]
    var subagentsEnabled: Bool
    var agentSelection: Set<String>?
    var injectedExtensions: [String]?
    var agentName: String?
    var isCompacting: Bool
    var isTitleUserEdited: Bool
    var forkedFromSessionID: UUID?
    var forkedFromParentTitle: String?
    var forkedFromUserMessageText: String?
    var forkedFromTranscriptSnapshot: String?
    /// Snapshot of the memory-context block recalled at this conversation's first
    /// launch. Replayed verbatim through `--append-system-prompt` on every later
    /// process relaunch of the SAME conversation (idle-park wake, model/thinking
    /// change, manual resume, recovery) so resumes restore the *same* system-prompt
    /// memory instead of re-running retrieval. A fork is a distinct session record,
    /// so it does not inherit this snapshot and recalls fresh as a new conversation.
    /// Pi's session file persists the conversation but not the system
    /// prompt, so the block must be re-supplied — but it must be the original bytes,
    /// not a fresh recall. See `memoryRecallCompleted`.
    var recalledMemoryPrompt: String?
    /// IDs of the memories in `recalledMemoryPrompt`, plus any pulled later via
    /// on-demand `agent_deck_memory_search`. Used to dedupe search results so the
    /// agent isn't handed memories it already has in context.
    var recalledMemoryIDs: [String]?
    /// True once launch-time recall has run for this logical conversation (even when
    /// it found nothing). Gates re-retrieval: a relaunch replays the snapshot rather
    /// than recalling again, which keeps the system prompt stable across the
    /// conversation and avoids duplicate "Memory Recalled" cards.
    var memoryRecallCompleted: Bool
    var createdAt: Date
    var updatedAt: Date

    var displayTitle: String {
        if let issueNumber {
            return "#\(issueNumber) \(title)"
        }
        return title
    }

    /// The working tree the agent and toolbar actions operate in. Falls back to the
    /// project path for sessions that pre-date worktree isolation or that opted out.
    var repositoryRoot: String { worktreePath ?? projectPath }

    /// True when this session is a 1:1 chat with a specific agent (`kind == .agent`
    /// and `agentName` resolved). The runner launches Pi with the agent's system
    /// prompt + tool allowlist + agent-defined extensions, with no
    /// `managed_subagent` bridge above it.
    var isAgentBound: Bool { kind == .agent && (agentName?.isEmpty == false) }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, projectPath, projectName, repository, issueNumber, issueURL, piSessionFile, piSessionId
        case model, modelProvider, modelOverrideID, modelOverrideProvider, commandInvocations, thinkingLevel, launchCommand, branchName, worktreePath, sourceBranch
        case status, lastError, lastSummary, needsAttention, isPinned, lastNotificationAt
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalTokens, toolCalls, toolResults, contextTokens, contextWindow, contextPercent, contextBreakdown, cost
        case finalSystemPrompt, finalSystemPromptCapturedAt
        case pendingSteeringMessages, pendingFollowUpMessages, subagentsEnabled, agentSelection, injectedExtensions, agentName, isCompacting, isTitleUserEdited, createdAt, updatedAt
        case forkedFromSessionID, forkedFromParentTitle, forkedFromUserMessageText, forkedFromTranscriptSnapshot
        case recalledMemoryPrompt, recalledMemoryIDs, memoryRecallCompleted
    }

    init(
        id: UUID,
        kind: PiAgentSessionKind,
        title: String,
        projectPath: String,
        projectName: String,
        repository: String?,
        issueNumber: Int?,
        issueURL: URL?,
        piSessionFile: String?,
        piSessionId: String?,
        model: String?,
        modelProvider: String?,
        modelOverrideID: String?,
        modelOverrideProvider: String?,
        commandInvocations: [String]? = nil,
        thinkingLevel: String?,
        launchCommand: String?,
        branchName: String?,
        worktreePath: String?,
        sourceBranch: String? = nil,
        status: PiAgentRunStatus,
        lastError: String?,
        lastSummary: String?,
        needsAttention: Bool,
        isPinned: Bool = false,
        lastNotificationAt: Date?,
        inputTokens: Int?,
        outputTokens: Int?,
        cacheReadTokens: Int?,
        cacheWriteTokens: Int?,
        totalTokens: Int?,
        toolCalls: Int?,
        toolResults: Int?,
        contextTokens: Int?,
        contextWindow: Int?,
        contextPercent: Double?,
        contextBreakdown: [PiAgentContextBreakdownItem] = [],
        cost: Double?,
        finalSystemPrompt: String? = nil,
        finalSystemPromptCapturedAt: Date? = nil,
        pendingSteeringMessages: [String],
        pendingFollowUpMessages: [String],
        subagentsEnabled: Bool,
        agentSelection: Set<String>? = nil,
        injectedExtensions: [String]? = nil,
        agentName: String? = nil,
        isCompacting: Bool = false,
        isTitleUserEdited: Bool = false,
        forkedFromSessionID: UUID? = nil,
        forkedFromParentTitle: String? = nil,
        forkedFromUserMessageText: String? = nil,
        forkedFromTranscriptSnapshot: String? = nil,
        recalledMemoryPrompt: String? = nil,
        recalledMemoryIDs: [String]? = nil,
        memoryRecallCompleted: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.projectPath = projectPath
        self.projectName = projectName
        self.repository = repository
        self.issueNumber = issueNumber
        self.issueURL = issueURL
        self.piSessionFile = piSessionFile
        self.piSessionId = piSessionId
        self.model = model
        self.modelProvider = modelProvider
        self.modelOverrideID = modelOverrideID
        self.modelOverrideProvider = modelOverrideProvider
        self.commandInvocations = commandInvocations
        self.thinkingLevel = thinkingLevel
        self.launchCommand = launchCommand
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.sourceBranch = sourceBranch
        self.status = status
        self.lastError = lastError
        self.lastSummary = lastSummary
        self.needsAttention = needsAttention
        self.isPinned = isPinned
        self.lastNotificationAt = lastNotificationAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.contextPercent = contextPercent
        self.contextBreakdown = contextBreakdown
        self.cost = cost
        self.finalSystemPrompt = finalSystemPrompt
        self.finalSystemPromptCapturedAt = finalSystemPromptCapturedAt
        self.pendingSteeringMessages = pendingSteeringMessages
        self.pendingFollowUpMessages = pendingFollowUpMessages
        self.subagentsEnabled = subagentsEnabled
        self.agentSelection = agentSelection
        self.injectedExtensions = injectedExtensions
        self.agentName = agentName
        self.isCompacting = isCompacting
        self.isTitleUserEdited = isTitleUserEdited
        self.forkedFromSessionID = forkedFromSessionID
        self.forkedFromParentTitle = forkedFromParentTitle
        self.forkedFromUserMessageText = forkedFromUserMessageText
        self.forkedFromTranscriptSnapshot = forkedFromTranscriptSnapshot
        self.recalledMemoryPrompt = recalledMemoryPrompt
        self.recalledMemoryIDs = recalledMemoryIDs
        self.memoryRecallCompleted = memoryRecallCompleted
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(PiAgentSessionKind.self, forKey: .kind),
            title: try container.decode(String.self, forKey: .title),
            projectPath: try container.decode(String.self, forKey: .projectPath),
            projectName: try container.decode(String.self, forKey: .projectName),
            repository: try container.decodeIfPresent(String.self, forKey: .repository),
            issueNumber: try container.decodeIfPresent(Int.self, forKey: .issueNumber),
            issueURL: try container.decodeIfPresent(URL.self, forKey: .issueURL),
            piSessionFile: try container.decodeIfPresent(String.self, forKey: .piSessionFile),
            piSessionId: try container.decodeIfPresent(String.self, forKey: .piSessionId),
            model: try container.decodeIfPresent(String.self, forKey: .model),
            modelProvider: try container.decodeIfPresent(String.self, forKey: .modelProvider),
            modelOverrideID: try container.decodeIfPresent(String.self, forKey: .modelOverrideID),
            modelOverrideProvider: try container.decodeIfPresent(String.self, forKey: .modelOverrideProvider),
            commandInvocations: try container.decodeIfPresent([String].self, forKey: .commandInvocations),
            thinkingLevel: try container.decodeIfPresent(String.self, forKey: .thinkingLevel),
            launchCommand: try container.decodeIfPresent(String.self, forKey: .launchCommand),
            branchName: try container.decodeIfPresent(String.self, forKey: .branchName),
            worktreePath: try container.decodeIfPresent(String.self, forKey: .worktreePath),
            sourceBranch: try container.decodeIfPresent(String.self, forKey: .sourceBranch),
            status: try container.decode(PiAgentRunStatus.self, forKey: .status),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
            lastSummary: try container.decodeIfPresent(String.self, forKey: .lastSummary),
            needsAttention: try container.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false,
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            lastNotificationAt: try container.decodeIfPresent(Date.self, forKey: .lastNotificationAt),
            inputTokens: try container.decodeIfPresent(Int.self, forKey: .inputTokens),
            outputTokens: try container.decodeIfPresent(Int.self, forKey: .outputTokens),
            cacheReadTokens: try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens),
            cacheWriteTokens: try container.decodeIfPresent(Int.self, forKey: .cacheWriteTokens),
            totalTokens: try container.decodeIfPresent(Int.self, forKey: .totalTokens),
            toolCalls: try container.decodeIfPresent(Int.self, forKey: .toolCalls),
            toolResults: try container.decodeIfPresent(Int.self, forKey: .toolResults),
            contextTokens: try container.decodeIfPresent(Int.self, forKey: .contextTokens),
            contextWindow: try container.decodeIfPresent(Int.self, forKey: .contextWindow),
            contextPercent: try container.decodeIfPresent(Double.self, forKey: .contextPercent),
            contextBreakdown: try container.decodeIfPresent([PiAgentContextBreakdownItem].self, forKey: .contextBreakdown) ?? [],
            cost: try container.decodeIfPresent(Double.self, forKey: .cost),
            finalSystemPrompt: try container.decodeIfPresent(String.self, forKey: .finalSystemPrompt),
            finalSystemPromptCapturedAt: try container.decodeIfPresent(Date.self, forKey: .finalSystemPromptCapturedAt),
            pendingSteeringMessages: try container.decodeIfPresent([String].self, forKey: .pendingSteeringMessages) ?? [],
            pendingFollowUpMessages: try container.decodeIfPresent([String].self, forKey: .pendingFollowUpMessages) ?? [],
            subagentsEnabled: try container.decodeIfPresent(Bool.self, forKey: .subagentsEnabled) ?? true,
            agentSelection: try container.decodeIfPresent(Set<String>.self, forKey: .agentSelection),
            injectedExtensions: try container.decodeIfPresent([String].self, forKey: .injectedExtensions),
            agentName: try container.decodeIfPresent(String.self, forKey: .agentName),
            isCompacting: try container.decodeIfPresent(Bool.self, forKey: .isCompacting) ?? false,
            isTitleUserEdited: try container.decodeIfPresent(Bool.self, forKey: .isTitleUserEdited) ?? false,
            forkedFromSessionID: try container.decodeIfPresent(UUID.self, forKey: .forkedFromSessionID),
            forkedFromParentTitle: try container.decodeIfPresent(String.self, forKey: .forkedFromParentTitle),
            forkedFromUserMessageText: try container.decodeIfPresent(String.self, forKey: .forkedFromUserMessageText),
            forkedFromTranscriptSnapshot: try container.decodeIfPresent(String.self, forKey: .forkedFromTranscriptSnapshot),
            recalledMemoryPrompt: try container.decodeIfPresent(String.self, forKey: .recalledMemoryPrompt),
            recalledMemoryIDs: try container.decodeIfPresent([String].self, forKey: .recalledMemoryIDs),
            memoryRecallCompleted: try container.decodeIfPresent(Bool.self, forKey: .memoryRecallCompleted) ?? false,
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }
}

extension PiAgentSessionRecord {
    static func sessionListPrecedes(_ lhs: PiAgentSessionRecord, _ rhs: PiAgentSessionRecord, calendar: Calendar = .current) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }

        let updatedDayComparison = calendar.compare(lhs.updatedAt, to: rhs.updatedAt, toGranularity: .day)
        if updatedDayComparison != .orderedSame { return updatedDayComparison == .orderedDescending }

        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
