import Foundation

// MARK: - Session plan

struct PiSessionPlanBridgeItem: Codable, Hashable {
    var id: String?
    var title: String
    var status: PiSessionPlanItemStatus?
}

struct PiSessionPlanBridgeUpdate: Codable, Hashable {
    var id: String
    var title: String?
    var status: PiSessionPlanItemStatus?
}

enum PiSessionPlanItemStatus: String, Codable, Hashable, CaseIterable {
    case todo
    case inProgress = "in_progress"
    case done
    case blocked
    case skipped

    var displayName: String {
        switch self {
        case .todo: return "Todo"
        case .inProgress: return "In Progress"
        case .done: return "Done"
        case .blocked: return "Blocked"
        case .skipped: return "Skipped"
        }
    }
}

struct PiSessionPlanItemRecord: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var status: PiSessionPlanItemStatus
    var updatedAt: Date
}

enum PiSessionPlanEventKind: String, Codable, Hashable {
    case created
    case updated
    case replaced
    case cleared
}

struct PiSessionPlanRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var items: [PiSessionPlanItemRecord]
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case items
        case createdAt
        case updatedAt
    }

    init(id: UUID = UUID(), sessionID: UUID, items: [PiSessionPlanItemRecord], createdAt: Date, updatedAt: Date) {
        self.id = id
        self.sessionID = sessionID
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        items = try container.decode([PiSessionPlanItemRecord].self, forKey: .items)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct PiSessionPlanEventRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var sessionID: UUID
    var planID: UUID
    var kind: PiSessionPlanEventKind
    var items: [PiSessionPlanItemRecord]
    var timestamp: Date
}
