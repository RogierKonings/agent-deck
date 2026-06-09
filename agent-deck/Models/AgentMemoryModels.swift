import Foundation

nonisolated enum AgentMemoryScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case general
    case project

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: return "General"
        case .project: return "Project"
        }
    }
}

nonisolated enum AgentMemoryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case fact
    case event
    case procedure
    case insight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fact: return "Fact"
        case .event: return "Event"
        case .procedure: return "Procedure"
        case .insight: return "Insight"
        }
    }

    var explanation: String {
        switch self {
        case .fact: return "Deduplicatable knowledge: preferences, config, decisions, or durable facts."
        case .event: return "Timestamped occurrences such as crashes, deploys, milestones, or completed runs."
        case .procedure: return "Versioned workflows or runbooks that evolve by supersession."
        case .insight: return "General observations, patterns, gotchas, and edge cases."
        }
    }
}

nonisolated enum AgentMemoryStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case active
    case stale

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: return "Current"
        case .stale: return "Superseded"
        }
    }

    var isInjectable: Bool { self == .active }
}

nonisolated struct AgentMemoryRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var kind: AgentMemoryKind
    var scope: AgentMemoryScope
    var status: AgentMemoryStatus
    var title: String
    /// Canonical Pi memory content. Kept as `summary` for compatibility with existing Agent Deck transcript/UI call sites.
    var summary: String
    var filePath: String
    var projectPath: String?
    var sourceSessionID: UUID?
    var sourceRunID: UUID?
    var sourceAgentName: String?
    /// Canonical Pi memory reasoning.
    var writeReason: String?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var tags: [String]
    var weight: Double
    var effectiveWeight: Double
    var projectID: String
    var supersedes: String?
    var supersededBy: String?
    var synthesizedFrom: [String]?
    var sourceSession: String?

    var isInjectable: Bool { status.isInjectable }
    var isSuperseded: Bool { supersededBy?.isEmpty == false }
}

struct AgentMemoryDocument: Hashable, Sendable {
    var record: AgentMemoryRecord
    var body: String
}

struct AgentMemoryRetrieval: Hashable, Sendable {
    var records: [AgentMemoryRecord]
    var prompt: String
}

enum AgentMemoryEventKind: String, Codable, Hashable {
    case recalled
    case searched
    case stored
    case edited
    case archived
    case stale
    case blocked

    var displayTitle: String {
        switch self {
        case .recalled: return "Memory Recalled"
        case .searched: return "Memory Searched"
        case .stored: return "Memory Stored"
        case .edited: return "Memory Edited"
        case .archived: return "Memory Archived"
        case .stale: return "Memory Superseded"
        case .blocked: return "Memory Blocked"
        }
    }

    var systemImage: String {
        switch self {
        case .recalled: return "brain"
        case .searched: return "text.magnifyingglass"
        case .stored: return "tray.and.arrow.down"
        case .edited: return "pencil"
        case .archived: return "archivebox"
        case .stale: return "arrow.triangle.2.circlepath"
        case .blocked: return "exclamationmark.shield"
        }
    }
}

struct AgentMemoryTranscriptEvent: Codable, Hashable, Sendable {
    var type: String
    var event: AgentMemoryEventKind
    var memoryIDs: [String]
    var memoryTitles: [String]?
    var scope: AgentMemoryScope?
    var title: String
    var summary: String

    static let rawType = "agent_deck_memory_event"
}

struct AgentMemoryStoreBridgeRequest: Codable, Hashable, Sendable {
    var title: String
    var content: String
    var reasoning: String
    var tags: [String]?
    var weight: Double?
    var scope: AgentMemoryScope?
    var project: String?
    var type: AgentMemoryKind?
    var supersedes: String?

    enum CodingKeys: String, CodingKey {
        case title, content, reasoning, tags, weight, scope, project, type, supersedes
    }
}

struct AgentMemoryRecallBridgeRequest: Codable, Hashable, Sendable {
    var query: String?
    var id: String?
    var project: String?
    var type: AgentMemoryKind?
    var includeSuperseded: Bool?
    var limit: Int?
}

struct AgentMemoryReinforceBridgeRequest: Codable, Hashable, Sendable {
    var id: String
}

struct AgentMemoryUpdateBridgeRequest: Codable, Hashable, Sendable {
    var id: String
    var title: String?
    var content: String?
    var reasoning: String?
    var tags: [String]?
    var weight: Double?
    var type: AgentMemoryKind?
    var supersedes: String?
    var supersedesWasProvided: Bool
    var project: String?

    enum CodingKeys: String, CodingKey {
        case id, title, content, reasoning, tags, weight, type, supersedes, project
    }

