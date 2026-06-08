import AppKit
import Foundation

// MARK: - App lifecycle host

extension AppViewModel: AppLifecycleHost {
    func openPiAgentSessionFromNotification(_ sessionID: UUID) {
        selectPiAgentSession(sessionID)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainWindow?.makeKeyAndOrderFront(nil)
    }

    func onAppDidBecomeActive() {
        rebuildAutomationModelCaches()
        catalogAutoRefresh.start()
        catalogAutoRefresh.refreshIfWatchedFilesChanged()
        acknowledgeVisibleSelectedPiAgentSession()
        if selectedSidebarItem == .agent && shouldShowPiAgentGitActions {
            prepareRepoChangesForSelectedPiAgentSession()
        }
    }

    func onAppWillResignActive() {
        catalogAutoRefresh.stop(cancelPendingScan: true)
    }

    func onAppWillTerminate() {
        shutDownForTermination()
        piAgentSessionStore.flushPendingSave()
    }
}
