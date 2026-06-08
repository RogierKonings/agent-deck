import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppSettingsCoordinator {
    weak var host: AppSettingsHost?

    let controller: AppSettingsController

    init(controller: AppSettingsController) {
        self.controller = controller
    }

    func attach(host: AppSettingsHost) {
        self.host = host
    }

    func bootstrapFromController() {
        host?.appSettings = controller.settings
        ThemeManager.shared.apply(controller.resolvedActiveTheme)
        ThemeManager.shared.setMarkdownHighlightingEnabled(controller.settings.piAgentMarkdownHighlightingEnabled)
        writeOpenAIFastModeConfig()
    }

    func publish(sideEffects: AppSettingsSideEffects = []) {
        host?.appSettings = controller.settings
        if sideEffects.contains(.syncOpenAIFastConfig) {
            writeOpenAIFastModeConfig()
        }
        host?.applySettingsSideEffects(sideEffects)
    }

    // MARK: - Model catalog

    func setProviderEnabled(_ provider: String, isEnabled: Bool) {
        guard controller.setProviderEnabled(provider, isEnabled: isEnabled) else { return }
        publish()
    }

    func setModelEnabled(_ model: AvailableModel, isEnabled: Bool) {
        guard controller.setModelEnabled(identifier: model.identifier, isEnabled: isEnabled) else { return }
        publish()
    }

    func setOpenAIFastMode(_ model: AvailableModel, isEnabled: Bool) {
        guard PiNativeSubagentBridgeExtensions.isOpenAIFastEligibleModel(provider: model.provider, modelID: model.model) else { return }
        guard controller.setOpenAIFastMode(identifier: model.identifier, isEnabled: isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func enableAllModels() {
        guard controller.enableAllModels() else { return }
        publish()
    }

    // MARK: - Pi Agent session behavior

    var gitHubBoardCacheLifetimeMinutes: Int { controller.gitHubBoardCacheLifetimeMinutes }
    var piAgentNotificationDelayMinutes: Int { controller.piAgentNotificationDelayMinutes }
    var piAgentIdleParkingTimeoutMinutes: Int { controller.piAgentIdleParkingTimeoutMinutes }
    var isPiAgentIdleParkingEnabled: Bool { controller.isPiAgentIdleParkingEnabled }

    func setPiAgentNotificationDelayMinutes(_ minutes: Int) {
        guard controller.setPiAgentNotificationDelayMinutes(minutes) else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentIdleParkingEnabled(_ isEnabled: Bool) {
        guard controller.setPiAgentIdleParkingEnabled(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentIdleParkingTimeoutMinutes(_ minutes: Int) {
        guard controller.setPiAgentIdleParkingTimeoutMinutes(minutes) else { return }
        publish(sideEffects: .standard)
    }

    func setGitHubBoardCacheLifetimeMinutes(_ minutes: Int) {
        guard controller.setGitHubBoardCacheLifetimeMinutes(minutes) else { return }
        publish(sideEffects: .standard)
    }

    // MARK: - Color themes

    func selectTheme(id: UUID) {
        guard controller.selectTheme(id: id) else { return }
        publish(sideEffects: [.standard, .applyActiveTheme])
    }

    func setPiAgentMarkdownHighlightingEnabled(_ isEnabled: Bool) {
        guard controller.setPiAgentMarkdownHighlightingEnabled(isEnabled) else { return }
        publish(sideEffects: [.standard, .applyMarkdownHighlighting])
    }

    func addCustomTheme(_ theme: Theme) {
        guard controller.addCustomTheme(theme) else { return }
        publish(sideEffects: .standard)
    }

    func updateCustomTheme(_ theme: Theme) {
        guard controller.updateCustomTheme(theme) else { return }
        var effects: AppSettingsSideEffects = .standard
        if controller.resolvedActiveTheme.id == theme.id {
            effects.insert(.applyActiveTheme)
        }
        publish(sideEffects: effects)
    }

    func deleteCustomTheme(id: UUID) {
        guard controller.deleteCustomTheme(id: id) else { return }
        publish(sideEffects: [.standard, .applyActiveTheme])
    }

    @discardableResult
    func duplicateTheme(id: UUID) -> Theme? {
        guard let copy = controller.duplicateTheme(id: id) else { return nil }
        publish(sideEffects: .standard)
        return copy
    }

    // MARK: - App icon

    var selectedAppIcon: AppIconChoice { controller.selectedAppIcon }

    func selectAppIcon(_ choice: AppIconChoice) {
        guard controller.selectAppIcon(choice) else { return }
        publish(sideEffects: [.standard, .applyAppIcon])
    }

    // MARK: - Projects root

    func chooseProjectsRootDirectory(replacingExisting: Bool = false) {
        guard controller.chooseProjectsRootDirectory(replacingExisting: replacingExisting) else { return }
        publish(sideEffects: [.standard, .refreshProjectsRoot])
    }

    func useSuggestedProjectsRootDirectory(replacingExisting: Bool = false) {
        guard controller.useSuggestedProjectsRootDirectory(replacingExisting: replacingExisting) else { return }
        publish(sideEffects: [.standard, .refreshProjectsRoot])
    }

    func addProjectsRootPaths(_ paths: [String]) {
        guard controller.addProjectsRootPaths(paths) else { return }
        publish(sideEffects: [.standard, .refreshProjectsRoot])
    }

    func removeProjectsRootPath(_ path: String) {
        guard controller.removeProjectsRootPath(path) else { return }
        publish(sideEffects: [.standard, .refreshProjectsRoot])
    }

    func replaceProjectsRootPath(at index: Int, with path: String) {
        guard controller.replaceProjectsRootPath(at: index, with: path) else { return }
        publish(sideEffects: [.standard, .refreshProjectsRoot])
    }

    func resetProjectsRootPathsToDefault() {
        guard controller.resetProjectsRootPathsToDefault() else { return }
        publish(sideEffects: [.standard, .refreshProjectsRoot])
    }

    // MARK: - Terminal + extensions

    var piAgentTerminalApplicationDisplayName: String { controller.piAgentTerminalApplicationDisplayName }
    var piAgentTerminalApplicationSelectionID: String { controller.piAgentTerminalApplicationSelectionID }
    var piAgentTerminalApplicationOptions: [TerminalApplicationOption] { controller.piAgentTerminalApplicationOptions }
    var piAgentLaunchPreview: String { controller.piAgentLaunchPreview }

    /// Bumped by the Extensions toolbar Refresh action; the screen keys its
    /// off-main discovery `.task` on this so a Refresh re-scans without a project change.
    private(set) var piExtensionsRefreshToken = 0

    func refreshDiscoveredPiExtensions() {
        piExtensionsRefreshToken &+= 1
    }

    func isPiExtensionEnabled(_ candidate: PiExtensionCandidate) -> Bool {
        controller.isPiExtensionEnabled(candidate)
    }

    func setPiAgentExtensionLoadingMode(_ mode: PiAgentExtensionLoadingMode) {
        guard controller.setPiAgentExtensionLoadingMode(mode) else { return }
        publish(sideEffects: .standard)
    }

    func setPiExtension(_ candidate: PiExtensionCandidate, enabled: Bool) {
        guard controller.setPiExtension(candidate, enabled: enabled) else { return }
        publish(sideEffects: .standard)
    }

    func setAllPiExtensions(_ candidates: [PiExtensionCandidate], enabled: Bool) {
        guard controller.setAllPiExtensions(candidates, enabled: enabled) else { return }
        publish(sideEffects: .standard)
    }

    func prunePiExtensionSelection(to candidates: [PiExtensionCandidate]) {
        guard controller.prunePiExtensionSelection(to: candidates) else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentTerminalApplicationSelection(_ selectionID: String) {
        controller.setPiAgentTerminalApplicationSelection(selectionID)
        publish(sideEffects: .standard)
    }

    func choosePiAgentTerminalApplication() {
        guard controller.choosePiAgentTerminalApplication() else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentTerminalApplicationPath(_ path: String?) {
        guard controller.setPiAgentTerminalApplicationPath(path) else { return }
        publish(sideEffects: .standard)
    }

    func resetPiAgentTerminalApplicationToDefault() {
        guard controller.resetPiAgentTerminalApplicationToDefault() else { return }
        publish(sideEffects: .standard)
    }

    func togglePiAgentThinkingBlocksVisibility() {
        guard controller.togglePiAgentThinkingBlocksVisibility() else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentTranscriptVisibility(_ keyPath: WritableKeyPath<PiAgentTranscriptVisibilitySettings, Bool>, to value: Bool) {
        guard controller.setPiAgentTranscriptVisibility(keyPath, to: value) else { return }
        publish(sideEffects: .standard)
    }

    // MARK: - Memory settings

    func setAgentMemoryEnabled(_ isEnabled: Bool) {
        guard controller.setAgentMemoryEnabled(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setAgentMemorySubagentsEnabled(_ isEnabled: Bool) {
        guard controller.setAgentMemorySubagentsEnabled(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setAgentMemoryShowTranscriptCards(_ isEnabled: Bool) {
        guard controller.setAgentMemoryShowTranscriptCards(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setAgentMemoryInjectionCharacterBudget(_ budget: Int) {
        guard controller.setAgentMemoryInjectionCharacterBudget(budget) else { return }
        publish(sideEffects: .standard)
    }

    // MARK: - Pi Agent automation + titles

    func setShowContextSmartZoneHint(_ isEnabled: Bool) {
        guard controller.setShowContextSmartZoneHint(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setAutoGeneratePiAgentSessionTitles(_ isEnabled: Bool) {
        guard controller.setAutoGeneratePiAgentSessionTitles(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setAutoUpdatePiAgentSessionTitles(_ isEnabled: Bool) {
        guard controller.setAutoUpdatePiAgentSessionTitles(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentTitleGenerationModelIdentifier(_ identifier: String?) {
        guard controller.setPiAgentTitleGenerationModelIdentifier(identifier) else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentGitAutomationEnabled(_ isEnabled: Bool) {
        guard controller.setPiAgentGitAutomationEnabled(isEnabled) else { return }
        if isEnabled,
           controller.piAgentCommitMessageModelIdentifier == nil,
           host?.foundationAutomationModel != nil {
            _ = controller.setPiAgentCommitMessageModelIdentifier(FoundationModelAutomationService.identifier)
        }
        publish(sideEffects: .standard)
    }

    func setPiAgentGitAutomationRequiresConfirmation(_ isEnabled: Bool) {
        guard controller.setPiAgentGitAutomationRequiresConfirmation(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentCommitMessageModelIdentifier(_ identifier: String?) {
        guard controller.setPiAgentCommitMessageModelIdentifier(identifier) else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentSessionsUseWorktree(_ isEnabled: Bool) {
        guard controller.setPiAgentSessionsUseWorktree(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setPiAgentSessionsKeepWorktreeAfterMerge(_ isEnabled: Bool) {
        guard controller.setPiAgentSessionsKeepWorktreeAfterMerge(isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func setAutoGenerateAgentAvatarPrompts(_ isEnabled: Bool) {
        guard controller.setAutoGenerateAgentAvatarPrompts(isEnabled) else { return }
        if isEnabled,
           controller.agentAvatarPromptModelIdentifier == nil,
           host?.foundationAutomationModel != nil {
            _ = controller.setAgentAvatarPromptModelIdentifier(FoundationModelAutomationService.identifier)
        }
        publish(sideEffects: .standard)
    }

    func setAgentAvatarPromptModelIdentifier(_ identifier: String?) {
        guard controller.setAgentAvatarPromptModelIdentifier(identifier) else { return }
        publish(sideEffects: .standard)
    }

    func setSkillDescriptionModelIdentifier(_ identifier: String?) {
        guard controller.setSkillDescriptionModelIdentifier(identifier) else { return }
        publish(sideEffects: .standard)
    }

    func setInjectedCommandEnabled(_ command: PiInjectedCommand, isEnabled: Bool) {
        guard controller.setInjectedCommandEnabled(command, isEnabled: isEnabled) else { return }
        publish(sideEffects: .standard)
    }

    func importCommandFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.sourceCode, .javaScript]
        panel.message = "Choose a Pi extension file containing pi.registerCommand(...)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PiInjectedCommandCatalog.importCommandFile(url)
        publish(sideEffects: .standard)
    }

    // MARK: - Native subagents defaults

    var areSubagentsEnabledForNewSessions: Bool { controller.areSubagentsEnabledForNewSessions }

    func setSubagentsEnabledForNewSessions(_ isEnabled: Bool) {
        guard controller.setSubagentsEnabledForNewSessions(isEnabled) else { return }
        publish(sideEffects: [.standard, .syncSubagentsNewSessionStore])
    }

    func setNativeSubagentDelegationPolicy(_ policy: NativeSubagentDelegationPolicy) {
        guard controller.setNativeSubagentDelegationPolicy(policy) else { return }
        publish(sideEffects: .standard)
    }

    func toggleSubagentsForNewSessions() {
        guard controller.toggleSubagentsForNewSessions() else { return }
        publish(sideEffects: [.standard, .syncSubagentsNewSessionStore])
    }

    // MARK: - Projects root reads

    var configuredProjectsRootURLs: [URL] { controller.configuredProjectsRootURLs }
    var configuredProjectsRootPaths: [String] { controller.configuredProjectsRootPaths }
    var primaryProjectsRootURL: URL { controller.primaryProjectsRootURL }
    var primaryProjectsRootPath: String { controller.primaryProjectsRootPath }
    var suggestedProjectsRootPath: String? { controller.suggestedProjectsRootURL?.path }
    var hasConfirmedProjectsRootPaths: Bool { controller.hasConfirmedProjectsRootPaths }

    // MARK: - Private

    private func writeOpenAIFastModeConfig() {
        let identifiers = controller.settings.openAIFastModeModelIdentifiers
        Task.detached(priority: .utility) {
            PiNativeSubagentBridgeExtensions.writeOpenAIFastConfig(
                enabledModelIdentifiers: identifiers
            )
        }
    }
}
