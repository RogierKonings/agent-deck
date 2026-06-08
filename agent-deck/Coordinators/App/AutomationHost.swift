import Foundation

/// Model catalog and project context for `AutomationCoordinator`.
@MainActor
protocol AutomationHost: AnyObject {
    var piAgentGitAutomationEnabled: Bool { get }
    var piAgentTitleGenerationModelIdentifier: String? { get }
    var piAgentCommitMessageModelIdentifier: String? { get }
    var agentAvatarPromptModelIdentifier: String? { get }
    var skillDescriptionModelIdentifier: String? { get }
    var automationAvailableModels: [AvailableModel] { get }
    var foundationAutomationModel: AvailableModel? { get }
    var enabledAvailableModels: [AvailableModel] { get }
    func defaultPiAgentModel() -> AvailableModel?
    var selectedProjectPath: String? { get }
    var primaryProjectsRootPath: String { get }
}
