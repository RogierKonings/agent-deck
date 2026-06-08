import Foundation

enum PiParentAppendPromptResolver {
    static func appendSystemPromptArguments(
        projectURL: URL,
        agentDeckAppendPrompts: [String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String] {
        let explicitPrompts = agentDeckAppendPrompts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !explicitPrompts.isEmpty else { return [] }

        var appendValues: [String] = []
        if let activeAppendFile = activeAppendSystemPromptURL(projectURL: projectURL, homeDirectory: homeDirectory, fileManager: fileManager) {
            appendValues.append(activeAppendFile.path)
        }
        appendValues.append(contentsOf: explicitPrompts)
        return appendValues.flatMap { ["--append-system-prompt", $0] }
    }

    static func activeAppendSystemPromptURL(
        projectURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let projectAppend = projectURL.standardizedFileURL
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("APPEND_SYSTEM.md")
        if fileManager.fileExists(atPath: projectAppend.path) {
            return projectAppend
        }

        let globalAppend = homeDirectory.standardizedFileURL
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("APPEND_SYSTEM.md")
        if fileManager.fileExists(atPath: globalAppend.path) {
            return globalAppend
        }

        return nil
    }
}
