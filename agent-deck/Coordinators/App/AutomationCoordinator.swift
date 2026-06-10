import Foundation
import Observation

@MainActor
@Observable
final class AutomationCoordinator {
    weak var host: AutomationHost?

    private let avatarPromptService: AgentAvatarPromptGenerationService
    private let skillDescriptionService: SkillDescriptionGenerationService

    init(
        avatarPromptService: AgentAvatarPromptGenerationService,
        skillDescriptionService: SkillDescriptionGenerationService
    ) {
        self.avatarPromptService = avatarPromptService
        self.skillDescriptionService = skillDescriptionService
    }

    func attach(host: AutomationHost) {
        self.host = host
    }

    func piAgentTitleGenerationModel() -> AvailableModel? {
        if let identifier = host?.piAgentTitleGenerationModelIdentifier,
           let selected = host?.automationAvailableModels.first(where: { $0.identifier == identifier }) {
            return selected
        }
        return host?.foundationAutomationModel ?? host?.defaultPiAgentModel() ?? host?.enabledAvailableModels.first
    }

    func piAgentCommitMessageModel() -> AvailableModel? {
        guard host?.piAgentGitAutomationEnabled == true,
              let identifier = host?.piAgentCommitMessageModelIdentifier,
              let selected = host?.automationAvailableModels.first(where: { $0.identifier == identifier }) else { return nil }
        return selected
    }

    func agentAvatarPromptGenerationModel() -> AvailableModel? {
        if let identifier = host?.agentAvatarPromptModelIdentifier,
           let selected = host?.automationAvailableModels.first(where: { $0.identifier == identifier }) {
            return selected
        }
        return host?.foundationAutomationModel ?? host?.defaultPiAgentModel() ?? host?.enabledAvailableModels.first
    }

    func generateAgentAvatarPrompt(for agent: EffectiveAgentRecord) async throws -> String {
        guard let model = agentAvatarPromptGenerationModel() else {
            throw PiAgentShipService.ShipError.noModel
        }
        let projectPath = agent.projectRoot ?? host?.selectedProjectPath ?? host?.primaryProjectsRootPath ?? ""
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectURL)
        return try await avatarPromptService.generatePrompt(for: agent, model: model, projectURL: projectURL, environment: environment)
    }

    /// An explicit Automations pick wins; otherwise Apple Foundation Models when available.
    func skillDescriptionGenerationModel() -> AvailableModel? {
        if let identifier = host?.skillDescriptionModelIdentifier,
           let selected = host?.automationAvailableModels.first(where: { $0.identifier == identifier }) {
            return selected
        }
        return host?.foundationAutomationModel
    }

    func generateSkillDescription(skillContent: String) async throws -> String {
        guard let model = skillDescriptionGenerationModel() else {
            throw SkillDescriptionGenerationService.GenerationError.rpc("No model is configured for skill summaries.")
        }
        let hash = SkillDescriptionCache.sha256(of: Data(skillContent.utf8))
        if let cached = SkillDescriptionCache.get(hash: hash) {
            return cached.summary
        }
        let projectPath = host?.selectedProjectPath ?? host?.primaryProjectsRootPath ?? ""
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectURL)
        let summary = try await skillDescriptionService.generate(
            skillContent: skillContent,
            model: model,
            projectURL: projectURL,
            environment: environment
        )
        SkillDescriptionCache.put(hash: hash, summary: summary, modelIdentifier: model.identifier)
        return summary
    }
}
