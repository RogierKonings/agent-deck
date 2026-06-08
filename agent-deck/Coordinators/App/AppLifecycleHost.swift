import Foundation

@MainActor
protocol AppLifecycleHost: AnyObject {
    func openPiAgentSessionFromNotification(_ sessionID: UUID)
    func onAppDidBecomeActive()
    func onAppWillResignActive()
    func onAppWillTerminate()
}
