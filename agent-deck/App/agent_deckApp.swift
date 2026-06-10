//
//  agent_deckApp.swift
//  agent-deck
//
//  Created by Andrea Corvi on 29/04/2026.
//

import AppKit
import SwiftUI
import UserNotifications

final class AgentDeckAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var shared: AgentDeckAppDelegate?

    let updater = UpdaterService()

    override init() {
        super.init()
        AgentDeckAppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            // Unit-test host: stay out of the way. AppKit's window open/close
            // transform animation intermittently over-releases during CA commits
            // while tests pump the run loop (SIGSEGV in
            // -[_NSWindowTransformAnimation dealloc]), so suppress window
            // animations entirely and skip the real startup side effects.
            NSApp.setActivationPolicy(.accessory)
            suppressWindowAnimationsForTesting()
            return
        }
        // Crash-proof hang detector: when the main thread freezes (janky scroll),
        // it auto-captures the hung backtrace via the external `sample` tool to
        // /tmp/agentdeck-hang-<n>.txt. Disable with HangWatchdogEnabled=NO.
        // Skipped under XCTest — UI smoke tests trigger hitch sampling that
        // stalls the hosted test runner for minutes.
        HangWatchdog.shared.start()
        // Debug: render sample native transcript bubbles for visual verification
        // without loading a real session. Off unless NativeBubblePreview=YES.
        NativeBubblePreviewDebug.showIfEnabled()
        // Agent Deck is a dark-only app — force the appearance at the AppKit
        // layer so menus, file panels, and the Sparkle updater are dark too
        // (SwiftUI's `.preferredColorScheme` does not reach those surfaces).
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Restore the user's chosen Dock icon. The override is per-launch:
        // macOS resets `applicationIconImage` to the bundle default every time.
        AppIconChoice.apply(
            AppIconChoice.choice(forStoredName: AppSettingsStore.shared.settings.selectedAppIconName)
        )
        UNUserNotificationCenter.current().delegate = self
        // Defer the background update check off the launch path. Sparkle's
        // controller is still constructed at first scene-body eval (via the
        // `.environmentObject(appDelegate.updater)` injection), but the
        // explicit `checkForUpdatesInBackground()` call no longer sits inside
        // applicationDidFinishLaunching.
        let updater = updater
        Task.detached(priority: .background) {
            await MainActor.run {
                updater.checkForUpdatesInBackground()
            }
        }
    }

    /// There is no "window created" notification, so re-apply `.none` to every
    /// window after each event cycle. `didUpdateNotification` is chatty, but the
    /// observer only exists in test runs and the window list stays tiny.
    private func suppressWindowAnimationsForTesting() {
        let disable = {
            for window in NSApp.windows {
                window.animationBehavior = .none
            }
        }
        disable()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated(disable)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let sessionID = response.notification.request.content.userInfo["sessionID"] as? String {
            var userInfo: [AnyHashable: Any] = ["sessionID": sessionID]
            if let windowID = response.notification.request.content.userInfo["windowID"] as? String {
                userInfo["windowID"] = windowID
            }
            NotificationCenter.default.post(
                name: .piAgentNotificationResponse,
                object: nil,
                userInfo: userInfo
            )
        }
        completionHandler()
    }
}

@main
struct agent_deckApp: App {
    @NSApplicationDelegateAdaptor(AgentDeckAppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()
    @State private var themeManager = ThemeManager.shared

    /// Unit tests are hosted inside the full app (TEST_HOST). Rendering the
    /// real `ContentView` during test runs boots the entire UI — including the
    /// launch splash cover panel and its animated fade-out, whose window
    /// animation teardown intermittently crashes (over-released
    /// `_NSWindowTransformAnimation`) while tests pump the run loop. Show an
    /// inert placeholder instead; tests build their own stores/services.
    private static let isHostingUnitTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        AppFonts.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            if Self.isHostingUnitTests {
                Text("Running unit tests…")
                    .frame(width: 320, height: 160)
            } else {
                ContentView()
                    .environment(viewModel)
                    .environmentObject(appDelegate.updater)
                    .preferredColorScheme(.dark)
                    // `AppTheme`'s themed tokens are computed `static var`s, so a
                    // theme switch is invisible to SwiftUI's dependency graph.
                    // Re-keying on the theme revision forces a uniform repaint.
                    .id(themeManager.revision)
            }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        // Under XCTest, never open the main window at launch. The window-open
        // transform animation is what later over-releases (see
        // `isHostingUnitTests`); a window that never appears never animates.
        .defaultLaunchBehavior(Self.isHostingUnitTests ? .suppressed : .automatic)
        Settings {
            SettingsSceneContent()
                .environment(viewModel)
                .environmentObject(appDelegate.updater)
                .preferredColorScheme(.dark)
                // The theme re-key lives INSIDE SettingsSceneContent (around the
                // themed content only) rather than here, so a theme switch repaints
                // without discarding the view's `selectedTab` @State — otherwise
                // every theme change bounced the user back to the General tab.
        }
        .commands {
            AgentDeckCommands()
        }

        Window("About \(AppBrand.displayName)", id: AboutWindow.id) {
            AboutView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 440, height: 560)
        .defaultPosition(.center)
    }
}
