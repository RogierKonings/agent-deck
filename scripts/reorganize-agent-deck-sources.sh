#!/usr/bin/env bash
# Reorganize flat agent-deck/*.swift into a feature-oriented folder layout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)/agent-deck"
cd "$ROOT"

move() {
  local dest="$1"
  shift
  mkdir -p "$dest"
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    git mv "$file" "$dest/" 2>/dev/null || mv "$file" "$dest/"
  done
}

move_dir() {
  local dest="$1"
  local dir="$2"
  [[ -d "$dir" ]] || return 0
  mkdir -p "$dest"
  git mv "$dir" "$dest/" 2>/dev/null || mv "$dir" "$dest/"
}

# --- App entry ---
move App \
  agent_deckApp.swift \
  AgentDeckCommands.swift \
  AppEnvironment.swift \
  AppNotifications.swift

# --- App shell (view model) ---
move AppShell/ViewModel \
  AppViewModel.swift \
  AppViewModel+*.swift

move AppShell \
  RefreshCoordinator.swift

# --- Coordinators ---
move Coordinators/App \
  AppLifecycleCoordinator.swift AppLifecycleHost.swift \
  AppSettingsCoordinator.swift AppSettingsHost.swift \
  CatalogAutoRefreshCoordinator.swift CatalogAutoRefreshHost.swift \
  AgentDeckReleaseCoordinator.swift AgentDeckReleaseHost.swift \
  AutomationCoordinator.swift AutomationHost.swift \
  AgentMemoryCoordinator.swift AgentMemoryHost.swift

move Coordinators/Catalog \
  ResourceCatalogCoordinator.swift ResourceCatalogHost.swift \
  ComposerSlashCoordinator.swift ComposerSlashHost.swift \
  ModelCatalogCoordinator.swift ModelCatalogHost.swift

move Coordinators/Agents \
  AgentUniverseCoordinator.swift AgentUniverseHost.swift \
  AgentRepositoryCoordinator.swift AgentRepositoryHost.swift \
  AgentDraftCoordinator.swift AgentDraftHost.swift \
  PromptRepositoryCoordinator.swift PromptRepositoryHost.swift \
  SkillCatalogCoordinator.swift SkillCatalogHost.swift \
  EnvCatalogCoordinator.swift EnvCatalogHost.swift \
  SkillRepositoryCoordinator.swift SkillRepositoryHost.swift

move Coordinators/Pi \
  PiAgentRunnerCoordinator.swift PiAgentRunnerHost.swift \
  PiAgentSessionLifecycleCoordinator.swift PiAgentSessionLifecycleHost.swift \
  PiAgentGitShipCoordinator.swift PiAgentGitShipHost.swift \
  PiNativeSubagentCoordinator.swift PiNativeSubagentHost.swift \
  PiRuntimeSettingsCoordinator.swift PiRuntimeSettingsHost.swift \
  PiTerminalCoordinator.swift PiTerminalHost.swift \
  PiAgentWorkspaceState.swift

move Coordinators/Projects \
  ProjectDiscoveryState.swift ProjectDiscoveryHost.swift \
  ProjectServerCoordinator.swift ProjectServerHost.swift

# --- Models ---
move Models \
  Models.swift EditingModels.swift SidebarModels.swift \
  AppSettings.swift ProjectPreferences.swift ProjectType.swift \
  SkillFrontmatter.swift SkillRepositoryModels.swift \
  AgentMemoryModels.swift \
  GitHubModels.swift GitHubWorkspaceModels.swift \
  PiAgentAttachmentModels.swift PiAgentBridgeRequestModels.swift \
  PiAgentComposerModels.swift PiAgentContextModels.swift \
  PiAgentRPCModels.swift PiAgentSessionCoreModels.swift \
  PiAgentSessionPlanModels.swift PiAgentSessionRecord.swift \
  PiAgentSubagentModels.swift PiAgentSubagentRunModels.swift \
  PiAgentTranscriptModels.swift PiAgentTranscriptThreadModels.swift

# --- Services ---
move Services/Catalog \
  PiScanner.swift AppRefreshService.swift \
  AgentPersistence.swift EnvPersistence.swift SubagentConfigPersistence.swift \
  ExternalSkillDiscovery.swift SkillRepositorySyncService.swift \
  ResourceRenameSupport.swift SlashCommandCatalog.swift SlashUniverse.swift

move Services/Pi \
  PiAgentProcess.swift PiRPCClient.swift PiExecutableResolver.swift \
  PiAuthCredentialStore.swift \
  PiAgentRunnerService.swift PiSubagentRunService.swift \
  PiAgentSessionStore.swift PiAgentSessionWorktreeService.swift \
  PiAgentShipService.swift PiAgentUpdateService.swift \
  PiAgentLaunchArgumentBuilder.swift PiAgentLaunchResolver.swift \
  PiExtensionDiscoveryService.swift PiInjectedCommandExtensions.swift \
  PiIssuePromptBuilder.swift PiModelDiscoveryService.swift \
  PiNativeSubagentBridgeExtensions.swift PiParentAppendPromptResolver.swift \
  PiPromptTemplateLaunchResolver.swift PiProviderCatalogService.swift \
  PiProviderLoginService.swift PiSkillLaunchResolver.swift \
  PiSubagentLaunchPlanner.swift PiSubagentWorktreeService.swift