    init(id: String, title: String? = nil, content: String? = nil, reasoning: String? = nil, tags: [String]? = nil, weight: Double? = nil, type: AgentMemoryKind? = nil, supersedes: String? = nil, supersedesWasProvided: Bool = false, project: String? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.reasoning = reasoning
        self.tags = tags
        self.weight = weight
        self.type = type
        self.supersedes = supersedes
        self.supersedesWasProvided = supersedesWasProvided
        self.project = project
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        tags = try container.decodeIfPresent([String].self, forKey: .tags)
        weight = try container.decodeIfPresent(Double.self, forKey: .weight)
        type = try container.decodeIfPresent(AgentMemoryKind.self, forKey: .type)
        supersedesWasProvided = container.contains(.supersedes)
        supersedes = try container.decodeIfPresent(String.self, forKey: .supersedes)
        project = try container.decodeIfPresent(String.self, forKey: .project)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(reasoning, forKey: .reasoning)
        try container.encodeIfPresent(tags, forKey: .tags)
        try container.encodeIfPresent(weight, forKey: .weight)
        try container.encodeIfPresent(type, forKey: .type)
        if supersedesWasProvided { try container.encodeIfPresent(supersedes, forKey: .supersedes) }
        try container.encodeIfPresent(project, forKey: .project)
    }
}

struct AgentMemoryDeleteBridgeRequest: Codable, Hashable, Sendable {
    var id: String
}

// Compatibility DTOs retained so older generated bridge payloads and tests decode while the model-facing tools use canonical Pi names.
typealias AgentMemoryWriteBridgeRequest = AgentMemoryStoreBridgeRequest

struct AgentMemoryStaleBridgeRequest: Codable, Hashable, Sendable {
    var memoryIDs: [String]?
    var query: String?
    var reason: String?
}

struct AgentMemorySearchBridgeRequest: Codable, Hashable, Sendable {
    var query: String
    var limit: Int?
}

enum PiMemoryDreamPhase: String, Codable, CaseIterable, Identifiable, Sendable {
    case clusterReview = "cluster-review"
    case schemaSynthesis = "schema-synthesis"
    case weightRebalance = "weight-rebalance"
    case contradictionScan = "contradiction-scan"
    case temporalPatterns = "temporal-patterns"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clusterReview: return "Cluster Review"
        case .schemaSynthesis: return "Schema Synthesis"
        case .weightRebalance: return "Weight Rebalance"
        case .contradictionScan: return "Contradiction Scan"
        case .temporalPatterns: return "Temporal Patterns"
        }
    }
}

enum PiMemoryDreamActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case merge
    case synthesize
    case reweight
    case flagContradiction = "flag-contradiction"
    case discoverPattern = "discover-pattern"
    case skip

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .merge: return "Merge"
        case .synthesize: return "Synthesize"
        case .reweight: return "Reweight"
        case .flagContradiction: return "Flag Contradiction"
        case .discoverPattern: return "Discover Pattern"
        case .skip: return "Skip"
        }
    }
}

struct PiMemoryDreamProposal: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var phase: PiMemoryDreamPhase
    var action: PiMemoryDreamActionKind
    var sourceMemoryIDs: [String]
    var title: String
    var content: String
    var reasoning: String
    var tags: [String]
    var weight: Double?
    var type: AgentMemoryKind?
    var weightChanges: [String: Double]
    var contradictionPairs: [[String]]
    var reviewerRawResponse: String?

    init(id: String, phase: PiMemoryDreamPhase = .clusterReview, action: PiMemoryDreamActionKind, sourceMemoryIDs: [String], title: String, content: String, reasoning: String, tags: [String], weight: Double?, type: AgentMemoryKind?, weightChanges: [String: Double], contradictionPairs: [[String]] = [], reviewerRawResponse: String? = nil) {
        self.id = id
        self.phase = phase
        self.action = action
        self.sourceMemoryIDs = sourceMemoryIDs
        self.title = title
        self.content = content
        self.reasoning = reasoning
        self.tags = tags
        self.weight = weight
        self.type = type
        self.weightChanges = weightChanges
        self.contradictionPairs = contradictionPairs
        self.reviewerRawResponse = reviewerRawResponse
    }
}

struct PiMemoryDreamCycleResult: Codable, Hashable, Sendable {
    var id: String
    var startedAt: Date
    var finishedAt: Date
    var trigger: String
    var phase: String
    var clustersReviewed: Int
    var memoriesMerged: Int
    var schemasCreated: Int
    var weightsAdjusted: Int
    var contradictionsFound: Int
    var patternsDiscovered: Int
    var proposals: [PiMemoryDreamProposal]
}
