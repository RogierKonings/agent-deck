import Foundation

// MARK: - Automation host

extension AppViewModel: AutomationHost {
    var piAgentGitAutomationEnabled: Bool { appSettings.piAgentGitAutomationEnabled }
    var piAgentTitleGenerationModelIdentifier: String? { appSettings.piAgentTitleGenerationModelIdentifier }
    var piAgentCommitMessageModelIdentifier: String? { appSettings.piAgentCommitMessageModelIdentifier }
    var agentAvatarPromptModelIdentifier: String? { appSettings.agentAvatarPromptModelIdentifier }
    var skillDescriptionModelIdentifier: String? { appSettings.skillDescriptionModelIdentifier }
}

// MARK: - Automation view/API compatibility

extension AppViewModel {
    func piAgentTitleGenerationModel() -> AvailableModel? {
        automation.piAgentTitleGenerationModel()
    }

    func piAgentCommitMessageModel() -> AvailableModel? {
        automation.piAgentCommitMessageModel()
    }

    func agentAvatarPromptGenerationModel() -> AvailableModel? {
        automation.agentAvatarPromptGenerationModel()
    }

    func generateAgentAvatarPrompt(for agent: EffectiveAgentRecord) async throws -> String {
        try await automation.generateAgentAvatarPrompt(for: agent)
    }

    func skillDescriptionGenerationModel() -> AvailableModel? {
        automation.skillDescriptionGenerationModel()
    }

    func generateSkillDescription(skillContent: String) async throws -> String {
        try await automation.generateSkillDescription(skillContent: skillContent)
    }
}
