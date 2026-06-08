import Foundation

// MARK: - App settings host

extension AppViewModel: AppSettingsHost {
    func resolvedActiveTheme() -> Theme {
        settings.controller.resolvedActiveTheme
    }

    func applySettingsSideEffects(_ effects: AppSettingsSideEffects) {
        if effects.contains(.reconfigureIdleParking) {
            piSessions.configureIdleParking()
        }
        if effects.contains(.refreshProjectsRoot) {
            refresh(includeModels: false)
            github.resetProjectScopedState()
        }
        if effects.contains(.applyActiveTheme) {
            ThemeManager.shared.apply(resolvedActiveTheme())
        }
        if effects.contains(.applyMarkdownHighlighting) {
            ThemeManager.shared.setMarkdownHighlightingEnabled(appSettings.piAgentMarkdownHighlightingEnabled)
        }
        if effects.contains(.applyAppIcon) {
            AppIconChoice.apply(settings.selectedAppIcon)
        }
        if effects.contains(.syncSubagentsNewSessionStore) {
            piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions
        }
    }
}

// MARK: - App settings view/API compatibility

extension AppViewModel {
    func setProviderEnabled(_ provider: String, isEnabled: Bool) {
        settings.setProviderEnabled(provider, isEnabled: isEnabled)
    }

    func setModelEnabled(_ model: AvailableModel, isEnabled: Bool) {
        settings.setModelEnabled(model, isEnabled: isEnabled)
    }

    func setOpenAIFastMode(_ model: AvailableModel, isEnabled: Bool) {
        settings.setOpenAIFastMode(model, isEnabled: isEnabled)
    }

    func enableAllModels() {
        settings.enableAllModels()
    }

    var gitHubBoardCacheLifetimeMinutes: Int { settings.gitHubBoardCacheLifetimeMinutes }
    var piAgentNotificationDelayMinutes: Int { settings.piAgentNotificationDelayMinutes }
    var piAgentIdleParkingTimeoutMinutes: Int { settings.piAgentIdleParkingTimeoutMinutes }
    var isPiAgentIdleParkingEnabled: Bool { settings.isPiAgentIdleParkingEnabled }

    func setPiAgentNotificationDelayMinutes(_ minutes: Int) {
        settings.setPiAgentNotificationDelayMinutes(minutes)
    }

    func setPiAgentIdleParkingEnabled(_ isEnabled: Bool) {
        settings.setPiAgentIdleParkingEnabled(isEnabled)
    }

    func setPiAgentIdleParkingTimeoutMinutes(_ minutes: Int) {
        settings.setPiAgentIdleParkingTimeoutMinutes(minutes)
    }

    func setGitHubBoardCacheLifetimeMinutes(_ minutes: Int) {
        settings.setGitHubBoardCacheLifetimeMinutes(minutes)
    }

    func selectTheme(id: UUID) {
        settings.selectTheme(id: id)
    }

    func setPiAgentMarkdownHighlightingEnabled(_ isEnabled: Bool) {
        settings.setPiAgentMarkdownHighlightingEnabled(isEnabled)
    }

    func addCustomTheme(_ theme: Theme) {
        settings.addCustomTheme(theme)
    }

    func updateCustomTheme(_ theme: Theme) {
        settings.updateCustomTheme(theme)
    }

    func deleteCustomTheme(id: UUID) {
        settings.deleteCustomTheme(id: id)
    }

    @discardableResult
    func duplicateTheme(id: UUID) -> Theme? {
        settings.duplicateTheme(id: id)
    }

    var selectedAppIcon: AppIconChoice { settings.selectedAppIcon }

    func selectAppIcon(_ choice: AppIconChoice) {
        settings.selectAppIcon(choice)
    }

    func chooseProjectsRootDirectory(replacingExisting: Bool = false) {
        settings.chooseProjectsRootDirectory(replacingExisting: replacingExisting)
    }

    func useSuggestedProjectsRootDirectory(replacingExisting: Bool = false) {
        settings.useSuggestedProjectsRootDirectory(replacingExisting: replacingExisting)
    }

    func addProjectsRootPaths(_ paths: [String]) {
        settings.addProjectsRootPaths(paths)
    }

    func removeProjectsRootPath(_ path: String) {
        settings.removeProjectsRootPath(path)
    }

    func replaceProjectsRootPath(at index: Int, with path: String) {
        settings.replaceProjectsRootPath(at: index, with: path)
    }

    func resetProjectsRootPathsToDefault() {
        settings.resetProjectsRootPathsToDefault()
    }

    var piAgentTerminalApplicationDisplayName: String { settings.piAgentTerminalApplicationDisplayName }
    var piAgentTerminalApplicationSelectionID: String { settings.piAgentTerminalApplicationSelectionID }
    var piAgentTerminalApplicationOptions: [TerminalApplicationOption] { settings.piAgentTerminalApplicationOptions }
    var piAgentLaunchPreview: String { settings.piAgentLaunchPreview }

    func isPiExtensionEnabled(_ candidate: PiExtensionCandidate) -> Bool {
        settings.isPiExtensionEnabled(candidate)
    }

    func setPiAgentExtensionLoadingMode(_ mode: PiAgentExtensionLoadingMode) {
        settings.setPiAgentExtensionLoadingMode(mode)
    }

    func setPiExtension(_ candidate: PiExtensionCandidate, enabled: Bool) {
        settings.setPiExtension(candidate, enabled: enabled)
    }

