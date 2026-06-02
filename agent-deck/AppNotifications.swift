import Foundation

extension Notification.Name {
    static let piAgentNotificationResponse = Notification.Name("piAgentNotificationResponse")
    static let agentDeckImportSkillsRequested = Notification.Name("agentDeckImportSkillsRequested")
    static let agentDeckNewSkillRequested = Notification.Name("agentDeckNewSkillRequested")
    static let agentDeckNewPromptRequested = Notification.Name("agentDeckNewPromptRequested")
    static let agentDeckImportPromptRequested = Notification.Name("agentDeckImportPromptRequested")
    static let agentDeckNewMemoryRequested = Notification.Name("agentDeckNewMemoryRequested")
    /// Posted from a transcript memory-recall card when the user taps an injected
    /// memory title. `userInfo["id"]` carries the memory record id to open.
    static let agentDeckOpenMemoryRequested = Notification.Name("agentDeckOpenMemoryRequested")
}
