import Foundation

// MARK: - Session lifecycle

enum PiAgentSessionKind: String, Codable, CaseIterable, Identifiable {
    case project = "Project"
    case issue = "Issue"
    case changesReview = "Changes Review"
    case agent = "Agent"

    var id: String { rawValue }
}

enum PiAgentRunStatus: String, Codable, CaseIterable, Identifiable {
    case draft = "Draft"
    case starting = "Starting"
    case running = "Running"
    case idle = "Idle"
    case stopped = "Stopped"
    case failed = "Failed"
    case completed = "Completed"

    var id: String { rawValue }

    var isActive: Bool {
        self == .starting || self == .running
    }
}

enum PiAgentInputMode: String, CaseIterable, Identifiable {
    case prompt = "Send"
    case steer = "Steer"
    case followUp = "Follow Up"

    var id: String { rawValue }
}