    func setAllPiExtensions(_ candidates: [PiExtensionCandidate], enabled: Bool) {
        settings.setAllPiExtensions(candidates, enabled: enabled)
    }

    func prunePiExtensionSelection(to candidates: [PiExtensionCandidate]) {
        settings.prunePiExtensionSelection(to: candidates)
    }

    var piExtensionsRefreshToken: Int { settings.piExtensionsRefreshToken }

    func refreshDiscoveredPiExtensions() {
        settings.refreshDiscoveredPiExtensions()
    }

    func setPiAgentTerminalApplicationSelection(_ selectionID: String) {
        settings.setPiAgentTerminalApplicationSelection(selectionID)
    }

    func choosePiAgentTerminalApplication() {
        settings.choosePiAgentTerminalApplication()
    }

    func setPiAgentTerminalApplicationPath(_ path: String?) {
        settings.setPiAgentTerminalApplicationPath(path)
    }

    func resetPiAgentTerminalApplicationToDefault() {
        settings.resetPiAgentTerminalApplicationToDefault()
    }

    func togglePiAgentThinkingBlocksVisibility() {
        settings.togglePiAgentThinkingBlocksVisibility()
    }

    func setPiAgentTranscriptVisibility(_ keyPath: WritableKeyPath<PiAgentTranscriptVisibilitySettings, Bool>, to value: Bool) {
        settings.setPiAgentTranscriptVisibility(keyPath, to: value)
    }

    func setAgentMemoryEnabled(_ isEnabled: Bool) {
        settings.setAgentMemoryEnabled(isEnabled)
    }

    func setAgentMemorySubagentsEnabled(_ isEnabled: Bool) {
        settings.setAgentMemorySubagentsEnabled(isEnabled)
    }

    func setAgentMemoryShowTranscriptCards(_ isEnabled: Bool) {
        settings.setAgentMemoryShowTranscriptCards(isEnabled)
    }

    func setAgentMemoryInjectionCharacterBudget(_ budget: Int) {
        settings.setAgentMemoryInjectionCharacterBudget(budget)
    }

    func setShowContextSmartZoneHint(_ isEnabled: Bool) {
        settings.setShowContextSmartZoneHint(isEnabled)
    }

    func setAutoGeneratePiAgentSessionTitles(_ isEnabled: Bool) {
        settings.setAutoGeneratePiAgentSessionTitles(isEnabled)
    }

    func setAutoUpdatePiAgentSessionTitles(_ isEnabled: Bool) {
        settings.setAutoUpdatePiAgentSessionTitles(isEnabled)
    }

    func setPiAgentTitleGenerationModelIdentifier(_ identifier: String?) {
        settings.setPiAgentTitleGenerationModelIdentifier(identifier)
    }

    func setPiAgentGitAutomationEnabled(_ isEnabled: Bool) {
        settings.setPiAgentGitAutomationEnabled(isEnabled)
    }

    func setPiAgentGitAutomationRequiresConfirmation(_ isEnabled: Bool) {
        settings.setPiAgentGitAutomationRequiresConfirmation(isEnabled)
    }

    func setPiAgentCommitMessageModelIdentifier(_ identifier: String?) {
        settings.setPiAgentCommitMessageModelIdentifier(identifier)
    }

    func setPiAgentSessionsUseWorktree(_ isEnabled: Bool) {
        settings.setPiAgentSessionsUseWorktree(isEnabled)
    }

    func setPiAgentSessionsKeepWorktreeAfterMerge(_ isEnabled: Bool) {
        settings.setPiAgentSessionsKeepWorktreeAfterMerge(isEnabled)
    }

    func setAutoGenerateAgentAvatarPrompts(_ isEnabled: Bool) {
        settings.setAutoGenerateAgentAvatarPrompts(isEnabled)
    }

    func setAgentAvatarPromptModelIdentifier(_ identifier: String?) {
        settings.setAgentAvatarPromptModelIdentifier(identifier)
    }

    func setSkillDescriptionModelIdentifier(_ identifier: String?) {
        settings.setSkillDescriptionModelIdentifier(identifier)
    }

    func isInjectedCommandEnabled(_ command: PiInjectedCommand) -> Bool {
        PiInjectedCommandCatalog.isEnabled(command, settings: appSettings)
    }

    func setInjectedCommandEnabled(_ command: PiInjectedCommand, isEnabled: Bool) {
        settings.setInjectedCommandEnabled(command, isEnabled: isEnabled)
    }

    func importCommandFile() {
        settings.importCommandFile()
    }

    var areSubagentsEnabledForNewSessions: Bool { settings.areSubagentsEnabledForNewSessions }

    func setSubagentsEnabledForNewSessions(_ isEnabled: Bool) {
        settings.setSubagentsEnabledForNewSessions(isEnabled)
    }

    func setNativeSubagentDelegationPolicy(_ policy: NativeSubagentDelegationPolicy) {
        settings.setNativeSubagentDelegationPolicy(policy)
    }

    func toggleSubagentsForNewSessions() {
        settings.toggleSubagentsForNewSessions()
    }

    var configuredProjectsRootURLs: [URL] { settings.configuredProjectsRootURLs }
    var configuredProjectsRootPaths: [String] { settings.configuredProjectsRootPaths }
    var primaryProjectsRootURL: URL { settings.primaryProjectsRootURL }
    var primaryProjectsRootPath: String { settings.primaryProjectsRootPath }
    var suggestedProjectsRootPath: String? { settings.suggestedProjectsRootPath }
    var hasConfirmedProjectsRootPaths: Bool { settings.hasConfirmedProjectsRootPaths }
}
