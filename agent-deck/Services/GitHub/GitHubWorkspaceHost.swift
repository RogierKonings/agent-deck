import Foundation

/// Dynamic project/catalog context `GitHubWorkspace` reads from the app shell.
@MainActor
protocol GitHubWorkspaceHost: AnyObject {
    var selectedGitHubProject: DiscoveredProject? { get }
    var selectedDiscoveredProject: DiscoveredProject? { get }
    var gitHubProjects: [DiscoveredProject] { get }
    var discoveredProjects: [DiscoveredProject] { get }
    var selectedProjectPath: String? { get set }
    var gitHubBoardCacheLifetime: TimeInterval { get }
    var piAgentSessionStore: PiAgentSessionStore { get }

    func setSelectedProject(_ url: URL?)
    func refreshCatalog(includeModels: Bool, scanAllProjects: Bool, extraProjectPathsToScan: Set<String>, silentlyReconcile: Bool)
    func runShellScriptInTerminal(named: String, body: String)
}
