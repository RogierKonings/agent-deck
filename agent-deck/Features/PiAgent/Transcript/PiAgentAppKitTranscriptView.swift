import AppKit
import Combine
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

private enum PiAgentTranscriptTableSection: Hashable {
    case main
}

/// Floating "scroll to latest" affordance shown when the transcript is not
/// pinned to the bottom — tapping it scrolls to the newest content and
/// re-engages streaming auto-follow.
private struct JumpToLatestPill: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // Fill the full 32pt circle inside the button label so the whole pill
            // is the hit target — not just the glyph. The frame/contentShape must
            // live on the label (the button's interactive region), not outside it.
            Image(systemName: "chevron.down")
                .font(AppTheme.Font.footnote.weight(.bold))
                .offset(x: 0.5, y: 0.5)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .foregroundStyle(AppTheme.brandAccent)
        .glassEffect(.regular.tint(AppTheme.brandAccent.opacity(0.16)), in: Circle())
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .scaleEffect(isHovering ? 1.07 : 1)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("Jump to latest")
        .accessibilityLabel("Jump to latest message")
    }
}

/// Holds the transcript's pinned-to-bottom flag in a reference type so the screen
/// can keep it in `@State` (which watches identity only). Scrolling flips this
/// constantly; only `JumpToLatestOverlay` observes it, so flips don't invalidate
/// the screen body or re-run the transcript items build.
final class TranscriptPinnedState: ObservableObject {
    @Published var isPinned = true
}

/// The "jump to latest" pill, isolated so that toggling pinned-to-bottom on scroll
/// re-renders only this small view — never the screen body / transcript host.
struct JumpToLatestOverlay: View {
    @ObservedObject var pinnedState: TranscriptPinnedState
    let onJump: () -> Void

    var body: some View {
        ZStack {
            if !pinnedState.isPinned {
                JumpToLatestPill(action: onJump)
                    .padding(.trailing, 22)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: pinnedState.isPinned)
    }
}

/// Intermediate per-block descriptor used while flattening threads into rows.
/// Insets are filled in a second pass from row adjacency, then folded into the
/// final `PiAgentAppKitTranscriptItem` (`contentRevision` + `estimatedHeight`).
struct PiAgentTranscriptBlockDescriptor {
    let id: String
    /// Legacy SwiftUI content for hosted rows. `nil` when `kind` is native.
    let view: AnyView?
    /// Native render kind; `nil` falls back to hosting `view`.
    var kind: PiAgentTranscriptCellKind? = nil
    /// Content hash WITHOUT insets — insets are folded in at materialize time.
    let baseRevision: Int
    /// Height estimate for the block content alone (insets added separately).
    let estimatedContentHeight: (CGFloat) -> CGFloat
    /// Thread id this block belongs to, or nil for chrome / plan / anchor rows.
    let threadID: String?
    /// True only for a thread's user-question block (drives the 10pt q↔reply gap).
    let isThreadQuestion: Bool
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
}

/// The transcript-rendering unit, deliberately split out from `PiAgentScreen` so
/// that it — and only it — observes `PiAgentTranscriptRenderCache`. The render
/// cache pulses `streamingRevision` ~30Hz during streaming; isolating the
/// subscription here keeps that pulse from re-evaluating the screen's session
/// list and composer (see the `@State transcriptCache` note in `PiAgentScreen`).
///
/// `makeItems` is supplied by the parent and re-run on every pulse. It reads the
/// live cache (`threads`) and parent references (`store`/`viewModel`), so the
/// rebuilt items reflect the latest streamed content even though the parent view
/// struct captured in the closure isn't itself re-evaluated between pulses.
struct PiAgentTranscriptHost: View {
    @ObservedObject var cache: PiAgentTranscriptRenderCache
    let sessionID: UUID?
    let bottomScrollRequest: Int
    let makeItems: () -> [PiAgentAppKitTranscriptItem]
    let onPinnedToBottomChange: (Bool) -> Void
    let onBenchAdvanceSession: () -> Void
    let benchSessionCount: () -> Int