move Services/Git \
  GitRepositoryService.swift

move Services/GitHub \
  GitHubAPIClient.swift GitHubAuthService.swift GitHubCLIAuthService.swift \
  GitHubIssueService.swift GitHubSearchService.swift GitHubWorkspace.swift

move Services/Projects \
  ProjectDiscovery.swift ProjectServerService.swift

move Services/Release \
  ReleaseService.swift ReleaseNotesGenerationService.swift UpdaterService.swift

move Services/Automation \
  FoundationModelAutomationService.swift \
  AgentAvatarPromptGenerationService.swift \
  SkillDescriptionGenerationService.swift \
  PiSessionTitleGenerationService.swift \
  PiMemoryDreamService.swift

move Services/Memory \
  AgentMemoryStore.swift AgentImageStore.swift

move Services/Utilities \
  AppSettingsController.swift CommandRunner.swift HangWatchdog.swift \
  CollectionFormatting.swift MarkedJSSource.swift SkillDescriptionCache.swift

# --- Features / UI ---
move Features/Shell \
  ContentView.swift SidebarViews.swift CreditsView.swift IssuesScreen.swift \
  AppList.swift EditorSheets.swift ProviderLoginSheets.swift

move Features/Agents \
  AgentManagementViews.swift

move Features/Skills \
  SkillManagementViews.swift SkillImportSheet.swift SkillUpdateConflictSheet.swift

move Features/Prompts \
  PromptsViews.swift

move Features/Environment \
  EnvironmentDoctorViews.swift

move Features/Settings \
  SettingsAndCatalogViews.swift SettingsSceneContent.swift ExtensionsScreen.swift

move Features/Projects \
  ProjectViews.swift ProjectServerPopover.swift ProjectServerToolbarButton.swift

move Features/GitHub \
  GitHubConnectionViews.swift GitHubIssuesViews.swift

move Features/Memory \
  AgentMemoryViews.swift

move Features/Onboarding \
  OnboardingViews.swift

move Features/Release \
  AgentDeckReleaseViews.swift

move Features/PiAgent/Screen \
  PiAgentScreen.swift \
  PiAgentScreen+AppKitTranscriptItems.swift \
  PiAgentScreen+Composer.swift \
  PiAgentScreen+ProcessingState.swift \
  PiAgentScreen+SessionHelpers.swift \
  PiAgentScreen+TranscriptTimeline.swift \
  PiAgentToolbarViews.swift PiAgentStartupViews.swift \
  PiAgentActivityPanelViews.swift PiAgentPlanToolbarButton.swift \
  PiAgentRetryCardView.swift PiAgentSuggestionViews.swift \
  PiAgentAttachmentPopover.swift PiAgentGitAutomationAction.swift

move Features/PiAgent/Composer \
  PiAgentComposerAttachmentViews.swift PiAgentComposerControlsViews.swift \
  PiAgentComposerPanel.swift PiAgentComposerViews.swift

move Features/PiAgent/Transcript \
  PiAgentAppKitTranscriptView.swift \
  PiAgentTranscriptActivityViews.swift PiAgentTranscriptCardViews.swift \
  PiAgentTranscriptDebugViews.swift PiAgentTranscriptDiffViews.swift \
  PiAgentTranscriptLayout.swift PiAgentTranscriptNativeBlocks.swift \
  PiAgentTranscriptNativeCell.swift PiAgentTranscriptNativeChrome.swift \
  PiAgentTranscriptNativeMemory.swift PiAgentTranscriptNativeQuestion.swift \
  PiAgentTranscriptNativeSubagent.swift PiAgentTranscriptNativeSummary.swift \
  PiAgentTranscriptNativeSupervisor.swift PiAgentTranscriptNativeToolGroup.swift \
  PiAgentTranscriptRenderCache.swift PiAgentTranscriptRenderSupport.swift \
  PiAgentTranscriptStatusViews.swift PiAgentTranscriptThreadCard.swift \
  NativeBubblePreviewDebug.swift

move Features/PiAgent/Sessions \
  PiAgentSessionListContent.swift PiAgentSessionListViews.swift

move Features/PiAgent/Subagents \
  PiAgentSubagentSummaryViews.swift PiAgentSubagentViews.swift

# --- Design ---
move Design \
  DesignSystem.swift Theme.swift ThemeManager.swift \
  AppBrand.swift AppFonts.swift AppIcon.swift ProviderLogo.swift \
  MarkdownViews.swift PerfScene.swift

# --- Debug / profiling ---
move Debug \
  RPCDebugLog.swift TranscriptScrollProfiler.swift

# --- Resources (non-Swift) ---
move Resources \
  agent-deck.entitlements

move_dir Resources agent-deck-icon.icon
move_dir Resources agent-deck-icon-alt.icon
move_dir Resources Assets.xcassets
move_dir Resources Fonts

echo "Reorganization complete. Remaining root files:"
find . -maxdepth 1 -type f | sort
