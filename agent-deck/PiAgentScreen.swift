import AppKit
import Combine
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pi Agent session screen

struct PiAgentScreen: View {
    var viewModel: AppViewModel
    var store: PiAgentSessionStore
    @Binding var sessionSearchText: String
    @State private var composerText = ""
    @State private var composerSuggestionIndex = 0
    @State private var composerSuggestionsDismissed = false
    @State private var composerSuggestionScrollTick = 0
    @State private var composerSuggestionHoverSuppressedUntil = Date.distantPast
    @State private var fileSuggestionResults: [PiAgentFileSuggestion] = []
    @State private var fileScanTask: Task<Void, Never>?
    /// Cached slash universe. Built once when the `/` panel opens (off the body
    /// hot path, in `.onChange`) and reused for the whole interaction so neither
    /// typing nor scrolling re-walks the catalog.
    @State private var slashUniverse: SlashUniverse = .empty
    @State private var slashState = SlashSuggestionState()
    /// The picked slash item — when non-nil, the composer shows it as a glass
    /// capsule chip above the editor and includes it in the send payload.
    @State private var slashSelection: SlashItem?
    @State private var lastSlashTriggerActive = false
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var selectedSessionTitleDraft = ""
    @State private var renamingSessionID: UUID?
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var lastSelectedSessionID: UUID?
    @State private var pendingDeleteSessionIDs: Set<UUID> = []
    @State private var pendingDeleteIsClearAll = false
    @State private var pendingDeleteClearAllProjects = false
    @State private var pendingDeleteProjectName: String?
    @State private var isDeleteSessionsAlertPresented = false
    @State private var composerPasteAttachments: [PiAgentPasteAttachment] = []
    @State private var nextComposerPasteID = 1
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerFolders: [PiAgentFolderAttachment] = []
    @State private var composerIssueAttachment: PiAgentIssueAttachment?
    @State private var composerAttachmentError: String?
    @State private var composerHistoryIndex: Int?
    @State private var composerHistoryDraft = ""
    @State private var selectedSubagentTranscriptRunID: UUID?
    @State private var selectedSubagentGraphRunID: UUID?
    // Owned but NOT observed: `@State` (not `@StateObject`) holds the cache for the
    // view's lifetime without subscribing `PiAgentScreen.body` to its
    // `objectWillChange`. The cache pulses `streamingRevision` ~30Hz while a session
    // streams; subscribing the whole screen re-evaluated the session list + composer
    // on every pulse (the SessionListContent re-eval storm). Only the extracted
    // `PiAgentTranscriptHost` child takes the cache as `@ObservedObject`, so the
    // pulse now re-renders the transcript table alone. The cache is driven entirely
    // by `store.*`-keyed `.task`/`.onChange` triggers, which the parent still
    // observes — so dropping the subscription doesn't miss any update.
    @State private var transcriptCache = PiAgentTranscriptRenderCache()
    @State private var transcriptBottomScrollRequest = 0
    // Pinned-to-bottom lives in its own ObservableObject, held by `@State` so this
    // screen's body watches only the reference identity — NOT `isPinned`. Scrolling
    // flips `isPinned` ~constantly; if the screen body read it directly, every flip
    // would re-evaluate the whole body and re-run the O(N) `appKitTranscriptItems`
    // build (the `itemsBuild` scroll cost). Only `JumpToLatestOverlay` `@ObservedObject`s
    // it, so a flip re-renders just the pill, leaving the transcript host untouched.
    @State private var transcriptPinnedState = TranscriptPinnedState()
    @State private var showArchivedPreCompactionTranscript = false
    @State private var isEarlierTranscriptSheetPresented = false
    @State private var cachedVisibleSessions: [PiAgentSessionRecord] = []
    @State private var hasBuiltVisibleSessions = false
    /// Per-session derived git activity (commit/push/merge timestamps), keyed by
    /// session.id. Rebuilt off the body hot path on transcript-revision or
    /// visible-set changes — never recomputed inline in row `body` to avoid
    /// jank (see `[[feedback_performance_sensitive]]`).
    @State private var sessionActivityCache: [UUID: PiAgentSessionGitActivity] = [:]
    @State private var isUIRequestSheetPresented = false
    @State private var frozenRuntimeFooterSession: PiAgentSessionRecord?
    @State private var stabilizedProcessingMessage: String?
    @State private var processingMessageUpdateTask: Task<Void, Never>?

    // Keep long sessions cheap to relayout when side panels open; older visible items remain accessible separately.
    private let recentTranscriptTimelineItemLimit = 50

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                sessionsColumn
                    .frame(minWidth: 190, idealWidth: 250, maxWidth: 360)

