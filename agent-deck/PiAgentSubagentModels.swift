import Foundation

// MARK: - Subagent supervisor

enum PiSubagentRunStatus: String, Codable, Hashable, CaseIterable, Identifiable {
    case queued
    case starting
    case running
    case blocked
    case completed
    case failed
    case stopped
    case disconnected

    var id: String { rawValue }

    var isActive: Bool {
        self == .queued || self == .starting || self == .running || self == .blocked
    }
}

enum PiSubagentSupervisorRequestStatus: String, Codable, Hashable, Identifiable {
    case pending
    case answered
    case cancelled

    var id: String { rawValue }
}

enum PiSubagentSupervisorRequestKind: String, Codable, Hashable, Identifiable {
    case progressUpdate = "progress_update"
    case needDecision = "need_decision"
    case interviewRequest = "interview_request"

    var id: String { rawValue }

    var isBlocking: Bool {
        self == .needDecision || self == .interviewRequest
    }
}

struct PiSubagentSupervisorRequest: Identifiable, Codable, Hashable {
    var id: String
    var bridgeRequestID: String?
    var runID: UUID
    var parentSessionID: UUID
    var childID: UUID?
    var kind: PiSubagentSupervisorRequestKind
    var title: String
    var message: String
    var status: PiSubagentSupervisorRequestStatus
    var response: String?
    var createdAt: Date
    var updatedAt: Date
}
