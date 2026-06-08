import Foundation

@MainActor
protocol ProjectServerHost: AnyObject {
    var selectedSessionProjectPath: String? { get }
    func appendProjectServerStatus(sessionID: UUID, title: String, text: String)
}
