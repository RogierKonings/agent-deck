import Foundation

/// Dynamic context and side effects `AgentMemoryCoordinator` delegates to the app shell.
@MainActor
protocol AgentMemoryHost: AnyObject {
    var agentMemoryEnabled: Bool { get }
    var agentMemorySubagentsEnabled: Bool { get }
    var agentMemoryInjectionCharacterBudget: Int { get }
    var agentMemoryShowTranscriptCards: Bool { get }
    var selectedProjectPath: String? { get }
    var selectedSessionID: UUID? { get }
    func session(for id: UUID) -> PiAgentSessionRecord?
    func updateSession(_ id: UUID, mutate: (inout PiAgentSessionRecord) -> Void)
    func appendMemoryTranscriptEntry(_ entry: PiAgentTranscriptEntry)
    func dreamReviewModel() -> AvailableModel?
    func dreamProjectURL() -> URL
    func dreamProcessEnvironment(for projectURL: URL) -> [String: String]
    func navigateToMemory(recordID: String, projectPath: String?)
}
