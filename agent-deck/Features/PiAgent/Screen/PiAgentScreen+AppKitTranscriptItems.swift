import AppKit
import Combine
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

extension PiAgentScreen {
    var appKitTranscriptItems: [PiAgentAppKitTranscriptItem] {
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
    /// `renderRevision`/`streamingRevision` cover all transcript content (threads —
    /// and therefore the timeline snapshot, which derives purely from
    /// `transcriptCache.threads` + the archive toggle hashed below).
    /// `appKitTranscript{Chrome,ThreadContext}Revision` are the SAME hashes the build
    /// folds into each row's `contentRevision`, so reusing them here captures the
    /// session-level inputs (status, worktree/project, loading, visibility, skills,
    /// subagent summary) without re-listing them — and can't drift if those helpers
    /// gain a read. The tail adds the few inputs those revisions don't cover.
    ///
    /// This runs on every host body pass (~30Hz while streaming), so it must stay
    /// O(1) in transcript length: no timeline snapshot, no per-run/request hashing.
    /// Subagent runs + supervisor requests are covered by the store's per-session
    /// `subagentActivityRevision`, bumped on every mutation of either collection.
    var appKitTranscriptItemsSignature: Int {
        var hasher = Hasher()
        hasher.combine(transcriptCache.renderRevision)
        hasher.combine(transcriptCache.streamingRevision)
        hasher.combine(appKitTranscriptChromeRevision())
        hasher.combine(appKitTranscriptThreadContextRevision())
        hasher.combine(showArchivedPreCompactionTranscript)
        if let session = store.selectedSession {
            hasher.combine(session.commandInvocations)         // slash-command chrome
            hasher.combine(session.forkedFromParentTitle)      // fork-origin card
            hasher.combine(session.forkedFromSessionID)
            hasher.combine(session.forkedFromTranscriptSnapshot)
            hasher.combine(store.subagentActivityRevision(for: session.id))
        }
        return hasher.finalize()
    }

    var appKitTranscriptItemsBuild: [PiAgentAppKitTranscriptItem] {
        let timelineSnapshot = transcriptTimelineSnapshot
        let timelineItems = timelineSnapshot.mainVisibleItems
        let chromeRevision = appKitTranscriptChromeRevision()
        let contextRevision = appKitTranscriptThreadContextRevision()
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
    func threadBlockCard(
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
    func questionForkModel(_ question: PiAgentTranscriptEntry) -> ForkModel {
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
    func nativeChipQuestionKind(
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

    func nativeQuestionKind(
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

    func nativeChildKind(
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
    func appKitQuestionBlockRevision(_ entry: PiAgentTranscriptEntry, contextRevision: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        hashEntryRevision(entry, into: &hasher)
        return hasher.finalize()
    }

    /// Content revision for a child block — only that child's entry/entries +
    /// context. A sibling streaming does not bump this, so only the streaming
    /// block's row reconfigures.
    func appKitChildBlockRevision(_ child: PiAgentThreadChild, contextRevision: Int) -> Int {
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

    func appKitTranscriptChromeRevision() -> Int {
        var hasher = Hasher()
        hasher.combine(store.selectedSession?.id)
        hasher.combine(String(describing: store.selectedSession?.status))
        hasher.combine(store.isSelectedTranscriptLoading)
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        return hasher.finalize()
    }

    func appKitTranscriptThreadContextRevision() -> Int {
        var hasher = Hasher()
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        hasher.combine(store.selectedSession.map { $0.worktreePath ?? $0.projectPath })
        if let sessionID = store.selectedSession?.id {
            // Covers every run/request mutation without an O(runs) string map.
            hasher.combine(store.subagentActivityRevision(for: sessionID))
        }
        return hasher.finalize()
    }

    func appKitTranscriptContentRevision(
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
    func cheapThreadSignature(
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

    func inlineEntrySignature(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
    }

    func hashThreadRevision(_ thread: PiAgentTranscriptThread, into hasher: inout Hasher) {
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

    func hashEntryRevision(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.title)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
        hasher.combine(entry.timestamp)
    }

}
