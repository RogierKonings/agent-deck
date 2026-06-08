import Foundation

// MARK: - Native bridge requests

struct PiManagedSubagentBridgeRequest: Codable, Hashable {
    var agent: String
    var task: String
    var continueSubagentID: String?
    var reads: [String]?
}

struct PiManagedParallelTaskRequest: Codable, Hashable {
    var agent: String
    var task: String
}

struct PiManagedParallelBridgeRequest: Codable, Hashable {
    var tasks: [PiManagedParallelTaskRequest]
    var concurrency: Int?
    var worktree: Bool?
}

struct PiSupervisorAnswerBridgeRequest: Codable, Hashable {
    var requestID: String
    var response: String
}

struct PiSessionPlanSetBridgeRequest: Codable, Hashable {
    var items: [PiSessionPlanBridgeItem]
}

struct PiSessionPlanUpdateBridgeRequest: Codable, Hashable {
    var updates: [PiSessionPlanBridgeUpdate]
}

struct PiSystemPromptAuditBridgeRequest: Codable, Hashable {
    var scope: String?
    var parentSessionID: String?
    var runID: String?
    var agent: String?
    var systemPrompt: String
}

struct PiNativeAskBridgeRequest: Codable, Hashable {
    var question: String
    var context: String?
    var options: [JSONValue]?
    var allowMultiple: Bool?
    var allowFreeform: Bool?
    var allowComment: Bool?
    var timeout: Double?

    var normalizedOptions: [PiNativeAskOption] {
        (options ?? []).compactMap { value in
            if let title = value.stringValue {
                return PiNativeAskOption(title: title, description: nil)
            }
            guard case let .object(object) = value,
                  let title = object["title"]?.stringValue,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PiNativeAskOption(title: title, description: object["description"]?.stringValue)
        }
    }
}

struct PiNativeAskOption: Codable, Hashable {
    var title: String
    var description: String?
}