    var body: some View {
        PiAgentAppKitTranscriptView(
            items: makeItems(),
            sessionID: sessionID,
            renderRevision: cache.renderRevision,
            streamingRevision: cache.streamingRevision,
            autoScrollTurnRevision: cache.autoScrollTurnRevision,
            bottomScrollRequest: bottomScrollRequest,
            onPinnedToBottomChange: onPinnedToBottomChange,
            onBenchAdvanceSession: onBenchAdvanceSession,
            benchSessionCount: benchSessionCount
        )
    }
}

struct PiAgentAppKitTranscriptView: NSViewRepresentable {
    let items: [PiAgentAppKitTranscriptItem]
    let sessionID: UUID?
    let renderRevision: Int
    let streamingRevision: Int
    let autoScrollTurnRevision: Int
    let bottomScrollRequest: Int
    let onPinnedToBottomChange: (Bool) -> Void
    /// Advance selection to the next session (the ⌘] action). Used only by the
    /// scroll benchmark to sweep multiple chats; nil disables multi-session.
    var onBenchAdvanceSession: (() -> Void)?
    var benchSessionCount: (() -> Int)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPinnedToBottomChange: onPinnedToBottomChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        // Rows are block-granular; inter-row spacing varies (question↔reply,
        // sibling, thread↔thread), so it's baked into each row as padding
        // rather than this uniform value. See `PiAgentAppKitTranscriptItem`.
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 120
        tableView.usesAutomaticRowHeights = false
        // The default `.automatic` style resolves to `.inset`, which adds a
        // system horizontal margin (~16pt) to every cell. That pushed all rows
        // inboard of the composer (which lives outside the table). `.plain`
        // removes the inset so a cell pinned at x=0 lines up with the composer's
        // container edge. Row-internal padding is handled per-block instead.
        tableView.style = .plain

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TranscriptColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        // Pin the clip view to x = 0 so the transcript can never be panned
        // horizontally, even if a width desync transiently makes the document
        // view wider than the clip view during a resize or split-divider drag.
        let clipView = TranscriptClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        // Keep AppKit insets at zero. The top fade compensation is a real table
        // spacer row, so the first visible row starts in the same precise place
        // on the initial layout, before any scroll event reconciles NSScrollView
        // contentInsets.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        context.coordinator.scrollView = scrollView
        context.coordinator.tableView = tableView
        context.coordinator.onBenchAdvanceSession = onBenchAdvanceSession
        context.coordinator.benchSessionCount = benchSessionCount
        context.coordinator.setupDataSource(for: tableView)
        context.coordinator.setupScrollObservation(scrollView)
        context.coordinator.updateColumnWidthIfNeeded()
        context.coordinator.apply(
            items: items,
            sessionID: sessionID,
            renderRevision: renderRevision,
            streamingRevision: streamingRevision,
            autoScrollTurnRevision: autoScrollTurnRevision,
            bottomScrollRequest: bottomScrollRequest
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        TranscriptScrollProfiler.measureBody("updateNSView") {
            let coordinator = context.coordinator
            coordinator.onPinnedToBottomChange = onPinnedToBottomChange
            coordinator.onBenchAdvanceSession = onBenchAdvanceSession
            coordinator.benchSessionCount = benchSessionCount
            coordinator.updateColumnWidthIfNeeded()
            coordinator.apply(
                items: items,
                sessionID: sessionID,
                renderRevision: renderRevision,
                streamingRevision: streamingRevision,
                autoScrollTurnRevision: autoScrollTurnRevision,
                bottomScrollRequest: bottomScrollRequest
            )
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate {
        weak var scrollView: NSScrollView?
        weak var tableView: NSTableView?
        private var dataSource: NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String>?

        // Render-product cache: one persistent cell per item id, returned to the
        // diffable data source instead of recycling an arbitrary pooled cell. The
        // expensive part of a vend is building the cell's content (markdown blocks,
        // tool sections); `measuredHeightByID` already caches the *height*, but the
        // built *views* were rebuilt every time a recycled cell took on a new item.
        // Pinning a cell to its item means scrolling back re-hosts the finished cell
        // and `configure(...)` is a no-op (same id/revision/width) — no rebuild — and
        // a cell only ever renders one item, so there is no content bleed. Bounded
        // LRU (offscreen entries evicted; re-vending just rebuilds them) and purged
        // for items dropped from the transcript in `apply(...)`.
        private var cellCache: [String: TranscriptTableCellView] = [:]
        private var cellCacheLRU: [String] = []        // least-recent first, MRU at end
        private let cellCacheLimit = 160

        let profiler = TranscriptScrollProfiler()

        // MARK: Scroll benchmark (autonomous, multi-session validation)
        // Gated by `defaults write streetcoding.agent-deck ScrollBenchEnabled -bool YES`.
        // When on, it sweeps several content-bearing chats in turn — for each it
        // runs a SHORT scroll burst (local up/down) then a LONG full top↔bottom
        // sweep, then advances to the next session via the same path as the ⌘]
        // shortcut. Each pass is bracketed as a profiler "gesture" tagged with the
        // session + phase, so one run produces a comparable per-session report you
        // can diff across builds to see when the jank fix actually lands. Programmatic
        // scrolls exercise the real cell-vend + sizeThatFits + layout path (synthetic
        // OS scroll events are blocked by TCC).
        private var benchTimer: Timer?
        private var benchStart: CFTimeInterval = 0
        private var benchDir: CGFloat = -1
        private let benchStepPoints: CGFloat = 36

        /// Switch selection to the next session (wired by the screen to
        /// `viewModel.selectNextPiAgentSession()` — the ⌘] action). Returns
        /// selection control to SwiftUI, which re-vends the transcript and lands
        /// back in `apply()`, where the bench state machine resumes.
        var onBenchAdvanceSession: (() -> Void)?
        /// Total sessions in the current project's scope — sizes the run.
        var benchSessionCount: (() -> Int)?

        private enum BenchPhase { case idle, settling, shortScroll, longScroll, advancing }
        private var benchActive = false
        private var benchStarted = false
        private var benchPhase: BenchPhase = .idle
        private var benchTargetSessions = 0
        private var benchScopedCount = 0
        private var benchSessionsTested = 0
        private var benchVisitedSessionIDs: Set<UUID> = []
        /// Every session the sweep has landed on (tested or skipped) — lets the
        /// run stop after one full lap of the list even if some are empty drafts.
        private var benchSeenIDs: Set<UUID> = []
        /// Hard stop on advances so a project with fewer content-bearing sessions
        /// than the target can never loop forever wrapping the list.
        private var benchAdvanceBudget = 0
        private let benchMaxSessions = 6
        private let benchShortDuration: CFTimeInterval = 2.5
        private let benchLongDuration: CFTimeInterval = 7
        /// Long full-sweeps run back-to-back per session: repeated traversals are
        /// far more likely to surface a hang/hitch than a single pass (the first
        /// pass warms caches; a stall that survives into passes 2–3 is the real
        /// jank). Each pass is its own profiler gesture, so each gets a summary
        /// and can trip the hitch backtrace independently.
        private let benchLongRepeats = 3

        var sessionID: UUID?
        var lastRenderRevision = -1
        var lastStreamingRevision = -1
        var lastAutoScrollTurnRevision = -1
        var lastBottomScrollRequest = -1
        var onPinnedToBottomChange: (Bool) -> Void

        private var items: [PiAgentAppKitTranscriptItem] = []
        private var itemByID: [String: PiAgentAppKitTranscriptItem] = [:]
        private var orderedIDs: [String] = []
        // Persisted across session switches. Item IDs (thread UUIDs etc.) are
        // globally unique, so a revision recorded for one session never collides
        // with another. Keeping this means a revisited session detects content
        // that changed while it was off-screen and re-measures only those rows.
        private var contentRevisionByID: [String: Int] = [:]
        // Heights live in two caches:
        //  1. `measuredHeightByID` — precise heights reported by a live cell once
        //     it has laid out, keyed [block id → width bucket → height]. The
        //     width key means a width change just
        //     selects a different bucket instead of wiping every height — so a
        //     row measured once at a given width keeps its exact height forever,
        //     across width changes and session switches. A single block's entry
        //     is dropped when its content revision changes.
        //  2. `estimateByID` — fast char-count estimates, used only until a row
        //     has a real measurement. Transient: dropped freely.
        // `noteHeightOfRows` runs debounced ~16ms when a measured height differs.
        private var measuredHeightByID: [String: [Int: CGFloat]] = [:]
        private var estimateByID: [String: CGFloat] = [:]
        // What AppKit currently has each row laid out at — the baseline a fresh
        // measurement is compared against to decide whether a re-tile is needed.
        // Tracked separately from `measuredHeightByID` so a cache change that
        // doesn't actually change the laid-out height can't trigger a spurious
        private var lastNotedHeight: [String: CGFloat] = [:]
        private var pendingHeightIDs = Set<String>()
        private var pendingHeightWork: DispatchWorkItem?
        private var pendingScrollWork: DispatchWorkItem?
        private var pendingSettleScrollWork: DispatchWorkItem?
        private var pendingRemeasureWork: DispatchWorkItem?
        private var pendingScrollSettle = false
        private var pendingWidthWork: DispatchWorkItem?
        // Smooth auto-follow. The streaming follow doesn't snap to the bottom each
        // batch (that reads as a step every ~130ms); instead a 60fps timer eases
        // the clip origin toward the *current* bottom each frame, continuously
        // chasing the growing document so the motion is a glide. It disengages the
        // instant the user scrolls (checked per tick + on live-scroll start + on
        // any user-driven bounds change). Explicit scrolls (send, jump-to-latest,
        // session switch) still snap — see `performScrollToBottom(_:animated:)`.
        private var followGlideTimer: Timer?
        // Fraction of the remaining gap consumed per frame. Higher = snappier /
        // smaller trailing gap during fast streaming; lower = softer glide.
        private let followGlideFactor: CGFloat = 0.5
        private var boundsObserver: NSObjectProtocol?
        private var frameObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var lastPinnedState = true
        // Auto-follow *intent*, distinct from the position-based `isPinnedToBottom`.
        // True = stick to the bottom as content streams. Only a user scroll changes
        // it (set from the resulting position) or an explicit jump/send/session
        // switch (set true). The follow decisions read this, NOT the live position,
        // so the smooth-glide trailing a little behind the bottom never causes the
        // follow to give up and leave the view parked below the latest content.
        private var isAutoFollowing = true
        private var isProgrammaticScroll = false
        // True between willStartLiveScroll / didEndLiveScroll — an authoritative
        // "user is driving the scroll" signal, but it only fires for trackpad
        // gestures and scroller-knob drags, not discrete mouse wheels.
        private var isLiveScrolling = false
        // CACurrentMediaTime of the most recent *user-driven* clip-bounds change,
        // stamped on every non-programmatic boundsDidChange. Bridges the gap left
        // by devices that post no live-scroll notification (mouse wheels) and
        // covers debounced cell measurements that land just after a gesture ends.
        private var lastUserScrollTime: CFTimeInterval = 0
        private let userScrollGraceWindow: CFTimeInterval = 0.35
        // True while the user is actively scrolling — or did within the grace
        // window. Passive auto-follow and anchor restoration stay out of the way
        // while this holds, so a streaming update can't yank the viewport out
        // from under a user gesture.
        private var isUserScrollingRecently: Bool {
            if isLiveScrolling { return true }
            return CACurrentMediaTime() - lastUserScrollTime < userScrollGraceWindow
        }
        private var contentWidth: CGFloat = 0
        // Bucket key for `measuredHeightByID`. Rounding to a whole point keeps
        // sub-pixel width jitter during a scroll from spilling into a new bucket.
        private var widthBucket: Int { Int(contentWidth.rounded()) }
        private let estimatedRowHeight: CGFloat = 120
        private let heightChangeEpsilon: CGFloat = 0.5
        // One-frame debounce so a burst of cell measurements during a single
        // layout pass coalesces into one noteHeightOfRows call.
        private let heightReportInterval: TimeInterval = 0.016
        /// When the last synchronous streaming measure+retile ran. Streaming-only
        /// updates allow at most one synchronous retile per display refresh;
        /// throttled pulses fall back to the async pending-height machinery.
        private var lastSynchronousRetileTime: CFTimeInterval = 0

        private struct ScrollAnchor {
            let id: String
            let offsetFromRowTop: CGFloat
        }

        init(onPinnedToBottomChange: @escaping (Bool) -> Void) {
            self.onPinnedToBottomChange = onPinnedToBottomChange
        }

        func setupDataSource(for tableView: NSTableView) {
            dataSource = NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String>(tableView: tableView) { [weak self] _, _, row, id in
                guard let self, let item = self.itemByID[id] else { return NSView() }
                let cell = self.cachedCell(for: id)
                self.configure(cell, with: item, row: row)
                return cell
            }
            tableView.delegate = self
        }

        /// The persistent cell for `id` — reused across vends so its built content
        /// survives scrolling off and back. Created on first use, then cached.
        private func cachedCell(for id: String) -> TranscriptTableCellView {
            if let cached = cellCache[id] {
                touchCell(id)
                return cached
            }
            let cell = TranscriptTableCellView(frame: .zero)
            cell.identifier = TranscriptTableCellView.reuseIdentifier
            // The live cell reports its own height once it has laid out — the
            // coordinator caches it and re-tiles the row. No offscreen render: the
            // cell had to lay out for display anyway.
            cell.onMeasuredHeight = { [weak self] itemID, height in
                self?.reportMeasuredHeight(height, forItemID: itemID)
            }
            cellCache[id] = cell
            cellCacheLRU.append(id)
            evictCellsIfNeeded()
            return cell
        }

        private func touchCell(_ id: String) {
            if let idx = cellCacheLRU.firstIndex(of: id) { cellCacheLRU.remove(at: idx) }
            cellCacheLRU.append(id)
        }

        /// Drop least-recently-vended cached cells over the cap. Never evicts a row
        /// that's currently on screen (its cell is live), so eviction only releases
        /// offscreen views — which simply rebuild when scrolled back to.
        private func evictCellsIfNeeded() {
            guard cellCacheLRU.count > cellCacheLimit else { return }
            let visible = visibleIDs()
            var i = 0
            while cellCacheLRU.count > cellCacheLimit, i < cellCacheLRU.count {
                let id = cellCacheLRU[i]
                if visible.contains(id) { i += 1; continue }
                cellCacheLRU.remove(at: i)
                cellCache.removeValue(forKey: id)
            }
        }

        /// Forget cached cells for items no longer in the transcript. Called from
        /// `apply(...)` so a removed/replaced message doesn't pin its view forever.
        private func purgeCellCache(keeping ids: Set<String>) {
            guard !cellCache.isEmpty else { return }
            for id in cellCache.keys where !ids.contains(id) {
                cellCache.removeValue(forKey: id)
            }
            cellCacheLRU.removeAll { !ids.contains($0) }
        }

        private func visibleIDs() -> Set<String> {
            guard let tableView else { return [] }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return [] }
            var result = Set<String>()
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                result.insert(orderedIDs[row])
            }
            return result
        }

        func setupScrollObservation(_ scrollView: NSScrollView) {
            // queue: nil — synchronous delivery on the posting (main) thread.
            // Required so `isProgrammaticScroll` still reads true when the
            // notification for our own scroll mutation arrives: with queue:.main
            // the block runs a runloop tick later, after the flag is cleared,
            // and our self-induced bounds change would be mis-stamped as a user
            // scroll — pinning `isUserScrollingRecently` true and killing
            // streaming auto-follow.
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let scrollView = self.scrollView else { return }
                    self.profiler.measureBoundsCallback {
                    if !self.isProgrammaticScroll {
                        // Authoritative user-scroll timestamp — covers mouse
                        // wheels and scroller drags that post no live-scroll
                        // notification at all.
                        self.lastUserScrollTime = CACurrentMediaTime()
                        self.profiler.userScrollTick()
                        // A genuine user-driven bounds change ends the auto-follow
                        // glide immediately (the glide's own scrolls set the
                        // programmatic flag, so they don't reach here).
                        self.stopFollowGlide()
                        // Re-evaluate follow intent from where the *user* left the
                        // viewport: at the bottom → keep following, scrolled away →
                        // stop. This is the ONLY place position decides intent —
                        // the auto-glide's own trailing never flips it, so a glide
                        // running a little behind the bottom can't disengage itself.
                        self.isAutoFollowing = self.isPinnedToBottom(scrollView)
                        self.pendingScrollWork?.cancel()
                        self.pendingScrollWork = nil
                        self.pendingSettleScrollWork?.cancel()
                        self.pendingSettleScrollWork = nil
                        self.pendingScrollSettle = false
                    }
                    // Clip-view bounds change before the scrollView frame notification fires,
                    // so resync column width here to avoid a one-frame horizontal overflow
                    // when the inspector slides in or the window resizes.
                    self.updateColumnWidthIfNeeded()
                    self.publishPinnedState(self.isAutoFollowing)
                    }
                }
            }

            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateColumnWidthIfNeeded()
                }
            }

            // Live-scroll notifications bracket trackpad gestures / scroller
            // drags. They miss discrete mouse wheels entirely — the timestamp
            // stamped in the bounds observer covers those, and the grace window
            // in `isUserScrollingRecently` covers the tail after a gesture ends.
            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = true
                    self.profiler.gestureStart()
                    self.stopFollowGlide()
                    // The user grabbed the scroll — drop follow intent until they
                    // either land back at the bottom or jump to latest.
                    self.isAutoFollowing = false
                    self.publishPinnedState(false)
                }
            }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = false
                    self.profiler.gestureEnd()
                    // Start the grace window from gesture end so a streaming
                    // update arriving right after release can't snap the view.
                    self.lastUserScrollTime = CACurrentMediaTime()
                }
            }
        }

        /// Removes the four NotificationCenter observers and cancels in-flight
        /// DispatchWorkItems. SwiftUI calls `dismantleNSView(_:coordinator:)`
        /// (defined above at `:501-503`) when the representable goes away,
        /// which invokes this — that is the documented teardown contract for
        /// `NSViewRepresentable`. We can't add a defensive `deinit` here under
        /// Swift 6 because `Coordinator` is MainActor-isolated and `deinit`
        /// runs in a nonisolated context.
        func invalidate() {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
            if let liveScrollStartObserver { NotificationCenter.default.removeObserver(liveScrollStartObserver) }
            if let liveScrollEndObserver { NotificationCenter.default.removeObserver(liveScrollEndObserver) }
            boundsObserver = nil
            frameObserver = nil
            liveScrollStartObserver = nil
            liveScrollEndObserver = nil
            pendingHeightWork?.cancel()
            pendingScrollWork?.cancel()
            pendingSettleScrollWork?.cancel()
            pendingRemeasureWork?.cancel()
            pendingWidthWork?.cancel()
            stopFollowGlide()
        }

        func apply(
            items: [PiAgentAppKitTranscriptItem],
            sessionID: UUID?,
            renderRevision: Int,
            streamingRevision: Int,
            autoScrollTurnRevision: Int,
            bottomScrollRequest: Int
        ) {
            guard let tableView, scrollView != nil else { return }
            let wasFollowing = isAutoFollowing
            let isSessionSwitch = self.sessionID != sessionID
            let structuralUpdate = lastRenderRevision != renderRevision
            let streamingUpdate = lastStreamingRevision != streamingRevision
            let explicitScroll = lastAutoScrollTurnRevision != autoScrollTurnRevision || lastBottomScrollRequest != bottomScrollRequest

            let nextIDs = items.map(\.id)
            let idsChanged = nextIDs != orderedIDs
            // True iff some row's content revision moved (mirrors the `changedIDs`
            // test below). Catches updates that don't bump renderRevision/
            // streamingRevision — e.g. skill/visibility/subagent context folded
            // into per-item revisions during itemsBuild.
            let revisionChanged = items.contains { contentRevisionByID[$0.id] != $0.contentRevision }

            // SwiftUI re-runs updateNSView on every screen-body re-evaluation,
            // including ones driven by unrelated state (e.g. sidebar selection).
            // When neither the rows, their revisions, nor any scroll/structural
            // signal moved, there is nothing to do — bail before the O(N)
            // dictionary rebuilds, snapshot diff, reconfigure, scroll handling, and
            // column refit below. (Column width is handled separately in
            // updateNSView via updateColumnWidthIfNeeded.)
            if !isSessionSwitch && !idsChanged && !revisionChanged
                && !structuralUpdate && !streamingUpdate && !explicitScroll {
                return
            }

            self.items = items
            itemByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            let nextRevisions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.contentRevision) })

            if isSessionSwitch || idsChanged {
                let anchor = (!isSessionSwitch && !explicitScroll && !wasFollowing) ? captureScrollAnchor() : nil
                if isSessionSwitch {
                    pendingHeightIDs.removeAll()
                    pendingHeightWork?.cancel()
                    pendingHeightWork = nil
                }
                let previousIDs = Set(orderedIDs)
                let removedIDs = previousIDs.subtracting(nextIDs)
                for id in removedIDs {
                    // Measured heights and revisions are intentionally NOT dropped
                    // here — they persist so a return visit to this session reuses
                    // exact heights. Only the transient estimate and any in-flight
                    // height work for the now-absent row are cleared.
                    estimateByID.removeValue(forKey: id)
                    pendingHeightIDs.remove(id)
                }
                // A changed row KEEPS its last measured height — the cell
                // re-renders and reports the new one via onMeasuredHeight.
                // heightOfRow must never drop a measured row back to the rough
                // char-count estimate, or every streaming token would jump the
                // row estimate↔measured (and a short estimate compounds the gap
                // to the bottom until auto-follow disengages). Only the
                // transient estimate is cleared, for never-measured rows.
                for id in nextIDs {
                    if contentRevisionByID[id] != nil, contentRevisionByID[id] != nextRevisions[id] {
                        estimateByID.removeValue(forKey: id)
                    }
                }
                orderedIDs = nextIDs
                // Release cached cells for rows the transcript no longer has (removed
                // messages, or every row on a session switch) so their views don't
                // linger pinned to absent ids.
                purgeCellCache(keeping: Set(nextIDs))
                for (id, revision) in nextRevisions { contentRevisionByID[id] = revision }
                applySnapshot(ids: nextIDs) { [weak self] in
                    guard let self else { return }
                    // Visible cells whose content changed (same id, new revision) are NOT
                    // reconfigured automatically by the diffable data source — it only
                    // touches cells whose ids changed. Walk the visible window and
                    // reconfigure those whose item revision has shifted.
                    self.reconfigureChangedVisibleCells()
                    self.restoreScrollAnchorIfNeeded(anchor)
                    self.handleScrollAfterUpdate(isSessionSwitch: isSessionSwitch, explicitScroll: explicitScroll, wasFollowing: wasFollowing)
                }
            } else {
                let changedIDs = nextIDs.filter { contentRevisionByID[$0] != nextRevisions[$0] }
                for (id, revision) in nextRevisions { contentRevisionByID[id] = revision }
                if !changedIDs.isEmpty {
                    // Keep the last measured height (see the idsChanged branch):
                    // the cell re-renders and reports the new height, so the
                    // streaming row grows real→real with no estimate jump.
                    for id in changedIDs {
                        estimateByID.removeValue(forKey: id)
                    }
                    reconfigureVisibleCellsForIDs(Set(changedIDs))
                    // Re-tile the changed rows synchronously, in this same pass.
                    // The cell was just handed taller content; if we wait for the
                    // debounced async measurement (~16ms) the row stays tiled at
                    // the old, shorter height in the meantime and the host —
                    // pinned to the cell — renders the new content squished into
                    // the old frame, then snaps when the re-tile lands. That
                    // squish→snap every token is the streaming bubble's up/down
                    // wobble. Measuring now and routing through the existing
                    // noteHeightsChanged keeps the follow/anchor behaviour intact;
                    // the later async report sees no height change and no-ops.
                    //
                    // Throttle: during pure streaming (no structural change) run at
                    // most one synchronous measure+retile per display refresh. A
                    // throttled pulse still reconfigured the cells above; their
                    // async height reports (reportMeasuredHeight → ~16ms debounce)
                    // issue a single trailing retile, so no growth is ever lost.
                    let now = CACurrentMediaTime()
                    let isStreamingOnlyUpdate = streamingUpdate && !structuralUpdate && !isSessionSwitch
                    if !isStreamingOnlyUpdate || now - lastSynchronousRetileTime >= heightReportInterval {
                        lastSynchronousRetileTime = now
                        let retileIDs = profiler.measureForced { measureChangedCellsSynchronously(Set(changedIDs)) }
                        if !retileIDs.isEmpty {
                            flushPendingHeightWorkSynchronously()
                            noteHeightsChanged(forIDs: retileIDs)
                        }
                    }
                } else if streamingUpdate || structuralUpdate {
                    publishPinnedState(isAutoFollowing)
                }
                handleScrollAfterUpdate(isSessionSwitch: false, explicitScroll: explicitScroll, wasFollowing: wasFollowing)
            }

            self.sessionID = sessionID
            lastRenderRevision = renderRevision
            lastStreamingRevision = streamingRevision
            lastAutoScrollTurnRevision = autoScrollTurnRevision
            lastBottomScrollRequest = bottomScrollRequest
            tableView.sizeLastColumnToFit()
            maybeStartScrollBenchmark()
        }

        // MARK: - Scroll benchmark (multi-session)

        /// Entry point, called at the end of every `apply()`. Arms the run the
        /// first time a content-bearing transcript appears, and — once armed —
        /// drives the per-session continuation after each programmatic advance.
        private func maybeStartScrollBenchmark() {
#if DEBUG
            guard UserDefaults.standard.bool(forKey: "ScrollBenchEnabled") else { return }
            guard let tableView else { return }

            if !benchStarted {
                guard tableView.numberOfRows > 5 else { return }   // wait for real content
                benchStarted = true
                benchActive = true
                // Target the scoped session list (not just already-loaded ones —
                // selecting a session lazy-loads its transcript). Empty drafts are
                // skipped at runtime via the row-count guard below; `benchScopedCount`
                // + the advance budget guarantee the sweep terminates after one lap.
                benchScopedCount = benchSessionCount?() ?? 1
                benchTargetSessions = min(benchMaxSessions, max(1, benchScopedCount))
                benchAdvanceBudget = benchScopedCount + benchMaxSessions + 4
                if let id = sessionID { benchSeenIDs.insert(id) }
                TranscriptScrollProfiler.logger.info("SCROLLBENCH armed — sweeping up to \(self.benchTargetSessions) of \(self.benchScopedCount) session(s)")
                scheduleSessionRoutine()
                return
            }

            // Continuation: we just advanced and a new transcript settled in.
            guard benchActive, benchPhase == .advancing else { return }
            if let sessionID = self.sessionID { benchSeenIDs.insert(sessionID) }
            if let sessionID = self.sessionID,
               tableView.numberOfRows > 5,
               !benchVisitedSessionIDs.contains(sessionID) {
                scheduleSessionRoutine()
            } else {
                // Empty/draft or already-tested session — skip straight on.
                advanceOrFinish()
            }
#endif
        }

        /// Let the freshly-shown transcript settle (initial auto-scroll + first
        /// measures), then run its short+long routine.
        private func scheduleSessionRoutine() {
            benchPhase = .settling
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.runSessionRoutine()
            }
        }

        private func runSessionRoutine() {
            guard benchActive, let sessionID = self.sessionID, let tableView else { return }
            benchVisitedSessionIDs.insert(sessionID)
            benchSessionsTested += 1
            let label = "S\(benchSessionsTested)/\(benchTargetSessions):\(sessionID.uuidString.prefix(8))"
            updateBenchFingerprint()
            TranscriptScrollProfiler.logger.info("SCROLLBENCH \(label, privacy: .public) rows=\(tableView.numberOfRows)")

            // Short burst: small local oscillation near current position.
            benchPhase = .shortScroll
            profiler.setBenchTag("\(label) short")
            runScrollPass(duration: benchShortDuration, step: 22) { [weak self] in
                guard let self, self.benchActive else { return }
                // Then several full top↔bottom sweeps back-to-back.
                self.benchPhase = .longScroll
                self.runLongPasses(label: label, remaining: self.benchLongRepeats) { [weak self] in
                    self?.profiler.setBenchTag(nil)
                    self?.advanceOrFinish()
                }
            }
        }

        /// Run `remaining` full top↔bottom sweeps back-to-back, each its own
        /// profiler gesture, then call `completion`.
        private func runLongPasses(label: String, remaining: Int, completion: @escaping @MainActor () -> Void) {
            guard benchActive, remaining > 0 else { completion(); return }
            let idx = benchLongRepeats - remaining + 1
            profiler.setBenchTag("\(label) long \(idx)/\(benchLongRepeats)")
            runScrollPass(duration: benchLongDuration, step: 48) { [weak self] in
                guard let self else { return }
                self.runLongPasses(label: label, remaining: remaining - 1, completion: completion)
            }
        }

        private func advanceOrFinish() {
            benchAdvanceBudget -= 1
            let sweptWholeList = benchSeenIDs.count >= benchScopedCount && benchScopedCount > 0
            if benchSessionsTested >= benchTargetSessions || sweptWholeList || benchAdvanceBudget <= 0 {
                benchActive = false
                benchPhase = .idle
                TranscriptScrollProfiler.logger.info("SCROLLBENCH COMPLETE — tested \(self.benchSessionsTested) session(s); see per-gesture summaries above")
                return
            }
            benchPhase = .advancing
            // Hand off to SwiftUI; the next session's transcript settles into
            // `apply()`, where `maybeStartScrollBenchmark` resumes the machine.
            onBenchAdvanceSession?()
        }

        /// Drive a programmatic scroll for `duration`, stepping `step` points per
        /// frame at ~120Hz and bouncing at the ends, then call `completion`. The
        /// whole pass is bracketed as one profiler gesture (its bounds changes are
        /// non-programmatic here, so they tick the profiler exactly like a real
        /// scroll, and a full SwiftUI cell layout is forced each frame).
        private func runScrollPass(duration: CFTimeInterval, step: CGFloat, completion: @escaping @MainActor () -> Void) {
            guard let scrollView, scrollView.documentView != nil else { completion(); return }
            benchTimer?.invalidate()
            benchStart = CACurrentMediaTime()
            benchDir = -1
            profiler.gestureStart()
            let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let sv = self.scrollView, let dv = sv.documentView else { return }
                    let now = CACurrentMediaTime()
                    let clip = sv.contentView
                    let maxY = max(0, dv.bounds.height - clip.bounds.height)
                    var y = clip.bounds.origin.y + self.benchDir * step
                    if y <= 0 { y = 0; self.benchDir = 1 }
                    else if y >= maxY { y = maxY; self.benchDir = -1 }
                    clip.scroll(to: NSPoint(x: 0, y: y))
                    sv.reflectScrolledClipView(clip)
                    // Live scroll re-lays-out visible cells each frame; emulate that
                    // so the per-frame measure path is exercised, not just a reposition.
                    self.tableView?.layoutSubtreeIfNeeded()
                    if now - self.benchStart > duration {
                        self.benchTimer?.invalidate()
                        self.benchTimer = nil
                        self.profiler.gestureEnd()
                        completion()
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            benchTimer = timer
        }

        /// Feed the profiler a coarse content fingerprint for the current session
        /// so each gesture summary records what was on screen (row count + how many
        /// rows are tall markdown/code) — the "why is *this* chat slow" signal.
        private func updateBenchFingerprint() {
            let width = currentViewportWidth()
            var tall = 0
            var totalEst: CGFloat = 0
            for item in items {
                let h = item.estimatedHeight(width)
                totalEst += h
                if h > 200 { tall += 1 }
            }
            profiler.setContentFingerprint(rows: items.count, tallRows: tall, totalEstHeight: totalEst)
        }

        private func applySnapshot(ids: [String], completion: @escaping () -> Void) {
            var snapshot = NSDiffableDataSourceSnapshot<PiAgentTranscriptTableSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(ids, toSection: .main)
            dataSource?.apply(snapshot, animatingDifferences: false, completion: completion)
        }

        func updateColumnWidthIfNeeded() {
            guard let tableView else { return }
            let width = currentViewportWidth()
            guard abs(width - contentWidth) > 0.5 else { return }
            contentWidth = width
            tableView.tableColumns.first?.width = width
            // Re-fit the table to the clip view so the document view shrinks
            // with it. Setting only the column width leaves the table's own
            // frame stale and wider than the visible area, which lets the
            // transcript be panned/cropped horizontally after a resize.
            tableView.sizeLastColumnToFit()

            // Heights are width-specific, but `measuredHeightByID` is keyed by
            // width bucket — the new width simply selects (or starts) its own
            // bucket, so nothing is wiped. This is the fix for the scroll shake:
            // this method runs from the bounds observer on every scroll, and the
            // old `measuredHeightByID.removeAll()` meant any width recompute
            // (panel toggle, sub-pixel jitter) nuked every measured height and
            // forced a full estimate→measure→re-tile cascade. Only the transient
            // char-count estimates (not bucketed) are dropped.
            estimateByID.removeAll()

            pendingWidthWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingWidthWork = nil
                self.reconfigureAllVisibleCells()
            }
            pendingWidthWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        /// Walk visible rows and reconfigure cells whose content has changed since
        /// they were last configured. Used after a snapshot apply (diffable data
        /// source only reconfigures rows whose ids changed).
        private func reconfigureChangedVisibleCells() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard let item = itemByID[id],
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                // configure() is a no-op when nothing's changed; otherwise the cell
                // measures itself and reports a new height via onHeightChanged.
                configure(cell, with: item, row: row)
            }
        }

        private func reconfigureVisibleCellsForIDs(_ ids: Set<String>) {
            guard let tableView, !ids.isEmpty else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard ids.contains(id),
                      let item = itemByID[id],
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                configure(cell, with: item, row: row)
            }
        }

        /// Force-lay-out the freshly-reconfigured visible cells for `ids` and
        /// write their true heights into `measuredHeightByID` synchronously, so a
        /// re-tile issued in this same pass uses the new content height. Returns
        /// the ids whose tiled height actually needs to change.
        private func measureChangedCellsSynchronously(_ ids: Set<String>) -> Set<String> {
            guard let tableView, !ids.isEmpty else { return [] }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return [] }
            var needRetile = Set<String>()
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard ids.contains(id),
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                let h = cell.forcedIntrinsicHeight()
                guard h > 0 else { continue }
                let height = ceil(h)
                measuredHeightByID[id, default: [:]][widthBucket] = height
                if abs((lastNotedHeight[id] ?? -1) - height) > heightChangeEpsilon {
                    needRetile.insert(id)
                }
            }
            return needRetile
        }

        private func reconfigureAllVisibleCells() {
            guard let tableView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
                let id = orderedIDs[row]
                guard let item = itemByID[id],
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TranscriptTableCellView else { continue }
                // Don't drop the measured height — it's width-bucketed, so the
                // new width's bucket fills in on its own as the cell re-measures
                // and reports. Only the transient estimate is cleared.
                estimateByID.removeValue(forKey: id)
                configure(cell, with: item, row: row)
            }
        }

        private func configure(_ cell: TranscriptTableCellView, with item: PiAgentAppKitTranscriptItem, row: Int) {
            let width = currentViewportWidth()
            // Each cell owns its own NSHostingView for its lifetime. Recycling
            // a cell for a new item just swaps the host's rootView — never
            // detaches the host. That's what keeps multiple visible cells from
            // ever contending for a single shared host (the bug fixed here).
            profiler.noteConfigure()
            cell.installRootView(item: item, width: width, profiler: profiler)
            // No measurement here — the cell reports its real height via
            // `onMeasuredHeight` once it lays out. Until then `heightOfRow`
            // serves the char-count estimate (or a cached real height).
        }

        private func currentViewportWidth() -> CGFloat {
            let viewportCandidates = [
                scrollView?.bounds.width,
                scrollView?.contentView.bounds.width,
                tableView?.enclosingScrollView?.bounds.width,
                tableView?.enclosingScrollView?.contentView.bounds.width
            ].compactMap { $0 }.filter { $0.isFinite && $0 > 1 }
            if let width = viewportCandidates.max() {
                return max(200, width)
            }

            let tableCandidates = [
                tableView?.visibleRect.width,
                tableView?.bounds.width,
                tableView?.tableColumns.first?.width
            ].compactMap { $0 }.filter { $0.isFinite && $0 > 1 }
            return max(200, tableCandidates.max() ?? contentWidth)
        }

        /// Called by a live cell once it has laid out, with the SwiftUI
        /// content's intrinsic height. Updates the cache and (debounced) tells
        /// the table to re-tile the row when the height actually changed.
        func reportMeasuredHeight(_ rawHeight: CGFloat, forItemID itemID: String) {
            let height = ceil(rawHeight)
            let bucket = widthBucket
            let priorMeasured = measuredHeightByID[itemID]?[bucket]
            measuredHeightByID[itemID, default: [:]][bucket] = height
            estimateByID.removeValue(forKey: itemID)
            // Re-tile only when AppKit's *laid-out* height is genuinely stale.
            // The baseline is what the table currently has tiled (lastNotedHeight),
            // not the cache — falling back to the prior measurement, then the
            // rough row estimate. Comparing against the cache would fire a
            // spurious noteHeightOfRows whenever the cache shifted without the
            // laid-out height actually changing.
            let baseline = lastNotedHeight[itemID] ?? priorMeasured ?? estimatedRowHeight
            let delta = abs(baseline - height)
            guard delta > heightChangeEpsilon else { return }
            pendingHeightIDs.insert(itemID)
            guard pendingHeightWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let ids = self.pendingHeightIDs
                self.pendingHeightIDs.removeAll()
                self.pendingHeightWork = nil
                self.noteHeightsChanged(forIDs: ids)
            }
            pendingHeightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + heightReportInterval, execute: work)
        }

        private func noteHeightsChanged(forIDs ids: Set<String>) {
            guard let tableView, scrollView != nil, !ids.isEmpty else { return }
            let wasFollowing = isAutoFollowing
            var rows = IndexSet()
            for id in ids {
                if let row = orderedIDs.firstIndex(of: id), row < tableView.numberOfRows {
                    rows.insert(row)
                    // Record what AppKit is about to lay this row out at — the
                    // baseline future measurements are compared against.
                    // reportMeasuredHeight already wrote the fresh height into
                    // measuredHeightByID before scheduling this call.
                    if let h = measuredHeightByID[id]?[widthBucket] { lastNotedHeight[id] = h }
                }
            }
            guard !rows.isEmpty else { return }
            // A row re-tiling to its true height shifts everything below it.
            // NSTableView pins row 0 to the document top, so a correction to any
            // row above the viewport yanks visible content out from under the
            // reader. Capture the top-visible row and restore its on-screen
            // offset right after the re-tile so the shift is absorbed silently.
            //
            // Preserve the anchor whenever we're not pinned — INCLUDING while the
            // user is actively scrolling. Scrolling up through history is exactly
            // when never-measured rows above the viewport first resolve from their
            // rough estimate to a real height (a +1000pt correction is common for a
            // long reply), and leaving those uncompensated is what makes the
            // transcript lurch under the reader. Restoring the top-visible row's
            // on-screen offset does NOT fight the gesture: capture and restore run
            // synchronously around `noteHeightOfRows` here (no stale anchor), and
            // `restoreScrollAnchor` self-guards — when the changed rows are at or
            // below the anchor row its minY is unchanged, so the target equals the
            // current origin and no scroll happens. The viewport only moves when a
            // row *above* the anchor reflowed, which is precisely the shift we want
            // to absorb. (Was previously gated on `!isUserScrollingRecently`, which
            // disabled compensation during the one gesture that needs it most.)
            // Every re-tile must compensate one way or the other: follow to the
            // bottom when auto-following, otherwise hold the top-visible anchor. The
            // one case that must NOT be left bare is "following but the user just
            // started scrolling" (wasFollowing && isUserScrollingRecently): autoFollow
            // is off (we don't yank a scrolling user to the bottom) so the anchor must
            // carry it, or the streaming row grows with nothing holding position.
            let willAutoFollow = wasFollowing && !isUserScrollingRecently
            let preserveAnchor = !willAutoFollow
            let anchor = preserveAnchor ? captureScrollAnchor() : nil
            profiler.measureRetile(rows: rows.count) {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            // Suppress implicit Core Animation actions so a streaming row's
            // height change re-tiles instantly with no per-token animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Flag the whole re-tile as programmatic. `noteHeightOfRows` /
            // `layoutSubtreeIfNeeded` can nudge the clip origin by a sub-pixel as
            // AppKit re-lays the rows; that nudge posts a boundsDidChange, and if
            // the flag isn't set the observer mistakes it for a *user* scroll. On a
            // streaming row that fires every token, re-stamping `lastUserScrollTime`
            // continuously — which pins `isUserScrollingRecently` true and the
            // auto-follow off until the stream ends (a stray touch could leave the
            // view parked below the latest content for the rest of the response).
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            tableView.noteHeightOfRows(withIndexesChanged: rows)
            if let anchor {
                // rect(ofRow:) must see the new heights before we re-anchor.
                tableView.layoutSubtreeIfNeeded()
                restoreScrollAnchor(anchor)
            }
            isProgrammaticScroll = wasProgrammatic
            CATransaction.commit()
            NSAnimationContext.endGrouping()
            }
            if willAutoFollow {
                scrollToBottom(settle: false)
            }
        }

        private func flushPendingHeightWorkSynchronously() {
            guard let work = pendingHeightWork else { return }
            work.cancel()
            pendingHeightWork = nil
            let ids = pendingHeightIDs
            pendingHeightIDs.removeAll()
            noteHeightsChanged(forIDs: ids)
        }

        private func captureScrollAnchor() -> ScrollAnchor? {
            guard let tableView, let scrollView else { return nil }
            let originY = scrollView.contentView.bounds.origin.y
            let row = tableView.row(at: NSPoint(x: 0, y: originY))
            guard row >= 0, row < orderedIDs.count else { return nil }
            let rowRect = tableView.rect(ofRow: row)
            return ScrollAnchor(id: orderedIDs[row], offsetFromRowTop: originY - rowRect.minY)
        }

        private func restoreScrollAnchorIfNeeded(_ anchor: ScrollAnchor?) {
            // Don't restore over a live user gesture — let their scroll stand.
            // (The height-change compensation path uses `restoreScrollAnchor`
            // directly, since there it must run *during* the gesture.)
            guard !isUserScrollingRecently, let anchor else { return }
            restoreScrollAnchor(anchor)
        }

        /// Re-scroll so `anchor`'s row sits at the same on-screen offset it had
        /// when the anchor was captured. Unlike `restoreScrollAnchorIfNeeded`,
        /// this runs even mid-gesture — it is the height-change compensation
        /// that keeps a row re-tile from shifting content under the user.
        private func restoreScrollAnchor(_ anchor: ScrollAnchor) {
            guard let tableView, let scrollView,
                  let row = orderedIDs.firstIndex(of: anchor.id),
                  row >= 0, row < tableView.numberOfRows,
                  let documentView = scrollView.documentView else { return }
            let rowRect = tableView.rect(ofRow: row)
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            let targetY = min(max(0, rowRect.minY + anchor.offsetFromRowTop), maxY)
            let originY = scrollView.contentView.bounds.origin.y
            guard abs(originY - targetY) > 0.5 else { return }
            // Save/restore rather than force-false: this runs nested inside the
            // `noteHeightsChanged` re-tile, which holds the flag true around the
            // whole transaction. Clearing it here would unflag the rest of that
            // transaction's AppKit-driven origin nudges.
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isProgrammaticScroll = wasProgrammatic
        }

        private func handleScrollAfterUpdate(isSessionSwitch: Bool, explicitScroll: Bool, wasFollowing: Bool) {
            guard scrollView != nil else { return }
            if isSessionSwitch || explicitScroll {
                // An explicit request (send, jump-to-latest) or a session
                // switch always wins — the user isn't fighting it. Re-arm
                // follow intent so streaming after the jump keeps tracking.
                isAutoFollowing = true
                scrollToBottom(settle: true)
            } else if wasFollowing && !isUserScrollingRecently {
                // Passive streaming follow — but never while the user is
                // actively scrolling, or it would yank the viewport.
                scrollToBottom(settle: false)
            } else {
                publishPinnedState(isAutoFollowing)
            }
        }

        private func scrollToBottom(settle: Bool) {
            pendingScrollSettle = pendingScrollSettle || settle
            guard pendingScrollWork == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                let shouldSettle = self.pendingScrollSettle
                self.pendingScrollWork = nil
                self.pendingScrollSettle = false
                // Streaming follow (settle == false) glides; explicit / session
                // switch (settle == true) snaps.
                self.performScrollToBottom(scrollView, animated: !shouldSettle)
                guard shouldSettle else { return }
                self.pendingSettleScrollWork?.cancel()
                let settleWork = DispatchWorkItem { [weak self] in
                    guard let self, let scrollView = self.scrollView else { return }
                    self.pendingSettleScrollWork = nil
                    // Don't force a re-measure here — pre-measurement and the synchronous
                    // height-work flush inside performScrollToBottom mean heights are already
                    // accurate. Re-measuring would risk a small secondary scroll jump.
                    self.performScrollToBottom(scrollView, animated: false)
                }
                self.pendingSettleScrollWork = settleWork
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: settleWork)
            }
            pendingScrollWork = work
            DispatchQueue.main.async(execute: work)
        }

        private func performScrollToBottom(_ scrollView: NSScrollView, animated: Bool) {
            guard let documentView = scrollView.documentView else { return }
            // Cheap pre-check: when no height work is pending (so the content
            // height is already settled) and the current bounds already place us at
            // the bottom, skip the forced flush + full-document layout below. This
            // is the common case for auto-follow glide ticks and bounds-callback
            // re-checks — running `layoutSubtreeIfNeeded()` there cost a full layout
            // pass (~50ms on large transcripts) just to confirm we hadn't moved.
            if pendingHeightIDs.isEmpty {
                let clipView = scrollView.contentView
                let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
                if abs(clipView.bounds.origin.y - maxY) <= 1 {
                    stopFollowGlide()
                    publishPinnedState(true)
                    return
                }
            }
            // Flush any debounced height work and force a layout pass so the documentView's
            // bounds reflect current row heights. Without this, the math below uses stale
            // heights and ends up scrolling short of the true bottom — which crops the last
            // assistant message during streaming.
            flushPendingHeightWorkSynchronously()
            documentView.layoutSubtreeIfNeeded()
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            let clipView = scrollView.contentView
            guard abs(clipView.bounds.origin.y - maxY) > 1 else {
                stopFollowGlide()
                publishPinnedState(true)
                return
            }
            // Streaming follow: hand off to the glide timer, which eases toward the
            // (still-growing) bottom over the next frames instead of snapping.
            if animated {
                startFollowGlide()
                return
            }
            // Explicit / settle: snap immediately.
            stopFollowGlide()
            isProgrammaticScroll = true
            clipView.scroll(to: NSPoint(x: 0, y: maxY))
            scrollView.reflectScrolledClipView(clipView)
            isProgrammaticScroll = false
            publishPinnedState(true)
        }

        /// Begin (or keep) easing the clip origin toward the document bottom each
        /// frame. Idempotent — if a glide is already running it simply continues
        /// and naturally picks up the new, larger bottom on its next tick.
        private func startFollowGlide() {
            guard followGlideTimer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    // self is nil only after the coordinator tore down, which
                    // invalidates this timer in `invalidate()`; nothing to do here.
                    self?.stepFollowGlide()
                }
            }
            // .common so the glide keeps ticking during resize / tracking runloop modes.
            RunLoop.main.add(timer, forMode: .common)
            followGlideTimer = timer
        }

        private func stepFollowGlide() {
            guard let scrollView, let documentView = scrollView.documentView else {
                stopFollowGlide()
                return
            }
            // The user's scroll is authoritative — disengage and let it stand.
            if isUserScrollingRecently {
                stopFollowGlide()
                return
            }
            let clipView = scrollView.contentView
            let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
            let current = clipView.bounds.origin.y
            let gap = maxY - current
            // Within a frame's worth of the bottom — land exactly and stop.
            guard abs(gap) > 0.5 else {
                if abs(gap) > 0.01 {
                    isProgrammaticScroll = true
                    clipView.scroll(to: NSPoint(x: 0, y: maxY))
                    scrollView.reflectScrolledClipView(clipView)
                    isProgrammaticScroll = false
                }
                stopFollowGlide()
                publishPinnedState(true)
                return
            }
            let nextY = current + gap * followGlideFactor
            isProgrammaticScroll = true
            clipView.scroll(to: NSPoint(x: 0, y: nextY))
            scrollView.reflectScrolledClipView(clipView)
            isProgrammaticScroll = false
        }

        private func stopFollowGlide() {
            followGlideTimer?.invalidate()
            followGlideTimer = nil
        }

        private func isPinnedToBottom(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return true }
            let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            return maxY - scrollView.contentView.bounds.origin.y < 80
        }

        private func publishPinnedState(_ pinned: Bool) {
            guard pinned != lastPinnedState else { return }
            lastPinnedState = pinned
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
                self?.onPinnedToBottomChange(pinned)
            }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            TranscriptTableRowView()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < orderedIDs.count else { return estimatedRowHeight }
            let id = orderedIDs[row]
            // Prefer a real measurement for the current width — it survives
            // width changes and session switches, so a revisited row lays out at
            // its exact height with no reflow.
            if let measured = measuredHeightByID[id]?[widthBucket] { return measured }
            if let estimate = estimateByID[id] { return estimate }
            // No measurement yet — use the item's fast estimator so the table can lay
            // the row out close to its natural size without triggering a SwiftUI pass.
            // The cell measures precisely as it renders and reports back via
            // reportMeasuredHeight, at which point this row gets re-tiled.
            if let item = itemByID[id] {
                let est = item.estimatedHeight(contentWidth)
                estimateByID[id] = est
                return est
            }
            return estimatedRowHeight
        }
    }

    /// Clip view for the transcript scroll view. The transcript never scrolls
    /// horizontally, so the bounds origin is pinned to x = 0 — this guarantees
    /// the content can't be panned sideways even if the document view is
    /// transiently wider than the clip view during a resize or divider drag.
    final class TranscriptClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds)
            rect.origin.x = 0
            return rect
        }
    }

    final class TranscriptTableRowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { false }
            set { }
        }

        override func drawSelection(in dirtyRect: NSRect) { }
        override func drawBackground(in dirtyRect: NSRect) { }
    }

    final class TranscriptTableCellView: NSTableCellView {
        static let reuseIdentifier = NSUserInterfaceItemIdentifier("PiAgentTranscriptTableCell")
        // Native render path (no SwiftUI / NSHostingView). `nativeRow` is the
        // concrete view; `nativeRowTypeID`/`nativeRowSpec` track which kind it is
        // so a recycled cell reuses a same-typed view and reads the row height
        // through the spec's measure closure.
        fileprivate var nativeRow: NSView?
        private var nativeRowTypeID: ObjectIdentifier?
        private var nativeRowSpec: NativeRowSpec?
        private var nativeTopC: NSLayoutConstraint?
        private var nativeBottomC: NSLayoutConstraint?
        private var configuredTopInset: CGFloat = 0
        private var configuredBottomInset: CGFloat = 0
        fileprivate var configuredItemID: String?
        private var configuredRevision: Int?
        fileprivate var configuredWidth: CGFloat = 0
        fileprivate var lastIntrinsicHeight: CGFloat = -1
        fileprivate weak var profiler: TranscriptScrollProfiler?

        /// Wired by the coordinator at cell-vend time. Reports this row's true
        /// height — the hosted SwiftUI content's intrinsic size — whenever it
        /// changes. The cell already laid out to display, so reading its size
        /// is essentially free; there is no second offscreen render.
        var onMeasuredHeight: ((String, CGFloat) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Configure the cell for an item. Every row is native; the spec's view is
        /// built/reused and pinned to the cell with the row insets.
        func installRootView(item: PiAgentAppKitTranscriptItem, width: CGFloat, profiler: TranscriptScrollProfiler? = nil) {
            self.profiler = profiler
            guard case .native(let spec) = item.kind else { return }
            installNativeRow(spec: spec, item: item, width: width)
        }

        /// Tear down the native row view (when a recycled cell switches to a
        /// different native view type).
        private func teardownNativeRow() {
            guard let row = nativeRow else { return }
            nativeRowSpec?.reset(row)
            row.removeFromSuperview()
            nativeRow = nil
            nativeRowTypeID = nil
            nativeRowSpec = nil
            nativeTopC = nil
            nativeBottomC = nil
            lastIntrinsicHeight = -1
        }

        /// Native render path: build/configure the spec's view pinned to the cell
        /// with the row insets, rebuilding if the recycled cell held a different
        /// view type.
        private func installNativeRow(spec: NativeRowSpec, item: PiAgentAppKitTranscriptItem, width: CGFloat) {
            // A recycled cell holding a different native view type must rebuild it.
            if let existingType = nativeRowTypeID, existingType != spec.typeID {
                teardownNativeRow()
            }
            let row: NSView
            let createdNow: Bool
            if let existing = nativeRow {
                row = existing
                createdNow = false
            } else {
                createdNow = true
                row = spec.make()
                row.translatesAutoresizingMaskIntoConstraints = false
                addSubview(row)
                // Full-width row; the view sizes/positions its own content.
                let top = row.topAnchor.constraint(equalTo: topAnchor, constant: item.topInset)
                let bottom = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -item.bottomInset)
                // During a diffable `apply`, AppKit briefly sets each row to its
                // default 17pt height (its `NSView-Encapsulated-Layout-Height`)
                // before it consults `heightOfRow`. A row whose content has firm
                // internal pins — e.g. a tool-group card pinned top+bottom — can't
                // fit 17pt, so a REQUIRED bottom pin makes AppKit break-and-log a
                // constraint every apply. Drop the bottom pin just below required so
                // it silently yields during that transient and is satisfied exactly
                // once the real row height lands (measurement is unaffected — height
                // comes from `spec.measure`, not these pins).
                bottom.priority = .required - 1
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: trailingAnchor),
                    top, bottom
                ])
                nativeTopC = top
                nativeBottomC = bottom
                nativeRow = row
                nativeRowTypeID = spec.typeID
                lastIntrinsicHeight = -1
            }
            nativeRowSpec = spec
            // Let an interactive native row (e.g. expanding a list) ask the cell to
            // re-measure and the table to re-tile when its content height changes.
            spec.setHeightCallback(row) { [weak self] in
                guard let self, let itemID = self.configuredItemID, self.configuredWidth > 1 else { return }
                let h = self.forcedIntrinsicHeight()
                if h > 0 { self.onMeasuredHeight?(itemID, h) }
            }
            let insetChanged = configuredTopInset != item.topInset || configuredBottomInset != item.bottomInset
            if insetChanged {
                nativeTopC?.constant = item.topInset
                nativeBottomC?.constant = -item.bottomInset
            }

            let itemChanged = configuredItemID != item.id
            let revisionChanged = itemChanged || configuredRevision != item.contentRevision
            let widthChanged = abs(configuredWidth - width) > 0.5
            if revisionChanged || widthChanged {
                spec.configure(row, width)
                lastIntrinsicHeight = -1
            }
            // `settle` is the immediate layout pass that stops a layer painting at a
            // stale position. With per-item cells (one cell per id, never recycled to a
            // different item) there is no stale recycled position to fix on a fresh
            // build — and forcing the layout here would lay out rows that scroll past
            // before they're ever displayed, the dominant cold-scroll cost. So skip it
            // on first build (`createdNow`) and on streaming appends (same id/width),
            // running it only when an already-displayed cell changes geometry (width or
            // inset). The cell still lays out + reports its real height naturally via
            // `layout()` when AppKit displays it.
            if !createdNow && (widthChanged || insetChanged) {
                spec.settle(row)
            }
            configuredItemID = item.id
            configuredRevision = item.contentRevision
            configuredWidth = width
            configuredTopInset = item.topInset
            configuredBottomInset = item.bottomInset
        }

        private var pendingLayoutHeightReport = false

        /// AppKit's per-pass layout hook, and where the row reports height drift.
        override func layout() {
            if let profiler {
                profiler.measureCellLayout { super.layout() }
            } else {
                super.layout()
            }
            guard nativeRow != nil, nativeRowSpec != nil, configuredItemID != nil, configuredWidth > 1 else { return }
            // Reporting height means MEASURING the row, which forces its subtree to
            // lay out. AppKit recurses into that subtree only AFTER this `layout()`
            // returns, so forcing it here is illegal re-entrancy — it logs
            // `_NSDetectedLayoutRecursion` (captured: cell.layout → spec.measure →
            // NativeMarkdownTextContainer.measureHeight → stackView.layoutSubtreeIfNeeded
            // inside `_layoutSubtreeWithOldSize`). Hop out of the pass and measure
            // once it has completed; coalesced so streaming's many passes don't
            // stack up. Until it lands, `heightOfRow` keeps the row's estimate, and
            // freshly-streamed rows already report synchronously via
            // `forcedIntrinsicHeight()` — this path only catches later drift.
            scheduleLayoutHeightReport()
        }

        private func scheduleLayoutHeightReport() {
            guard !pendingLayoutHeightReport else { return }
            pendingLayoutHeightReport = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingLayoutHeightReport = false
                guard let row = self.nativeRow, let spec = self.nativeRowSpec,
                      let itemID = self.configuredItemID, self.configuredWidth > 1 else { return }
                let h = self.configuredTopInset + spec.measure(row, self.configuredWidth) + self.configuredBottomInset
                guard h > 0, h.isFinite, abs(h - self.lastIntrinsicHeight) > 0.5 else { return }
                self.lastIntrinsicHeight = h
                self.onMeasuredHeight?(itemID, h)
            }
        }

        /// Force the native row to lay out *now* and return its height, instead of
        /// waiting for AppKit's async `layout()` pass to report it. Used right after
        /// installing new streaming content so the coordinator can re-tile the row
        /// in the same pass. Records `lastIntrinsicHeight` so the subsequent async
        /// `layout()` sees no change and doesn't redundantly re-report.
        func forcedIntrinsicHeight() -> CGFloat {
            guard let row = nativeRow, let spec = nativeRowSpec, configuredWidth > 1 else { return -1 }
            row.layoutSubtreeIfNeeded()
            let h = configuredTopInset + spec.measure(row, configuredWidth) + configuredBottomInset
            guard h > 0, h.isFinite else { return -1 }
            lastIntrinsicHeight = h
            return h
        }
    }
}

