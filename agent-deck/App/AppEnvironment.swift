import Foundation

/// Injectable service bundle for `AppViewModel`. Use `.live` in production and
/// construct custom instances in tests to swap persistence or Git services.
struct AppEnvironment {
    let agentPersistence: AgentPersistence
    let envPersistence: EnvPersistence
    let appSettingsController: AppSettingsController
    let gitRepositoryService: GitRepositoryService
    let projectPreferencesStore: ProjectPreferencesStore
    let shipService: PiAgentShipService
    let agentAvatarPromptService: AgentAvatarPromptGenerationService
    let skillDescriptionService: SkillDescriptionGenerationService
    let releaseNotesGenerator: ReleaseNotesGenerationService
    let subagentWorktreeService: PiSubagentWorktreeService
    let sessionWorktreeService: PiAgentSessionWorktreeService
    let piSessionTitleGenerator: PiSessionTitleGenerationService
    let skillRepositorySyncService: SkillRepositorySyncService

    static let live = AppEnvironment(
        agentPersistence: AgentPersistence(),
        envPersistence: EnvPersistence(),
        appSettingsController: AppSettingsController(),
        gitRepositoryService: GitRepositoryService(),
        projectPreferencesStore: .shared,
        shipService: PiAgentShipService(),
        agentAvatarPromptService: AgentAvatarPromptGenerationService(),
        skillDescriptionService: SkillDescriptionGenerationService(),
        releaseNotesGenerator: ReleaseNotesGenerationService(),
        subagentWorktreeService: PiSubagentWorktreeService(),
        sessionWorktreeService: PiAgentSessionWorktreeService(),
        piSessionTitleGenerator: PiSessionTitleGenerationService(),
        skillRepositorySyncService: SkillRepositorySyncService()
    )
}
