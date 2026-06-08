import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppLifecycleCoordinator: NSObject {
    weak var host: AppLifecycleHost?

    private var windowID: UUID?

    func attach(host: AppLifecycleHost) {
        self.host = host
    }

    func startObserving(windowID: UUID) {
        stopObserving()
        self.windowID = windowID
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handlePiAgentNotificationResponse(_:)), name: .piAgentNotificationResponse, object: nil)
        center.addObserver(self, selector: #selector(handleAppDidBecomeActive(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAppWillResignActive(_:)), name: NSApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAppWillTerminate(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        windowID = nil
    }

    @objc private func handlePiAgentNotificationResponse(_ notification: Notification) {
        guard let windowID,
              let rawSessionID = notification.userInfo?["sessionID"] as? String,
              let sessionID = UUID(uuidString: rawSessionID) else { return }
        if let rawWindowID = notification.userInfo?["windowID"] as? String,
           let notificationWindowID = UUID(uuidString: rawWindowID),
           notificationWindowID != windowID {
            return
        }
        host?.openPiAgentSessionFromNotification(sessionID)
    }

    @objc private func handleAppDidBecomeActive(_ notification: Notification) {
        host?.onAppDidBecomeActive()
    }

    @objc private func handleAppWillResignActive(_ notification: Notification) {
        host?.onAppWillResignActive()
    }

    @objc private func handleAppWillTerminate(_ notification: Notification) {
        host?.onAppWillTerminate()
    }

    nonisolated deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
