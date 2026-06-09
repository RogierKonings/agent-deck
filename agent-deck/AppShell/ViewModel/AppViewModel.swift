import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
@Observable
final class AppViewModel: NSObject {
    let windowID = UUID()
    var snapshot: ScanSnapshot = .empty {
        didSet { clearAgentUniverseCache() }
    }
    var selectedSidebarItem: SidebarItem = .agent
    var selectedAgentID: EffectiveAgentRecord.ID?
    var selectedSkillID: SkillRecord.ID?
    /// Skills whose deletion file I/O has finished but for which a fresh
    /// snapshot has not yet landed. Filtered out of `allVisibleSkillRecords`
    /// so the row disappears instantly. Pruned in `applyRefreshSnapshot`.
    private(set) var pendingDeletedSkillIDs: Set<String> = []
    /// Prompt templates whose deletion file I/O has finished but for which a
    /// fresh snapshot has not yet landed. Filtered out of
    /// `allVisiblePromptTemplateRecords`. Pruned in `applyRefreshSnapshot`.
    private(set) var pendingDeletedPromptIDs: Set<String> = []
    /// After a rename the fresh snapshot is applied asynchronously, so the
    /// renamed record's new id is not known synchronously. These hold the new
    /// name so `applyRefreshSnapshot` can restore the selection once it lands.
    @ObservationIgnored private var pendingSelectAgentName: String?
    @ObservationIgnored private var pendingSelectSkillName: String?
    /// After a new skill/prompt is saved its record only appears in the
    /// snapshot once the next refresh lands. These hold the filepath so
    /// `applyRefreshSnapshot` can select the freshly-created record once it
    /// becomes visible — replaces the older "synchronous refresh + lookup"
    /// pattern that froze the UI on the filesystem scan.
    @ObservationIgnored private var pendingSelectSkillFilePath: String?
    @ObservationIgnored private var pendingSelectPromptFilePath: String?
    var selectedCommandItemID: String?
    /// Set by `openMemory(byID:)` when the user taps an injected memory title in a
    /// transcript recall card. `MemoryScreen` consumes it to select that record,
    /// then nils it. Observable so the screen's `.onChange` fires.
    var selectedMemoryID: String?
    var selectedAgentFilter: AgentFilter = .all
    let projects: ProjectDiscoveryState
    private(set) var isRefreshingProjects: Bool {
        get { refreshCoordinator.isRefreshingProjects }
        set { refreshCoordinator.isRefreshingProjects = newValue }
    }
    var allProjectSnapshots: [String: ScanSnapshot] = [:] {
        didSet { clearAgentUniverseCache() }
    }
    var appSettings: AppSettings = AppSettings() {
        didSet {
            rebuildAutomationModelCaches()
            rebuildExternalSkillPathCache()
        }
    }
    /// Standardized `externalSkillPaths` as a set. `isImportedSkill` is called
    /// per skill row during layout and otherwise re-allocates + standardizes
    /// every external path for every skill (O(skills × paths) `URL` churn — a
    /// measured Skills-tab hang hotspot). Derived from `appSettings`, so it is
    /// observation-ignored and rebuilt in the `didSet` above.
    @ObservationIgnored private var cachedStandardizedExternalSkillPaths: Set<String> = []
    let resourceCatalog = ResourceCatalogCoordinator()
    var hasCompletedInitialRefresh: Bool { resourceCatalog.hasCompletedInitialRefresh }
    // Automation-model lookup is cached. `FoundationModelAutomationService`
    // queries Apple's Foundation Models availability API, and the Pi Agent
    // toolbar reads `automationAvailableModels` on every `ContentView.body`
    // eval (i.e. once per streaming token). The result only changes at real
    // boundaries — see `rebuildAutomationModelCaches()`.
    private(set) var cachedFoundationAutomationModel: AvailableModel?
    private(set) var cachedAutomationAvailableModels: [AvailableModel] = []
    // Agent-list caches live in `resourceCatalog` — rebuilt by `resourceCatalog.rebuildWarningCaches()`.
    var cachedAllDisplayAgents: [EffectiveAgentRecord] { resourceCatalog.allDisplayAgents }
    var cachedDisplayAgentByID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] { resourceCatalog.displayAgentByID }
    var displayAgentsRevision: Int { resourceCatalog.displayAgentsRevision }
    var cachedAgentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]] { resourceCatalog.agentWarningsByID }
    var cachedSkillMetadataByID: [SkillRecord.ID: SkillListMetadata] { resourceCatalog.skillMetadataByID }
    var cachedWarningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]] { resourceCatalog.warningsBySkillID }
    var cachedHasAgentWarnings: Bool { resourceCatalog.hasAgentWarnings }
    var cachedHasSkillWarnings: Bool { resourceCatalog.hasSkillWarnings }
    var cachedHasPromptWarnings: Bool { resourceCatalog.hasPromptWarnings }
    var cachedSkillWarnings: [DiagnosticWarning] { resourceCatalog.skillWarnings }
    var cachedPromptWarnings: [DiagnosticWarning] { resourceCatalog.promptWarnings }
    var cachedSkillReferenceWarnings: [SkillReferenceWarning] { resourceCatalog.skillReferenceWarnings }
    var cachedSkillVisibilityIssuesByAgentID: [String: [AgentSkillVisibilityIssue]] { resourceCatalog.skillVisibilityIssuesByAgentID }
    var enabledAvailableModels: [AvailableModel] {
        modelCatalog.availableModels.filter { modelCatalog.isModelAvailable($0) }
    }

    var foundationAutomationModel: AvailableModel? { cachedFoundationAutomationModel }

    var automationAvailableModels: [AvailableModel] { cachedAutomationAvailableModels }
    let piAgentSessionStore: PiAgentSessionStore
    let piWorkspace: PiAgentWorkspaceState
    let piGitShip: PiAgentGitShipCoordinator
    let piSessions: PiAgentSessionLifecycleCoordinator
    let piRunner: PiAgentRunnerCoordinator
    let piSubagents: PiNativeSubagentCoordinator
    let settings: AppSettingsCoordinator
    let memory: AgentMemoryCoordinator
    let agentImageStore = AgentImageStore()
    let skillRepositories: SkillRepositoryCoordinator

    private let environment: AppEnvironment
    private var agentPersistence: AgentPersistence { environment.agentPersistence }
    private var projectPreferencesStore: ProjectPreferencesStore { environment.projectPreferencesStore }
    private var appSettingsController: AppSettingsController { settings.controller }
    private var gitRepositoryService: GitRepositoryService { environment.gitRepositoryService }
    @ObservationIgnored private lazy var githubWorkspace = GitHubWorkspace(gitRepositoryService: gitRepositoryService)
    var github: GitHubWorkspace { githubWorkspace }
    private var shipService: PiAgentShipService { environment.shipService }
    let piRuntime: PiRuntimeSettingsCoordinator
    let modelCatalog: ModelCatalogCoordinator
    let piTerminal: PiTerminalCoordinator
    let projectServer: ProjectServerCoordinator
    let agentDeckRelease: AgentDeckReleaseCoordinator
    let catalogAutoRefresh: CatalogAutoRefreshCoordinator
    let appLifecycle: AppLifecycleCoordinator
    let agentUniverse: AgentUniverseCoordinator
    let agentRepository: AgentRepositoryCoordinator
    let promptRepository: PromptRepositoryCoordinator
    let skillCatalog: SkillCatalogCoordinator
    let envCatalog: EnvCatalogCoordinator
    let agentDraft: AgentDraftCoordinator
    let composerSlash: ComposerSlashCoordinator
    let automation: AutomationCoordinator
    private var sessionWorktreeService: PiAgentSessionWorktreeService { environment.sessionWorktreeService }
    /// Cleared in `clearAgentUniverseCache()` whenever a snapshot publishes.
    private var piSessionTitleGenerator: PiSessionTitleGenerationService { environment.piSessionTitleGenerator }
    var globalSnapshot: ScanSnapshot = .empty {
        didSet { clearAgentUniverseCache() }
    }
    var didShutdown = false
    let refreshCoordinator = RefreshCoordinator()

    convenience override init() {
        self.init(environment: .live)
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        skillRepositories = SkillRepositoryCoordinator(syncService: environment.skillRepositorySyncService)
        projects = ProjectDiscoveryState(preferencesStore: environment.projectPreferencesStore)
        let sessionStore = PiAgentSessionStore()
        piAgentSessionStore = sessionStore
        piWorkspace = PiAgentWorkspaceState(sessionStore: sessionStore)
        piGitShip = PiAgentGitShipCoordinator(
            sessionStore: sessionStore,
            workspace: piWorkspace,
            gitRepositoryService: environment.gitRepositoryService,
            shipService: environment.shipService,
            sessionWorktreeService: environment.sessionWorktreeService
        )
        piSessions = PiAgentSessionLifecycleCoordinator(
            sessionStore: sessionStore,
            sessionWorktreeService: environment.sessionWorktreeService
        )
        piRunner = PiAgentRunnerCoordinator(
            sessionStore: sessionStore,
            workspace: piWorkspace,
            titleGenerator: environment.piSessionTitleGenerator
        )
        piSubagents = PiNativeSubagentCoordinator(
            sessionStore: sessionStore,
            worktreeService: environment.subagentWorktreeService
        )
        settings = AppSettingsCoordinator(controller: environment.appSettingsController)
        memory = AgentMemoryCoordinator()
        automation = AutomationCoordinator(
            avatarPromptService: environment.agentAvatarPromptService,
            skillDescriptionService: environment.skillDescriptionService
        )
        piRuntime = PiRuntimeSettingsCoordinator()
        modelCatalog = ModelCatalogCoordinator()
        piTerminal = PiTerminalCoordinator(sessionStore: sessionStore)
        projectServer = ProjectServerCoordinator()
        agentDeckRelease = AgentDeckReleaseCoordinator(
            gitRepositoryService: environment.gitRepositoryService,
            releaseNotesGenerator: environment.releaseNotesGenerator
        )
        catalogAutoRefresh = CatalogAutoRefreshCoordinator()
        appLifecycle = AppLifecycleCoordinator()
        agentUniverse = AgentUniverseCoordinator()
        agentRepository = AgentRepositoryCoordinator()
        promptRepository = PromptRepositoryCoordinator()
        skillCatalog = SkillCatalogCoordinator()
        envCatalog = EnvCatalogCoordinator(persistence: environment.envPersistence)
        agentDraft = AgentDraftCoordinator(persistence: environment.agentPersistence)
        composerSlash = ComposerSlashCoordinator()
        super.init()
        projects.host = self
        githubWorkspace.host = self
        piGitShip.host = self
        piSessions.host = self
        piRunner.attach(host: self)
        piSubagents.attach(host: self)
        settings.attach(host: self)
        memory.attach(host: self)
        skillRepositories.attach(host: self)
        automation.attach(host: self)
        piRuntime.attach(host: self)
        modelCatalog.attach(host: self)
        piTerminal.attach(host: self)
        projectServer.attach(host: self)
        agentDeckRelease.attach(host: self)
        catalogAutoRefresh.attach(host: self)
        appLifecycle.attach(host: self)
        agentUniverse.attach(host: self)
        agentRepository.attach(host: self)
        promptRepository.attach(host: self)
        skillCatalog.attach(host: self)
        envCatalog.attach(host: self)
        agentDraft.attach(host: self)
        composerSlash.attach(host: self)
        resourceCatalog.attach(host: self)

        settings.bootstrapFromController()
        #if DEBUG
        // Xcode Previews: stop here so preview view models stay empty (no models,
        // no projects, no GitHub) and never spawn pi/gh subprocesses — giving a
        // deterministic "nothing installed" state for the onboarding/Doctor previews.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
        #endif
        projects.loadPersistedSelection()
        piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions
        piSessions.configureIdleParking()
        refreshAvailableModels()
        // First-frame refresh: only scan global + the last-selected project
        // (cheap). The full-project scan is deferred to after first paint so a
        // user with many projects doesn't pay the O(P × dir-walk) cost before
        // the first frame renders. The scheduled follow-up below populates the
        // remaining projects ~500ms later.
        let initialExtras: Set<String> = selectedProjectPath.map { [$0] } ?? []
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: initialExtras)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !self.didShutdown else { return }
            self.refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
        }
        appLifecycle.startObserving(windowID: windowID)
        catalogAutoRefresh.start()
        piSubagents.cleanupOrphanedArtifacts()

        Task { [weak self] in
            guard let self else { return }
            await github.refreshGitHubStatus()
            if case .available = github.githubConnectionState {
                await github.connectGitHubUsingCLIIfNeeded()
            }
        }
    }

    func shutDownForTermination() {
        shutdown(recordTranscript: false)
    }

    private func shutdown(recordTranscript: Bool) {
        guard !didShutdown else { return }
        didShutdown = true
        catalogAutoRefresh.stop(cancelPendingScan: true)
        refreshCoordinator.cancelPendingRefresh()
        piSessions.cancelAllPendingNotifications()
        piSessionTitleGenerator.cancelAll()
        memory.cancelDreamMemory()
        piRunner.stopAll(recordTranscript: recordTranscript)
        piSubagents.stopAll(recordTranscript: recordTranscript)
        projectServer.terminateAll()
    }

    /// `silentlyReconcile`: when true, skip toggling `isRefreshingProjects`.
    /// Use this from "patch then refresh" callers — `setSkill`, `deleteSkill`,
    /// `saveAgentDraft`, etc. — where the visible state has already been
    /// updated in-memory and the background scan is just confirming. Without
    /// this, the list dims + disables for the duration of the scan even
    /// though it shows the correct state already, which reads as a long wait
    /// after every toggle. Structural refreshes (project switch, initial
    /// load) leave the default so the spinner + disabled state still appear.
    func refresh(includeModels: Bool = false, scanAllProjects: Bool = false, extraProjectPathsToScan: Set<String> = [], silentlyReconcile: Bool = false) {
        refreshCoordinator.scheduleRefresh(
            inputs: RefreshInputs(
                rootURLs: configuredProjectsRootURLs,
                selectedProjectPath: selectedProjectPath,
                preferencesByPath: projectPreferencesStore.preferencesByPath,
                externalSkillPaths: appSettings.externalSkillPaths,
                externalPromptPaths: appSettings.externalPromptPaths,
                scanAllProjects: scanAllProjects,
                extraProjectPathsToScan: extraProjectPathsToScan
            ),
            includeModels: includeModels,
            silentlyReconcile: silentlyReconcile
        ) { [weak self] result, includeModels in
            self?.applyRefreshSnapshot(result, includeModels: includeModels)
        }
    }

    /// Queue a "select this skill once it shows up" intent and kick off an
    /// async refresh. Used by sheet-save flows that create a new skill —
    /// avoids the prior synchronous refresh that blocked the UI on the
    /// filesystem scan just so the next line could look up the new record's id.
    func scheduleSelectSkill(byFilePath path: String) {
        pendingSelectSkillFilePath = path
        // Already-visible record? Select it inline so the detail pane updates
        // before the rescan lands.
        if let id = allVisibleSkillRecords.first(where: { $0.filePath == path })?.id {
            selectedSkillID = id
        }
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Sibling of `scheduleSelectSkill(byFilePath:)` for prompts.
    func scheduleSelectPrompt(byFilePath path: String) {
        pendingSelectPromptFilePath = path
        if let id = allVisiblePromptTemplateRecords.first(where: { $0.filePath == path })?.id {
            selectedCommandItemID = id
        }
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Navigate to the Memory screen and select a specific record. Driven by the
    /// `.agentDeckOpenMemoryRequested` notification a transcript recall card posts
    /// when an injected memory title is tapped. Switches the project if the record
    /// lives in another one so it lands in the visible set; `MemoryScreen` consumes
    /// `selectedMemoryID`. A since-deleted id simply won't resolve — a graceful no-op.
    func openMemory(byID id: String) {
        let projectPath = memory.store.records.first(where: { $0.id == id })?.projectPath
        navigateToMemory(recordID: id, projectPath: projectPath)
    }

    private func applyRefreshSnapshot(
        _ result: AppRefreshSnapshot,
        includeModels: Bool
    ) {
        projects.applyFromRefresh(
            discoveredProjects: result.discoveredProjects,
            preferencesByPath: result.projectPreferencesByPath
        )

        if !appSettings.didMigrateAgentAssignmentsFromDiscoveredFiles {
            guard result.includesAllProjectSnapshots else {
                refresh(includeModels: includeModels, scanAllProjects: true)
                return
            }
            migrateAgentAssignmentsFromDiscoveredFiles(globalSnapshot: result.globalSnapshot, projectSnapshots: result.projectSnapshots)
        }

        let catalogProjectSnapshots = Array(result.projectSnapshots.values)
        globalSnapshot = scopedAgentSnapshot(result.globalSnapshot, projectPath: nil, globalCatalogSnapshot: result.globalSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
        let freshProjectSnapshots = result.projectSnapshots.mapValues { projectSnapshot in
            scopedAgentSnapshot(projectSnapshot, projectPath: projectSnapshot.projectRoot, globalCatalogSnapshot: result.globalSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
        }
        if result.includesAllProjectSnapshots {
            allProjectSnapshots = freshProjectSnapshots
        } else {
            allProjectSnapshots.merge(freshProjectSnapshots) { _, fresh in fresh }
            let discoveredProjectPaths = Set(result.discoveredProjects.map(\.path))
            allProjectSnapshots = allProjectSnapshots.filter { discoveredProjectPaths.contains($0.key) }
        }
        catalogAutoRefresh.applyRefreshSnapshot(
            watchedURLs: result.watchedURLs,
            watchFingerprint: result.watchFingerprint,
            includesWatchFingerprint: result.includesWatchFingerprint
        )

        if let matchingProject = result.selectedProject {
            projects.applySelectedProjectFromRefresh(url: matchingProject.url, path: matchingProject.path)
            snapshot = allProjectSnapshots[matchingProject.path]
                ?? result.selectedProjectSnapshot.map { scopedAgentSnapshot($0, projectPath: matchingProject.path, globalCatalogSnapshot: result.globalSnapshot, catalogProjectSnapshots: catalogProjectSnapshots) }
                ?? globalSnapshot
        } else {
            projects.clearSelectionFromRefresh()
            snapshot = makeAggregateSnapshot()
        }

        // A fresh snapshot is authoritative. Drop pending deletions no longer
        // present (deletion confirmed); keep IDs still present so a stale
        // in-flight refresh can't un-hide a row mid-deletion.
        if !pendingDeletedSkillIDs.isEmpty {
            let liveSkillIDs = Set((snapshot.skills + snapshot.librarySkills).map(\.id))
            pendingDeletedSkillIDs.formIntersection(liveSkillIDs)
        }
        if !pendingDeletedPromptIDs.isEmpty {
            let livePromptIDs = Set((snapshot.promptTemplates + snapshot.libraryPromptTemplates).map(\.id))
            pendingDeletedPromptIDs.formIntersection(livePromptIDs)
        }

        let currentAgentID = selectedAgentID
        let currentSkillID = selectedSkillID
        let currentCommandItemID = selectedCommandItemID

        selectedAgentID = filteredAgents.contains(where: { $0.id == currentAgentID }) ? currentAgentID : filteredAgents.first?.id
        selectedSkillID = allVisibleSkillRecords.contains(where: { $0.id == currentSkillID }) ? currentSkillID : allVisibleSkillRecords.first?.id
        let availablePromptIDs = Set(allVisiblePromptTemplateRecords.map(\.id))
        if availablePromptIDs.contains(currentCommandItemID ?? "") {
            selectedCommandItemID = currentCommandItemID
        } else {
            selectedCommandItemID = allVisiblePromptTemplateRecords.first?.id
        }

        // After a rename, restore the selection onto the renamed record now
        // that the fresh snapshot exposes its new id.
        if let name = pendingSelectAgentName {
            if let id = filteredAgents.first(where: { $0.name == name })?.id {
                selectedAgentID = id
            }
            pendingSelectAgentName = nil
        }
        if let name = pendingSelectSkillName {
            if let id = allVisibleSkillRecords.first(where: { $0.name == name })?.id {
                selectedSkillID = id
            }
            pendingSelectSkillName = nil
        }
        // After a new skill/prompt save, switch selection onto the newly-
        // visible record. Replaces the prior synchronous-refresh + manual
        // lookup at the call site, which blocked the UI on a full scan.
        if let path = pendingSelectSkillFilePath {
            if let id = allVisibleSkillRecords.first(where: { $0.filePath == path })?.id {
                selectedSkillID = id
            }
            pendingSelectSkillFilePath = nil
        }
        if let path = pendingSelectPromptFilePath {
            if let id = allVisiblePromptTemplateRecords.first(where: { $0.filePath == path })?.id {
                selectedCommandItemID = id
            }
            pendingSelectPromptFilePath = nil
        }

        piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions

        if includeModels {
            refreshAvailableModels()
        }

        resourceCatalog.rebuildWarningCaches(markInitialRefreshComplete: true)
    }

    /// Re-derive snapshot-scoped state from the already-cached raw snapshots
    /// after an assignment-preference change. No disk I/O: project assignment
    /// only mutates UserDefaults, and `scopedAgentSnapshot` is idempotent over
    /// the agent-catalog fields it copies through. This replaces a full
    /// `refresh()` (which re-walks the filesystem) for assignment toggles.
    func reconcileSnapshotsFromPreferences() {
        let catalogProjectSnapshots = Array(allProjectSnapshots.values)
        globalSnapshot = scopedAgentSnapshot(
            globalSnapshot,
            projectPath: nil,
            globalCatalogSnapshot: globalSnapshot,
            catalogProjectSnapshots: catalogProjectSnapshots
        )
        allProjectSnapshots = allProjectSnapshots.mapValues { projectSnapshot in
            scopedAgentSnapshot(
                projectSnapshot,
                projectPath: projectSnapshot.projectRoot,
                globalCatalogSnapshot: globalSnapshot,
                catalogProjectSnapshots: catalogProjectSnapshots
            )
        }
        if let path = selectedProjectPath, let scoped = allProjectSnapshots[path] {
            snapshot = scoped
        } else if selectedProjectPath == nil {
            snapshot = makeAggregateSnapshot()
        }
        resourceCatalog.rebuildWarningCaches()
    }

    /// Patch the in-memory effective-agent skill list so snapshot-derived
    /// toggles (`skill(_:isAssignedTo:)`) update immediately after a draft
    /// save, without waiting for a disk rescan.
    private func patchEffectiveAgentSkills(agentName: String, skills: [String]) {
        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            guard snap.effectiveAgents.contains(where: { $0.name == agentName }) else { return snap }
            let patchedAgents = snap.effectiveAgents.map { record -> EffectiveAgentRecord in
                guard record.name == agentName else { return record }
                var resolved = record.resolved
                resolved.skills = skills
                return EffectiveAgentRecord(
                    id: record.id,
                    name: record.name,
                    projectRoot: record.projectRoot,
                    builtin: record.builtin,
                    globalCustom: record.globalCustom,
                    projectCustom: record.projectCustom,
                    userOverride: record.userOverride,
                    projectOverride: record.projectOverride,
                    resolved: resolved,
                    resolutionKind: record.resolutionKind
                )
            }
            return ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: snap.globalAgents,
                projectAgents: snap.projectAgents,
                legacyProjectAgents: snap.legacyProjectAgents,
                effectiveAgents: patchedAgents,
                libraryAgents: snap.libraryAgents,
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: snap.settings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }
        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)
    }

    /// Mirror a `.custom` agent-draft save into the in-memory snapshots so
    /// `cachedDisplayAgentByID` (read by the detail pane via `selectedAgent`)
    /// and `displayAgentsRevision` (drives the list `cachedLayout` rebuild)
    /// reflect the new config before the post-save rescan lands.
    ///
    /// Skips renames — `EffectiveAgentRecord.id` and `AgentRecord.id` both
    /// encode the name, so a rename needs the existing refresh path that also
    /// Skips builtin-override edits when the caller already patched snapshots in memory.
    private func patchEffectiveAgentConfig(originalName: String, newConfig: AgentConfig, filePath: String?) {
        guard originalName == newConfig.name else { return }

        func matches(_ record: AgentRecord) -> Bool {
            guard record.name == originalName else { return false }
            if let filePath, !filePath.isEmpty { return record.filePath == filePath }
            return true
        }

        func updated(_ record: AgentRecord) -> AgentRecord {
            AgentRecord(
                id: record.id,
                name: newConfig.name,
                description: newConfig.description,
                source: record.source,
                filePath: record.filePath,
                rawFrontmatter: record.rawFrontmatter,
                promptBody: newConfig.systemPrompt,
                parsed: newConfig
            )
        }

        func patchAgents(_ records: [AgentRecord]) -> [AgentRecord] {
            records.map { matches($0) ? updated($0) : $0 }
        }

        func patchEffective(_ records: [EffectiveAgentRecord]) -> [EffectiveAgentRecord] {
            records.map { record -> EffectiveAgentRecord in
                guard record.name == originalName else { return record }
                let newGlobalCustom = record.globalCustom.map { matches($0) ? updated($0) : $0 }
                let newProjectCustom = record.projectCustom.map { matches($0) ? updated($0) : $0 }
                // Custom-agent resolution: project > global > builtin, with no
                // overrides applied (overrides only graft onto a builtin winner).
                // Match `PiAgentLaunchResolver.effectiveCustomAgent`'s winner pick.
                let winner = newProjectCustom ?? newGlobalCustom ?? record.builtin
                let resolved = winner?.parsed ?? record.resolved
                return EffectiveAgentRecord(
                    id: record.id,
                    name: record.name,
                    projectRoot: record.projectRoot,
                    builtin: record.builtin,
                    globalCustom: newGlobalCustom,
                    projectCustom: newProjectCustom,
                    userOverride: record.userOverride,
                    projectOverride: record.projectOverride,
                    resolved: resolved,
                    resolutionKind: record.resolutionKind
                )
            }
        }

        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: patchAgents(snap.globalAgents),
                projectAgents: patchAgents(snap.projectAgents),
                legacyProjectAgents: patchAgents(snap.legacyProjectAgents),
                effectiveAgents: patchEffective(snap.effectiveAgents),
                libraryAgents: patchAgents(snap.libraryAgents),
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: snap.settings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)
    }

    /// In-memory patch of `settings[].agentOverrides[name]["disabled"]` followed
    /// by a re-resolve. Matches the skill-assignment fast path: no disk re-scan,
    /// so toggles render immediately instead of waiting for `refresh()`. The
    /// file watcher will still fire later for the actual JSON write, but the
    /// resulting snapshot is identical so there is no visible flash.
    private func patchBuiltinDisabledOverride(agentName: String, scope: AgentEditingTarget.OverrideScope, isDisabled: Bool, explicitProjectRoot: String? = nil) {
        let targetPath: String
        switch scope {
        case .global:
            targetPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json").path
        case .project:
            guard let projectRoot = explicitProjectRoot ?? selectedProjectPath else { return }
            targetPath = URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/settings.json").path
        }

        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            let updatedSettings: [SettingsSummary] = snap.settings.map { summary in
                guard summary.path == targetPath else { return summary }
                var overrides = summary.agentOverrides
                if let idx = overrides.firstIndex(where: { $0.agentName == agentName }) {
                    var values = overrides[idx].values
                    values["disabled"] = .bool(isDisabled)
                    overrides[idx] = BuiltinOverrideRecord(
                        agentName: agentName,
                        scope: ScopeID(kind: .override, path: targetPath),
                        settingsPath: targetPath,
                        values: values
                    )
                } else {
                    overrides.append(BuiltinOverrideRecord(
                        agentName: agentName,
                        scope: ScopeID(kind: .override, path: targetPath),
                        settingsPath: targetPath,
                        values: ["disabled": .bool(isDisabled)]
                    ))
                    overrides.sort { $0.agentName.localizedCaseInsensitiveCompare($1.agentName) == .orderedAscending }
                }
                return SettingsSummary(
                    path: summary.path,
                    packages: summary.packages,
                    prompts: summary.prompts,
                    disableBuiltins: summary.disableBuiltins,
                    agentOverrides: overrides
                )
            }
            return ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: snap.globalAgents,
                projectAgents: snap.projectAgents,
                legacyProjectAgents: snap.legacyProjectAgents,
                effectiveAgents: snap.effectiveAgents,
                libraryAgents: snap.libraryAgents,
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: updatedSettings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)

        reconcileSnapshotsFromPreferences()
    }

    func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a repo or project root to add to \(AppBrand.displayName)."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(url, selectingAfterAdd: true)
    }

    private func settingsSummary(for scope: AgentEditingTarget.OverrideScope) -> SettingsSummary? {
        switch scope {
        case .global:
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/settings.json").path
            return snapshot.settings.first(where: { $0.path == path })
        case .project:
            guard let selectedProjectPath else { return nil }
            let path = URL(fileURLWithPath: selectedProjectPath)
                .appendingPathComponent(".pi/settings.json").path
            return snapshot.settings.first(where: { $0.path == path })
        }
    }

    /// Cached — see `cachedAllDisplayAgents`. Rebuilt by `resourceCatalog.rebuildWarningCaches()`.
    var allDisplayAgents: [EffectiveAgentRecord] { cachedAllDisplayAgents }

    var selectedAgent: EffectiveAgentRecord? {
        // O(1) lookup over `cachedDisplayAgentByID`. The cache is sourced from
        // `cachedAllDisplayAgents` (a superset of `snapshot.effectiveAgents`,
        // `catalogOnlyEffectiveAgents`, and `libraryOnlyEffectiveAgents`), so
        // we drop the heavy fallback that recomputed the catalog walk on every
        // body read.
        guard let id = selectedAgentID else { return nil }
        return cachedDisplayAgentByID[id]
    }

    private func scopedAgentSnapshot(_ base: ScanSnapshot, projectPath: String?, globalCatalogSnapshot: ScanSnapshot, catalogProjectSnapshots: [ScanSnapshot]) -> ScanSnapshot {
        let projectAgentNames = projectPath.map { projectPreference(for: $0).assignedAgentNames } ?? []
        return ScanSnapshot(
            projectRoot: base.projectRoot,
            builtinAgents: base.builtinAgents,
            globalAgents: base.globalAgents,
            projectAgents: base.projectAgents,
            legacyProjectAgents: base.legacyProjectAgents,
            effectiveAgents: PiAgentLaunchResolver.effectiveAgents(
                defaultAgentNames: appSettings.defaultAgentNames,
                projectAgentNames: projectAgentNames,
                snapshot: base,
                catalog: agentUniverse.agentCatalog(globalSnapshot: globalCatalogSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
            ),
            libraryAgents: base.libraryAgents,
            skills: base.skills,
            librarySkills: base.librarySkills,
            promptTemplates: base.promptTemplates,
            libraryPromptTemplates: base.libraryPromptTemplates,
            settings: base.settings,
            envKeys: base.envKeys,
            warnings: base.warnings
        )
    }

    private func migrateAgentAssignmentsFromDiscoveredFiles(globalSnapshot: ScanSnapshot, projectSnapshots: [String: ScanSnapshot]) {
        for name in Set(globalSnapshot.globalAgents.map(\.name)) {
            _ = appSettingsController.setDefaultAgent(name, enabled: true)
        }
        for (projectPath, projectSnapshot) in projectSnapshots {
            for name in Set((projectSnapshot.projectAgents + projectSnapshot.legacyProjectAgents).map(\.name)) {
                projectPreferencesStore.setAssignedAgent(name, assigned: true, for: projectPath)
            }
        }
        _ = appSettingsController.markAgentAssignmentsMigratedFromDiscoveredFiles()
        settings.publish()
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
    }

    var selectedSkill: SkillRecord? {
        allVisibleSkillRecords.first(where: { $0.id == selectedSkillID })
    }

    var allVisibleSkillRecords: [SkillRecord] {
        let records = deduplicateByID(snapshot.skills + snapshot.librarySkills)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.source.kind.rawValue < rhs.source.kind.rawValue
            }
        guard !pendingDeletedSkillIDs.isEmpty else { return records }
        return records.filter { !pendingDeletedSkillIDs.contains($0.id) }
    }

    /// Standardized `SKILL.md` paths of every skill currently in the catalog
    /// (builtin, global, project, package, and imported). The import sheet uses
    /// this to hide skills the user already has. Pure string work, no I/O — but
    /// O(catalog) to build, so callers should read it once and cache it rather
    /// than re-reading it per render.
    var catalogedSkillFilePaths: Set<String> {
        Set(allVisibleSkillRecords.map { URL(fileURLWithPath: $0.filePath).standardizedFileURL.path })
    }

    func startupSnapshot(forProjectPath path: String) -> ScanSnapshot {
        guard let projectSnapshot = allProjectSnapshots[path] else { return snapshot }
        return scopedStartupSnapshot(projectSnapshot: projectSnapshot)
    }

    private func scopedStartupSnapshot(projectSnapshot: ScanSnapshot) -> ScanSnapshot {
        projectSnapshot
    }

    var selectedPromptTemplate: PromptTemplateRecord? {
        allVisiblePromptTemplateRecords.first(where: { $0.id == selectedCommandItemID })
    }

    var allVisiblePromptTemplateRecords: [PromptTemplateRecord] {
        let records = deduplicateByID(snapshot.promptTemplates + snapshot.libraryPromptTemplates)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.source.kind.rawValue < rhs.source.kind.rawValue
            }
        guard !pendingDeletedPromptIDs.isEmpty else { return records }
        return records.filter { !pendingDeletedPromptIDs.contains($0.id) }
    }

    var packageNames: [String] {
        Array(Set(snapshot.settings.flatMap(\.packages))).sorted()
    }

    func availableExtensionNames(for target: AgentEditingTarget) -> [String] {
        let snapshot = scopeSnapshot(for: target)
        return Array(Set(snapshot.settings.flatMap(\.packages)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableSkillNames(for target: AgentEditingTarget) -> [String] {
        let snapshot = scopeSnapshot(for: target)
        return Array(Set((snapshot.skills + snapshot.librarySkills).map(\.name)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableToolNames(for target: AgentEditingTarget) -> [String] {
        let scopeSnapshot = scopeSnapshot(for: target)
        var tools = [
            "read", "grep", "find", "ls", "bash",
            "edit", "write", "ask_user"
        ]
        let exaConfigured = isExaConfigured(for: target)
        if exaConfigured {
            tools.append(contentsOf: PiNativeSubagentBridgeExtensions.exaToolNames)
        } else if WebFetchDependencyService().status().isInstalled {
            tools.append(PiNativeSubagentBridgeExtensions.fallbackWebFetchToolName)
        }

        let explicitTools = scopeSnapshot.effectiveAgents.flatMap { $0.resolved.tools ?? [] }
            .filter { tool in
                let normalized = tool.lowercased()
                if PiNativeSubagentBridgeExtensions.exaToolNames.contains(normalized) { return exaConfigured }
                if normalized == PiNativeSubagentBridgeExtensions.fallbackWebFetchToolName {
                    return !exaConfigured && WebFetchDependencyService().status().isInstalled
                }
                return true
            }
        return Array(Set(tools + explicitTools))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func isExaConfigured(for target: AgentEditingTarget) -> Bool {
        let projectRoot = scopeSnapshot(for: target).projectRoot.map { URL(fileURLWithPath: $0) }
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectRoot)
        return PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment)
    }

    func availableModelIdentifiers() -> [String] {
        enabledAvailableModels.map(\.identifier)
    }

    var selectedProjectName: String {
        projectRootURL?.lastPathComponent ?? "No Project Selected"
    }

    var shouldWarnDoctor: Bool {
        !hasConfirmedProjectsRootPaths || !configuredProjectsRootsExist || !snapshot.warnings.isEmpty
    }

    /// True only when every configured projects-root entry resolves to an
    /// existing directory. Empty list ⇒ warn.
    private var configuredProjectsRootsExist: Bool {
        let urls = configuredProjectsRootURLs
        guard !urls.isEmpty else { return false }
        return urls.allSatisfy { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    var hasAgentWarnings: Bool {
        cachedHasAgentWarnings
    }

    var hasSkillWarnings: Bool {
        cachedHasSkillWarnings
    }

    var hasPromptWarnings: Bool {
        cachedHasPromptWarnings
    }

    var skillWarnings: [DiagnosticWarning] {
        cachedSkillWarnings
    }

    var promptWarnings: [DiagnosticWarning] {
        cachedPromptWarnings
    }

    var skillReferenceWarnings: [SkillReferenceWarning] {
        guard !pendingDeletedSkillIDs.isEmpty else { return cachedSkillReferenceWarnings }
        // The cached warnings are rebuilt only on refresh, so for the ~1s until
        // the background scan lands they can still cite a skill the user just
        // deleted. Drop those so the warnings card matches the visible list.
        let names = Set((snapshot.skills + snapshot.librarySkills)
            .filter { pendingDeletedSkillIDs.contains($0.id) }
            .map(\.name))
        return cachedSkillReferenceWarnings.filter { !names.contains($0.missingSkill) }
    }

    func piAgentSessionProjectContext() -> DiscoveredProject {
        if let selectedDiscoveredProject {
            return selectedDiscoveredProject
        }

        let rootURL = primaryProjectsRootURL
        let rootName = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
        return DiscoveredProject(
            url: rootURL,
            gitHubRemote: nil,
            isGitRepository: false,
            iconFileURL: nil,
            projectType: .unknown,
            fallbackSymbolName: ProjectType.unknown.sfSymbolFallback,
            searchIndex: [rootName, rootURL.path].joined(separator: "\n").lowercased()
        )
    }

    var availableModelProviders: [String] {
        Array(Set(enabledAvailableModels.map(\.provider)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var totalProjectWarnings: Int {
        let enabledProjectPaths = Set(enabledProjects.map(\.path))
        return allProjectSnapshots
            .filter { enabledProjectPaths.contains($0.key) }
            .values
            .reduce(0) { $0 + $1.warnings.count }
    }

    func canRenameAgent(_ agent: EffectiveAgentRecord) -> Bool {
        renameableAgentRecord(for: agent) != nil
    }

    func renamePreview(for agent: EffectiveAgentRecord, to requestedName: String) -> ResourceRenamePreview {
        renamePreview(oldName: agent.name, requestedName: requestedName) { newName in
            guard let record = renameableAgentRecord(for: agent) else {
                throw ResourceRenameError.unsupportedResource("Bundled agents cannot be renamed. Create a custom replacement or duplicate instead.")
            }
            try validateAgentRename(record, to: newName)
            var changes = ["Update agent frontmatter `name` from `\(agent.name)` to `\(newName)`.", "Rename the agent markdown file to `\(newName).md`."]
            if appSettings.defaultAgentNames.contains(agent.name) { changes.append("Update Default agent assignment.") }
            if projectPreferencesByPath.values.contains(where: { $0.assignedAgentNames.contains(agent.name) }) { changes.append("Update project agent assignments.") }
            var warnings: [String] = []
            if snapshot.builtinAgents.contains(where: { $0.name == agent.name }) {
                warnings.append("This custom agent currently replaces a builtin. After renaming it, it will become a separate custom agent.")
            }
            return (changes, warnings)
        }
    }

    func renameAgent(_ agent: EffectiveAgentRecord, to requestedName: String) throws {
        refreshAllProjectSnapshotsForRename()
        let newName = try ResourceRenameSupport.normalizedName(requestedName)
        guard newName != agent.name else { return }
        guard let record = renameableAgentRecord(for: agent) else {
            throw ResourceRenameError.unsupportedResource("Bundled agents cannot be renamed. Create a custom replacement or duplicate instead.")
        }
        try validateAgentRename(record, to: newName)

        let oldName = record.name
        let sourceURL = URL(fileURLWithPath: record.filePath).standardizedFileURL
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(destinationURL, sourceURL: sourceURL)

        var config = record.parsed
        config.name = newName
        let serialized = agentPersistence.serializedText(for: config)
        try moveItemIfNeeded(from: sourceURL, to: destinationURL)
        try serialized.write(to: destinationURL, atomically: true, encoding: .utf8)

        _ = appSettingsController.renameDefaultAgent(from: oldName, to: newName)
        projectPreferencesStore.renameAssignedAgent(from: oldName, to: newName)
        applyProjectPreferenceChanges()
        settings.publish()

        // Drop the redundant synchronous rescan; the async refresh reconciles.
        // `pendingSelectAgentName` keeps the selection on the renamed agent
        // once that fresh snapshot lands.
        pendingSelectAgentName = newName
        refresh(includeModels: false, scanAllProjects: true)
    }

    func canRenameSkill(_ skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func renamePreview(for skill: SkillRecord, to requestedName: String) -> ResourceRenamePreview {
        renamePreview(oldName: skill.name, requestedName: requestedName) { newName in
            guard canRenameSkill(skill) else {
                throw ResourceRenameError.unsupportedResource("Bundled and package skills are read-only and cannot be renamed.")
            }
            try validateSkillRename(skill, to: newName)
            var changes = ["Update `SKILL.md` frontmatter `name` from `\(skill.name)` to `\(newName)`." ]
            if skill.filePath.hasSuffix("/SKILL.md") {
                changes.append("Rename the skill folder to `\(newName)`.")
            } else {
                changes.append("Rename the skill file to `\(newName).md`.")
            }
            if appSettings.defaultSkillNames.contains(skill.name) { changes.append("Update Default skill assignment.") }
            if projectPreferencesByPath.values.contains(where: { $0.assignedSkillNames.contains(skill.name) }) { changes.append("Update project skill assignments.") }
            if allAgentRecordsForReferenceUpdates().contains(where: { $0.parsed.skills.contains(skill.name) }) { changes.append("Update agent skill references.") }
            return (changes, [])
        }
    }

    func renameSkill(_ skill: SkillRecord, to requestedName: String) throws {
        refreshAllProjectSnapshotsForRename()
        let newName = try ResourceRenameSupport.normalizedName(requestedName)
        guard newName != skill.name else { return }
        guard canRenameSkill(skill) else {
            throw ResourceRenameError.unsupportedResource("Bundled and package skills are read-only and cannot be renamed.")
        }
        try validateSkillRename(skill, to: newName)

        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let isSkillFolder = fileURL.lastPathComponent == "SKILL.md"
        let oldTargetURL = isSkillFolder ? fileURL.deletingLastPathComponent() : fileURL
        let newTargetURL = isSkillFolder
            ? oldTargetURL.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
            : oldTargetURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(newTargetURL, sourceURL: oldTargetURL)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let updatedText = ResourceRenameSupport.replacingFrontmatterValue(in: text, key: "name", value: newName)
        try updatedText.write(to: fileURL, atomically: true, encoding: .utf8)
        try moveItemIfNeeded(from: oldTargetURL, to: newTargetURL)

        _ = appSettingsController.renameDefaultSkill(from: skill.name, to: newName)
        projectPreferencesStore.renameAssignedSkill(from: skill.name, to: newName)
        applyProjectPreferenceChanges()
        try replaceSkillReferencesInCustomAgents(from: skill.name, to: newName)
        try replaceSkillReferencesInBuiltinOverrides(from: skill.name, to: newName)
        _ = appSettingsController.replaceExternalSkillPath(from: oldTargetURL.path, to: newTargetURL.path)
        _ = appSettingsController.replaceExternalSkillPath(from: fileURL.path, to: (isSkillFolder ? newTargetURL.appendingPathComponent("SKILL.md") : newTargetURL).path)
        settings.publish()

        // Drop the redundant synchronous rescan; the async refresh reconciles.
        // `pendingSelectSkillName` keeps the selection on the renamed skill
        // once that fresh snapshot lands.
        pendingSelectSkillName = newName
        refresh(includeModels: false, scanAllProjects: true)
    }

    func canRenamePrompt(_ prompt: PromptTemplateRecord) -> Bool {
        prompt.source.kind != .package
    }

    func renamePreview(for prompt: PromptTemplateRecord, to requestedName: String) -> ResourceRenamePreview {
        renamePreview(oldName: prompt.name, requestedName: requestedName) { newName in
            guard canRenamePrompt(prompt) else {
                throw ResourceRenameError.unsupportedResource("Package prompts are read-only and cannot be renamed.")
            }
            try validatePromptRename(prompt, to: newName)
            var changes = ["Rename prompt file to `\(newName).md`."]
            if appSettings.defaultPromptTemplateNames.contains(prompt.name) { changes.append("Update Default prompt assignment.") }
            if projectPreferencesByPath.values.contains(where: { $0.assignedPromptTemplateNames.contains(prompt.name) }) { changes.append("Update project prompt assignments.") }
            if settingsContainPromptFile(prompt.filePath) { changes.append("Update direct prompt paths in settings.json.") }
            return (changes, [])
        }
    }

    func renamePrompt(_ prompt: PromptTemplateRecord, to requestedName: String) throws {
        refreshAllProjectSnapshotsForRename()
        let newName = try ResourceRenameSupport.normalizedName(requestedName)
        guard newName != prompt.name else { return }
        guard canRenamePrompt(prompt) else {
            throw ResourceRenameError.unsupportedResource("Package prompts are read-only and cannot be renamed.")
        }
        try validatePromptRename(prompt, to: newName)

        let fileURL = URL(fileURLWithPath: prompt.filePath).standardizedFileURL
        let destinationURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(destinationURL, sourceURL: fileURL)
        try moveItemIfNeeded(from: fileURL, to: destinationURL)

        _ = appSettingsController.renameDefaultPromptTemplate(from: prompt.name, to: newName)
        projectPreferencesStore.renameAssignedPromptTemplate(from: prompt.name, to: newName)
        applyProjectPreferenceChanges()
        try replacePromptSettingsPaths(oldURLs: [fileURL], newURL: destinationURL)
        settings.publish()

        refresh(includeModels: false, scanAllProjects: true)
        selectedCommandItemID = allVisiblePromptTemplateRecords.first { $0.name == newName }?.id ?? selectedCommandItemID
    }

    private func renamePreview(oldName: String, requestedName: String, build: (String) throws -> (changes: [String], warnings: [String])) -> ResourceRenamePreview {
        do {
            let newName = try ResourceRenameSupport.normalizedName(requestedName)
            guard newName != oldName else {
                return ResourceRenameSupport.preview(oldName: oldName, requestedName: requestedName, changes: [])
            }
            let result = try build(newName)
            return ResourceRenameSupport.preview(oldName: oldName, requestedName: requestedName, changes: result.changes, warnings: result.warnings)
        } catch {
            return ResourceRenameSupport.preview(oldName: oldName, requestedName: requestedName, changes: [], blockers: [error.localizedDescription])
        }
    }

    private func renameableAgentRecord(for agent: EffectiveAgentRecord) -> AgentRecord? {
        let record = agent.projectCustom ?? agent.globalCustom ?? snapshot.libraryAgents.first { $0.name == agent.name }
        guard let record, record.source.kind != .builtin, record.source.kind != .package else { return nil }
        return record
    }

    private func refreshAllProjectSnapshotsForRename() {
        refreshCoordinator.scheduleRefresh(
            inputs: RefreshInputs(
                rootURLs: configuredProjectsRootURLs,
                selectedProjectPath: selectedProjectPath,
                preferencesByPath: projectPreferencesStore.preferencesByPath,
                externalSkillPaths: appSettings.externalSkillPaths,
                externalPromptPaths: appSettings.externalPromptPaths,
                scanAllProjects: true,
                extraProjectPathsToScan: []
            ),
            includeModels: false,
            silentlyReconcile: true
        ) { [weak self] result, _ in
            self?.applyRefreshSnapshot(result, includeModels: false)
        }
    }

    private func validateAgentRename(_ record: AgentRecord, to newName: String) throws {
        guard !agentNameExists(newName, excludingPaths: [standardizedPath(record.filePath)]) else {
            throw ResourceRenameError.duplicateName(newName)
        }
        let sourceURL = URL(fileURLWithPath: record.filePath).standardizedFileURL
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(destinationURL, sourceURL: sourceURL)
    }

    private func validateSkillRename(_ skill: SkillRecord, to newName: String) throws {
        guard !allSkillRecordsForRenameValidation().contains(where: { $0.name == newName && standardizedPath($0.filePath) != standardizedPath(skill.filePath) }) else {
            throw ResourceRenameError.duplicateName(newName)
        }
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ResourceRenameError.unsupportedResource("Symlinked skills cannot be renamed safely in app. Rename the real skill file or folder instead.")
        }
        let oldTargetURL = fileURL.lastPathComponent == "SKILL.md" ? fileURL.deletingLastPathComponent() : fileURL
        if (try? oldTargetURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ResourceRenameError.unsupportedResource("Symlinked skill folders cannot be renamed safely in app. Rename the real skill folder instead.")
        }
        let newTargetURL = fileURL.lastPathComponent == "SKILL.md"
            ? oldTargetURL.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
            : oldTargetURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(newTargetURL, sourceURL: oldTargetURL)
    }

    private func validatePromptRename(_ prompt: PromptTemplateRecord, to newName: String) throws {
        guard !allPromptRecordsForRenameValidation().contains(where: { $0.name == newName && standardizedPath($0.filePath) != standardizedPath(prompt.filePath) }) else {
            throw ResourceRenameError.duplicateName(newName)
        }
        let fileURL = URL(fileURLWithPath: prompt.filePath).standardizedFileURL
        if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ResourceRenameError.unsupportedResource("Symlinked prompts cannot be renamed safely in app. Rename the real prompt file instead.")
        }
        let destinationURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(destinationURL, sourceURL: fileURL)
    }

    private func ensureRenameDestinationAvailable(_ destinationURL: URL, sourceURL: URL) throws {
        let destinationPath = destinationURL.standardizedFileURL.path
        let sourcePath = sourceURL.standardizedFileURL.path
        guard destinationPath.hasPrefix(sourceURL.deletingLastPathComponent().standardizedFileURL.path + "/") else {
            throw ResourceRenameError.unsafePath(destinationPath)
        }
        if pathExistsOrIsSymlink(destinationURL), destinationPath != sourcePath {
            throw ResourceRenameError.destinationExists(destinationPath)
        }
    }

    private func pathExistsOrIsSymlink(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func moveItemIfNeeded(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source.path != destination.path else { return }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func agentNameExists(_ name: String, excludingPaths: Set<String>) -> Bool {
        allAgentRecordsForReferenceUpdates().contains { record in
            record.name == name && !excludingPaths.contains(standardizedPath(record.filePath))
        }
    }

    private func allAgentRecordsForReferenceUpdates() -> [AgentRecord] {
        var seen = Set<String>()
        let snapshots = [snapshot, globalSnapshot] + Array(allProjectSnapshots.values)
        var records: [AgentRecord] = []
        for snapshot in snapshots {
            records.append(contentsOf: snapshot.libraryAgents)
            records.append(contentsOf: snapshot.globalAgents)
            records.append(contentsOf: snapshot.projectAgents)
            records.append(contentsOf: snapshot.legacyProjectAgents)
            records.append(contentsOf: snapshot.effectiveAgents.compactMap(\.winningRecord))
        }
        return records.filter { record in
            seen.insert(standardizedPath(record.filePath)).inserted
        }
    }

    private func allSkillRecordsForRenameValidation() -> [SkillRecord] {
        var seen = Set<String>()
        return ([snapshot, globalSnapshot] + Array(allProjectSnapshots.values))
            .flatMap { $0.skills + $0.librarySkills }
            .filter { seen.insert(standardizedPath($0.filePath)).inserted }
    }

    private func allPromptRecordsForRenameValidation() -> [PromptTemplateRecord] {
        var seen = Set<String>()
        return ([snapshot, globalSnapshot] + Array(allProjectSnapshots.values))
            .flatMap { $0.promptTemplates + $0.libraryPromptTemplates }
            .filter { seen.insert(standardizedPath($0.filePath)).inserted }
    }

    private func replaceSkillReferencesInCustomAgents(from oldName: String, to newName: String) throws {
        var seenWriteTargets = Set<String>()
        for record in allAgentRecordsForReferenceUpdates() where record.parsed.skills.contains(oldName) && record.source.kind != .builtin && record.source.kind != .package {
            let writeURL = customAgentWriteURL(for: record)
            guard seenWriteTargets.insert(writeURL.path).inserted else { continue }
            var config = record.parsed
            config.skills = config.skills.map { $0 == oldName ? newName : $0 }
            let text = agentPersistence.serializedText(for: config)
            try text.write(to: writeURL, atomically: true, encoding: .utf8)
        }
    }

    private func customAgentWriteURL(for record: AgentRecord) -> URL {
        URL(fileURLWithPath: record.filePath).standardizedFileURL
    }

    private func replaceSkillReferencesInBuiltinOverrides(from oldName: String, to newName: String) throws {
        for settingsPath in allSettingsPaths() {
            var root = try loadJSONDictionary(at: settingsPath)
            guard var subagents = root["subagents"] as? [String: Any], var overrides = subagents["agentOverrides"] as? [String: Any] else { continue }
            var changed = false
            for key in overrides.keys {
                guard var override = overrides[key] as? [String: Any] else { continue }
                if let skills = override["skills"] as? [Any] {
                    let updated = skills.map { value -> Any in
                        guard let skill = value as? String, skill == oldName else { return value }
                        changed = true
                        return newName
                    }
                    override["skills"] = updated
                    overrides[key] = override
                } else if let skill = override["skills"] as? String, skill == oldName {
                    override["skills"] = newName
                    overrides[key] = override
                    changed = true
                }
            }
            guard changed else { continue }
            subagents["agentOverrides"] = overrides
            root["subagents"] = subagents
            try writeJSONDictionary(root, to: settingsPath)
        }
    }

    private func settingsContainPromptFile(_ filePath: String) -> Bool {
        let target = standardizedPath(filePath)
        return allSettingsPaths().contains { settingsPath in
            guard let root = try? loadJSONDictionary(at: settingsPath), let prompts = root["prompts"] else { return false }
            let baseURL = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
            return promptEntries(from: prompts).contains { standardizedPath(resolveSettingsPath($0, baseURL: baseURL).path) == target }
        }
    }

    func replacePromptSettingsPaths(oldURLs: [URL], newURL: URL?) throws {
        let oldPaths = Set(oldURLs.map { $0.standardizedFileURL.path })
        for settingsPath in allSettingsPaths() {
            var root = try loadJSONDictionary(at: settingsPath)
            guard let prompts = root["prompts"] else { continue }
            let baseURL = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
            var changed = false
            func replacement(for entry: String) -> String? {
                let resolved = resolveSettingsPath(entry, baseURL: baseURL).standardizedFileURL.path
                guard oldPaths.contains(resolved) else { return entry }
                changed = true
                guard let newURL else { return nil }
                return rewrittenSettingsPath(for: newURL, originalEntry: entry, baseURL: baseURL)
            }
            if let value = prompts as? String {
                if let updatedValue = replacement(for: value) {
                    root["prompts"] = updatedValue
                } else {
                    root.removeValue(forKey: "prompts")
                }
            } else if let values = prompts as? [Any] {
                let updatedValues = values.compactMap { value -> Any? in
                    guard let entry = value as? String else { return value }
                    return replacement(for: entry)
                }
                if updatedValues.isEmpty {
                    root.removeValue(forKey: "prompts")
                } else {
                    root["prompts"] = updatedValues
                }
            }
            guard changed else { continue }
            try writeJSONDictionary(root, to: settingsPath)
        }
    }

    private func promptEntries(from rawValue: Any) -> [String] {
        if let value = rawValue as? String { return [value] }
        if let values = rawValue as? [Any] { return values.compactMap { $0 as? String } }
        return []
    }

    private func resolveSettingsPath(_ entry: String, baseURL: URL) -> URL {
        let expanded = NSString(string: entry).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return baseURL.appendingPathComponent(expanded)
    }

    private func rewrittenSettingsPath(for newURL: URL, originalEntry: String, baseURL: URL) -> String {
        let expanded = NSString(string: originalEntry).expandingTildeInPath
        if expanded.hasPrefix("/") || originalEntry.hasPrefix("~") { return newURL.standardizedFileURL.path }
        let basePath = baseURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        if newPath.hasPrefix(basePath + "/") {
            return String(newPath.dropFirst(basePath.count + 1))
        }
        return newPath
    }

    private func allSettingsPaths() -> [String] {
        var seen = Set<String>()
        return ([snapshot, globalSnapshot] + Array(allProjectSnapshots.values))
            .flatMap(\.settings)
            .map(\.path)
            .filter { seen.insert(standardizedPath($0)).inserted }
    }

    private func loadJSONDictionary(at path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func writeJSONDictionary(_ dictionary: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { text.append("\n") }
        try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    /// Computes the path and seed content for a brand-new library prompt
    /// template without touching the disk. The `.md` file is written only when
    /// the user saves the editor sheet, so cancelling creates nothing.
    func newLibraryPromptTemplateDraft() -> (path: String, seedContent: String) {
        let fileManager = FileManager.default
        let libraryRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/prompt-library", isDirectory: true)
        var candidate = "new-prompt"
        var index = 2
        while fileManager.fileExists(atPath: libraryRoot.appendingPathComponent("\(candidate).md").path) {
            candidate = "new-prompt-\(index)"
            index += 1
        }
        let url = libraryRoot.appendingPathComponent("\(candidate).md")
        let text = """
        ---
        description: Describe this reusable prompt template.
        argument-hint: "<task>"
        ---

        Write the reusable prompt template here. Use $ARGUMENTS where all slash-command arguments should be inserted.
        """
        return (url.path, text)
    }

    /// Registers an external prompt template file as a referenced library prompt
    /// and returns the source URL. The file stays where the user keeps it — Agent
    /// Deck scans and edits it in place, mirroring how external skills are imported.
    @discardableResult
    func importPromptTemplate(from sourceURL: URL) throws -> URL {
        let standardizedURL = sourceURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if appSettingsController.addExternalPromptPaths([standardizedURL.path]) {
            settings.publish()
        }
        refresh(includeModels: false)
        let importedName = standardizedURL.deletingPathExtension().lastPathComponent
        selectedCommandItemID = allVisiblePromptTemplateRecords.first { $0.name == importedName }?.id ?? selectedCommandItemID
        return standardizedURL
    }

    /// Presents a file picker for choosing a single markdown prompt file to import.
    func choosePromptFileToImport(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Prompt"
        panel.message = "Choose a markdown file to reference in the \(AppBrand.displayName) prompt library. The file stays where it is and is edited in place."
        let markdownTypes = ["md", "markdown", "mdown", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = markdownTypes.isEmpty ? [.plainText] : markdownTypes + [.plainText]

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            DispatchQueue.main.async {
                guard response == .OK, let url = panel.url?.standardizedFileURL else {
                    completion(nil)
                    return
                }
                completion(url)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func makeNewLibrarySkillDraft() -> NewSkillDraft {
        .init(
            name: nextAvailableSkillName(),
            description: "",
            body: "Document the skill instructions here."
        )
    }

    func newLibrarySkillPath(for name: String) -> String {
        let skillsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        return skillsRoot
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md")
            .path
    }

    func saveNewLibrarySkill(_ draft: NewSkillDraft) throws {
        let name = try validateNewSkillName(draft.name)
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw ResourceRenameError.invalidName("Description cannot be empty.")
        }

        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Document the skill instructions here."
            : draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        \(body)
        """

        let fileURL = URL(fileURLWithPath: newLibrarySkillPath(for: name))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Computes the path and seed content for a brand-new library skill
    /// (`~/.pi/agent/skills/<name>/SKILL.md`) without touching the disk. The
    /// folder and `SKILL.md` are written only when the user saves the editor
    /// sheet, so cancelling creates nothing — matching the agent editor, where
    /// nothing is stored until Save.
    func newLibrarySkillDraft() -> (path: String, seedContent: String) {
        let fileManager = FileManager.default
        let skillsRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        let candidate = nextAvailableSkillName()
        let url = skillsRoot
            .appendingPathComponent(candidate, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        let text = """
        ---
        name: \(candidate)
        description: Describe what this skill does and when Pi should use it.
        ---

        # \(candidate)

        Document the skill instructions here.
        """
        return (url.path, text)
    }

    private func nextAvailableSkillName() -> String {
        let fileManager = FileManager.default
        let skillsRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        var candidate = "new-skill"
        var index = 2
        while fileManager.fileExists(atPath: skillsRoot.appendingPathComponent(candidate, isDirectory: true).path) {
            candidate = "new-skill-\(index)"
            index += 1
        }
        return candidate
    }

    private func validateNewSkillName(_ requestedName: String) throws -> String {
        let name = try ResourceRenameSupport.normalizedName(requestedName)
        let pattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
        guard name.wholeMatch(of: pattern) != nil else {
            throw ResourceRenameError.invalidName("Skill name must use lowercase letters, numbers, and single hyphens only.")
        }

        let fileURL = URL(fileURLWithPath: newLibrarySkillPath(for: name))
        guard !FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path) else {
            throw ResourceRenameError.destinationExists(fileURL.deletingLastPathComponent().path)
        }
        return name
    }

    func explicitSkillVisibilityIssues(for agent: EffectiveAgentRecord) -> [AgentSkillVisibilityIssue] {
        cachedSkillVisibilityIssuesByAgentID[agent.id] ?? []
    }

    private func skillNamed(_ skillName: String, isRuntimeVisibleIn project: DiscoveredProject) -> Bool {
        let projectSnapshot = allProjectSnapshots[project.path] ?? PiScanner(externalSkillPaths: appSettings.externalSkillPaths, externalPromptPaths: appSettings.externalPromptPaths).scan(projectRoot: project.url)
        let matches = PiSkillLaunchResolver.catalog(from: projectSnapshot).filter { $0.name == skillName }
        return matches.count == 1
    }

    func unavailableSkillResolutionCandidate(for warning: SkillReferenceWarning) -> SkillRecord? {
        let records = deduplicateByID(
            allVisibleSkillRecords + allProjectSnapshots.values.flatMap { $0.skills + $0.librarySkills }
        )
        return records
            .filter { $0.name == warning.missingSkill }
            .filter { !skillNamed($0.name, isRuntimeVisibleIn: warning.project) }
            .sorted { lhs, rhs in
                let lhsIsProject = lhs.source.kind == .project || lhs.source.kind == .legacyProject
                let rhsIsProject = rhs.source.kind == .project || rhs.source.kind == .legacyProject
                if lhsIsProject != rhsIsProject { return lhsIsProject && !rhsIsProject }
                return lhs.filePath < rhs.filePath
            }
            .first
    }

    /// Recomputes the cached automation-model lookup. Called only at real
    /// boundaries — app launch / activation, a model-list reload, a settings
    /// change — never per `ContentView.body` eval. Mirrors `resourceCatalog.rebuildWarningCaches`.
    /// Triggered when the model catalog reloads and when `appSettings` changes,
    /// which also covers app launch (init assigns `appSettings`).
    func rebuildAutomationModelCaches() {
        let foundation = FoundationModelAutomationService.availableModel()
        var models = enabledAvailableModels
        if let foundation,
           !models.contains(where: { $0.identifier == foundation.identifier }) {
            models.insert(foundation, at: 0)
        }
        cachedFoundationAutomationModel = foundation
        cachedAutomationAvailableModels = models
    }

    private func rebuildExternalSkillPathCache() {
        cachedStandardizedExternalSkillPaths = Set(
            appSettings.externalSkillPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        )
    }

    func skillRecap(for project: DiscoveredProject) -> ProjectSkillRecap {
        let defaultNames = appSettings.defaultSkillNames
        let projectNames = projectPreference(for: project.path).assignedSkillNames.subtracting(defaultNames)
        let catalog = skillCatalogForProjectPath( project.path)
        let grouped = Dictionary(grouping: catalog, by: \.name)

        func resolvedSkills(for names: Set<String>) -> ([SkillRecord], [String]) {
            var skills: [SkillRecord] = []
            var unresolved: [String] = []

            for name in names.sorted() {
                let matches = grouped[name] ?? []
                if matches.count == 1, let skill = matches.first {
                    skills.append(skill)
                } else {
                    unresolved.append(name)
                }
            }

            return (
                skills.sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                },
                unresolved
            )
        }

        let defaultResult = resolvedSkills(for: defaultNames)
        let projectResult = resolvedSkills(for: projectNames)
        return ProjectSkillRecap(
            defaultSkills: defaultResult.0,
            projectSkills: projectResult.0,
            unresolvedNames: (defaultResult.1 + projectResult.1).sorted()
        )
    }

    func agentRecap(for project: DiscoveredProject) -> ProjectAgentRecap {
        let defaultNames = appSettings.defaultAgentNames
        let projectNames = projectPreference(for: project.path).assignedAgentNames.subtracting(defaultNames)
        let effectiveAgents = (allProjectSnapshots[project.path]?.effectiveAgents ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let effectiveByName = Dictionary(uniqueKeysWithValues: effectiveAgents.map { ($0.name, $0) })

        func resolvedAgents(for names: Set<String>) -> ([EffectiveAgentRecord], [String]) {
            var agents: [EffectiveAgentRecord] = []
            var unresolved: [String] = []
            for name in names.sorted() {
                if let agent = effectiveByName[name] {
                    agents.append(agent)
                } else {
                    unresolved.append(name)
                }
            }
            return (agents, unresolved)
        }

        let defaultResult = resolvedAgents(for: defaultNames)
        let projectResult = resolvedAgents(for: projectNames)
        let highlightedNames = Set(defaultResult.0.map(\.name)).union(projectResult.0.map(\.name))
        let otherEffectiveAgents = effectiveAgents.filter { !highlightedNames.contains($0.name) }
        return ProjectAgentRecap(
            defaultAgents: defaultResult.0,
            projectAgents: projectResult.0,
            otherEffectiveAgents: otherEffectiveAgents,
            unresolvedNames: (defaultResult.1 + projectResult.1).sorted()
        )
    }

    func parentSkillArguments(for projectURL: URL) throws -> [String] {
        let projectPath = projectURL.standardizedFileURL.path
        let names = Array(appSettings.defaultSkillNames.union(projectPreference(for: projectPath).assignedSkillNames))
        return try PiSkillLaunchResolver.skillArguments(for: names, catalog: skillCatalogForProjectPath( projectPath))
    }

    func parentPromptTemplateArguments(for projectURL: URL) throws -> [String] {
        let projectPath = projectURL.standardizedFileURL.path
        let names = Array(appSettings.defaultPromptTemplateNames.union(projectPreference(for: projectPath).assignedPromptTemplateNames))
        return try PiPromptTemplateLaunchResolver.promptTemplateArguments(for: names, catalog: promptTemplateCatalog(forProjectPath: projectPath))
    }

    func promptTemplateCatalog(forProjectPath projectPath: String) -> [PromptTemplateRecord] {
        var records = globalSnapshot.promptTemplates + globalSnapshot.libraryPromptTemplates
        if let projectSnapshot = allProjectSnapshots[projectPath] {
            records += projectSnapshot.promptTemplates + projectSnapshot.libraryPromptTemplates
        }
        if selectedProjectPath == projectPath {
            records += snapshot.promptTemplates + snapshot.libraryPromptTemplates
        }
        let disabledBundled = appSettings.disabledBundledPromptNames
        var seen = Set<String>()
        return records
            .filter { !($0.source.kind == .builtin && disabledBundled.contains($0.name)) }
            .filter { seen.insert($0.id).inserted }
    }

    func skillCatalogForProjectPath(_ projectPath: String) -> [SkillRecord] {
        var records = globalSnapshot.skills + globalSnapshot.librarySkills
        if let projectSnapshot = allProjectSnapshots[projectPath] {
            records += projectSnapshot.skills + projectSnapshot.librarySkills
        }
        if selectedProjectPath == projectPath {
            records += snapshot.skills + snapshot.librarySkills
        }
        let disabledBundled = appSettings.disabledBundledSkillNames
        var seen = Set<String>()
        return records
            .filter { !($0.source.kind == .builtin && disabledBundled.contains($0.name)) }
            .filter { seen.insert($0.id).inserted }
    }

    var userDisableBuiltins: Bool {
        settingsSummary(for: .global)?.disableBuiltins ?? false
    }

    var projectDisableBuiltins: Bool {
        settingsSummary(for: .project)?.disableBuiltins ?? false
    }

    func setDisableBuiltins(_ isDisabled: Bool, scope: AgentEditingTarget.OverrideScope) {
        do {
            try agentPersistence.setDisableBuiltins(isDisabled, scope: scope, projectRoot: selectedProjectPath)
            patchDisableBuiltins(isDisabled, scope: scope)
            refreshAfterOverrideChange(scope: scope)
        } catch {
            github.githubLastError = error.localizedDescription
        }
    }

    func setBuiltinDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord, scope: AgentEditingTarget.OverrideScope, explicitProjectRoot: String? = nil) {
        let targetRoot = explicitProjectRoot ?? selectedProjectPath
        do {
            try agentPersistence.setBuiltinDisabled(isDisabled, for: agent, scope: scope, projectRoot: targetRoot)
            patchBuiltinDisabledOverride(agentName: agent.name, scope: scope, isDisabled: isDisabled, explicitProjectRoot: explicitProjectRoot)
        } catch {
            github.githubLastError = error.localizedDescription
        }
    }

    /// Toggles the global state for a builtin and, atomically, wipes every
    /// per-project `disabled` override for the same agent. Per-project
    /// overrides take precedence in [[builtinIsDisabled]] (see
    /// `PiAgentLaunchResolver`), so without this sweep "All Projects" would
    /// silently fail in any project that had been individually toggled off.
    func setBuiltinGloballyEnabled(_ isEnabled: Bool, for agent: EffectiveAgentRecord) {
        setBuiltinDisabled(!isEnabled, for: agent, scope: .global)

        for (projectPath, snap) in allProjectSnapshots {
            let projectSettingsPath = URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/settings.json").standardizedFileURL.path
            let hasDisabledOverride = snap.settings.contains { summary in
                URL(fileURLWithPath: summary.path).standardizedFileURL.path == projectSettingsPath
                && summary.agentOverrides.contains { $0.agentName == agent.name && $0.values["disabled"] != nil }
            }
            guard hasDisabledOverride else { continue }
            do {
                try agentPersistence.clearBuiltinDisabledOverride(for: agent, scope: .project, projectRoot: projectPath)
                patchBuiltinDisabledOverrideCleared(agentName: agent.name, projectRoot: projectPath)
            } catch {
                github.githubLastError = error.localizedDescription
            }
        }
    }

    private func patchBuiltinDisabledOverrideCleared(agentName: String, projectRoot: String) {
        let targetPath = URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/settings.json").path

        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            let updatedSettings: [SettingsSummary] = snap.settings.map { summary in
                guard summary.path == targetPath else { return summary }
                var overrides = summary.agentOverrides
                if let idx = overrides.firstIndex(where: { $0.agentName == agentName }) {
                    var values = overrides[idx].values
                    values.removeValue(forKey: "disabled")
                    if values.isEmpty {
                        overrides.remove(at: idx)
                    } else {
                        overrides[idx] = BuiltinOverrideRecord(
                            agentName: agentName,
                            scope: ScopeID(kind: .override, path: targetPath),
                            settingsPath: targetPath,
                            values: values
                        )
                    }
                }
                return SettingsSummary(
                    path: summary.path,
                    packages: summary.packages,
                    prompts: summary.prompts,
                    disableBuiltins: summary.disableBuiltins,
                    agentOverrides: overrides
                )
            }
            return ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: snap.globalAgents,
                projectAgents: snap.projectAgents,
                legacyProjectAgents: snap.legacyProjectAgents,
                effectiveAgents: snap.effectiveAgents,
                libraryAgents: snap.libraryAgents,
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: updatedSettings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)

        reconcileSnapshotsFromPreferences()
    }

    /// Effective disabled state for a builtin in a specific project. Mirrors
    /// `PiAgentLaunchResolver`'s precedence so the per-project checkboxes
    /// show what Pi actually loads: explicit per-agent project override →
    /// project `disableBuiltins` → per-agent user override → user
    /// `disableBuiltins`. Falling through to global state matters when the
    /// project has no settings file yet (e.g. just-added project), otherwise
    /// brand-new projects render as "enabled" even when global says disabled.
    func builtinIsDisabled(agentName: String, inProject projectPath: String) -> Bool {
        let projectSettingsPath = URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/settings.json").standardizedFileURL.path
        let projectSettings = allProjectSnapshots[projectPath]?.settings.first { summary in
            URL(fileURLWithPath: summary.path).standardizedFileURL.path == projectSettingsPath
        }
        if let projectOverrideDisabled = projectSettings?.agentOverrides.first(where: { $0.agentName == agentName })?.disabledOverride {
            return projectOverrideDisabled
        }
        if projectSettings?.disableBuiltins == true {
            return true
        }

        let globalSettingsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json").standardizedFileURL.path
        let globalSettings = globalSnapshot.settings.first { summary in
            URL(fileURLWithPath: summary.path).standardizedFileURL.path == globalSettingsPath
        }
        if let userOverrideDisabled = globalSettings?.agentOverrides.first(where: { $0.agentName == agentName })?.disabledOverride {
            return userOverrideDisabled
        }
        return globalSettings?.disableBuiltins == true
    }

    func toggleBuiltinDisabledGlobally(_ agent: EffectiveAgentRecord) {
        setBuiltinDisabled(!(agent.resolved.disabled ?? false), for: agent, scope: .global)
    }

    func builtinStateBadge(for agent: EffectiveAgentRecord) -> (text: String, color: Color)? {
        guard agent.builtin != nil, agent.globalCustom == nil, agent.projectCustom == nil else { return nil }

        let projectOverrideDisabled = agent.projectOverride?.disabledOverride
        let userOverrideDisabled = agent.userOverride?.disabledOverride

        if agent.resolved.disabled == true {
            if projectOverrideDisabled == true || projectDisableBuiltins {
                return ("Disabled by project", .orange)
            }
            if userOverrideDisabled == true || userDisableBuiltins {
                return ("Disabled globally", .red)
            }
        } else if projectOverrideDisabled == false || userOverrideDisabled == false {
            return ("Explicitly enabled override", .green)
        }

        return nil
    }

    func agentsExplicitlyUsingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        snapshot.effectiveAgents
            .filter { $0.resolved.skills.contains(skill.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agentsAmbientlySeeingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        []
    }

    func makeAggregateSnapshot() -> ScanSnapshot {
        // The no-project view is a global/library management view. Project-local
        // resources remain visible only when their project is selected; they are not
        // merged here so global/library resources do not depend on scanning every repo.
        ScanSnapshot(
            projectRoot: nil,
            builtinAgents: globalSnapshot.builtinAgents,
            globalAgents: globalSnapshot.globalAgents,
            projectAgents: [],
            legacyProjectAgents: [],
            effectiveAgents: globalSnapshot.effectiveAgents,
            libraryAgents: globalSnapshot.libraryAgents,
            skills: globalSnapshot.skills,
            librarySkills: globalSnapshot.librarySkills,
            promptTemplates: globalSnapshot.promptTemplates,
            libraryPromptTemplates: globalSnapshot.libraryPromptTemplates,
            settings: globalSnapshot.settings,
            envKeys: globalSnapshot.envKeys,
            warnings: globalSnapshot.warnings
        )
    }

    private func refreshAfterOverrideChange(scope: AgentEditingTarget.OverrideScope) {
        switch scope {
        case .global:
            refresh(includeModels: false, silentlyReconcile: true)
        case .project:
            if let projectPath = selectedProjectPath {
                refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath], silentlyReconcile: true)
            } else {
                refresh(includeModels: false, silentlyReconcile: true)
            }
        }
    }

    private func refreshAfterFileScopedChange(sourceKind: ResourceScopeKind, filePath: String) {
        switch sourceKind {
        case .project, .legacyProject:
            refreshAfterProjectScopedChange(projectPath: projectPath(containing: filePath) ?? selectedProjectPath)
        default:
            refresh(includeModels: false)
        }
    }

    private func refreshAfterProjectScopedChange(projectPath: String?) {
        // Async-only: agent-draft saves, override edits and env-key changes all
        // route through here; a synchronous rescan would freeze the UI on each.
        // `silentlyReconcile`: the visible state has already been patched in
        // memory (e.g. by `patchEffectiveAgentSkills`), so the list stays
        // interactive while the background scan reconciles.
        guard let projectPath else {
            refresh(includeModels: false, silentlyReconcile: true)
            return
        }
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath], silentlyReconcile: true)
    }

    private func projectPath(containing filePath: String) -> String? {
        enabledProjects.first { project in
            filePath == project.path || filePath.hasPrefix(project.path + "/")
        }?.path
    }

    private func scopeSnapshot(for target: AgentEditingTarget) -> ScanSnapshot {
        switch target {
        case let .builtinOverride(scope):
            return scopedSnapshot(for: scope == .project)
        case let .custom(scope):
            return scopedSnapshot(for: scope == .project)
        }
    }

    private func scopedSnapshot(for includeProject: Bool) -> ScanSnapshot {
        guard includeProject, let selectedProjectPath, let projectSnapshot = allProjectSnapshots[selectedProjectPath] else {
            return globalSnapshot
        }
        return projectSnapshot
    }

    private func skillVisible(to agent: EffectiveAgentRecord, skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .project, .legacyProject:
            guard let skillProject = projectName(from: skill.filePath) else { return false }
            if let agentProject = agent.projectRoot.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
                return skillProject == agentProject
            }
            return false
        default:
            return true
        }
    }

    private func projectName(from path: String) -> String? {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        if let piIndex = components.lastIndex(of: ".pi"), piIndex > 0 {
            return components[piIndex - 1]
        }
        if let agentsIndex = components.lastIndex(of: ".agents"), agentsIndex > 0 {
            return components[agentsIndex - 1]
        }
        return nil
    }

    private func deduplicateByID<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    func markPromptPendingDeletion(_ prompt: PromptTemplateRecord) {
        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedPromptIDs.insert(prompt.id)
        }
    }

    func markSkillPendingDeletion(_ skill: SkillRecord) {
        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedSkillIDs.insert(skill.id)
        }
    }

    var standardizedExternalSkillPaths: Set<String> { cachedStandardizedExternalSkillPaths }

    func removeSkillFromAgentDrafts(named skillName: String) throws {
        for agent in snapshot.effectiveAgents where agent.resolved.skills.contains(skillName) {
            guard var draft = makeAgentDraft(for: agent) else { continue }
            draft.config.skills.removeAll { $0 == skillName }
            try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        }
    }

    func setSkillOnAgent(_ skill: SkillRecord, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        guard var draft = makeAgentDraft(for: agent) else { throw CocoaError(.fileNoSuchFile) }
        var skills = draft.config.skills
        if enabled {
            if !skills.contains(skill.name) { skills.append(skill.name) }
        } else {
            skills.removeAll { $0 == skill.name }
        }
        draft.config.skills = PiSkillLaunchResolver.normalizedNames(skills)
        try saveAgentDraft(draft, for: agent)
        patchEffectiveAgentSkills(agentName: agent.name, skills: draft.config.skills)
        resourceCatalog.rebuildWarningCaches()
    }

}

// MARK: - Env catalog host

extension AppViewModel: EnvCatalogHost {
    func refreshAfterEnvFileChange(sourceKind: ResourceScopeKind, filePath: String) {
        refreshAfterFileScopedChange(sourceKind: sourceKind, filePath: filePath)
    }
}

// MARK: - Agent draft host (private snapshot/refresh surface)

extension AppViewModel: AgentDraftHost {
    func resolveProjectPath(containing filePath: String) -> String? {
        projectPath(containing: filePath)
    }

    func applyEffectiveAgentConfigPatch(originalName: String, newConfig: AgentConfig, filePath: String?) {
        patchEffectiveAgentConfig(originalName: originalName, newConfig: newConfig, filePath: filePath)
    }

    func applyBuiltinOverridePatch(
        agentName: String,
        scope: AgentEditingTarget.OverrideScope,
        overrideValues: [String: Any]?
    ) {
        patchBuiltinOverrideRecord(agentName: agentName, scope: scope, overrideValues: overrideValues)
    }

    func rebuildWarningCachesAfterAgentDraftSave() {
        resourceCatalog.rebuildWarningCaches()
    }

    func refreshAfterAgentDraftChange(_ draft: AgentEditorDraft) {
        switch draft.target {
        case let .custom(scope):
            guard scope == .project else {
                refresh(includeModels: false, silentlyReconcile: true)
                return
            }
            refreshAfterProjectScopedChange(
                projectPath: draft.sourcePath.flatMap(projectPath(containing:)) ?? selectedProjectPath
            )
        case let .builtinOverride(scope):
            refreshAfterOverrideChange(scope: scope)
        }
    }

    func refreshGloballyAfterAgentDraftSave(silentlyReconcile: Bool) {
        refresh(includeModels: false, silentlyReconcile: silentlyReconcile)
    }

    func refreshAfterProjectScopedAgentDraftSave(projectPath: String) {
        refreshAfterProjectScopedChange(projectPath: projectPath)
    }

    func defaultCustomScope(for agent: EffectiveAgentRecord) -> AgentEditingTarget.CustomAgentScope {
        if agent.projectCustom != nil || agent.projectOverride != nil || (agent.projectRoot != nil && selectedProjectPath != nil) {
            return .project
        }
        return .global
    }

    func duplicatedName(for name: String) -> String {
        let existingNames = Set(snapshot.effectiveAgents.map(\.name))
        var candidate = "\(name)-copy"
        var index = 2
        while existingNames.contains(candidate) {
            candidate = "\(name)-copy-\(index)"
            index += 1
        }
        return candidate
    }
}
