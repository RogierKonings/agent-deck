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
    let resourceCatalog = ResourceCatalogState()
    var hasCompletedInitialRefresh: Bool { resourceCatalog.hasCompletedInitialRefresh }
    // Automation-model lookup is cached. `FoundationModelAutomationService`
    // queries Apple's Foundation Models availability API, and the Pi Agent
    // toolbar reads `automationAvailableModels` on every `ContentView.body`
    // eval (i.e. once per streaming token). The result only changes at real
    // boundaries — see `rebuildAutomationModelCaches()`.
    private(set) var cachedFoundationAutomationModel: AvailableModel?
    private(set) var cachedAutomationAvailableModels: [AvailableModel] = []
    // Agent-list caches live in `resourceCatalog` — rebuilt by `rebuildWarningCaches()`.
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
        modelCatalog.availableModels.filter { isModelAvailable($0) }
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
    private var envPersistence: EnvPersistence { environment.envPersistence }
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
    let automation: AutomationCoordinator
    private var sessionWorktreeService: PiAgentSessionWorktreeService { environment.sessionWorktreeService }
    /// Memoizes `selectableAgentUniverse(forProjectPath:)` so the subagent
    /// picker (and `catalogAgents(for:)` / `sessionHasSelectableAgents`) read
    /// a precomputed list instead of rebuilding it on every body evaluation.
    /// Cleared in `clearAgentUniverseCache()` whenever a snapshot publishes.
    @ObservationIgnored private var agentUniverseCacheByProjectPath: [String: [EffectiveAgentRecord]] = [:]
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

        rebuildWarningCaches(markInitialRefreshComplete: true)
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
        rebuildWarningCaches()
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

    func refreshEverything() {
        guard !github.githubIsRefreshingEverything else { return }

        github.githubIsRefreshingEverything = true
        github.githubLastError = nil

        // The outer @MainActor class implicitly bounds this Task to the main
        // actor, so the inner `await MainActor.run` blocks the previous
        // implementation used were no-ops. Sync work runs inline; only the
        // genuinely-async GitHub calls suspend.
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.github.githubIsRefreshingEverything = false
            }
            self.refresh(includeModels: true)
            await self.github.refreshGitHubStatus()
            if case .available = self.github.githubConnectionState {
                await self.github.connectGitHubUsingCLIIfNeeded()
            }
            if self.github.authenticatedSession != nil, self.github.githubConnectionState.isConnected {
                self.github.refreshProjectBoard(force: true)
            }
            if self.selectedDiscoveredProject?.isGitRepository == true {
                self.github.refreshRepositoryChanges(preservingDiffSelection: true)
            }
            if let selectedItem = self.github.githubSelectedWorkItem, self.github.authenticatedSession != nil {
                self.github.loadIssueDetail(for: selectedItem)
            }
        }
    }



    func ensureComposerIssuesLoaded() {
        Task { [weak self] in
            guard let self else { return }
            await github.prepareGitHubScreen()
            await MainActor.run {
                if selectedGitHubProject?.gitHubRemote != nil {
                    github.refreshProjectBoard(force: false)
                } else if github.githubAggregateBoard == nil, !gitHubProjects.isEmpty {
                    github.refreshAggregateBoard()
                }
            }
        }
    }

    func isProviderEnabled(_ provider: String) -> Bool {
        !appSettings.disabledProviders.contains(provider)
    }

    func isModelEnabled(_ model: AvailableModel) -> Bool {
        !appSettings.disabledModelIdentifiers.contains(model.identifier)
    }

    func isModelAvailable(_ model: AvailableModel) -> Bool {
        isProviderEnabled(model.provider) && isModelEnabled(model)
    }

    /// Bumped by the Extensions toolbar Refresh action; the screen keys its
    /// off-main discovery `.task` on this so a Refresh re-scans without a project change.
    private(set) var piExtensionsRefreshToken = 0

    func refreshDiscoveredPiExtensions() {
        piExtensionsRefreshToken &+= 1
    }

    func isOpenAIFastModeEnabled(_ model: AvailableModel) -> Bool {
        appSettings.openAIFastModeModelIdentifiers.contains(model.identifier)
    }

    func togglePiAgentSessionPinned(_ id: UUID) {
        piAgentSessionStore.togglePinned(id)
    }

    func setSubagentsEnabledForSelectedSession(_ isEnabled: Bool) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        piAgentSessionStore.updateSession(session.id, bumpUpdatedAt: false) { session in
            session.subagentsEnabled = isEnabled
        }
    }

    /// Draft-only footer control: before the first launch, subagents act like a
    /// session default. Update both the selected draft and the default for new
    /// sessions. Once Pi has started, the footer becomes read-only.
    func setSubagentsEnabledForSelectedDraftAndNewSessions(_ isEnabled: Bool) {
        setSubagentsEnabledForNewSessions(isEnabled)
        guard let session = piAgentSessionStore.selectedSession, session.status == .draft else { return }
        piAgentSessionStore.updateSession(session.id, bumpUpdatedAt: false) { session in
            session.subagentsEnabled = isEnabled
        }
    }

    /// Persists a session's per-session subagent selection. `nil` restores the
    /// default (all effective agents); a non-nil set pins an explicit choice.
    func setAgentSelection(_ selection: Set<String>?, for sessionID: UUID) {
        piAgentSessionStore.updateSession(sessionID, bumpUpdatedAt: false) { session in
            session.agentSelection = selection
        }
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

    var currentGitHubAccount: GitHubHostAccount? {
        github.githubConnectionState.account ?? github.authenticatedSession?.account
    }

    var shouldShowGitHubConnectionCard: Bool {
        currentGitHubAccount != nil || github.githubLastStatusCheckAt != nil || github.githubIsRefreshingEverything
    }

    /// Cached — see `cachedAllDisplayAgents`. Rebuilt by `rebuildWarningCaches()`.
    var allDisplayAgents: [EffectiveAgentRecord] { cachedAllDisplayAgents }

    /// The actual merge+sort. Called only from `rebuildWarningCaches()`.
    private func computeAllDisplayAgents() -> [EffectiveAgentRecord] {
        var byID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
        for agent in snapshot.effectiveAgents { byID[agent.id] = agent }
        for agent in catalogOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in libraryOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in projectAssignedLibraryAgentsForAggregateView { byID[agent.id] = agent }
        return Array(byID.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var filteredAgents: [EffectiveAgentRecord] {
        allDisplayAgents.filter { agent in
            switch selectedAgentFilter {
            case .all:
                return true
            case .builtin:
                return agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
            case .global:
                return agent.globalCustom?.source.kind == .global
            case .project:
                return agent.projectCustom != nil
            case .overriddenBuiltins:
                return agent.builtin != nil && (agent.userOverride != nil || agent.projectOverride != nil)
            case .replacedBuiltins:
                return agent.builtin != nil && (agent.globalCustom != nil || agent.projectCustom != nil)
            case .customOnly:
                return agent.globalCustom != nil || agent.projectCustom != nil
            case .disabled:
                return agent.resolved.disabled == true
            case .needsAttention:
                return !warnings(for: agent).isEmpty
            }
        }
    }

    var selectedAgent: EffectiveAgentRecord? {
        // O(1) lookup over `cachedDisplayAgentByID`. The cache is sourced from
        // `cachedAllDisplayAgents` (a superset of `snapshot.effectiveAgents`,
        // `catalogOnlyEffectiveAgents`, and `libraryOnlyEffectiveAgents`), so
        // we drop the heavy fallback that recomputed the catalog walk on every
        // body read.
        guard let id = selectedAgentID else { return nil }
        return cachedDisplayAgentByID[id]
    }

    private var catalogOnlyEffectiveAgents: [EffectiveAgentRecord] {
        let effectivePaths = Set(snapshot.effectiveAgents.compactMap(\.sourcePath).map(standardizedPath))
        return agentCatalog(forProjectPath: selectedProjectPath)
            .filter { $0.source.kind != .builtin }
            .filter { !effectivePaths.contains(standardizedPath($0.filePath)) }
            .filter { $0.source.kind != .library }
            .map { catalogDisplayAgent(from: $0, projectRoot: snapshot.projectRoot) }
    }

    private var libraryOnlyEffectiveAgents: [EffectiveAgentRecord] {
        // In the global view, project-local agents should not hide reusable library
        // agents with the same name. Global/custom winners still hide library duplicates.
        let agentsThatHideLibrary = snapshot.projectRoot == nil
            ? snapshot.effectiveAgents.filter { $0.projectCustom == nil && $0.projectOverride == nil }
            : snapshot.effectiveAgents
        let effectiveNames = Set(agentsThatHideLibrary.map(\.name))
        return snapshot.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: snapshot.projectRoot) }
    }

    /// Every agent a session could pick for its subagent catalog: the
    /// project-effective agents plus catalog-only and library agents not
    /// otherwise assigned. Parameterized by project path so it resolves for
    /// any session, not only the currently selected project.
    ///
    /// Results are memoized per project path; the cache is cleared via
    /// `clearAgentUniverseCache()` whenever any underlying snapshot
    /// publishes, so callers can read this on every `body` evaluation
    /// without rebuilding the catalog walk each time.
    /// Resolves the `EffectiveAgentRecord` an agent-bound session was created
    /// against. Looks up the session's `agentName` in the session's project
    /// snapshot first (so a project override wins), then falls back to the
    /// global snapshot and finally the cross-project union returned by
    /// `selectableAgentUniverse`. Returns `nil` when the agent is no longer
    /// present anywhere — the runner surfaces this as an "Agent Unavailable"
    /// transcript error.
    func boundAgent(for session: PiAgentSessionRecord) -> EffectiveAgentRecord? {
        guard session.isAgentBound, let name = session.agentName else { return nil }
        if let scoped = allProjectSnapshots[session.projectPath]?.effectiveAgents.first(where: { $0.name == name }) {
            return scoped
        }
        if let global = globalSnapshot.effectiveAgents.first(where: { $0.name == name }) {
            return global
        }
        return selectableAgentUniverse(forProjectPath: session.projectPath).first { $0.name == name }
    }

    /// Skill argument list (`--skill <name=path>` pairs) for a 1:1 agent chat.
    /// Reuses the subagent runner's resolver so the agent sees the same skill
    /// universe it would as a delegated child.
    func boundAgentSkillArguments(for agent: EffectiveAgentRecord) throws -> [String] {
        let snap = startupSnapshot(forProjectPath: agent.projectRoot ?? snapshot.projectRoot ?? "")
        return try PiSkillLaunchResolver.childSkillArguments(agent: agent, snapshot: snap)
    }

    func piAgentRunnerSurfaceError(message: String) {
        github.githubLastError = message
    }

    func selectableAgentUniverse(forProjectPath path: String) -> [EffectiveAgentRecord] {
        if let cached = agentUniverseCacheByProjectPath[path] {
            return cached
        }
        let snap = startupSnapshot(forProjectPath: path)
        let effective = snap.effectiveAgents
        let effectivePaths = Set(effective.compactMap(\.sourcePath).map(standardizedPath))
        let catalogOnly = agentCatalog(forProjectPath: path)
            .filter { $0.source.kind != .builtin && $0.source.kind != .library }
            .filter { !effectivePaths.contains(standardizedPath($0.filePath)) }
            .map { catalogDisplayAgent(from: $0, projectRoot: snap.projectRoot) }
        let effectiveNames = Set(effective.map(\.name))
        let libraryOnly = snap.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: snap.projectRoot) }
        let result = effective + catalogOnly + libraryOnly
        agentUniverseCacheByProjectPath[path] = result
        return result
    }

    func clearAgentUniverseCache() {
        agentUniverseCacheByProjectPath.removeAll(keepingCapacity: true)
    }

    /// The exact, deduplicated set of subagents advertised to — and delegable
    /// by — a session. Single source of truth shared by the catalog prompt,
    /// the delegation lookups, and the session resources popover. A `nil`
    /// `agentSelection` keeps the historical default of all effective agents;
    /// an explicit selection is resolved against the full universe so an agent
    /// not assigned to the project can still be included.
    func catalogAgents(for session: PiAgentSessionRecord) -> [EffectiveAgentRecord] {
        let agents: [EffectiveAgentRecord]
        if let selection = session.agentSelection {
            agents = selectableAgentUniverse(forProjectPath: session.projectPath)
                .filter { selection.contains($0.name) }
        } else {
            agents = startupSnapshot(forProjectPath: session.projectPath).effectiveAgents
        }
        var seen = Set<String>()
        return agents.filter { $0.resolved.disabled != true && seen.insert($0.name).inserted }
    }

    /// Whether a session has any non-disabled agent it could run as a subagent.
    /// Fast path: a usable effective agent (builtins normally qualify) returns
    /// immediately, so the cross-project catalog scan only runs in the rare
    /// case where the project has no usable effective agents at all.
    func sessionHasSelectableAgents(_ session: PiAgentSessionRecord) -> Bool {
        if startupSnapshot(forProjectPath: session.projectPath)
            .effectiveAgents.contains(where: { $0.resolved.disabled != true }) {
            return true
        }
        return selectableAgentUniverse(forProjectPath: session.projectPath)
            .contains { $0.resolved.disabled != true }
    }

    private var projectAssignedLibraryAgentsForAggregateView: [EffectiveAgentRecord] {
        guard snapshot.projectRoot == nil else { return [] }
        let effectiveNames = Set(snapshot.effectiveAgents.map(\.name))
        let libraryByName = Dictionary(uniqueKeysWithValues: snapshot.libraryAgents.map { ($0.name, $0) })
        let assignedNames = Set(projectPreferencesByPath.values.flatMap(\.assignedAgentNames))
        let libraryNames = Set(snapshot.libraryAgents.map(\.name))
        return assignedNames
            .filter { !effectiveNames.contains($0) && libraryNames.contains($0) }
            .compactMap { libraryByName[$0] }
            .map { libraryDisplayAgent(from: $0, projectRoot: nil) }
    }

    private func catalogDisplayAgent(from record: AgentRecord, projectRoot: String?) -> EffectiveAgentRecord {
        EffectiveAgentRecord(
            id: "catalog::\(record.source.kind.rawValue)::\(record.filePath)",
            name: record.name,
            projectRoot: projectRoot,
            builtin: nil,
            globalCustom: record.source.kind == .global ? record : nil,
            projectCustom: record.source.kind == .project || record.source.kind == .legacyProject ? record : nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: record.parsed,
            resolutionKind: record.source.kind == .global ? .globalCustom : .projectCustom
        )
    }

    private func libraryDisplayAgent(from record: AgentRecord, projectRoot: String?) -> EffectiveAgentRecord {
        EffectiveAgentRecord(
            id: "library::\(record.name)",
            name: record.name,
            projectRoot: projectRoot,
            builtin: nil,
            globalCustom: record,
            projectCustom: nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: record.parsed,
            resolutionKind: .library
        )
    }

    var allVisibleAgentRecords: [AgentRecord] {
        agentCatalog(forProjectPath: selectedProjectPath)
            .filter { $0.source.kind != .builtin }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func agentCatalog(forProjectPath projectPath: String?) -> [AgentRecord] {
        var records = globalSnapshot.globalAgents + globalSnapshot.libraryAgents
        for projectSnapshot in allProjectSnapshots.values {
            records += projectSnapshot.projectAgents + projectSnapshot.legacyProjectAgents + projectSnapshot.libraryAgents
        }
        if selectedProjectPath == projectPath {
            records += snapshot.projectAgents + snapshot.legacyProjectAgents + snapshot.libraryAgents
        }
        return deduplicateByID(records)
    }

    private func agentCatalog(globalSnapshot: ScanSnapshot, catalogProjectSnapshots: [ScanSnapshot]) -> [AgentRecord] {
        deduplicateByID(
            globalSnapshot.globalAgents +
            globalSnapshot.libraryAgents +
            catalogProjectSnapshots.flatMap { $0.projectAgents + $0.legacyProjectAgents + $0.libraryAgents }
        )
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
                catalog: agentCatalog(globalSnapshot: globalCatalogSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
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

    func makeAgentDraft(for agent: EffectiveAgentRecord, preferredOverrideScope: AgentEditingTarget.OverrideScope? = nil) -> AgentEditorDraft? {
        agentPersistence.makeDraft(for: agent, preferredOverrideScope: preferredOverrideScope)
    }

    func saveAgentDrafts(_ pairs: [(draft: AgentEditorDraft, agent: EffectiveAgentRecord)]) throws {
        guard !pairs.isEmpty else { return }
        for pair in pairs {
            try agentPersistence.save(pair.draft, original: pair.agent, projectRoot: selectedProjectPath)
        }
        var needsGlobalRefresh = false
        var projectPaths: Set<String> = []
        var didPatchInMemory = false
        for pair in pairs {
            switch pair.draft.target {
            case .custom(.global), .custom(.library), .builtinOverride(.global):
                needsGlobalRefresh = true
            case .custom(.project):
                if let path = pair.draft.sourcePath.flatMap(projectPath(containing:)) ?? selectedProjectPath {
                    projectPaths.insert(path)
                }
            case .builtinOverride(.project):
                if let path = selectedProjectPath {
                    projectPaths.insert(path)
                }
            }
            // Sync in-memory patch for custom edits so the panes update before
            // the rescan lands. Matches the single-save fast path in `saveAgentDraft`.
            if case .custom = pair.draft.target, pair.draft.originalName == pair.draft.config.name {
                patchEffectiveAgentConfig(
                    originalName: pair.draft.originalName,
                    newConfig: pair.draft.config,
                    filePath: pair.draft.sourcePath
                )
                didPatchInMemory = true
            }
        }
        if didPatchInMemory {
            rebuildWarningCaches()
        }
        if needsGlobalRefresh {
            refresh(includeModels: false, silentlyReconcile: didPatchInMemory)
        }
        for path in projectPaths {
            refreshAfterProjectScopedChange(projectPath: path)
        }
    }

    func saveAgentDraft(_ draft: AgentEditorDraft, for agent: EffectiveAgentRecord) throws {
        try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        // Fast-path: mirror the disk write into the in-memory snapshots so the
        // detail pane (reading `cachedDisplayAgentByID`) and the list layout
        // (driven by `displayAgentsRevision`) reflect the new config now,
        // instead of waiting for `refreshAfterAgentDraftChange`'s async rescan.
        // Skips rename + builtin-override edits; those keep the existing flow.
        if case .custom = draft.target, draft.originalName == draft.config.name {
            patchEffectiveAgentConfig(originalName: draft.originalName, newConfig: draft.config, filePath: draft.sourcePath)
            rebuildWarningCaches()
        } else if case let .builtinOverride(scope) = draft.target,
                  let builtin = agent.builtin?.parsed,
                  let overrideValues = agentPersistence.builtinOverrideValuesForTesting(base: builtin, edited: draft.config) {
            patchBuiltinOverrideRecord(agentName: agent.name, scope: scope, overrideValues: overrideValues)
        }
        refreshAfterAgentDraftChange(draft)
    }

    func setAgentDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord) throws {
        let overrideScope: AgentEditingTarget.OverrideScope = selectedProjectPath == nil ? .global : .project
        guard var draft = makeAgentDraft(for: agent, preferredOverrideScope: overrideScope) else { return }
        draft.config.disabled = isDisabled
        try saveAgentDraft(draft, for: agent)
    }

    func makeNewAgentDraft(scope: AgentEditingTarget.CustomAgentScope) -> AgentEditorDraft {
        let base = AgentConfig(
            name: "new-agent",
            description: "",
            whenToUse: nil,
            model: nil,
            fallbackModels: [],
            thinking: nil,
            systemPromptMode: "replace",
            inheritSkills: nil,
            disabled: nil,
            tools: ["read", "grep", "find", "ls", "bash"],
            mcpDirectTools: nil,
            extensions: nil,
            skills: [],
            output: nil,
            defaultExpectedOutcome: .reportOnly,
            defaultReads: nil,
            defaultProgress: nil,
            interactive: nil,
            maxSubagentDepth: nil,
            systemPrompt: "Describe the agent behavior here.",
            unknownFields: [:]
        )
        return agentPersistence.makeNewDraft(scope: scope, base: base)
    }

    func makeDuplicateAgentDraft(from agent: EffectiveAgentRecord, scope: AgentEditingTarget.CustomAgentScope? = nil) -> AgentEditorDraft {
        let targetScope = scope ?? defaultCustomScope(for: agent)
        var config = agent.winningRecord?.parsed ?? agent.resolved
        config.name = duplicatedName(for: config.name)
        return agentPersistence.makeNewDraft(scope: targetScope, base: config)
    }

    func makeReplacementAgentDraft(from agent: EffectiveAgentRecord, scope: AgentEditingTarget.CustomAgentScope) -> AgentEditorDraft {
        var config: AgentConfig
        if scope == .global, agent.builtin != nil, agent.globalCustom == nil {
            // Global replacement files should not accidentally bake in project-only overrides.
            config = makeAgentDraft(for: agent, preferredOverrideScope: .global)?.config ?? agent.resolved
        } else {
            config = agent.resolved
        }
        config.name = agent.name
        return agentPersistence.makeNewDraft(scope: scope, base: config)
    }

    func saveNewAgentDraft(_ draft: AgentEditorDraft) throws {
        try agentPersistence.saveNewCustomAgent(draft, projectRoot: selectedProjectPath)
        refreshAfterAgentDraftChange(draft)
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

    private func replacePromptSettingsPaths(oldURLs: [URL], newURL: URL?) throws {
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

    func prompt(_ prompt: PromptTemplateRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedPromptTemplateNames.contains(prompt.name)
    }

    func assignedProjects(for prompt: PromptTemplateRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.prompt(prompt, isEnabledFor: $0) }
    }

    func promptIsEnabledGlobally(_ prompt: PromptTemplateRecord) -> Bool {
        appSettings.defaultPromptTemplateNames.contains(prompt.name)
    }

    func setPrompt(_ prompt: PromptTemplateRecord, enabled: Bool, for project: DiscoveredProject) throws {
        projectPreferencesStore.setAssignedPromptTemplate(prompt.name, assigned: enabled, for: project.path)
        applyProjectPreferenceChanges()
        // Project assignment only mutates UserDefaults — nothing on disk
        // changed. Reconcile snapshot-derived state in memory instead of
        // re-walking the filesystem, so the toggle is instant.
        reconcileSnapshotsFromPreferences()
        selectedCommandItemID = allVisiblePromptTemplateRecords.first { $0.name == prompt.name }?.id ?? selectedCommandItemID
    }

    func enablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        guard appSettingsController.setDefaultPromptTemplate(prompt.name, enabled: true) else { return }
        settings.publish()
        refresh(includeModels: false)
    }

    func disablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        guard appSettingsController.setDefaultPromptTemplate(prompt.name, enabled: false) else { return }
        settings.publish()
        refresh(includeModels: false)
    }

    func bundledPromptIsDisabled(_ prompt: PromptTemplateRecord) -> Bool {
        prompt.source.kind == .builtin && appSettings.disabledBundledPromptNames.contains(prompt.name)
    }

    func setBundledPromptDisabled(_ isDisabled: Bool, for prompt: PromptTemplateRecord) {
        guard prompt.source.kind == .builtin else { return }
        guard appSettingsController.setBundledPromptDisabled(prompt.name, isDisabled: isDisabled) else { return }
        settings.publish()
        refresh(includeModels: false)
    }

    func bundledSkillIsDisabled(_ skill: SkillRecord) -> Bool {
        skill.source.kind == .builtin && appSettings.disabledBundledSkillNames.contains(skill.name)
    }

    func setBundledSkillDisabled(_ isDisabled: Bool, for skill: SkillRecord) {
        guard skill.source.kind == .builtin else { return }
        guard appSettingsController.setBundledSkillDisabled(skill.name, isDisabled: isDisabled) else { return }
        settings.publish()
        refresh(includeModels: false)
    }

    func movePromptToLibrary(_ prompt: PromptTemplateRecord) throws {
        _ = try ensureLibraryPrompt(for: prompt)
        refresh(includeModels: false)
    }

    func canDeletePrompt(_ prompt: PromptTemplateRecord) -> Bool {
        switch prompt.source.kind {
        case .package:
            return false
        case .builtin, .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func deletePrompt(_ prompt: PromptTemplateRecord) throws {
        guard canDeletePrompt(prompt) else { throw CocoaError(.fileWriteNoPermission) }

        // Throwing filesystem work first — optimistic hiding must not happen
        // unless it succeeds (the view shows an alert on throw).
        if prompt.discoveryKind == .externalReference {
            // Imported prompts are referenced in place — removing one only
            // un-registers the path. The user's original file is never trashed.
            try removePromptReferences(named: prompt.name)
            _ = appSettingsController.removeExternalPromptPaths([prompt.filePath])
            settings.publish()
        } else {
            try removePromptReferences(named: prompt.name)
            let fileURL = URL(fileURLWithPath: prompt.filePath).standardizedFileURL
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            try replacePromptSettingsPaths(oldURLs: [fileURL], newURL: nil)
            settings.publish()
        }

        // Hide the row immediately — no blocking rescan. The background refresh
        // prunes the pending id once the fresh snapshot confirms it's gone.
        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedPromptIDs.insert(prompt.id)
        }
        selectedCommandItemID = allVisiblePromptTemplateRecords.first?.id
        refresh(includeModels: false, scanAllProjects: true)
    }

    func agent(_ agent: AgentRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedAgentNames.contains(agent.name)
    }

    func assignedProjects(for agent: AgentRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.agent(agent, isEnabledFor: $0) }
    }

    /// Read-only accessor for the per-agent skill-visibility cache. The full map
    /// is computed by `buildSkillVisibilityIssuesByAgentID()` at refresh
    /// boundaries (alongside the other warning caches), so this must NEVER
    /// recompute or touch disk — it is called from view bodies for every agent
    /// on every layout pass. Agents without issues are intentionally absent from
    /// the cache, so a miss means "no issues", not "needs recompute". The old
    /// recompute-on-miss path fell through to a synchronous `PiScanner().scan()`
    /// per healthy agent, producing multi-hundred-ms main-thread hangs on tab
    /// switches.
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

    func moveSkillToGlobalCatalog(_ skill: SkillRecord) throws {
        try moveSkillToGlobalDirectory(skill)
        refresh(includeModels: false, scanAllProjects: true)
    }

    /// Recomputes the cached automation-model lookup. Called only at real
    /// boundaries — app launch / activation, a model-list reload, a settings
    /// change — never per `ContentView.body` eval. Mirrors `rebuildWarningCaches`.
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

    private func rebuildWarningCaches(markInitialRefreshComplete: Bool = false) {
        let allDisplayAgents = computeAllDisplayAgents()
        let skillWarnings = buildSkillWarnings()
        let promptWarnings = buildPromptWarnings()
        let visibilityIssuesByAgentID = buildSkillVisibilityIssuesByAgentID()
        let agentNamesByID = Dictionary(uniqueKeysWithValues: filteredAgents.map { ($0.id, $0.name) })
        let skillReferenceWarnings: [SkillReferenceWarning] = visibilityIssuesByAgentID
            .flatMap { pair -> [SkillReferenceWarning] in
                guard let agentName = agentNamesByID[pair.key] else { return [] }
                return pair.value.flatMap { issue in
                    issue.missingSkills.map { missingSkill in
                        SkillReferenceWarning(agentName: agentName, project: issue.project, missingSkill: missingSkill)
                    }
                }
            }
            .sorted(by: {
                if $0.missingSkill != $1.missingSkill { return $0.missingSkill < $1.missingSkill }
                if $0.agentName != $1.agentName { return $0.agentName < $1.agentName }
                return $0.project.name < $1.project.name
            })

        var agentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]] = [:]
        for agent in filteredAgents {
            agentWarningsByID[agent.id] = computeWarnings(for: agent)
        }

        var skillMetadataByID: [SkillRecord.ID: SkillListMetadata] = [:]
        var warningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]] = [:]
        let activeProject = selectedDiscoveredProject
        for record in allVisibleSkillRecords {
            let matchingWarnings = skillWarnings.filter { warning in
                warning.id == "duplicate-skill:\(record.name)" ||
                warning.id.contains(record.filePath) ||
                warning.message.contains("`\(record.name)`") ||
                warning.message.contains(record.filePath)
            }
            let hasWarnings = !matchingWarnings.isEmpty
            warningsBySkillID[record.id] = matchingWarnings
            let globallyEnabled = skillIsEnabledGlobally(record)
            let isAssigned = globallyEnabled ||
                !assignedProjects(for: record).isEmpty ||
                !assignedAgents(for: record).isEmpty
            let isActive = globallyEnabled ||
                (activeProject.map { skill(record, isEnabledFor: $0) } ?? false)
            skillMetadataByID[record.id] = SkillListMetadata(
                isAssigned: isAssigned,
                hasWarnings: hasWarnings,
                isActiveForCurrentProject: isActive
            )
        }

        resourceCatalog.applyRebuild(
            allDisplayAgents: allDisplayAgents,
            skillWarnings: skillWarnings,
            promptWarnings: promptWarnings,
            skillVisibilityIssuesByAgentID: visibilityIssuesByAgentID,
            skillReferenceWarnings: skillReferenceWarnings,
            agentWarningsByID: agentWarningsByID,
            skillMetadataByID: skillMetadataByID,
            warningsBySkillID: warningsBySkillID,
            markInitialRefreshComplete: markInitialRefreshComplete
        )
    }

    private func buildSkillWarnings() -> [DiagnosticWarning] {
        let baseWarnings = snapshot.warnings.filter { warning in
            warning.id.hasPrefix("malformed-skill:") || warning.message.localizedCaseInsensitiveContains("skill")
        }
        let collisionWarnings = PiSkillLaunchResolver.collisions(in: allVisibleSkillRecords).map { collision in
            let paths = collision.skills.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-skill:\(collision.name)", message: "Duplicate skill name `\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    private func buildPromptWarnings() -> [DiagnosticWarning] {
        let baseWarnings = snapshot.warnings.filter { warning in
            warning.id.hasPrefix("duplicate-prompt:")
        }
        let collisionWarnings = PiPromptTemplateLaunchResolver.collisions(in: allVisiblePromptTemplateRecords).map { collision in
            let paths = collision.prompts.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-prompt-template:\(collision.name)", message: "Duplicate prompt template name `/\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    private func buildSkillVisibilityIssuesByAgentID() -> [String: [AgentSkillVisibilityIssue]] {
        var issuesByAgentID: [String: [AgentSkillVisibilityIssue]] = [:]
        for agent in filteredAgents {
            guard !agent.resolved.skills.isEmpty else { continue }
            let explicitSkills = agent.resolved.skills
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !explicitSkills.isEmpty else { continue }

            let managedRecord = snapshot.libraryAgents.first { $0.name == agent.name }
                ?? agent.globalCustom
                ?? agent.projectCustom
            guard let managedRecord else { continue }

            let issues: [AgentSkillVisibilityIssue] = assignedProjects(for: managedRecord).compactMap { project in
                guard let projectSnapshot = allProjectSnapshots[project.path] else { return nil }
                let visibleSkillNames = Set(PiSkillLaunchResolver.catalog(from: projectSnapshot).map(\.name))
                let missingSkills = explicitSkills.filter { !visibleSkillNames.contains($0) }
                guard !missingSkills.isEmpty else { return nil }
                return AgentSkillVisibilityIssue(project: project, missingSkills: missingSkills)
            }
            if !issues.isEmpty {
                issuesByAgentID[agent.id] = issues
            }
        }
        return issuesByAgentID
    }

    func agentIsEnabledGlobally(_ agent: AgentRecord) -> Bool {
        appSettings.defaultAgentNames.contains(agent.name)
    }

    func setAgent(_ agent: AgentRecord, enabled: Bool, for project: DiscoveredProject) throws {
        projectPreferencesStore.setAssignedAgent(agent.name, assigned: enabled, for: project.path)
        applyProjectPreferenceChanges()
        // Project assignment only mutates UserDefaults — reconcile the
        // affected `effectiveAgents` in memory instead of rescanning disk.
        reconcileSnapshotsFromPreferences()
    }

    func enableAgentGlobally(_ agent: AgentRecord) throws {
        guard appSettingsController.setDefaultAgent(agent.name, enabled: true) else { return }
        settings.publish()
        refresh(includeModels: false)
    }

    func disableAgentGlobally(_ agent: AgentRecord) throws {
        guard appSettingsController.setDefaultAgent(agent.name, enabled: false) else { return }
        settings.publish()
        refresh(includeModels: false)
    }

    func moveAgentToLibrary(_ agent: AgentRecord) throws {
        _ = try ensureLibraryAgent(for: agent)
        refresh(includeModels: false)
    }

    /// Custom and library agents own a real file that can be removed. Builtin and
    /// package agents are read-only — they are disabled or overridden, not deleted.
    func canDeleteAgent(_ agent: AgentRecord) -> Bool {
        switch agent.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func deleteAgent(_ agent: AgentRecord) throws {
        guard canDeleteAgent(agent) else { throw CocoaError(.fileWriteNoPermission) }

        try removeAgentReferences(named: agent.name)
        let fileURL = URL(fileURLWithPath: agent.filePath).standardizedFileURL
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        // Reconcile in the background — no blocking rescan. The row updates
        // when the fresh snapshot lands; a builtin of the same name correctly
        // reappears instead of the row being wrongly hidden, so agent deletion
        // is not optimistically hidden the way skill/prompt deletion is.
        refresh(includeModels: false, scanAllProjects: true)
    }

    private func removeAgentReferences(named agentName: String) throws {
        _ = appSettingsController.setDefaultAgent(agentName, enabled: false)
        settings.publish()

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedAgent(agentName, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()
    }

    private func removePromptReferences(named promptName: String) throws {
        _ = appSettingsController.setDefaultPromptTemplate(promptName, enabled: false)
        settings.publish()

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedPromptTemplate(promptName, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()
    }

    func addSkillToSelectedProject(_ skill: SkillRecord) throws {
        guard let selectedProjectPath else { throw CocoaError(.fileNoSuchFile) }
        try setSkill(skill, enabled: true, forProjectPath: selectedProjectPath)
    }

    func removeSkillFromSelectedProject(_ skill: SkillRecord) throws {
        guard let selectedProjectPath else { throw CocoaError(.fileNoSuchFile) }
        try setSkill(skill, enabled: false, forProjectPath: selectedProjectPath)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for project: DiscoveredProject) throws {
        try setSkill(skill, enabled: enabled, forProjectPath: project.path)
    }

    func skill(_ skill: SkillRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedSkillNames.contains(skill.name)
    }

    func assignedProjects(for skill: SkillRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.skill(skill, isEnabledFor: $0) }
    }

    func skill(_ skill: SkillRecord, isAssignedTo agent: EffectiveAgentRecord) -> Bool {
        agent.resolved.skills.contains(skill.name)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        guard var draft = makeAgentDraft(for: agent) else { throw CocoaError(.fileNoSuchFile) }
        var skills = draft.config.skills
        if enabled {
            if !skills.contains(skill.name) { skills.append(skill.name) }
        } else {
            skills.removeAll { $0 == skill.name }
        }
        draft.config.skills = PiSkillLaunchResolver.normalizedNames(skills)
        try saveAgentDraft(draft, for: agent)
        // `saveAgentDraft` rewrites the agent `.md` and schedules a background
        // rescan, but the toggle's checkbox is snapshot-derived. Patch the
        // in-memory effective agent so the checkbox flips immediately instead
        // of waiting for that rescan to land.
        patchEffectiveAgentSkills(agentName: agent.name, skills: draft.config.skills)
        rebuildWarningCaches()
    }

    func assignedAgents(for skillRecord: SkillRecord) -> [EffectiveAgentRecord] {
        snapshot.effectiveAgents.filter { skill(skillRecord, isAssignedTo: $0) }
    }

    private func setSkill(_ skill: SkillRecord, enabled: Bool, forProjectPath projectPath: String) throws {
        projectPreferencesStore.setAssignedSkill(skill.name, assigned: enabled, for: projectPath)
        applyProjectPreferenceChanges()
        // Project assignment only mutates UserDefaults — nothing on disk
        // changed. Reconcile snapshot-derived state in memory instead of
        // re-walking the filesystem, so the toggle is instant.
        reconcileSnapshotsFromPreferences()
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    func enableSkillGlobally(_ skill: SkillRecord) throws {
        if skill.source.kind == .project || skill.source.kind == .legacyProject {
            try moveSkillToGlobalDirectory(skill)
        }
        guard appSettingsController.setDefaultSkill(skill.name, enabled: true) else {
            refresh(includeModels: false, scanAllProjects: true)
            selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
            return
        }
        settings.publish()
        refresh(includeModels: false, scanAllProjects: true)
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    func disableSkillGlobally(_ skill: SkillRecord) throws {
        guard appSettingsController.setDefaultSkill(skill.name, enabled: false) else { return }
        settings.publish()
        refresh(includeModels: false)
    }

    func canDeleteSkill(_ skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    /// Filesystem + state mutations for deleting one skill, WITHOUT triggering
    /// a refresh. The caller is responsible for calling `refresh()` once after
    /// all desired deletions — single call sites do it inline, batch call sites
    /// do it once after the loop.
    private func performSkillDeletion(_ skill: SkillRecord) throws {
        guard canDeleteSkill(skill) else { throw CocoaError(.fileWriteNoPermission) }

        // Throwing filesystem work first — optimistic hiding must not happen
        // unless these succeed (SkillsScreen shows an alert on throw).
        let targetURL = skillDeletionTargetURL(for: skill)
        try removeSkillReferences(named: skill.name)
        try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
        removeExternalSkillCatalogReferences(for: skill, deletedTarget: targetURL)
        skillRepositories.unlistSkillFromSyncedRepository(skill, deletionTargetURL: skillDeletionTargetURL(for: skill))

        // Hide the row immediately — no blocking rescan. SwiftUI updates the
        // list the instant the published set changes, like session deletion.
        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedSkillIDs.insert(skill.id)
        }
        // Recompute selection AFTER hiding so the deleted skill isn't re-picked.
        selectedSkillID = allVisibleSkillRecords.first?.id
    }

    func deleteSkill(_ skill: SkillRecord) throws {
        try performSkillDeletion(skill)
        // Reconcile in the background; applyRefreshSnapshot prunes the pending
        // ID once the fresh snapshot confirms the skill is gone. `silentlyReconcile`
        // because `pendingDeletedSkillIDs.insert` already hid the row.
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Batch delete: filesystem work per skill, then a single refresh. Returns
    /// the names of skills whose deletion threw (e.g. protected source kinds).
    /// Avoids the N-refresh storm of looping `deleteSkill(_:)`.
    func deleteSkills(_ skills: [SkillRecord]) -> [String] {
        var failed: [String] = []
        for skill in skills {
            do { try performSkillDeletion(skill) }
            catch { failed.append(skill.name) }
        }
        if skills.count > failed.count {
            refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
        }
        return failed
    }

    /// True when `skill` was imported — its root path is tracked in
    /// `externalSkillPaths` (a local-folder import or a Git-synced repo skill).
    func isImportedSkill(_ skill: SkillRecord) -> Bool {
        let paths = cachedStandardizedExternalSkillPaths
        guard !paths.isEmpty else { return false }
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        if paths.contains(filePath) { return true }
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        return paths.contains(rootPath)
    }

    /// Filesystem + state mutations for un-importing one skill, WITHOUT
    /// triggering a refresh. See `performSkillDeletion(_:)` for rationale.
    private func performSkillCatalogRemoval(_ skill: SkillRecord) throws {
        guard isImportedSkill(skill) else { throw CocoaError(.fileWriteNoPermission) }

        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let rootURL = skillDeletionTargetURL(for: skill).standardizedFileURL

        // Clear name-based assignments so no dangling missing-skill warning is
        // left behind — same as deletion, minus the trashing.
        try removeSkillReferences(named: skill.name)

        let pathsToRemove = appSettings.externalSkillPaths.filter { rawPath in
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            return path == rootURL.path || path == fileURL.path
        }
        if appSettingsController.removeExternalSkillPaths(pathsToRemove) {
            settings.publish()
        }
        skillRepositories.unlistSkillFromSyncedRepository(skill, deletionTargetURL: skillDeletionTargetURL(for: skill))

        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedSkillIDs.insert(skill.id)
        }
        selectedSkillID = allVisibleSkillRecords.first?.id
    }

    /// Un-import a skill: drop it from the catalog without trashing its files.
    /// For a Git-synced skill the repository clone is kept; the skill is just
    /// un-listed from that repository's synced set.
    func removeSkillFromCatalog(_ skill: SkillRecord) throws {
        try performSkillCatalogRemoval(skill)
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Batch un-import: filesystem work per skill, then a single refresh.
    /// Returns the names of skills whose removal threw.
    func removeSkillsFromCatalog(_ skills: [SkillRecord]) -> [String] {
        var failed: [String] = []
        for skill in skills {
            do { try performSkillCatalogRemoval(skill) }
            catch { failed.append(skill.name) }
        }
        if skills.count > failed.count {
            refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
        }
        return failed
    }

    /// Drop `skill` from its synced repository's tracked set, if it belongs to
    /// one. When that leaves the repository with no synced skills, the whole
    /// repository is un-registered — its record is removed (so it is no longer
    /// polled for updates) and its app-managed clone is deleted.

    func skillIsEnabledGlobally(_ skill: SkillRecord) -> Bool {
        appSettings.defaultSkillNames.contains(skill.name)
    }

    private func moveSkillToGlobalDirectory(_ skill: SkillRecord) throws {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let sourceURL = skillMoveSourceURL(fileURL: fileURL)
        let destinationRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/skills", isDirectory: true)
            .standardizedFileURL
        let destinationURL = destinationRoot.appendingPathComponent(skill.name, isDirectory: true)

        guard !isSymbolicLink(sourceURL), !isSymbolicLink(fileURL) else {
            throw ResourceRenameError.unsupportedResource("Symlinked skills cannot be made Default safely in app. Move the real skill folder to ~/.pi/agent/skills instead.")
        }
        guard sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else { return }
        try ensureGlobalSkillDestinationAvailable(destinationURL, sourceURL: sourceURL)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true, attributes: nil)

        if fileURL.lastPathComponent == "SKILL.md" {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false, attributes: nil)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL.appendingPathComponent("SKILL.md"))
        }
    }

    private func skillMoveSourceURL(fileURL: URL) -> URL {
        if fileURL.lastPathComponent == "SKILL.md" {
            return fileURL.deletingLastPathComponent().standardizedFileURL
        }
        return fileURL.standardizedFileURL
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true ||
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func ensureGlobalSkillDestinationAvailable(_ destinationURL: URL, sourceURL: URL) throws {
        let destination = destinationURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        guard destination.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true).standardizedFileURL.path + "/") else {
            throw ResourceRenameError.unsafePath(destination.path)
        }
        if pathExistsOrIsSymlink(destination), destination.path != source.path {
            throw ResourceRenameError.destinationExists(destination.path)
        }
    }

    func skillIsEnabledForSelectedProject(_ skill: SkillRecord) -> Bool {
        guard let selectedProjectPath else { return false }
        return projectPreference(for: selectedProjectPath).assignedSkillNames.contains(skill.name)
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

    private func promptTemplateCatalog(forProjectPath projectPath: String) -> [PromptTemplateRecord] {
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

    /// Names of the skills actually loaded into the parent session for
    /// `projectPath`: global defaults ∪ project-assigned. This is the exact set
    /// `parentSkillArguments` launches the orchestrator with — the single source
    /// of truth shared by the composer `/` browser's `isActive` flag and the
    /// session-resources popover, so neither recomputes it independently.
    func activeParentSkillNames(forProjectPath projectPath: String?) -> Set<String> {
        var names = appSettings.defaultSkillNames
        if let path = projectPath ?? selectedProjectPath {
            names.formUnion(projectPreference(for: path).assignedSkillNames)
        }
        return names
    }

    /// The resolved `SkillRecord`s actually available to the parent session for
    /// `projectPath` — the active names above, resolved against the same
    /// disabled-bundled-filtered catalog the launch path uses, deduped by name.
    func activeParentSkills(forProjectPath projectPath: String?) -> [SkillRecord] {
        let scopedPath = projectPath ?? selectedProjectPath
        let activeNames = activeParentSkillNames(forProjectPath: scopedPath)
        let catalog: [SkillRecord]
        if let path = scopedPath {
            catalog = skillCatalogForProjectPath( path)
        } else {
            var seen = Set<String>()
            catalog = (globalSnapshot.skills + globalSnapshot.librarySkills).filter { seen.insert($0.id).inserted }
        }
        var seenName = Set<String>()
        return catalog
            .filter { activeNames.contains($0.name) }
            .filter { seenName.insert($0.name).inserted }
    }

    /// Prompt-template analogue of `activeParentSkillNames`: the templates the
    /// parent session is launched with (`parentPromptTemplateArguments`).
    func activeParentPromptTemplateNames(forProjectPath projectPath: String?) -> Set<String> {
        var names = appSettings.defaultPromptTemplateNames
        if let path = projectPath ?? selectedProjectPath {
            names.formUnion(projectPreference(for: path).assignedPromptTemplateNames)
        }
        return names
    }

    /// The resolved `PromptTemplateRecord`s actually available to the parent
    /// session for `projectPath`, deduped by name. Shared by the `/` browser's
    /// `isActive` flag and the session-resources popover.
    func activeParentPromptTemplates(forProjectPath projectPath: String?) -> [PromptTemplateRecord] {
        let scopedPath = projectPath ?? selectedProjectPath
        let activeNames = activeParentPromptTemplateNames(forProjectPath: scopedPath)
        let catalog: [PromptTemplateRecord]
        if let path = scopedPath {
            catalog = promptTemplateCatalog(forProjectPath: path)
        } else {
            catalog = allVisiblePromptTemplateRecords
        }
        var seenName = Set<String>()
        return catalog
            .filter { activeNames.contains($0.name) }
            .filter { seenName.insert($0.name).inserted }
    }

    /// Materializes the full universe of Skills, Prompts, and Commands the
    /// composer's `/` browser can show. Pure in-memory: walks already-cached
    /// scan snapshots + the command catalog. Build once when the panel opens
    /// and hold the result in `@State` — never call inside a SwiftUI `body`,
    /// since command library discovery touches the filesystem.
    func slashUniverse(forProjectPath projectPath: String?) -> SlashUniverse {
        let scopedPath = projectPath ?? selectedProjectPath

        // Skills
        let skillRecords: [SkillRecord]
        if let path = scopedPath {
            skillRecords = skillCatalogForProjectPath( path)
        } else {
            var seen = Set<String>()
            skillRecords = (globalSnapshot.skills + globalSnapshot.librarySkills).filter { seen.insert($0.id).inserted }
        }
        let activeSkillNames = activeParentSkillNames(forProjectPath: scopedPath)
        let disabledBundledSkillNames = appSettings.disabledBundledSkillNames
        var seenSkillName = Set<String>()
        let skills = skillRecords
            .filter { !($0.source.kind == .builtin && disabledBundledSkillNames.contains($0.name)) }
            .filter { seenSkillName.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { record in
                SlashItem(
                    id: "skill:\(record.id)",
                    kind: .skill,
                    displayName: record.name,
                    description: record.description?.isEmpty == false ? record.description : nil,
                    scopeLabel: record.source.displayName,
                    isActive: activeSkillNames.contains(record.name),
                    payload: .skill(name: record.name, body: record.body)
                )
            }

        // Prompts
        let promptRecords: [PromptTemplateRecord]
        if let path = scopedPath {
            promptRecords = promptTemplateCatalog(forProjectPath: path)
        } else {
            promptRecords = allVisiblePromptTemplateRecords
        }
        let activePromptNames = activeParentPromptTemplateNames(forProjectPath: scopedPath)
        let disabledBundledPromptNames = appSettings.disabledBundledPromptNames
        var seenPromptName = Set<String>()
        let prompts = promptRecords
            .filter { !($0.source.kind == .builtin && disabledBundledPromptNames.contains($0.name)) }
            .filter { seenPromptName.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { record in
                SlashItem(
                    id: "prompt:\(record.id)",
                    kind: .prompt,
                    displayName: record.name,
                    description: record.description.isEmpty ? nil : record.description,
                    scopeLabel: record.source.displayName,
                    isActive: activePromptNames.contains(record.name),
                    payload: .prompt(name: record.name, body: record.body)
                )
            }

        // Commands — active only (inactive commands are TypeScript handlers
        // that aren't loaded into the running Pi process, so we can't safely
        // expand them client-side).
        let commands = PiInjectedCommandCatalog.all
            .filter { PiInjectedCommandCatalog.isEnabled($0, settings: appSettings) }
            .sorted { $0.slashName.localizedStandardCompare($1.slashName) == .orderedAscending }
            .map { command in
                SlashItem(
                    id: "command:\(command.id)",
                    kind: .command,
                    displayName: command.title,
                    description: command.description.isEmpty ? nil : command.description,
                    scopeLabel: command.source == .builtIn ? "Built-in" : "Library",
                    isActive: true,
                    payload: .command(slashName: command.slashName, commandID: command.id)
                )
            }

        return SlashUniverse(skills: skills, prompts: prompts, commands: commands)
    }

    private func skillDeletionTargetURL(for skill: SkillRecord) -> URL {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        if fileURL.lastPathComponent == "SKILL.md" {
            return fileURL.deletingLastPathComponent()
        }
        return fileURL
    }

    private func removeSkillReferences(named skillName: String) throws {
        _ = appSettingsController.setDefaultSkill(skillName, enabled: false)
        settings.publish()

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedSkill(skillName, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()

        for agent in snapshot.effectiveAgents where agent.resolved.skills.contains(skillName) {
            guard var draft = makeAgentDraft(for: agent) else { continue }
            draft.config.skills.removeAll { $0 == skillName }
            // Persist without a per-agent refresh — `saveAgentDraft` would
            // trigger a synchronous rescan per agent. The single trailing
            // refresh(scanAllProjects:) in deleteSkill picks up every edit.
            try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        }
    }

    private func removeExternalSkillCatalogReferences(for skill: SkillRecord, deletedTarget: URL) {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let deletedTargetPath = deletedTarget.standardizedFileURL.path
        let pathsToRemove = appSettings.externalSkillPaths.filter { rawPath in
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            return url.path == fileURL.path || url.path == deletedTargetPath
        }
        guard appSettingsController.removeExternalSkillPaths(pathsToRemove) else { return }
        settings.publish()
    }

    private func ensureLibraryAgent(for agent: AgentRecord) throws -> URL {
        let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/agent-library/agents", isDirectory: true)
        let libraryURL = libraryRoot.appendingPathComponent("\(agent.name).md")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: libraryURL.path) { return libraryURL }

        let sourceURL = URL(fileURLWithPath: agent.filePath)
        if agent.source.kind == .global {
            try fileManager.moveItem(at: sourceURL, to: libraryURL)
        } else if agent.source.kind == .library {
            return sourceURL
        } else {
            try fileManager.copyItem(at: sourceURL, to: libraryURL)
        }
        return libraryURL
    }

    private func ensureLibraryPrompt(for prompt: PromptTemplateRecord) throws -> URL {
        let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/prompt-library", isDirectory: true)
        let libraryURL = libraryRoot.appendingPathComponent("\(prompt.name).md")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: libraryURL.path) { return libraryURL }

        let sourceURL = URL(fileURLWithPath: prompt.filePath)
        if prompt.source.kind == .global {
            try fileManager.moveItem(at: sourceURL, to: libraryURL)
        } else if prompt.source.kind == .library {
            return sourceURL
        } else {
            try fileManager.copyItem(at: sourceURL, to: libraryURL)
        }
        return libraryURL
    }

    func makeEnvDraft(for record: EnvKeyRecord) -> EnvEditorDraft {
        envPersistence.makeDraft(for: record)
    }

    func makeNewEnvDraft(scope: AgentEditingTarget.CustomAgentScope, prefilledKey: String? = nil) -> EnvEditorDraft {
        envPersistence.makeNewDraft(scope: scope, projectRoot: selectedProjectPath, prefilledKey: prefilledKey)
    }

    func saveEnvDrafts(_ drafts: [EnvEditorDraft]) throws {
        guard !drafts.isEmpty else { return }
        // A batch may target both the project and the global file, so refresh
        // every distinct destination once. Recording inside the loop and
        // refreshing in `defer` keeps refreshes running for files already
        // written even if a later save throws.
        var written: [(scope: ResourceScopeKind, path: String)] = []
        defer {
            for file in written {
                refreshAfterFileScopedChange(sourceKind: file.scope, filePath: file.path)
            }
        }
        for draft in drafts {
            try envPersistence.save(draft)
            if !written.contains(where: { $0.path == draft.path }) {
                written.append((draft.scope, draft.path))
            }
        }
    }

    func deleteEnvKey(_ record: EnvKeyRecord) throws {
        try envPersistence.delete(record)
        refreshAfterFileScopedChange(sourceKind: record.source.kind, filePath: record.source.path)
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

    func warnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        // Cache hit (incl. an empty array) is authoritative — see
        // `rebuildWarningCaches()`. Miss → live compute (e.g. before first scan).
        if let cached = cachedAgentWarningsByID[agent.id] { return cached }
        return computeWarnings(for: agent)
    }

    private func computeWarnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        snapshot.warnings.filter { warning in
            warning.message.contains("Agent \(agent.name) ") || warning.message.contains("Agent \(agent.name)")
        }
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

    private func refreshAfterAgentDraftChange(_ draft: AgentEditorDraft) {
        switch draft.target {
        case let .custom(scope):
            guard scope == .project else {
                // Global agent edit (incl. setSkill→saveAgentDraft toggle) —
                // `patchEffectiveAgentSkills` already updated the in-memory
                // snapshot, so this scan is reconciliation only.
                refresh(includeModels: false, silentlyReconcile: true)
                return
            }
            refreshAfterProjectScopedChange(projectPath: draft.sourcePath.flatMap(projectPath(containing:)) ?? selectedProjectPath)
        case let .builtinOverride(scope):
            refreshAfterOverrideChange(scope: scope)
        }
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

    private func defaultCustomScope(for agent: EffectiveAgentRecord) -> AgentEditingTarget.CustomAgentScope {
        if agent.projectCustom != nil || agent.projectOverride != nil || (agent.projectRoot != nil && selectedProjectPath != nil) {
            return .project
        }
        return .global
    }

    private func duplicatedName(for name: String) -> String {
        let existingNames = Set(snapshot.effectiveAgents.map(\.name))
        var candidate = "\(name)-copy"
        var index = 2
        while existingNames.contains(candidate) {
            candidate = "\(name)-copy-\(index)"
            index += 1
        }
        return candidate
    }

    private func deduplicateByID<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        return values.filter { seen.insert($0.id).inserted }
    }

}
