import Foundation
import QuartzCore
import os

/// Lightweight, in-place scroll profiler for the Pi Agent transcript.
///
/// The transcript is an `NSTableView` of `NSHostingView`-backed cells (see
/// `PiAgentAppKitTranscriptView.Coordinator`). Scroll jank in that design comes
/// from main-thread work that lands *between* scroll frames: building a SwiftUI
/// root when a cell is vended, a row re-tile (`noteHeightOfRows` +
/// `layoutSubtreeIfNeeded` + anchor restore) when a never-measured row first
/// resolves its real height, or anything synchronous in the bounds observer.
///
/// This profiler frames each scroll gesture, watches the gap between
/// user-driven bounds ticks (a stalled main thread shows up as a long gap = a
/// dropped frame), and attributes time to each suspect op. On gesture end (or
/// after the scroll goes idle) it emits one summary line so you can see, per
/// gesture: how many frames hitched, the worst gap, and where the time went.
///
/// ## Reading the logs
/// No sandbox, so `os.Logger` is visible system-wide. After scrolling:
/// ```
/// log show --last 2m --predicate 'subsystem == "streetcoding.agent-deck" AND category == "ScrollPerf"' --info
/// ```
/// or live:
/// ```
/// log stream --predicate 'subsystem == "streetcoding.agent-deck" AND category == "ScrollPerf"' --info
/// ```
///
/// Toggle off via `defaults write streetcoding.agent-deck ScrollPerfEnabled -bool NO`
/// (defaults ON while we hunt this down — it is cheap: a couple of timestamp
/// reads per scroll frame, all threshold-gated so nothing logs when smooth).
@MainActor
final class TranscriptScrollProfiler {
    static let logger = Logger(subsystem: "streetcoding.agent-deck", category: "ScrollPerf")
    static let signposter = OSSignposter(subsystem: "streetcoding.agent-deck", category: "ScrollPerf")

