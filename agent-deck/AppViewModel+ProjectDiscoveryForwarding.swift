import Foundation

// MARK: - Project discovery view/API compatibility

extension AppViewModel {
    var discoveredProjects: [DiscoveredProject] {
        get { projects.discoveredProjects }
        set { projects.discoveredProjects = newValue }
    }

    var discoveredProjectsRevision: Int { projects.discoveredProjectsRevision }
    var projectByPath: [String: DiscoveredProject] { projects.projectByPath }
    var projectPreferencesByPath: [String: ProjectPreference] {
        get { projects.projectPreferencesByPath }
        set { projects.projectPreferencesByPath = newValue }
    }

    var projectPreferencesRevision: Int { projects.projectPreferencesRevision }
    var selectedProjectPath: String? {
        get { projects.selectedProjectPath }
        set { projects.selectedProjectPath = newValue }
    }

    var projectRootURL: URL? { projects.projectRootURL }
    var enabledProjects: [DiscoveredProject] { projects.enabledProjects }
    var favoriteProjects: [DiscoveredProject] { projects.favoriteProjects }
    var gitHubProjects: [DiscoveredProject] { projects.gitHubProjects }
    var selectedDiscoveredProject: DiscoveredProject? { projects.selectedDiscoveredProject }
    var selectedGitHubProject: DiscoveredProject? { projects.selectedGitHubProject }
    var shouldWarnProjectSelection: Bool { projects.shouldWarnProjectSelection }

    func projectPreference(for path: String) -> ProjectPreference {
        projects.projectPreference(for: path)
    }

    func addProject(_ url: URL, selectingAfterAdd: Bool = false) {
        projects.addProject(url, selectingAfterAdd: selectingAfterAdd)
    }

    func setSelectedProject(_ url: URL?) {
        projects.setSelectedProject(url)
    }

    func clearProjectRoot() {
        projects.clearProjectRoot()
    }

    func setProjectEnabled(_ isEnabled: Bool, for project: DiscoveredProject) {
        projects.setProjectEnabled(isEnabled, for: project)
    }

    func setAllProjectsEnabled(_ isEnabled: Bool) {
        projects.setAllProjectsEnabled(isEnabled)
    }

    func removeProjectFromLibrary(_ project: DiscoveredProject) {
        projects.removeProjectFromLibrary(project)
    }

    func moveProjectToTrash(_ project: DiscoveredProject) throws {
        try FileManager.default.trashItem(at: project.url, resultingItemURL: nil)
        projects.forgetProject(project)
        refresh(includeModels: false, scanAllProjects: true)
        github.resetProjectScopedState()
    }

    func toggleProjectFavorite(_ project: DiscoveredProject) {
        projects.toggleProjectFavorite(project)
    }

    func chooseCustomIcon(for project: DiscoveredProject) {
        do {
            try projects.chooseCustomIcon(for: project)
        } catch {
            github.githubLastError = error.localizedDescription
        }
    }

    func clearCustomIcon(for project: DiscoveredProject) {
        projects.clearCustomIcon(for: project)
    }

    func applyProjectPreferenceChanges() {
        projects.applyProjectPreferenceChanges()
    }
}
