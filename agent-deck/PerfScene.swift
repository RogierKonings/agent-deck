import SwiftUI

/// Names the currently-active UI area so the perf monitor can attribute a hang or
/// hitch to a component. Set declaratively with `.perfScene(_:)` on the views that
/// own a major area (transcript, sidebar, composer, settings, …). The hang/hitch
/// logs stamp `scene=<current>` so a run can be correlated to a component without
/// reading the backtrace.
///
/// Debug-only effect: in release builds `.perfScene` is a no-op and the perf
/// monitor never runs, so this is inert.
enum PerfScene {
    /// Read by the perf monitor's background watcher; written on the main thread
    /// from `.perfScene`. A plain stored value (debug-only string tag) — exact
    /// synchronization isn't needed for an attribution hint.
    nonisolated(unsafe) static var current: String = "app"
}

extension View {
    /// Tag the active UI scene/component for perf attribution (debug builds only).
    func perfScene(_ name: String) -> some View {
        #if DEBUG
        return self
            .onAppear { PerfScene.current = name }
            .onDisappear { if PerfScene.current == name { PerfScene.current = "app" } }
        #else
        return self
        #endif
    }
}
