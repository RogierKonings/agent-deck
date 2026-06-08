import Foundation

@MainActor
protocol PiTerminalHost: AnyObject {
    var piAgentTerminalApplicationPath: String? { get }
    func onTerminalResumeOpened(forSessionID id: UUID)
}