extension PiAgentTranscriptThread {
    var timelineTimestamp: Date {
        let activityEntries = activities.compactMap(\.representativeEntry)
        let candidates = [question].compactMap { $0 }
            + steeringMessages
            + thinkingParts
            + assistantMessages
            + activityEntries
            + statuses
            + errors
        return candidates.map(\.timestamp).min() ?? .distantPast
    }
}

/// The session list, isolated as an `Equatable` view so it can be wrapped in
/// `.equatable()`. It lives next to the transcript inside `PiAgentScreen.body`,
/// which re-runs at the streaming cadence (the transcript render cache is an
/// ObservableObject, so any of its published changes invalidates the whole body).
/// A SwiftUI `List` re-measures every row whenever its enclosing view updates —
/// even when the rows themselves are unchanged — so those pulses were re-laying
/// out the entire list ~30×/sec (the dominant `sizeThatFits` cost in the scroll
/// profiles). Comparing the value inputs lets SwiftUI skip the list entirely on a
/// pulse and rebuild it only when something it actually shows changed.
///
/// All per-row dynamic state (selection, running, renaming, title-generating, git
/// activity, project) is passed in as resolved values and compared in `==`, so the
/// list can never go stale: a real change to any of them differs the inputs and
/// forces a rebuild. Bindings and callbacks are intentionally excluded from `==`.