                activeSessionColumn
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            syncVisibleSessionSelection()
            syncMultiSelectionToSelectedSession()
            syncRuntimeFooterSnapshot()
            syncSelectedSessionTitleDraft()
            isUIRequestSheetPresented = store.selectedUIRequest != nil
            rebuildVisibleSessions()
            resetTranscriptAutoScroll()
            // Kick the load synchronously on appear so `isSelectedTranscriptLoading`
            // flips to true before the first render — otherwise the transcript area
            // is briefly blank (no loading card, no content) until the deferred task
            // runs after Task.yield.
            store.requestSelectedTranscriptLoad()
            requestSelectedTranscriptLoadAfterViewUpdate()
            viewModel.rehydratePiAgentTranscriptIfNeeded(store.selectedSession?.id)
            updateStabilizedProcessingMessage(selectedSessionProcessingMessage)
            Task { @MainActor in
                await Task.yield()
                viewModel.acknowledgeVisibleSelectedPiAgentSession()
                scheduleTranscriptCacheUpdate()
                viewModel.prepareRepoChangesForSelectedPiAgentSession()
            }
        }
        .onChange(of: store.sessionListRevision) { _, _ in rebuildVisibleSessions() }
        .onChange(of: sessionSearchText) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.showPiAgentAttentionOnly) { _, _ in rebuildVisibleSessions() }
        .onDisappear {
            processingMessageUpdateTask?.cancel()
            processingMessageUpdateTask = nil
        }
        .sheet(isPresented: uiRequestSheetBinding) {
            if let request = store.selectedUIRequest {
                PiAgentUIRequestSheet(
                    request: request,
                    onSubmitValue: { value in viewModel.respondToPiAgentUIRequest(request, value: value) },
                    onSubmitFreeform: { sentinel, value in viewModel.respondToPiAgentFreeformUIRequest(request, sentinel: sentinel, value: value) },
                    onConfirm: { confirmed in viewModel.confirmPiAgentUIRequest(request, confirmed: confirmed) },
                    onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                )
            }
        }
        .onChange(of: store.selectedUIRequest?.id) { _, newID in
            isUIRequestSheetPresented = newID != nil
        }
        .onChange(of: store.selectedSession?.id) { oldID, newID in
            renamingSessionID = nil
            syncSelectedSessionTitleDraft()
            if let newID, !selectedSessionIDs.contains(newID) {
                syncMultiSelectionToSelectedSession()
            } else if newID == nil {
                selectedSessionIDs = []
                lastSelectedSessionID = nil
            }
            resetTranscriptAutoScroll()
            showArchivedPreCompactionTranscript = false
            isEarlierTranscriptSheetPresented = false
            syncRuntimeFooterSnapshot()
            requestSelectedTranscriptLoadAfterViewUpdate()
            viewModel.rehydratePiAgentTranscriptIfNeeded(newID)
            Task { @MainActor in
                await Task.yield()
                scheduleTranscriptCacheUpdate()
                viewModel.prepareRepoChangesForSelectedPiAgentSession()
            }
        }
        .onChange(of: store.selectedSession?.status.isActive) { _, _ in
            syncRuntimeFooterSnapshot()
        }
        .onChange(of: store.selectedSession?.title) { _, _ in syncSelectedSessionTitleDraft() }
        .onChange(of: visibleSessionIDs) { _, _ in
            syncVisibleSessionSelection()
            pruneMultiSelectionToVisibleSessions()
            rebuildSessionActivityCache()
        }
        .onChange(of: store.transcriptRevisionsBySessionID) { _, _ in
            rebuildSessionActivityCache()
        }
        .onChange(of: viewModel.selectedProjectPath) { _, _ in
            rebuildVisibleSessions()
            syncVisibleSessionSelection()
            Task { @MainActor in
                await Task.yield()
                viewModel.acknowledgeVisibleSelectedPiAgentSession()
            }
        }
        .task(id: store.selectedTranscriptRevision) {
            await Task.yield()
            scheduleTranscriptCacheUpdate()
        }
        .sheet(item: selectedSubagentTranscriptBinding) { run in
            PiNativeSubagentTranscriptSheet(
                run: run,
                entries: store.cachedSubagentTranscript(for: run.id),
                visibility: viewModel.appSettings.piAgentTranscriptVisibility
            )
            .onAppear {
                requestSubagentTranscriptLoadAfterViewUpdate(runID: run.id)
            }
        }
        .sheet(isPresented: $isEarlierTranscriptSheetPresented) {
            earlierTranscriptSheet
        }
        .sheet(item: selectedSubagentGraphBinding) { run in
            PiNativeSubagentGraphSheet(
                run: run,
                onStopGraph: { viewModel.stopNativeSubagentGraph(runID: run.id, parentSessionID: run.parentSessionID) },
                onStopChild: { child in viewModel.stopNativeSubagentGraphChild(graphRunID: run.id, childID: child.id, parentSessionID: run.parentSessionID) },
                onRetryChild: { child in viewModel.retryNativeSubagentGraphChild(graphRunID: run.id, childID: child.id, parentSessionID: run.parentSessionID) },
                onOpenChildArtifacts: { child in if let path = child.artifactDirectory { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
            )
        }
        .alert(deleteSessionsAlertTitle, isPresented: $isDeleteSessionsAlertPresented) {
            Button(pendingDeleteIsClearAll ? "Clear" : "Delete", role: .destructive, action: deletePendingSessions)
            Button("Cancel", role: .cancel) {
                resetPendingSessionDelete()
            }
        } message: {
            Text(deleteSessionsAlertMessage)
        }
    }

    private var piAgentNewSessionProjects: [DiscoveredProject] {
        viewModel.enabledProjects.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var sessionScopePath: String? {
        viewModel.selectedProjectPath
    }

    private var scopedSessions: [PiAgentSessionRecord] {
        guard let sessionScopePath else { return store.sessions }
        return store.sessions.filter { $0.projectPath == sessionScopePath }
    }

    private var visibleSessions: [PiAgentSessionRecord] {
        hasBuiltVisibleSessions ? cachedVisibleSessions : computedVisibleSessions()
    }

    private func rebuildVisibleSessions() {
        let next = computedVisibleSessions()
        // Only write @State when the visible list actually changed. A bare
        // `sessionListRevision` bump (e.g. a background re-sort/refresh while the
        // user is just scrolling the transcript) otherwise re-evaluates the whole
        // screen body and re-runs the transcript's updateNSView for nothing.
        if !hasBuiltVisibleSessions || next != cachedVisibleSessions {
            cachedVisibleSessions = next
        }
        hasBuiltVisibleSessions = true
    }

    private func computedVisibleSessions() -> [PiAgentSessionRecord] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = viewModel.showPiAgentAttentionOnly ? scopedSessions.filter(\.needsAttention) : scopedSessions
        let filtered = query.isEmpty ? source : source.filter { sessionMatchesSearch($0, query: query) }
        return sortedSessions(filtered)
    }

    private var visibleSessionIDs: [UUID] {
        visibleSessions.map(\.id)
    }

    private func rebuildSessionActivityCache() {
        var fresh: [UUID: PiAgentSessionGitActivity] = [:]
        for session in visibleSessions {
            let entries = store.transcriptsBySessionID[session.id] ?? []
            let activity = piAgentSessionGitActivity(from: entries)
            if activity.hasCommit || activity.hasPush || activity.hasMerge {
                fresh[session.id] = activity
            }
        }
        if fresh != sessionActivityCache {
            sessionActivityCache = fresh
        }
    }

    private var deleteSessionsAlertTitle: String {
        if pendingDeleteIsClearAll {
            if pendingDeleteClearAllProjects { return "Clear all Pi Agent sessions?" }
            let projectName = pendingDeleteProjectName ?? "this project"
            return "Clear Pi Agent sessions for \(projectName)?"
        }
        return pendingDeleteSessionIDs.count == 1 ? "Delete Pi Agent session?" : "Delete \(pendingDeleteSessionIDs.count) Pi Agent sessions?"
    }

    private var deleteSessionsAlertMessage: String {
        if pendingDeleteIsClearAll {
            if pendingDeleteClearAllProjects {
                return "This removes all Pi Agent sessions and their local transcripts for every project from \(AppBrand.displayName)."
            }
            let projectName = pendingDeleteProjectName ?? "the current project"
            return "This removes all Pi Agent sessions and their local transcripts for \(projectName) from \(AppBrand.displayName). Other projects are not affected."
        }
        return pendingDeleteSessionIDs.count == 1
            ? "This removes the selected Pi Agent session and its local transcript from \(AppBrand.displayName)."
            : "This removes the selected Pi Agent sessions and their local transcripts from \(AppBrand.displayName)."
    }

    private var sessionDeleteTargets: Set<UUID> {
        if !selectedSessionIDs.isEmpty {
            return selectedSessionIDs
        }
        if let selectedID = store.selectedSession?.id {
            return [selectedID]
        }
        return []
    }

    private var uiRequestSheetBinding: Binding<Bool> {
        Binding(
            get: { isUIRequestSheetPresented && store.selectedUIRequest != nil },
            set: { isPresented in
                if isPresented {
                    isUIRequestSheetPresented = true
                } else {
                    isUIRequestSheetPresented = false
                }
            }
        )
    }


    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 6) {
                    Text("Sessions")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer()
                    if selectedSessionIDs.count > 1 {
                        Button(role: .destructive) {
                            requestDeleteSessions(selectedSessionIDs)
                        } label: {
                            Image(systemName: "trash.fill")
                                .font(AppTheme.Font.body.weight(.semibold))
                                .foregroundStyle(Color.red)
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.red.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help("Delete selected sessions")
                        .accessibilityLabel("Delete selected sessions")
                    }
                    if viewModel.appSettings.nativeSubagentsEnabledForNewSessions {
                        PiAgentChatWithAgentButton(viewModel: viewModel)
                    }
                    if viewModel.selectedDiscoveredProject == nil {
                        PiAgentAddSessionMenuButton(
                            projects: piAgentNewSessionProjects,
                            selectedProject: viewModel.selectedDiscoveredProject,
                            action: { viewModel.createPiAgentDraftForSelectedProject() },
                            onSelectProject: { project in
                                viewModel.createPiAgentDraft(for: project)
                            }
                        )
                    } else {
                        PiAgentAddSessionButton(
                            action: { viewModel.createPiAgentDraftForSelectedProject() }
                        )
                    }
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 18)

            if scopedSessions.isEmpty {
                AppEmptyState(
                    "No sessions yet",
                    systemImage: "square.and.pencil",
                    description: emptySessionsMessage,
                    layout: .fill
                )
            } else {
                VStack(spacing: 10) {
                    if visibleSessions.isEmpty {
                        AppEmptyState("No sessions found", systemImage: "magnifyingglass", description: "Try another search.", layout: .fill)
                    } else {
                        SessionListContent(
                            visibleSessions: visibleSessions,
                            selectedSessionIDs: selectedSessionIDs,
                            renamingSessionID: renamingSessionID,
                            workingSessionIDs: workingVisibleSessionIDs,
                            generatingTitleIDs: viewModel.piAgentTitleGeneratingSessionIDs,
                            activityByID: visibleSessionActivityByID,
                            projectsByID: visibleSessionProjectsByID,
                            selection: $selectedSessionIDs,
                            onSelect: { session in
                                renamingSessionID = nil
                                selectSessionFromList(session)
                            },
                            onBeginRename: { session in
                                selectSessionFromList(session, forceSingle: true)
                                renamingSessionID = session.id
                            },
                            onEndRename: { renamingSessionID = nil },
                            onRename: { viewModel.renamePiAgentSession($0, title: $1) },
                            onTogglePinned: { viewModel.togglePiAgentSessionPinned($0) },
                            onDelete: { id in
                                requestDeleteSessions(
                                    selectedSessionIDs.contains(id) && selectedSessionIDs.count > 1
                                        ? selectedSessionIDs
                                        : [id]
                                )
                            }
                        )
                        .equatable()
                    }
                }
            }
        }
        .background(Color.clear)
    }

    // Per-row dynamic state resolved up front so the session list can be an
    // Equatable view (see SessionListContent): comparing these resolved values is
    // what lets a streaming-cadence body re-eval skip the list unless a row's
    // contents actually changed. Each iterates only the (cached) visible sessions.
    private var workingVisibleSessionIDs: Set<UUID> {
        Set(visibleSessions.filter { viewModel.piAgentSessionIsWorking($0) }.map(\.id))
    }

    private var visibleSessionActivityByID: [UUID: PiAgentSessionGitActivity] {
        var map: [UUID: PiAgentSessionGitActivity] = [:]
        for session in visibleSessions where sessionActivityCache[session.id] != nil {
            map[session.id] = sessionActivityCache[session.id]
        }
        return map
    }

    private var visibleSessionProjectsByID: [UUID: DiscoveredProject?] {
        var map: [UUID: DiscoveredProject?] = [:]
        for session in visibleSessions {
            map[session.id] = viewModel.projectByPath[session.projectPath]
        }
        return map
    }

    private var activeSessionColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                transcript
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 18)
                    .transcriptEdgeFade()

                // Sits ON TOP of the edge fade (added after it) so the pill
                // itself is never faded out. Isolated in its own view that observes
                // `transcriptPinnedState` so toggling the pill never re-evaluates this
                // screen's body (and never re-runs the transcript items build).
                JumpToLatestOverlay(pinnedState: transcriptPinnedState) {
                    requestTranscriptBottomScroll()
                }
            }

            PiAgentProcessingIndicatorBar(message: stabilizedProcessingMessage)

            Divider()

            VStack(spacing: 12) {
                if let session = store.selectedSession,
                   session.status == .draft,
                   session.subagentsEnabled {
                    PiAgentSessionSubagentPickerCard(viewModel: viewModel, session: session)
                        .id(session.id)
                }

                if let request = store.selectedUIRequest {
                    PiAgentUIRequestInlineNotice(
                        request: request,
                        onRespond: { isUIRequestSheetPresented = true },
                        onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                    )
                }

                PiAgentComposerPanel(
                    viewModel: viewModel,
                    store: store,
                    onWillSend: beginTranscriptAutoScrollTurn,
                    onDidSend: requestTranscriptBottomScroll
                )
                .equatable()
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var sessionHeader: some View {
        if let session = store.selectedSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AppLabelTag(text: session.kind.rawValue, color: sessionKindTagColor(session.kind))
                    if session.isAgentBound, let agentName = session.agentName, !agentName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .font(AppTheme.Font.caption2.weight(.semibold))
                            Text("Chat with \(agentName)")
                                .font(AppTheme.Font.footnote.weight(.semibold))
                        }
                        .foregroundStyle(AppTheme.brandAccent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(AppTheme.brandAccent.opacity(0.12)))
                    }
                    AppLabelTag(text: effectiveStatus(for: session), color: effectiveStatusColor(for: session))
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(AppTheme.Font.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 0)
                }
                TextField("Session name", text: $selectedSessionTitleDraft)
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                    .fontWidth(.expanded)
                    .lineLimit(1)
                    .onSubmit(commitSelectedSessionRename)
                    .onDisappear(perform: commitSelectedSessionRename)

                if let error = session.lastError {
                    Text(error)
                        .font(AppTheme.Font.footnote)
                        .foregroundStyle(.red)
                }
            }
        } else {
            AppCard(title: "No Session Selected") {
                Text("Select a session from the left, or create a new draft for the selected project.")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    private var transcript: some View {
        // `PiAgentTranscriptHost` is the ONLY view that observes `transcriptCache`,
        // so the ~30Hz streaming pulse re-renders the transcript table alone and no
        // longer invalidates this screen's session list / composer. `makeItems` is
        // re-run inside the host on each pulse; it reads the live cache + parent
        // references (store/viewModel), so the items stay correct even though the
        // parent struct it captured isn't re-evaluated between pulses.
        PiAgentTranscriptHost(
            cache: transcriptCache,
            sessionID: store.selectedSession?.id,
            bottomScrollRequest: transcriptBottomScrollRequest,
            makeItems: { appKitTranscriptItems },
            onPinnedToBottomChange: { isPinnedToBottom in
                transcriptPinnedState.isPinned = isPinnedToBottom
            },
            onBenchAdvanceSession: { viewModel.selectNextPiAgentSession() },
            benchSessionCount: { viewModel.scopedPiAgentSessionsInOrder().count }
        )
        .onChange(of: selectedSessionProcessingMessage) { _, message in
            updateStabilizedProcessingMessage(message)
            guard message != nil, transcriptPinnedState.isPinned else { return }
            requestTranscriptBottomScroll()
        }
        .perfScene("PiAgentTranscript")
    }

    private var appKitTranscriptItems: [PiAgentAppKitTranscriptItem] {
        TranscriptScrollProfiler.measureBody("itemsBuild") {
            // `makeItems` is re-run on every host body pass — cache pulses, but also
            // scroll-time re-evaluations that don't change the transcript at all.
            // Skip the O(N) rebuild when no input changed: compute a cheap signature
            // and reuse the last array on a match. The signature reads every input the
            // build does, so it can never serve stale content.
            let signature = appKitTranscriptItemsSignature
            if transcriptCache.memoizedTranscriptItemsSignature == signature {
                return transcriptCache.memoizedTranscriptItems
            }
            let items = appKitTranscriptItemsBuild
            transcriptCache.memoizedTranscriptItems = items
            transcriptCache.memoizedTranscriptItemsSignature = signature
            return items
        }
    }

    /// COMPLETE signature of every input `appKitTranscriptItemsBuild` reads.
    /// `renderRevision`/`streamingRevision` cover all transcript content (threads).
    /// `appKitTranscript{Chrome,ThreadContext}Revision` are the SAME hashes the build
    /// folds into each row's `contentRevision`, so reusing them here captures the
    /// session-level inputs (status, worktree/project, loading, visibility, skills,
    /// subagent summary) without re-listing them — and can't drift if those helpers
    /// gain a read. The tail adds the few inputs those revisions don't cover.
    private var appKitTranscriptItemsSignature: Int {
        let snapshot = transcriptTimelineSnapshot
        var hasher = Hasher()
        hasher.combine(transcriptCache.renderRevision)
        hasher.combine(transcriptCache.streamingRevision)
        hasher.combine(appKitTranscriptChromeRevision(snapshot: snapshot))
        hasher.combine(appKitTranscriptThreadContextRevision(snapshot: snapshot))
        hasher.combine(showArchivedPreCompactionTranscript)
        if let session = store.selectedSession {
            hasher.combine(session.commandInvocations)         // slash-command chrome
            hasher.combine(session.forkedFromParentTitle)      // fork-origin card
            hasher.combine(session.forkedFromSessionID)
            hasher.combine(session.forkedFromTranscriptSnapshot)
            // Full run/request records (the chrome revisions only hash a summary):
            // a card/notice reflects the whole record, so hash all of it.
            for run in store.subagentRuns(for: session.id) { hasher.combine(run) }
            for request in store.supervisorRequests(for: session.id) { hasher.combine(request) }
        }
        return hasher.finalize()
    }

    private var appKitTranscriptItemsBuild: [PiAgentAppKitTranscriptItem] {
        let timelineSnapshot = transcriptTimelineSnapshot
        let timelineItems = timelineSnapshot.mainVisibleItems
        let chromeRevision = appKitTranscriptChromeRevision(snapshot: timelineSnapshot)
        let contextRevision = appKitTranscriptThreadContextRevision(snapshot: timelineSnapshot)
        let visibility = viewModel.appSettings.piAgentTranscriptVisibility
        let skills = visibleSkillsForSelectedSession
        let commandSlashNames = Set((store.selectedSession?.commandInvocations ?? []).map { name in
            name.hasPrefix("/") ? String(name.dropFirst()) : name
        })
        let subagentRuns = nativeSubagentRunsByID

        var descriptors: [PiAgentTranscriptBlockDescriptor] = []

        // --- Chrome rows (each its own revision) ---
        if let session = store.selectedSession {
            if visibility.showShortcutsStrip {
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "shortcuts-strip-\(session.id.uuidString)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeShortcutsStripView.self) { view, width in view.configure(width: width) }),
                    baseRevision: 0,
                    estimatedContentHeight: { _ in 40 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            if let parentTitle = session.forkedFromParentTitle, !parentTitle.isEmpty {
                let parentID = session.forkedFromSessionID
                let snapshot = session.forkedFromTranscriptSnapshot
                let storeRef = store
                let onSelect: (UUID) -> Void = { parentSessionID in
                    storeRef.select(parentSessionID)
                }
                var hasher = Hasher()
                hasher.combine(parentTitle)
                hasher.combine(parentID)
                hasher.combine(snapshot)
                let forkPayload = NativeForkOriginPayload.make(
                    parentTitle: parentTitle, parentSessionID: parentID,
                    transcriptSnapshot: snapshot, onSelectParent: onSelect)
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "fork-origin-\(session.id.uuidString)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeForkOriginCardView.self) { view, width in
                        view.configure(payload: forkPayload, width: width)
                    }),
                    baseRevision: hasher.finalize(),
                    estimatedContentHeight: { _ in 70 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            // The final system prompt is no longer a transcript card — it's a
            // toolbar button (next to Plan / Session Resources / Transcript Display)
            // that opens the same text popover. See `piAgentPrimaryToolbarContent`.
            for request in store.supervisorRequests(for: session.id).filter({ $0.status == .pending }) {
                let supervisorPayload = NativeSupervisorPayload.make(
                    request: request,
                    onRespond: { response in viewModel.respondToSubagentSupervisorRequest(request.id, parentSessionID: session.id, response: response) },
                    onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: session.id) }
                )
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "supervisor-request-\(request.id)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeSupervisorCardView.self) { view, width in
                        view.configure(payload: supervisorPayload, width: width)
                    }),
                    baseRevision: request.hashValue,
                    estimatedContentHeight: { _ in 180 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
        }

        if let archive = timelineSnapshot.preCompactionArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.compactedAt)
            let isShowing = showArchivedPreCompactionTranscript
            let archivePayload = NativeArchiveNoticePayload.preCompaction(
                hiddenCount: archive.hiddenCount, compactedAt: archive.compactedAt,
                isShowing: isShowing, onToggle: { showArchivedPreCompactionTranscript.toggle() })
            hasher.combine(isShowing)
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pre-compaction-archive",
                view: nil,
                kind: .native(.of(PiAgentNativeArchiveNoticeView.self) { view, width in
                    view.configure(payload: archivePayload, width: width)
                }),
                baseRevision: hasher.finalize(),
                estimatedContentHeight: { _ in 60 },
                threadID: nil,
                isThreadQuestion: false
            ))
        }
        if let archive = timelineSnapshot.recentWindowArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.limit)
            let recentPayload = NativeArchiveNoticePayload.recentWindow(
                hiddenCount: archive.hiddenCount, limit: archive.limit,
                onOpen: { isEarlierTranscriptSheetPresented = true })
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "recent-window-archive",
                view: nil,
                kind: .native(.of(PiAgentNativeArchiveNoticeView.self) { view, width in
                    view.configure(payload: recentPayload, width: width)
                }),
                baseRevision: hasher.finalize(),
                estimatedContentHeight: { _ in 60 },
                threadID: nil,
                isThreadQuestion: false
            ))
        }

        // --- Timeline rows: each thread flattens into one row per block ---
        if store.isSelectedTranscriptLoading && timelineItems.isEmpty {
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pi-agent-transcript-state-card",
                view: nil,
                kind: .native(.of(PiAgentNativeStateCardView.self) { view, width in
                    view.configure(payload: .loading(), width: width)
                }),
                baseRevision: chromeRevision,
                estimatedContentHeight: { _ in 80 },
                threadID: nil,
                isThreadQuestion: false
            ))
        } else if timelineItems.isEmpty && descriptors.isEmpty {
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pi-agent-transcript-state-card",
                view: nil,
                kind: .native(.of(PiAgentNativeStateCardView.self) { view, width in
                    view.configure(payload: .empty(), width: width)
                }),
                baseRevision: chromeRevision,
                estimatedContentHeight: { _ in 120 },
                threadID: nil,
                isThreadQuestion: false
            ))
        } else {
            for item in timelineItems {
                switch item.kind {
                case let .thread(thread):
                    if let question = thread.question {
                        let blockID = "q-\(item.id)"
                        // Native fast path for plain-text questions (no attachment
                        // Chip-bearing questions use the dedicated chip-aware card;
                        // plain questions use the lighter bubble.
                        let hasChips = PiAgentUserMessageContent.displayChipsNaturalWidth(
                            for: question, skills: skills, commandSlashNames: commandSlashNames) > 0
                        let questionKind = hasChips
                            ? nativeChipQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames)
                            : nativeQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames)
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: blockID,
                            view: nil,
                            kind: questionKind,
                            baseRevision: appKitQuestionBlockRevision(question, contextRevision: contextRevision),
                            estimatedContentHeight: { Self.estimatedQuestionHeight(question, width: $0) },
                            threadID: item.id,
                            isThreadQuestion: true
                        ))
                    }
                    for child in PiAgentTranscriptThreadCard.visibleChildren(
                        of: thread, visibility: visibility, nativeSubagentRunsByID: subagentRuns
                    ) {
                        // Native rendering for the supported child types; the
                        // rest (tool groups, subagent/memory cards) still hosted.
                        let nativeKind = nativeChildKind(
                            for: child, visibility: visibility, skills: skills,
                            commandSlashNames: commandSlashNames, subagentRuns: subagentRuns)
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: child.id,
                            view: nil,
                            kind: nativeKind ?? Self.nativeEmptyKind,
                            baseRevision: appKitChildBlockRevision(child, contextRevision: contextRevision),
                            estimatedContentHeight: { Self.estimatedChildHeight(child, width: $0) },
                            threadID: item.id,
                            isThreadQuestion: false
                        ))
                    }
                }
            }
        }

        // Bottom anchor — a 1pt row scrollToBottom can always land on.
        descriptors.append(PiAgentTranscriptBlockDescriptor(
            id: "pi-agent-bottom-anchor",
            view: nil,
            kind: .native(.of(PiAgentNativeSpacerView.self) { _, _ in }),
            baseRevision: 0,
            estimatedContentHeight: { _ in 1 },
            threadID: nil,
            isThreadQuestion: false
        ))

        // --- Inset pass: NSTableView intercell spacing is uniform, so split
        // each inter-row gap in half across the two adjacent rows. Gaps come from
        // the design system: question↔reply (threadSpacing), sibling children
        // (childSpacing), everything else (rowSpacing). ---
        if descriptors.count > 1 {
            for i in 0 ..< descriptors.count - 1 {
                let gap: CGFloat
                if let tid = descriptors[i].threadID, tid == descriptors[i + 1].threadID {
                    gap = descriptors[i].isThreadQuestion ? AppTheme.Chat.threadSpacing : AppTheme.Chat.childSpacing
                } else {
                    gap = AppTheme.Chat.rowSpacing
                }
                descriptors[i].bottomInset += gap / 2
                descriptors[i + 1].topInset += gap / 2
            }
        }

        // Match the old NSScrollView top inset as an actual row so new/small
        // transcripts do not start inside the SwiftUI top fade before scrolling.
        // Insert after the inter-row gap pass so this adds exactly 18pt and no
        // extra row spacing before the shortcuts/first message.
        descriptors.insert(PiAgentTranscriptBlockDescriptor(
            id: "pi-agent-top-fade-spacer",
            view: nil,
            kind: .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 18 }),
            baseRevision: 0,
            estimatedContentHeight: { _ in 18 },
            threadID: nil,
            isThreadQuestion: false
        ), at: 0)

        // --- Materialize: fold insets into the revision (so an inset change
        // re-tiles the row) and into the height estimate. ---
        return descriptors.map { descriptor in
            var revisionHasher = Hasher()
            revisionHasher.combine(descriptor.baseRevision)
            revisionHasher.combine(descriptor.topInset)
            revisionHasher.combine(descriptor.bottomInset)
            let topInset = descriptor.topInset
            let bottomInset = descriptor.bottomInset
            let contentEstimate = descriptor.estimatedContentHeight
            let kind = descriptor.kind ?? Self.nativeEmptyKind
            return PiAgentAppKitTranscriptItem(
                id: descriptor.id,
                kind: kind,
                contentRevision: revisionHasher.finalize(),
                topInset: topInset,
                bottomInset: bottomInset,
                estimatedHeight: { width in contentEstimate(width) + topInset + bottomInset }
            )
        }
    }

    /// Builds one block of a thread (question or a single child) as its own
    /// row view, via `PiAgentTranscriptThreadCard`'s `renderMode` — the card
    /// view is byte-identical to the full-thread rendering, just sliced to one
    /// `ThreadMessageRow`.
    private func threadBlockCard(
        thread: PiAgentTranscriptThread,
        visibility: PiAgentTranscriptVisibilitySettings,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        projectPath: String?,
        subagentRuns: [UUID: PiSubagentRunRecord],
        renderMode: PiAgentTranscriptThreadCard.RenderMode,
        blockID: String
    ) -> some View {
        let viewModel = viewModel
        return PiAgentTranscriptThreadCard(
            thread: thread,
            visibility: visibility,
            skills: skills,
            commandSlashNames: commandSlashNames,
            projectPath: projectPath,
            nativeSubagentRunsByID: subagentRuns,
            nativeSubagentCard: nativeSubagentCard,
            renderMode: renderMode,
            onFork: { entry in viewModel.forkPiAgentSession(from: entry) },
            forkAgentChoices: forkAgentChoicesForSelectedSession,
            onForkAsAgentChat: { entry, agent in
                viewModel.forkPiAgentSessionAsAgentChat(from: entry, agent: agent)
            }
        )
        .id(blockID)
    }

    /// Native payload for a plain-text user question (no attachment chips):
    /// hugged-width right-aligned bubble with leading copy + fork affordance.
    /// Instance method because the fork actions capture `viewModel`.
    /// The fork affordance for a user-question row (Pi session + per-agent chat).
    private func questionForkModel(_ question: PiAgentTranscriptEntry) -> ForkModel {
        let agentOptions: [ForkAgentOption] = (forkAgentChoicesForSelectedSession ?? []).map { agent in
            ForkAgentOption(
                title: agent.name,
                isDisabled: agent.resolved.disabled == true,
                action: { [viewModel] in viewModel.forkPiAgentSessionAsAgentChat(from: question, agent: agent) }
            )
        }
        return ForkModel(
            onForkSession: { [viewModel] in viewModel.forkPiAgentSession(from: question) },
            agentOptions: agentOptions
        )
    }

    /// Native render kind for a chip-bearing user question (skill/command/
    /// attachment chips) — the dedicated chip-aware question card.
    private func nativeChipQuestionKind(
        _ question: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>
    ) -> PiAgentTranscriptCellKind {
        // The ForkModel is cheap (it just wraps closures), so build it eagerly.
        // The payload parse (message text + chip extraction regex + folder
        // existence checks) is deferred into the configure closure so it runs only
        // when a cell actually configures — i.e. for visible rows — instead of for
        // every question on every `itemsBuild` pulse.
        let fork = questionForkModel(question)
        return .native(.of(PiAgentNativeQuestionView.self) { view, width in
            let payload = NativeQuestionPayload.make(
                entry: question, skills: skills, commandSlashNames: commandSlashNames, fork: fork)
            view.configure(payload: payload, width: width)
        })
    }

    private func nativeQuestionKind(
        _ question: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>
    ) -> PiAgentTranscriptCellKind {
        let text = PiAgentUserMessageContent.displayMessageText(
            for: question, skills: skills, commandSlashNames: commandSlashNames)
        let fork = questionForkModel(question)
        return .bubble(NativeBubblePayload(
            role: .user,
            headerTitle: "You",
            iconSymbol: "person.crop.circle",
            markdownSource: text,
            bodyPrefix: nil,
            copyText: question.text,
            copySide: .leading,
            isThreadChild: false,
            isUserHugged: true,
            fork: fork
        ))
    }

    /// Per-block height estimators — character-count math, no SwiftUI pass.
    /// Mirror the heights the old per-thread estimator summed per child.
    private static func estimatedQuestionHeight(_ entry: PiAgentTranscriptEntry, width: CGFloat) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
        return CGFloat(lines) * 18 + 56
    }

    /// Native render kind for a thread child, or nil to fall back to the hosted
    /// SwiftUI path. Tool groups and subagent/memory status cards stay hosted
    /// (later stages); everything else renders natively.
    /// A native 0-height empty row — the safety fallback now that every descriptor
    /// is native (no `.hosted` path remains).
    private static let nativeEmptyKind: PiAgentTranscriptCellKind =
        .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 0 })

    private func nativeChildKind(
        for child: PiAgentThreadChild,
        visibility: PiAgentTranscriptVisibilitySettings,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        subagentRuns: [UUID: PiSubagentRunRecord]
    ) -> PiAgentTranscriptCellKind? {
        switch child {
        case .assistant(let entry):
            if let summary = PiAgentSubagentSummary.cached(for: entry) {
                let payload = NativeSubagentSummaryPayload.make(summary: summary)
                return .native(.of(PiAgentNativeSubagentSummaryView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            return Self.nativeReplyPayload(for: child).map { .bubble($0) }
        case .thinking:
            return Self.nativeReplyPayload(for: child).map { .bubble($0) }
        case .steering(let entry):
            // Chip-bearing steering messages use the native chip-question card,
            // re-labeled as "Steering".
            let hasChips = PiAgentUserMessageContent.displayChipsNaturalWidth(
                for: entry, skills: skills, commandSlashNames: commandSlashNames) > 0
            if hasChips {
                var payload = NativeQuestionPayload.make(
                    entry: entry, skills: skills, commandSlashNames: commandSlashNames, fork: nil)
                payload.headerTitle = "Steering"
                payload.headerIcon = "arrowshape.turn.up.forward.circle"
                return .native(.of(PiAgentNativeQuestionView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let text = PiAgentUserMessageContent.displayMessageText(
                for: entry, skills: skills, commandSlashNames: commandSlashNames)
            return .bubble(NativeBubblePayload(
                role: .user,
                headerTitle: "Steering",
                iconSymbol: "arrowshape.turn.up.forward.circle",
                markdownSource: text,
                bodyPrefix: nil,
                copyText: entry.text,
                copySide: .trailing,
                isThreadChild: true
            ))
        case .status(let entry):
            if let memoryEvent = entry.agentMemoryEvent {
                let payload = NativeMemoryCardPayload.make(event: memoryEvent)
                return .native(.of(PiAgentNativeMemoryCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            if let runID = entry.nativeSubagentRunID, let run = subagentRuns[runID] {
                if NativeSubagentFactory.isParallel(run) {
                    let payload = NativeSubagentParallelPayload.make(
                        run: run,
                        imageStore: viewModel.agentImageStore,
                        onOpenChildTranscript: { [self] in selectedSubagentTranscriptRunID = $0 },
                        onStopChild: { [viewModel] in viewModel.stopNativeSubagent(runID: $0, parentSessionID: run.parentSessionID) }
                    )
                    return .native(.of(PiAgentNativeSubagentParallelCardView.self) { view, width in
                        view.configure(payload: payload, width: width)
                    })
                }
                let payload = NativeAgentBlockPayload.makeSingle(
                    run: run,
                    imageStore: viewModel.agentImageStore,
                    onStop: { [viewModel] in viewModel.stopNativeSubagent(runID: run.id, parentSessionID: run.parentSessionID) },
                    onTranscript: { [self] in selectedSubagentTranscriptRunID = run.id },
                    onReveal: { [self] in revealSubagentRun(run) }
                )
                return .native(.of(PiAgentNativeSubagentRunCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            // "System Prompt Captured" / "Subagent Started" render as a native
            // status row with prompt-audit buttons (computed in make(for:)).
            if entry.isDividerStatus {
                let payload = NativeDividerPayload.make(for: entry)
                return .native(.of(PiAgentNativeStatusDividerView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let payload = NativeStatusPayload.make(for: entry)
            return .native(.of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .error(let entry):
            // Fatal model/provider errors get the richer error row (headline +
            // collapsible italic detail); per-tool failures keep the compact row.
            if entry.isModelError {
                let payload = NativeErrorPayload.make(for: entry)
                return .native(.of(PiAgentNativeErrorRowView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let payload = NativeStatusPayload.make(for: entry)
            return .native(.of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .retry(let entry, let info):
            let payload = NativeRetryPayload.make(info: info, timestamp: entry.timestamp)
            return .native(.of(PiAgentNativeRetryRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .toolGroup(let group):
            guard let model = NativeToolGroupModel.make(
                group: group, visibility: visibility, projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
            ) else {
                // Tool sections all hidden by visibility → an empty 0-height row.
                return .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 0 })
            }
            return .native(.of(PiAgentNativeToolGroupView.self) { view, width in
                view.configure(model: model, width: width)
            })
        }
    }

    /// Maps a thread child to a native bubble payload for the plain-text reply
    /// rows (assistant / thinking). Returns nil for anything that still renders
    /// through the hosted SwiftUI path (subagent summaries, tool groups, status,
    /// errors, retries, steering — handled in later stages).
    private static func nativeReplyPayload(for child: PiAgentThreadChild) -> NativeBubblePayload? {
        switch child {
        case .assistant(let entry):
            if PiAgentSubagentSummary.cached(for: entry) != nil { return nil }
            let text = entry.text
            return NativeBubblePayload(
                role: .assistant,
                headerTitle: "Coding Agent",
                iconSymbol: nil,
                markdownSource: text,
                bodyPrefix: nil,
                copyText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                copySide: .trailing,
                isThreadChild: true
            )
        case .thinking(let entry):
            let display = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return NativeBubblePayload(
                role: .thinking,
                headerTitle: entry.title,
                iconSymbol: "brain.head.profile",
                markdownSource: display.isEmpty ? "Pi has not emitted reasoning text yet." : display,
                bodyPrefix: "Reasoning",
                copyText: display,
                copySide: .trailing,
                isThreadChild: true
            )
        default:
            return nil
        }
    }

    private static func estimatedChildHeight(_ child: PiAgentThreadChild, width: CGFloat) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        switch child {
        case let .assistant(entry), let .steering(entry), let .thinking(entry):
            let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
            return CGFloat(min(lines, 40)) * 18 + 48
        case let .toolGroup(group):
            // One row per activity — a flat estimate made a multi-tool group
            // pop hard the first time it appeared (before the cell re-measures).
            return CGFloat(max(group.activities.count, 1)) * 40 + 16
        case .status, .error, .retry:
            return 56
        }
    }

    /// Content revision for a question block — only that entry + context.
    private func appKitQuestionBlockRevision(_ entry: PiAgentTranscriptEntry, contextRevision: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        hashEntryRevision(entry, into: &hasher)
        return hasher.finalize()
    }

    /// Content revision for a child block — only that child's entry/entries +
    /// context. A sibling streaming does not bump this, so only the streaming
    /// block's row reconfigures.
    private func appKitChildBlockRevision(_ child: PiAgentThreadChild, contextRevision: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        switch child {
        case let .steering(entry), let .thinking(entry), let .assistant(entry),
             let .status(entry), let .error(entry):
            hashEntryRevision(entry, into: &hasher)
        case let .retry(entry, _):
            hashEntryRevision(entry, into: &hasher)
        case let .toolGroup(group):
            hasher.combine(group.id)
            for entry in group.entries { hashEntryRevision(entry, into: &hasher) }
            for activity in group.activities {
                hasher.combine(activity.id)
                hasher.combine(activity.entries.count)
                hashEntryRevision(activity.representativeEntry, into: &hasher)
            }
        }
        return hasher.finalize()
    }

    private func appKitTranscriptChromeRevision(snapshot: PiAgentTranscriptTimelineSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(store.selectedSession?.id)
        hasher.combine(String(describing: store.selectedSession?.status))
        hasher.combine(store.isSelectedTranscriptLoading)
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        return hasher.finalize()
    }

    private func appKitTranscriptThreadContextRevision(snapshot: PiAgentTranscriptTimelineSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        hasher.combine(store.selectedSession.map { $0.worktreePath ?? $0.projectPath })
        if let sessionID = store.selectedSession?.id {
            hasher.combine(store.subagentRuns(for: sessionID).map { "\($0.id):\($0.status):\($0.updatedAt)" })
        }
        return hasher.finalize()
    }

    private func appKitTranscriptContentRevision(
        for item: PiAgentTranscriptTimelineItem,
        snapshot: PiAgentTranscriptTimelineSnapshot,
        contextRevision: Int
    ) -> Int {
        switch item.kind {
        case let .thread(thread):
            let signature = cheapThreadSignature(thread, contextRevision: contextRevision)
            return transcriptCache.cachedThreadRevision(for: thread.id, signature: signature) {
                var hasher = Hasher()
                hasher.combine(contextRevision)
                hashThreadRevision(thread, into: &hasher)
                return hasher.finalize()
            }
        }
    }

    // Cache key for a thread's content revision. Hashes only (id, text.count) per entry —
    // about 3× cheaper than the full revision hash. Covers any mutation upsert/updateEntry
    // can make to a known entry, not just append-only streaming growth, so reusing the
    // cached full hash is safe whenever this signature is unchanged.
    private func cheapThreadSignature(
        _ thread: PiAgentTranscriptThread,
        contextRevision: Int
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        hasher.combine(thread.id)
        inlineEntrySignature(thread.question, into: &hasher)
        hasher.combine(thread.steeringMessages.count)
        for entry in thread.steeringMessages { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.thinkingParts.count)
        for entry in thread.thinkingParts { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.assistantMessages.count)
        for entry in thread.assistantMessages { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.activities.count)
        for activity in thread.activities {
            hasher.combine(activity.id)
            hasher.combine(activity.entries.count)
            inlineEntrySignature(activity.representativeEntry, into: &hasher)
        }
        hasher.combine(thread.statuses.count)
        for entry in thread.statuses { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.errors.count)
        for entry in thread.errors { inlineEntrySignature(entry, into: &hasher) }
        return hasher.finalize()
    }

    private func inlineEntrySignature(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
    }

    private func hashThreadRevision(_ thread: PiAgentTranscriptThread, into hasher: inout Hasher) {
        hasher.combine(thread.id)
        hashEntryRevision(thread.question, into: &hasher)
        thread.steeringMessages.forEach { hashEntryRevision($0, into: &hasher) }
        thread.thinkingParts.forEach { hashEntryRevision($0, into: &hasher) }
        thread.assistantMessages.forEach { hashEntryRevision($0, into: &hasher) }
        thread.activities.forEach { activity in
            hasher.combine(activity.id)
            hasher.combine(activity.entries.count)
            hashEntryRevision(activity.representativeEntry, into: &hasher)
        }
        thread.statuses.forEach { hashEntryRevision($0, into: &hasher) }
        thread.errors.forEach { hashEntryRevision($0, into: &hasher) }
    }

    private func hashEntryRevision(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.title)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
        hasher.combine(entry.timestamp)
    }


    private var loadingTranscriptCard: some View {
        AppRowCard {
            HStack(spacing: 12) {
                AppSpinner()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loading transcript")
                        .font(AppTheme.Font.headline)
                    Text("Restoring the selected chat from disk.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
        }
    }

    private var emptyTranscriptCard: some View {
        AppRowCard {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble")
                    .font(.title2)
                    .foregroundStyle(AppTheme.mutedText)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No transcript yet")
                        .font(AppTheme.Font.headline)
                    Text("Send a message below to launch Pi Agent for this session.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
        }
    }

    private var transcriptTimelineSnapshot: PiAgentTranscriptTimelineSnapshot {
        let items = transcriptTimelineItems
        let archiveRange = preCompactionArchiveRange(in: items)
        let archiveNotice = archiveRange.flatMap { archive -> (hiddenCount: Int, compactedAt: Date)? in
            archive.visibleStartIndex > 0 ? (archive.visibleStartIndex, archive.compactedAt) : nil
        }
        let visibleItems: [PiAgentTranscriptTimelineItem]
        if !showArchivedPreCompactionTranscript, let archiveRange {
            visibleItems = Array(items[archiveRange.visibleStartIndex...])
        } else {
            visibleItems = items
        }
        let earlierVisibleItems: [PiAgentTranscriptTimelineItem]
        let mainVisibleItems: [PiAgentTranscriptTimelineItem]
        if !showArchivedPreCompactionTranscript && visibleItems.count > recentTranscriptTimelineItemLimit {
            earlierVisibleItems = Array(visibleItems.dropLast(recentTranscriptTimelineItemLimit))
            mainVisibleItems = Array(visibleItems.suffix(recentTranscriptTimelineItemLimit))
        } else {
            earlierVisibleItems = []
            mainVisibleItems = visibleItems
        }
        let recentWindowArchive = earlierVisibleItems.isEmpty
            ? nil
            : (hiddenCount: earlierVisibleItems.count, limit: recentTranscriptTimelineItemLimit)
        return PiAgentTranscriptTimelineSnapshot(
            allItems: items,
            visibleItems: visibleItems,
            mainVisibleItems: mainVisibleItems,
            earlierVisibleItems: earlierVisibleItems,
            preCompactionArchive: archiveNotice,
            recentWindowArchive: recentWindowArchive
        )
    }

    private var transcriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        let items = transcriptCache.threads.map { thread in
            PiAgentTranscriptTimelineItem(
                id: "thread-\(thread.id.uuidString)",
                timestamp: thread.timelineTimestamp,
                kind: .thread(thread)
            )
        }
        return items.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
    }

    private var visibleTranscriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        transcriptTimelineSnapshot.mainVisibleItems
    }

    private var preCompactionArchiveNotice: (hiddenCount: Int, compactedAt: Date)? {
        transcriptTimelineSnapshot.preCompactionArchive
    }

    private func preCompactionArchiveRange(in items: [PiAgentTranscriptTimelineItem]) -> (visibleStartIndex: Int, compactedAt: Date)? {
        guard let index = items.indices.last(where: { index in
            guard case let .thread(thread) = items[index].kind else { return false }
            return thread.statuses.contains(where: isCompletedCompactionEntry)
        }) else { return nil }
        return (index, items[index].timestamp)
    }

    private func isCompletedCompactionEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        guard entry.title == "Compaction" else { return false }
        let text = entry.text.localizedLowercase
        return (text.contains("context compacted") || text.contains("compaction complete") || text.contains("compaction finished"))
            && !text.contains("nothing to compact")
            && !text.contains("compacting")
    }

    @ViewBuilder
    private func preCompactionArchiveCard(_ archive: (hiddenCount: Int, compactedAt: Date)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: showArchivedPreCompactionTranscript ? "tray.and.arrow.up" : "archivebox")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(showArchivedPreCompactionTranscript ? "Showing pre-compaction transcript" : "Pre-compaction transcript hidden")
                .font(AppTheme.Font.caption.weight(.semibold))
            Text("\(archive.hiddenCount) earlier item\(archive.hiddenCount == 1 ? "" : "s") before \(archive.compactedAt.formatted(date: .omitted, time: .shortened))")
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
            Spacer(minLength: 0)
            Button(showArchivedPreCompactionTranscript ? "Hide" : "Load Earlier") {
                withAnimation(.snappy(duration: 0.18)) {
                    showArchivedPreCompactionTranscript.toggle()
                }
            }
            .buttonStyle(.borderless)
            .font(AppTheme.Font.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    @ViewBuilder
    private func recentWindowArchiveCard(_ archive: (hiddenCount: Int, limit: Int)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Earlier transcript hidden")
                    .font(AppTheme.Font.caption.weight(.semibold))
                Text("Showing the latest \(archive.limit) items to keep this chat responsive. \(archive.hiddenCount) earlier item\(archive.hiddenCount == 1 ? "" : "s") are available.")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer(minLength: 0)
            Button("Open Earlier Transcript") {
                isEarlierTranscriptSheetPresented = true
            }
            .buttonStyle(.borderless)
            .font(AppTheme.Font.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var earlierTranscriptSheet: some View {
        let snapshot = transcriptTimelineSnapshot
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Earlier Transcript")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text("Messages before the latest \(recentTranscriptTimelineItemLimit) visible items.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button("Done") {
                    isEarlierTranscriptSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView(showsIndicators: false) {
                PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.earlierVisibleItems) { item in
                        transcriptTimelineItemView(item, snapshot: snapshot)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 720)
        .background(AppTheme.windowBackground)
    }

    @ViewBuilder
    private func transcriptTimelineItemView(_ item: PiAgentTranscriptTimelineItem, snapshot: PiAgentTranscriptTimelineSnapshot) -> some View {
        switch item.kind {
        case let .thread(thread):
            PiAgentTranscriptThreadCard(
                thread: thread,
                visibility: viewModel.appSettings.piAgentTranscriptVisibility,
                skills: visibleSkillsForSelectedSession,
                commandSlashNames: Set((store.selectedSession?.commandInvocations ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }),
                projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                nativeSubagentRunsByID: nativeSubagentRunsByID,
                nativeSubagentCard: nativeSubagentCard
            )
            .id(item.id)
        }
    }

    private func updateStabilizedProcessingMessage(_ message: String?) {
        processingMessageUpdateTask?.cancel()
        processingMessageUpdateTask = nil

        guard let message else {
            stabilizedProcessingMessage = nil
            return
        }

        guard stabilizedProcessingMessage != nil else {
            stabilizedProcessingMessage = message
            return
        }

        processingMessageUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            stabilizedProcessingMessage = message
            processingMessageUpdateTask = nil
        }
    }

    private var selectedSessionProcessingMessage: String? {
        guard let session = store.selectedSession,
              session.status.isActive,
              store.selectedUIRequest == nil else { return nil }

        if session.status == .starting { return "Starting Pi" }
        if session.isCompacting { return "Compacting context" }
        if let subagentMessage = runningSubagentsProcessingMessage(for: session) {
            return subagentMessage
        }

        // The RPC-derived activity knows exactly what Pi is doing this instant —
        // it distinguishes a running tool from a finished one and reasoning from
        // an empty turn-start placeholder, neither of which the transcript can.
        if let activity = store.processingActivity(for: session.id) {
            return processingMessage(for: activity)
        }

        // Fallback for a session that is active but has no live activity yet
        // (e.g. just reattached): infer from the last transcript entry.
        if let lastEntry = store.selectedTranscript.last {
            return processingMessage(after: lastEntry)
        }
        return "Working"
    }

    private func processingMessage(for activity: PiAgentProcessingActivity) -> String {
        switch activity {
        case .preparing: return "Preparing response"
        case .reasoning: return "Reasoning"
        case .responding: return "Writing response"
        case let .runningTool(toolName, detail): return toolProcessingMessage(forToolName: toolName, detail: detail)
        case .awaitingModel: return "Working"
        case let .applyingConfigurationChange(summary): return "Changing \(summary)"
        }
    }

    private func processingMessage(after entry: PiAgentTranscriptEntry) -> String? {
        switch entry.role {
        case .assistant:
            return entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Preparing response" : "Writing response"
        case .error, .stderr:
            return "Working"
        case .tool:
            if entry.text.localizedCaseInsensitiveContains("waiting for user input") { return nil }
            return toolProcessingMessage(for: entry)
        case .status:
            return statusProcessingMessage(for: entry)
        case .user:
            switch entry.title {
            case "Steering": return "Applying your steering"
            case "Queued follow-up": return "Queued follow-up"
            default: return "Processing your message"
            }
        case .thinking:
            return "Reasoning"
        case .raw:
            return "Working"
        }
    }

    private func statusProcessingMessage(for entry: PiAgentTranscriptEntry) -> String? {
        switch entry.title {
        case "Input Sent": return "Processing your response"
        case "Input Needed": return nil
        case "Retry": return "Retrying request"
        case "Compaction": return "Compacting context"
        case "Deck Agent Requested": return "Starting Deck agent"
        case "Parallel Deck Agents Requested": return "Starting parallel run"
        case "Supervisor Response Routed": return "Routing response"
        case "System Prompt Captured": return "Preparing context"
        case "Process Ended", "Stopped": return nil
        default: return "Processing update"
        }
    }

    private func toolProcessingMessage(for entry: PiAgentTranscriptEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.hasPrefix("Tool:") else { return "Running tool" }
        let toolName = title.dropFirst("Tool:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return toolProcessingMessage(forToolName: toolName)
    }

    /// Turns a raw Pi tool name (and, when available, its target) into a
    /// human phrase: `edit` + `PiAgentViews.swift` → "Editing PiAgentViews.swift".
    /// Unknown tools fall back to their de-underscored name so a new Pi tool
    /// still reads acceptably without a code change.
    private func toolProcessingMessage(forToolName toolName: String, detail: String? = nil) -> String {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil
        switch name {
        case "bash": return target.map { "Running \($0)" } ?? "Running a command"
        case "read": return target.map { "Reading \($0)" } ?? "Reading a file"
        case "edit": return target.map { "Editing \($0)" } ?? "Editing a file"
        case "write": return target.map { "Writing \($0)" } ?? "Writing a file"
        case "web_search": return target.map { "Searching the web for \($0)" } ?? "Searching the web"
        case "code_search": return target.map { "Searching the code for \($0)" } ?? "Searching the code"
        case "get_search_content", "fetch_content": return "Fetching a page"
        case "update_session_plan", "set_session_plan": return "Updating the plan"
        case "managed_subagent": return "Starting Deck agent"
        case "managed_parallel": return "Starting parallel agents"
        case "ask_user": return "Waiting for your input"
        case "agent_deck_memory_write", "agent_deck_memory_mark_stale": return "Updating memory"
        case "list_supervisor_requests", "answer_supervisor_request": return "Coordinating Deck agents"
        case "": return "Running tool"
        default: return "Running \(name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    private func runningSubagentsProcessingMessage(for session: PiAgentSessionRecord) -> String? {
        let agentNames = runningSubagentNames(for: session)
        guard !agentNames.isEmpty else { return nil }
        let prefix = agentNames.count == 1 ? "Running agent" : "Running agents"
        return "\(prefix): \(formattedRunningAgentList(agentNames))"
    }

    private func runningSubagentNames(for session: PiAgentSessionRecord) -> [String] {
        var names: [String] = []
        for run in store.subagentRuns(for: session.id) where run.status.isActive {
            if run.mode == .parallel, let children = run.children, !children.isEmpty {
                names.append(contentsOf: children
                    .filter { $0.status.isActive }
                    .sorted { $0.index < $1.index }
                    .map(\.agentName))
            } else if let child = run.child, child.status.isActive {
                names.append(child.agentName)
            } else {
                names.append(run.agentName)
            }
        }
        return names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func formattedRunningAgentList(_ names: [String]) -> String {
        let uniqueNames = names.reduce(into: [String]()) { result, name in
            if !result.contains(name) { result.append(name) }
        }
        guard uniqueNames.count > 3 else { return uniqueNames.joined(separator: ", ") }
        return uniqueNames.prefix(3).joined(separator: ", ") + " +\(uniqueNames.count - 3) more"
    }

    private func scheduleTranscriptCacheUpdate() {
        guard let session = store.selectedSession else {
            transcriptCache.scheduleUpdate(sessionID: nil, revision: 0, rawEntries: [])
            return
        }

        // Hydrate the selected transcript before updating the render cache. Small
        // transcripts decode synchronously here (instant, no spinner); large ones are
        // handed to the background loader and return an empty snapshot so the
        // "Loading transcript" card shows instead of hitching the main thread.
        let entries = store.transcriptForCacheUpdate(session.id)
        transcriptCache.scheduleUpdate(
            sessionID: session.id,
            revision: store.selectedTranscriptRevision,
            rawEntries: entries
        )
    }

    private func requestSelectedTranscriptLoadAfterViewUpdate() {
        Task { @MainActor in
            await Task.yield()
            store.requestSelectedTranscriptLoad()
        }
    }

    private func requestSubagentTranscriptLoadAfterViewUpdate(runID: UUID) {
        Task { @MainActor in
            await Task.yield()
            store.requestSubagentTranscriptLoad(for: runID)
        }
    }

    private func resetTranscriptAutoScroll() {
        transcriptPinnedState.isPinned = true
    }

    private func beginTranscriptAutoScrollTurn() {
        resetTranscriptAutoScroll()
    }

    private func requestTranscriptBottomScroll() {
        transcriptBottomScrollRequest &+= 1
    }

    @ViewBuilder
    private var composer: some View {
        let isRunning = store.selectedSession?.status.isActive == true
        let isCompacting = store.selectedSession?.isCompacting == true
        let hasSelectedSession = store.selectedSession != nil
        VStack(spacing: 6) {
            if hasFileSuggestions {
                PiAgentCommandSuggestions(
                    items: composerSuggestionItems,
                    selectedIndex: composerSuggestionIndex,
                    scrollTick: composerSuggestionScrollTick,
                    onSelect: { item in insertComposerSuggestion(item.insertion) },
                    onHover: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil else { return }
                        composerSuggestionIndex = index
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            } else if hasSlashSuggestions {
                PiAgentSlashSuggestions(
                    rows: slashSuggestionRows,
                    highlightedSelectableIndex: slashState.highlightedIndex,
                    scrollTick: slashState.scrollTick,
                    title: slashPanelTitle,
                    onSelect: { row in handleSlashRowSelect(row) },
                    onHoverSelectable: { index in
                        guard Date.now >= composerSuggestionHoverSuppressedUntil else { return }
                        slashState.highlightedIndex = index
                    },
                    onBack: slashCanGoBack ? { popSlashScreen() } : nil
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)))
            }
            PiAgentComposerBox(
                text: $composerText,
                pasteAttachments: $composerPasteAttachments,
                nextPasteID: $nextComposerPasteID,
                images: $composerImages,
                files: $composerFiles,
                folders: $composerFolders,
                issueAttachment: $composerIssueAttachment,
                attachmentError: $composerAttachmentError,
                inputMode: $inputMode,
                isRunning: isRunning,
                isDisabled: isCompacting,
                placeholder: !hasSelectedSession ? "Start a new Pi Agent session…" : (isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : "Ask Pi to implement, inspect, explain, or fix…")),
                canSend: !isCompacting && store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil || slashSelection != nil),
                canCreateSession: !isCompacting && store.selectedSession == nil,
                createSessionProjects: viewModel.selectedDiscoveredProject == nil ? piAgentNewSessionProjects : [],
                onFiles: addFileAttachments,
                onFolders: addFolderAttachments,
                viewModel: viewModel,
                footerSession: store.selectedSession,
                transcript: store.selectedTranscript,
                supportedThinkingLevels: store.selectedSession.map(supportedThinkingLevels(for:)) ?? [],
                metricsSession: runtimeFooterSession(isRunning: isRunning),
                slashSelection: slashSelection,
                onRemoveSlashSelection: { slashSelection = nil },
                onSend: hasSelectedSession ? sendComposerMessage : createSessionFromComposer,
                onStop: { viewModel.stopSelectedPiAgentSession() },
                onCreateSession: createSessionFromComposer,
                onCreateSessionForProject: createSessionFromComposer,
                onClear: clearComposerInput,
                suggestionKeyBridge: composerSuggestionKeyBridge
            )
        }
        .animation(.easeOut(duration: 0.12), value: hasComposerSuggestions)
        .onChange(of: composerText) { _, _ in
            composerSuggestionIndex = 0
            composerSuggestionsDismissed = false
            composerSuggestionScrollTick += 1
            composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            refreshFileSuggestions()
            refreshSlashUniverseLifecycle()
        }
    }

    private var activeSuggestionToken: (token: String, range: Range<String.Index>)? {
        guard !composerText.isEmpty else { return nil }
        let nsText = composerText as NSString
        let tokenRange = nsText.range(of: "[^\\s]+$", options: .regularExpression)
        guard tokenRange.location != NSNotFound,
              let range = Range(tokenRange, in: composerText) else {
            return nil
        }
        let token = String(composerText[range])
        guard !token.isEmpty else { return nil }
        return (token: token, range: range)
    }

    private enum ComposerSuggestionTrigger {
        case slash(query: String)
        case file(query: String)
    }

    private var composerSuggestionTrigger: ComposerSuggestionTrigger? {
        guard let active = activeSuggestionToken,
              let first = active.token.first else { return nil }

        switch first {
        case "/":
            // Pi only dispatches slash commands/templates when the prompt starts with `/`.
            // Keep file mentions available anywhere, but only suggest/action slash commands
            // when this token is the first non-whitespace content in the composer.
            let prefix = composerText[..<active.range.lowerBound]
            guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .slash(query: String(active.token.dropFirst()).lowercased())
        case "@":
            return .file(query: String(active.token.dropFirst()).lowercased())
        default:
            return nil
        }
    }

    private var composerSuggestionItems: [ComposerSuggestionItem] {
        // Slash mode now uses `PiAgentSlashSuggestions`; this builder is the
        // file-only path. Commands / skills are intentionally empty here.
        ComposerSuggestionItem.build(commands: [], skills: [], files: fileSuggestions)
    }

    private var slashQueryString: String {
        if case .slash(let query) = composerSuggestionTrigger { return query }
        return ""
    }

    private var slashSuggestionRows: [SlashSuggestionRow] {
        SlashSuggestionRowBuilder.rows(universe: slashUniverse, state: slashState, query: slashQueryString)
    }

    private var slashSelectableCount: Int {
        slashSuggestionRows.lazy.filter(\.isSelectable).count
    }

    private var slashPanelTitle: String? {
        switch slashState.screen {
        case .categoryPicker:
            return slashQueryString.isEmpty ? nil : "Search · \(slashQueryString)"
        case .category(let kind):
            switch kind {
            case .command: return "Commands"
            case .prompt: return "Prompts"
            case .skill: return "Skills"
            }
        }
    }

    private var slashCanGoBack: Bool {
        if case .category = slashState.screen { return true }
        return false
    }

    private var hasFileSuggestions: Bool {
        if composerSuggestionsDismissed { return false }
        if case .file = composerSuggestionTrigger { return !fileSuggestionResults.isEmpty }
        return false
    }

    private var hasSlashSuggestions: Bool {
        if composerSuggestionsDismissed { return false }
        guard case .slash = composerSuggestionTrigger else { return false }
        return !slashSuggestionRows.isEmpty
    }

    private var hasComposerSuggestions: Bool {
        hasFileSuggestions || hasSlashSuggestions
    }

    private var composerSuggestionKeyBridge: ComposerSuggestionKeyBridge {
        ComposerSuggestionKeyBridge(
            isActive: hasComposerSuggestions,
            onMove: { delta in
                if hasSlashSuggestions {
                    let count = slashSelectableCount
                    guard count > 0 else { return }
                    slashState.highlightedIndex = min(max(slashState.highlightedIndex + delta, 0), count - 1)
                    slashState.scrollTick &+= 1
                } else {
                    let count = composerSuggestionItems.count
                    guard count > 0 else { return }
                    composerSuggestionIndex = min(max(composerSuggestionIndex + delta, 0), count - 1)
                    composerSuggestionScrollTick += 1
                }
                // Ignore hover briefly so the scroll sliding rows under a
                // stationary pointer can't hijack the keyboard selection.
                composerSuggestionHoverSuppressedUntil = Date.now.addingTimeInterval(0.25)
            },
            onAccept: { acceptComposerSuggestion() },
            onDismiss: {
                if slashCanGoBack {
                    popSlashScreen()
                } else {
                    composerSuggestionsDismissed = true
                }
            }
        )
    }

    private func acceptComposerSuggestion() -> Bool {
        if hasSlashSuggestions {
            let selectable = slashSuggestionRows.filter(\.isSelectable)
            guard selectable.indices.contains(slashState.highlightedIndex) else { return false }
            handleSlashRowSelect(selectable[slashState.highlightedIndex])
            return true
        }
        let items = composerSuggestionItems
        guard items.indices.contains(composerSuggestionIndex) else { return false }
        insertComposerSuggestion(items[composerSuggestionIndex].insertion)
        return true
    }

    private func handleSlashRowSelect(_ row: SlashSuggestionRow) {
        switch row.kind {
        case .header:
            return
        case .category(let kind):
            slashState.screen = .category(kind)
            slashState.highlightedIndex = 0
            slashState.scrollTick &+= 1
        case .item(let item):
            commitSlashSelection(item)
        }
    }

    private func popSlashScreen() {
        slashState.screen = .categoryPicker
        slashState.highlightedIndex = 0
        slashState.scrollTick &+= 1
    }

    private func commitSlashSelection(_ item: SlashItem) {
        // Strip the leading `/<typed>` token so the pill alone represents the
        // invocation. Any other composer text the user typed is preserved.
        if let token = activeSuggestionToken, token.token.hasPrefix("/") {
            composerText.replaceSubrange(token.range, with: "")
        }
        composerText = composerText.trimmingCharacters(in: .whitespaces)

        // For prompts, seed the editor with the body so the user can edit
        // before sending. Commands and skills leave the editor alone — any
        // text the user types becomes the args / message body.
        if case .prompt(_, let body) = item.payload {
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            composerText = composerText.isEmpty ? trimmedBody : "\(trimmedBody)\n\n\(composerText)"
        }

        slashSelection = item
        slashState = SlashSuggestionState()
        composerSuggestionsDismissed = true
    }

    /// Builds (or releases) the cached slash universe on transitions in/out of
    /// `/` mode. Runs from `.onChange(of: composerText)` — never in `body` — so
    /// the catalog walk and its filesystem lookups stay off the hot render path.
    private func refreshSlashUniverseLifecycle() {
        let isSlashActive: Bool
        if case .slash = composerSuggestionTrigger { isSlashActive = true } else { isSlashActive = false }

        if isSlashActive && !lastSlashTriggerActive {
            let projectPath = store.selectedSession?.projectPath ?? viewModel.selectedProjectPath
            slashUniverse = viewModel.slashUniverse(forProjectPath: projectPath)
            slashState = SlashSuggestionState()
        } else if !isSlashActive && lastSlashTriggerActive {
            slashUniverse = .empty
            slashState = SlashSuggestionState()
        }
        lastSlashTriggerActive = isSlashActive
    }

    private var slashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        guard !query.hasPrefix("skill:") else { return [] }
        let all = runtimeCommandInvocations(excludingSkills: true) ?? fallbackCommandInvocations
        return all.filter { query.isEmpty || $0.dropFirst().lowercased().hasPrefix(query) }.prefix(8).map { $0 }
    }

    private var skillSlashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        let normalizedQuery = query.hasPrefix("skill:") ? String(query.dropFirst("skill:".count)) : query
        let all = runtimeCommandInvocations(onlySkills: true) ?? fallbackSkillInvocations
        return all
            .filter { invocation in
                let name = invocation.replacingOccurrences(of: "/skill:", with: "")
                return normalizedQuery.isEmpty || name.lowercased().hasPrefix(normalizedQuery)
            }
            .prefix(8)
            .map { $0 }
    }

    private func runtimeCommandInvocations(onlySkills: Bool = false, excludingSkills: Bool = false) -> [String]? {
        guard let commands = store.selectedSession?.commandInvocations else { return nil }
        let filtered = commands.filter { invocation in
            let isSkill = invocation.hasPrefix("/skill:")
            if onlySkills { return isSkill }
            if excludingSkills { return !isSkill }
            return true
        }
        return Array(Set(filtered)).sorted()
    }

    private var fallbackCommandInvocations: [String] {
        let configuredCommands = PiInjectedCommandCatalog.all
            .filter { PiInjectedCommandCatalog.isEnabled($0, settings: viewModel.appSettings) }
            .map(\.slashName)
        return Array(Set(snapshotForSelectedSession.promptTemplates.map(\.invocation) + configuredCommands + ["/compact"]))
            .sorted()
    }

    private var fallbackSkillInvocations: [String] {
        // Runtime RPC is authoritative. Before it responds, use active skills only;
        // External/catalog-only skills are management records, not guaranteed runtime commands.
        var seen = Set<String>()
        return snapshotForSelectedSession.skills
            .filter { seen.insert($0.name).inserted }
            .map { "/skill:\($0.name)" }
            .sorted()
    }

    private var snapshotForSelectedSession: ScanSnapshot {
        let projectPath = store.selectedSession?.projectPath ?? viewModel.selectedProjectPath
        return projectPath.map { viewModel.startupSnapshot(forProjectPath: $0) } ?? viewModel.snapshot
    }

    private var visibleSkillsForSelectedSession: [SkillRecord] {
        let projectPath = store.selectedSession?.projectPath ?? viewModel.selectedProjectPath
        let snapshot = projectPath.map { viewModel.startupSnapshot(forProjectPath: $0) } ?? viewModel.snapshot
        var seen = Set<String>()
        return (snapshot.skills + snapshot.librarySkills)
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Agents offered in the user-message Fork submenu. Returns `nil` (single
    /// fork action) when the session has no subagents enabled, isn't a normal
    /// project session, or no agents are discovered. Re-evaluated when the
    /// selected session, its subagent toggle, or the agent catalog change.
    private var forkAgentChoicesForSelectedSession: [EffectiveAgentRecord]? {
        guard let session = store.selectedSession,
              session.kind != .agent,
              session.subagentsEnabled else { return nil }
        let agents = viewModel.selectableAgentUniverse(forProjectPath: session.projectPath)
            .filter { $0.resolved.disabled != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return agents.isEmpty ? nil : agents
    }

    private var fileSuggestions: [PiAgentFileSuggestion] {
        guard case .file = composerSuggestionTrigger else { return [] }
        return fileSuggestionResults
    }

    /// Re-scans `@`-file suggestions off the main thread, debounced. Called only
    /// when the composer text changes — never on hover or arrow-key navigation —
    /// so the filesystem walk never blocks typing or moving the highlight.
    private func refreshFileSuggestions() {
        fileScanTask?.cancel()
        guard let session = store.selectedSession,
              case let .file(query) = composerSuggestionTrigger else {
            fileScanTask = nil
            if !fileSuggestionResults.isEmpty { fileSuggestionResults = [] }
            return
        }
        let rootPath = session.worktreePath ?? session.projectPath
        fileScanTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) {
                PiAgentFileSuggestion.scan(rootPath: rootPath, query: query)
            }.value
            guard !Task.isCancelled else { return }
            fileSuggestionResults = results
        }
    }

    private func insertComposerSuggestion(_ text: String) {
        replaceCurrentSuggestionToken(with: text)
    }

    private var nativeSubagentRunsByID: [UUID: PiSubagentRunRecord] {
        guard let session = store.selectedSession else { return [:] }
        return Dictionary(uniqueKeysWithValues: store.subagentRuns(for: session.id).map { ($0.id, $0) })
    }

    private func nativeSubagentCard(for run: PiSubagentRunRecord) -> PiNativeSubagentRunCard {
        PiNativeSubagentRunCard(
            run: run,
            onStop: { viewModel.stopNativeSubagent(runID: run.id, parentSessionID: run.parentSessionID) },
            onOpenTranscript: { selectedSubagentTranscriptRunID = run.id },
            onReveal: { revealSubagentRun(run) },
            onOpenGraph: { selectedSubagentGraphRunID = run.id },
            onOpenChildTranscript: { selectedSubagentTranscriptRunID = $0 },
            onStopChild: { viewModel.stopNativeSubagent(runID: $0, parentSessionID: run.parentSessionID) },
            imageStore: viewModel.agentImageStore
        )
    }

    private var selectedSubagentTranscriptBinding: Binding<PiSubagentRunRecord?> {
        Binding(
            get: {
                guard let runID = selectedSubagentTranscriptRunID,
                      let session = store.selectedSession else { return nil }
                return store.subagentRuns(for: session.id).first(where: { $0.id == runID })
            },
            set: { newValue in selectedSubagentTranscriptRunID = newValue?.id }
        )
    }

    private var selectedSubagentGraphBinding: Binding<PiSubagentRunRecord?> {
        Binding(
            get: {
                guard let runID = selectedSubagentGraphRunID,
                      let session = store.selectedSession else { return nil }
                return store.subagentRuns(for: session.id).first(where: { $0.id == runID })
            },
            set: { newValue in selectedSubagentGraphRunID = newValue?.id }
        )
    }

    private func revealSubagentRun(_ run: PiSubagentRunRecord) {
        let target = run.outputPath ?? run.artifactDirectory
        guard !target.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    private func replaceCurrentSuggestionToken(with replacement: String) {
        guard let active = activeSuggestionToken else { return }
        composerText.replaceSubrange(active.range, with: replacement)
        composerText += " "
    }

    private func addFileAttachments(_ urls: [URL]) {
        let attachments = urls.filter { !$0.hasDirectoryPath }.compactMap { PiAgentFileAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        // O(1) membership instead of `contains(where:)` per attachment; the Set
        // also de-dupes within the incoming batch.
        var seenURLs = Set(composerFiles.map(\.url))
        for attachment in attachments where seenURLs.insert(attachment.url).inserted {
            composerFiles.append(attachment)
        }
    }

    private func addFolderAttachments(_ urls: [URL]) {
        let attachments = urls.compactMap { PiAgentFolderAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        var seenURLs = Set(composerFolders.map(\.url))
        for attachment in attachments where seenURLs.insert(attachment.url).inserted {
            composerFolders.append(attachment)
        }
    }

    private func loadComposerDraft(for sessionID: UUID?) {
        resetComposerHistoryNavigation()
        if let pending = viewModel.consumePendingPiAgentComposerText() {
            composerText = pending
            composerIssueAttachment = viewModel.consumePendingPiAgentIssueAttachment()
            composerPasteAttachments = []
            nextComposerPasteID = 1
            composerImages = []
            composerFiles = []
            composerFolders = []
            composerAttachmentError = nil
            saveComposerDraft(for: sessionID)
            return
        }

        guard let sessionID else {
            clearComposerInput()
            return
        }
        let draft = store.composerDraft(for: sessionID)
        composerText = draft.text
        composerPasteAttachments = []
        nextComposerPasteID = 1
        composerImages = draft.images
        composerFiles = draft.files
        composerFolders = draft.folders
        composerIssueAttachment = nil
        composerAttachmentError = nil
    }

    private func saveComposerDraft(for sessionID: UUID?) {
        guard let sessionID else { return }
        let draftText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: composerPasteAttachments)
        store.saveComposerDraft(text: draftText, images: composerImages, files: composerFiles, folders: composerFolders, for: sessionID)
    }

    private func clearComposerInput() {
        resetComposerHistoryNavigation()
        composerText = ""
        composerPasteAttachments = []
        nextComposerPasteID = 1
        composerImages = []
        composerFiles = []
        composerFolders = []
        composerIssueAttachment = nil
        composerAttachmentError = nil
        slashSelection = nil
        slashState = SlashSuggestionState()
    }

    private func resetComposerHistoryNavigation(keepDraft: Bool = false) {
        composerHistoryIndex = nil
        if !keepDraft {
            composerHistoryDraft = ""
        }
    }

    private func createSessionFromComposer() {
        createSessionFromComposer(for: nil)
    }

    private func createSessionFromComposer(for project: DiscoveredProject?) {
        guard store.selectedSession == nil else { return }
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: composerPasteAttachments)
        let shouldSend = !expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil
        if let project {
            viewModel.createPiAgentDraft(for: project)
        } else {
            viewModel.createPiAgentDraftForSelectedProject()
        }
        if shouldSend {
            sendComposerMessage()
        }
    }

    private func sendComposerMessage() {
        let activePasteAttachments = PiAgentPasteMarkerCodec.activeAttachments(in: composerText, attachments: composerPasteAttachments)
        let expandedComposerText = PiAgentPasteMarkerCodec.expandMarkers(in: composerText, attachments: activePasteAttachments)
        let baseMessage = expandedComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTranscript = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = slashSelection?.materialize(userText: baseMessage) ?? baseMessage
        let transcriptMessage = slashSelection?.materialize(userText: baseTranscript) ?? baseTranscript
        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty || !composerFolders.isEmpty || composerIssueAttachment != nil else { return }
        guard store.selectedSession?.isCompacting != true else { return }
        guard let payload = attachedFilePayload() else { return }
        let combined = [expandFileReferences(in: message), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let transcriptCombined = [expandFileReferences(in: transcriptMessage), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isRunning = store.selectedSession?.status.isActive == true
        let sentSessionID = store.selectedSession?.id
        beginTranscriptAutoScrollTurn()
        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, transcriptText: transcriptCombined, images: composerImages, pasteAttachments: activePasteAttachments, issueAttachment: composerIssueAttachment)
        requestTranscriptBottomScroll()
        clearComposerInput()
        if let sentSessionID {
            store.clearComposerDraft(for: sentSessionID)
        }
    }

    private func expandFileReferences(in message: String) -> String {
        guard let session = store.selectedSession else { return message }
        let rootURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        return message
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { part in
                guard part.hasPrefix("@"), part.count > 1 else { return String(part) }
                let relative = String(part.dropFirst())
                let url = rootURL.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: url.path) else { return String(part) }
                return fileTag(for: url)
            }
            .joined(separator: " ")
    }

    private func attachedFilePayload() -> String? {
        var tags: [String] = []
        for file in composerFiles {
            tags.append(fileTag(for: file.url))
        }
        for folder in composerFolders {
            tags.append(folderReference(for: folder.url))
        }
        return tags.joined(separator: "\n")
    }

    private func folderReference(for url: URL) -> String {
        "folder: `\(url.path)`"
    }

    private func fileTag(for url: URL) -> String {
        "<file name=\"\(url.path)\"></file>"
    }

    private var runningCount: Int {
        scopedSessions.count(where: { viewModel.piAgentSessionIsWorking($0) })
    }

    private var emptySessionsMessage: String {
        if let project = viewModel.selectedDiscoveredProject {
            return "Use + to create a draft for \(project.name), or open from a GitHub issue."
        }
        return "Use + to create a draft, or select a project to narrow the list."
    }

    private func supportedThinkingLevels(for session: PiAgentSessionRecord) -> [String] {
        let defaultModel = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? defaultModel?.provider
        let modelID = session.modelOverrideID ?? session.model ?? defaultModel?.model
        if let provider, let modelID {
            if let cached = viewModel.enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                return cached.supportedThinkingLevels.isEmpty ? (cached.supportsThinking ? [] : ["off"]) : cached.supportedThinkingLevels
            }
        }
        return []
    }

    private func syncVisibleSessionSelection() {
        if let selectedID = store.selectedSession?.id,
           visibleSessions.contains(where: { $0.id == selectedID }) {
            return
        }

        if let firstVisible = visibleSessions.first {
            store.select(firstVisible.id)
        } else {
            store.clearSelection()
        }
    }

    private func syncMultiSelectionToSelectedSession() {
        let next: Set<UUID> = store.selectedSession.map { [$0.id] } ?? []
        // Only write @State when it actually changes — an unconditional assign
        // re-evaluates the whole screen body (and re-runs the transcript's
        // updateNSView) on every sidebar refresh, including streaming pulses.
        if next != selectedSessionIDs { selectedSessionIDs = next }
        lastSelectedSessionID = store.selectedSession?.id
    }

    private func pruneMultiSelectionToVisibleSessions() {
        let visibleIDs = Set(visibleSessionIDs)
        var next = selectedSessionIDs.intersection(visibleIDs)
        if let selectedID = store.selectedSession?.id, visibleIDs.contains(selectedID) {
            next.insert(selectedID)
        }
        // Guard the @State write so a session-list reorder (e.g. streaming bumping
        // a session's activity) doesn't pulse selection and storm the body.
        if next != selectedSessionIDs { selectedSessionIDs = next }
        if let lastSelectedSessionID, !visibleIDs.contains(lastSelectedSessionID) {
            self.lastSelectedSessionID = store.selectedSession?.id
        }
    }

    private func selectSessionFromList(_ session: PiAgentSessionRecord, forceSingle: Bool = false) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if forceSingle || modifiers.isEmpty {
            selectedSessionIDs = [session.id]
        } else if modifiers.contains(.shift), let anchorID = lastSelectedSessionID, let anchorIndex = visibleSessionIDs.firstIndex(of: anchorID), let targetIndex = visibleSessionIDs.firstIndex(of: session.id) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedSessionIDs.formUnion(visibleSessionIDs[range])
        } else if modifiers.contains(.command) {
            if selectedSessionIDs.contains(session.id), selectedSessionIDs.count > 1 {
                selectedSessionIDs.remove(session.id)
            } else {
                selectedSessionIDs.insert(session.id)
            }
        }
        lastSelectedSessionID = session.id
        viewModel.selectPiAgentSession(session.id)
    }

    private func requestDeleteSessions(_ ids: Set<UUID>, isClearAll: Bool = false) {
        let existing = Set(store.sessions.map(\.id))
        let deleteIDs = ids.intersection(existing)
        guard !deleteIDs.isEmpty else { return }
        pendingDeleteSessionIDs = deleteIDs
        pendingDeleteIsClearAll = isClearAll
        pendingDeleteClearAllProjects = isClearAll && viewModel.selectedProjectPath == nil
        pendingDeleteProjectName = isClearAll && viewModel.selectedProjectPath != nil ? (viewModel.selectedDiscoveredProject?.name ?? "the current project") : nil
        isDeleteSessionsAlertPresented = true
    }

    private func resetPendingSessionDelete() {
        pendingDeleteSessionIDs = []
        pendingDeleteIsClearAll = false
        pendingDeleteClearAllProjects = false
        pendingDeleteProjectName = nil
    }

    private func deleteSessionsImmediately(_ ids: Set<UUID>) {
        let existing = Set(store.sessions.map(\.id))
        let deleteIDs = ids.intersection(existing)
        guard !deleteIDs.isEmpty else { return }
        selectedSessionIDs.subtract(deleteIDs)
        withAnimation(.snappy(duration: 0.18)) {
            cachedVisibleSessions.removeAll { deleteIDs.contains($0.id) }
            hasBuiltVisibleSessions = true
        }
        viewModel.deletePiAgentSessions(deleteIDs)
        rebuildVisibleSessions()
        syncMultiSelectionToSelectedSession()
        syncRuntimeFooterSnapshot()
    }

    private func deletePendingSessions() {
        let ids = pendingDeleteSessionIDs
        resetPendingSessionDelete()
        deleteSessionsImmediately(ids)
    }

    private func runtimeFooterSession(isRunning: Bool) -> PiAgentSessionRecord? {
        isRunning ? frozenRuntimeFooterSession ?? store.selectedSession : store.selectedSession
    }

    private func syncRuntimeFooterSnapshot() {
        frozenRuntimeFooterSession = store.selectedSession
    }

    private func syncSelectedSessionTitleDraft() {
        selectedSessionTitleDraft = store.selectedSession?.title ?? ""
    }

    private func commitSelectedSessionRename() {
        guard let session = store.selectedSession else { return }
        let trimmedTitle = selectedSessionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            selectedSessionTitleDraft = session.title
        } else if trimmedTitle != session.title {
            viewModel.renamePiAgentSession(session.id, title: trimmedTitle)
            selectedSessionTitleDraft = trimmedTitle
        }
    }

    private func sortedSessions(_ sessions: [PiAgentSessionRecord]) -> [PiAgentSessionRecord] {
        sessions.sorted { PiAgentSessionRecord.sessionListPrecedes($0, $1) }
    }

    private func sessionMatchesSearch(_ session: PiAgentSessionRecord, query: String) -> Bool {
        let haystack = [
            session.title,
            session.projectName,
            session.projectPath,
            session.repository ?? "",
            session.issueNumber.map(String.init) ?? "",
            session.lastSummary ?? ""
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func effectiveStatus(for session: PiAgentSessionRecord) -> String {
        session.status.rawValue
    }

    private func effectiveStatusColor(for session: PiAgentSessionRecord) -> Color {
        switch session.status {
        case .running, .starting: return .orange
        case .idle, .completed: return .blue
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }

    private func sessionKindTagColor(_ kind: PiAgentSessionKind) -> Color {
        switch kind {
        case .issue: return .purple
        case .agent: return .teal
        case .project, .changesReview: return .blue
        }
    }
}