    /// Master switch. DEBUG builds only (defaults ON, toggleable); release builds
    /// compile it to a constant `false`, so every `measure*` is a pass-through and
    /// nothing logs in production.
    static let isEnabled: Bool = {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "ScrollPerfEnabled") == nil { return true }
        return defaults.bool(forKey: "ScrollPerfEnabled")
        #else
        return false
        #endif
    }()

    // A 60 Hz frame is 16.67 ms. Treat a gap between consecutive user-driven
    // bounds ticks above this as a dropped frame ("hitch") — the main thread
    // couldn't service the scroll in time.
    private let hitchThresholdMs: Double = 24
    // Per-op single-event log threshold. An individual op slower than this is
    // worth surfacing on its own line, not just in the gesture aggregate.
    private let opLogThresholdMs: Double = 4
    // Idle gap that ends a gesture for devices that post no live-scroll
    // notifications (discrete mouse wheel). Trackpad/scroller use start/end.
    private let idleFlushMs: Double = 300
    // A hitch at or above this gap triggers a one-shot external backtrace via
    // HangWatchdog — the decisive capture for sustained "feels slow" jank that
    // never reaches the 150ms hang threshold. HangWatchdog throttles the
    // captures, so this can fire freely. Disable with
    // `defaults write streetcoding.agent-deck ScrollPerfBacktrace -bool NO`.
    private let backtraceThresholdMs: Double = 45
    private static let backtraceOnHitch: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "ScrollPerfBacktrace") == nil { return true }
        return defaults.bool(forKey: "ScrollPerfBacktrace")
    }()

    /// Optional label stamped onto every gesture summary + hitch line — set by
    /// the scroll benchmark to "S2/4 long abc123" so each gesture is attributable
    /// to a specific session + phase across an automated multi-session run.
    var benchTag: String?
    /// Coarse description of what's on screen, set at gesture/bench start, so a
    /// slow gesture is correlated with content shape ("why these sessions").
    var contentFingerprint: String?

    func setBenchTag(_ tag: String?) { benchTag = tag }
    func setContentFingerprint(rows: Int, tallRows: Int, totalEstHeight: CGFloat) {
        contentFingerprint = "rows=\(rows) tall=\(tallRows) estH=\(Int(totalEstHeight))"
    }

    // MARK: Body-side instrumentation (static)
    //
    // The `PiAgentAppKitTranscriptView` representable is a SwiftUI value type
    // with no handle on the coordinator's profiler instance. These static
    // hooks measure the work that happens in the SwiftUI body / representable
    // update path: rebuilding the `items` array (an AnyView per row) and the
    // `updateNSView` apply. Both log every call over a low threshold AND every
    // Nth call regardless, so the per-second call frequency is visible — that
    // distinguishes "body re-evaluates every scroll frame" from "rare rebuild".
    private static var bodyCounters: [String: Int] = [:]

    static func measureBody<T>(_ label: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let t = CACurrentMediaTime()
        let r = body()
        let dt = (CACurrentMediaTime() - t) * 1000
        let n = (bodyCounters[label] ?? 0) + 1
        bodyCounters[label] = n
        // Log if slow, OR every 20th call (so cadence is always visible even
        // when each call is cheap).
        if dt > 2 || n % 20 == 0 {
            logger.info("\(label, privacy: .public) \(dt, format: .fixed(precision: 1))ms (call #\(n))")
        }
        return r
    }

    // MARK: Per-gesture accumulator
    private struct Window {
        var startTime: CFTimeInterval
        var lastTickTime: CFTimeInterval
        var tickCount = 0
        var hitchCount = 0
        var maxGapMs: Double = 0
        var sumGapMs: Double = 0

        var configures = 0
        var rootSwaps = 0
        var rootSwapMs: Double = 0
        var maxRootSwapMs: Double = 0
        var hostCreates = 0
        var hostCreateMs: Double = 0

        var retiles = 0
        var retiledRows = 0
        var retileMs: Double = 0
        var maxRetileMs: Double = 0

        var forcedMeasures = 0
        var forcedMeasureMs: Double = 0

        // The deferred SwiftUI layout/draw of a hosting view, captured in the
        // cell's AppKit layout() pass — the work that actually lands *after* a
        // cheap rootView swap.
        var cellLayouts = 0
        var cellLayoutMs: Double = 0
        var maxCellLayoutMs: Double = 0

        // Synchronous time spent inside the bounds observer itself (our own
        // per-tick code: width resync, pinned-state publish, follow decisions).
        var boundsTicks = 0
        var boundsMs: Double = 0
        var maxBoundsMs: Double = 0
    }

    private var window: Window?
    private var idleFlush: DispatchWorkItem?
    private var gestureSeq = 0
    /// Live os_signpost interval for the current gesture — lets Instruments'
    /// timeline (Time Profiler / os_signpost lanes) align CPU samples and the
    /// deferred CoreAnimation/TextKit work to the exact gesture that hitched,
    /// covering the work this profiler can't measure synchronously in-process.
    private var gestureSignpost: OSSignpostIntervalState?

    private func now() -> CFTimeInterval { CACurrentMediaTime() }

    private func ms(_ a: CFTimeInterval, _ b: CFTimeInterval) -> Double { (a - b) * 1000 }

    // MARK: Gesture framing

    /// A trackpad gesture / scroller drag began (`willStartLiveScroll`).
    func gestureStart() {
        guard Self.isEnabled else { return }
        flush(reason: "newGesture")
        beginWindow()
    }

    /// A trackpad gesture / scroller drag ended (`didEndLiveScroll`).
    func gestureEnd() {
        guard Self.isEnabled else { return }
        scheduleIdleFlush()
    }

    private func beginWindow() {
        let t = now()
        gestureSeq += 1
        window = Window(startTime: t, lastTickTime: t)
        let id = Self.signposter.makeSignpostID()
        gestureSignpost = Self.signposter.beginInterval("scrollGesture", id: id)
    }

    /// One user-driven (non-programmatic) clip-bounds change. Called from the
    /// bounds observer. Measures the gap to the previous tick to spot dropped
    /// frames, and lazily opens a window for wheel scrolls that never sent a
    /// live-scroll start.
    func userScrollTick() {
        guard Self.isEnabled else { return }
        let t = now()
        if window == nil { beginWindow() }
        guard var w = window else { return }
        if w.tickCount > 0 {
            let gap = ms(t, w.lastTickTime)
            w.sumGapMs += gap
            if gap > w.maxGapMs { w.maxGapMs = gap }
            if gap > hitchThresholdMs {
                w.hitchCount += 1
                Self.logger.info("hitch Δ=\(gap, format: .fixed(precision: 1))ms (gesture #\(self.gestureSeq)) \(self.benchTag ?? "", privacy: .public)")
                Self.signposter.emitEvent("hitch", "gap=\(Int(gap))ms")
                // The decisive capture: a real backtrace of whatever blocked the
                // frame, for jank too brief to trip the hang watchdog.
                if Self.backtraceOnHitch, gap >= backtraceThresholdMs {
                    HangWatchdog.shared.captureHitch(gapMs: Int(gap))
                }
            }
        }
        w.tickCount += 1
        w.lastTickTime = t
        window = w
        scheduleIdleFlush()
    }

    private func scheduleIdleFlush() {
        idleFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush(reason: "idle")
        }
        idleFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleFlushMs / 1000, execute: work)
    }

    private func flush(reason: String) {
        idleFlush?.cancel()
        idleFlush = nil
        guard let w = window, w.tickCount > 0 else {
            window = nil
            if let s = gestureSignpost { Self.signposter.endInterval("scrollGesture", s); gestureSignpost = nil }
            return
        }
        window = nil
        if let s = gestureSignpost {
            Self.signposter.endInterval("scrollGesture", s, "hitches=\(w.hitchCount) maxGap=\(Int(w.maxGapMs))ms")
            gestureSignpost = nil
        }
        let durMs = ms(w.lastTickTime, w.startTime)
        let avgGap = w.tickCount > 1 ? w.sumGapMs / Double(w.tickCount - 1) : 0
        Self.logger.info("""
        gesture #\(self.gestureSeq) [\(reason, privacy: .public)] \(self.benchTag ?? "", privacy: .public) \(self.contentFingerprint ?? "", privacy: .public) \
        \(w.tickCount) ticks / \(durMs, format: .fixed(precision: 0))ms · \
        hitches=\(w.hitchCount) maxGap=\(w.maxGapMs, format: .fixed(precision: 1))ms avgGap=\(avgGap, format: .fixed(precision: 1))ms │ \
        configures=\(w.configures) rootSwaps=\(w.rootSwaps)(\(w.rootSwapMs, format: .fixed(precision: 1))ms,max \(w.maxRootSwapMs, format: .fixed(precision: 1))) \
        hostCreate=\(w.hostCreates)(\(w.hostCreateMs, format: .fixed(precision: 1))ms) │ \
        retiles=\(w.retiles)/rows \(w.retiledRows)(\(w.retileMs, format: .fixed(precision: 1))ms,max \(w.maxRetileMs, format: .fixed(precision: 1))) \
        forced=\(w.forcedMeasures)(\(w.forcedMeasureMs, format: .fixed(precision: 1))ms) │ \
        cellLayout=\(w.cellLayouts)(\(w.cellLayoutMs, format: .fixed(precision: 1))ms,max \(w.maxCellLayoutMs, format: .fixed(precision: 1))) \
        boundsCb=\(w.boundsTicks)(\(w.boundsMs, format: .fixed(precision: 1))ms,max \(w.maxBoundsMs, format: .fixed(precision: 1)))
        """)
    }

    // MARK: Op timers — call around the suspected hot paths.

    /// Wrap the SwiftUI root swap in `installRootView` (existing host gets a new
    /// `rootView`). This forces a SwiftUI build/layout for the cell.
    func measureRootSwap<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = Self.signposter.withIntervalSignpost("rootSwap") { body() }
        let dt = ms(now(), t)
        if window != nil {
            window!.rootSwaps += 1
            window!.rootSwapMs += dt
            if dt > window!.maxRootSwapMs { window!.maxRootSwapMs = dt }
        }
        if dt > opLogThresholdMs {
            Self.logger.info("rootSwap \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Wrap the first-time `NSHostingView` creation in `installRootView`.
    func measureHostCreate<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = body()
        let dt = ms(now(), t)
        if window != nil {
            window!.hostCreates += 1
            window!.hostCreateMs += dt
        }
        if dt > opLogThresholdMs {
            Self.logger.info("hostCreate \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Count a cell configure (cheap; just a counter to gauge churn per gesture).
    func noteConfigure() {
        guard Self.isEnabled, window != nil else { return }
        window!.configures += 1
    }

    /// Wrap the whole `noteHeightsChanged` re-tile (noteHeightOfRows +
    /// layoutSubtreeIfNeeded + anchor restore) — the row-resolve lurch suspect.
    func measureRetile<T>(rows: Int, _ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = Self.signposter.withIntervalSignpost("retile") { body() }
        let dt = ms(now(), t)
        if window != nil {
            window!.retiles += 1
            window!.retiledRows += rows
            window!.retileMs += dt
            if dt > window!.maxRetileMs { window!.maxRetileMs = dt }
        }
        if dt > opLogThresholdMs {
            Self.logger.info("retile rows=\(rows) \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Wrap the cell's `layout()` pass — this is where the deferred SwiftUI
    /// layout/draw of a freshly-swapped `rootView` actually lands.
    func measureCellLayout<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = Self.signposter.withIntervalSignpost("cellLayout") { body() }
        let dt = ms(now(), t)
        if window != nil {
            window!.cellLayouts += 1
            window!.cellLayoutMs += dt
            if dt > window!.maxCellLayoutMs { window!.maxCellLayoutMs = dt }
        }
        if dt > opLogThresholdMs {
            Self.logger.info("cellLayout \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Wrap the bounds-observer body — our own synchronous per-scroll-tick work.
    func measureBoundsCallback<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = body()
        let dt = ms(now(), t)
        if window != nil {
            window!.boundsTicks += 1
            window!.boundsMs += dt
            if dt > window!.maxBoundsMs { window!.maxBoundsMs = dt }
        }
        if dt > opLogThresholdMs {
            Self.logger.info("boundsCb \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Wrap a synchronous forced measurement (`forcedIntrinsicHeight` batches).
    func measureForced<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = Self.signposter.withIntervalSignpost("forcedMeasure") { body() }
        let dt = ms(now(), t)
        if window != nil {
            window!.forcedMeasures += 1
            window!.forcedMeasureMs += dt
        }
        if dt > opLogThresholdMs {
            Self.logger.info("forcedMeasure \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }
}
