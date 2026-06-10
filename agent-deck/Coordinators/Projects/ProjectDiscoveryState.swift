import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

// MARK: - Project discovery and selection

@MainActor
@Observable
final class ProjectDiscoveryState {
    weak var host: ProjectDiscoveryHost?

    var discoveredProjects: [DiscoveredProject] = [] {
        didSet {
            rebuildProjectByPath()
            discoveredProjectsRevision &+= 1
        }
    }

    private(set) var discoveredProjectsRevision: Int = 0
    private(set) var projectByPath: [String: DiscoveredProject] = [:]
    var projectPreferencesByPath: [String: ProjectPreference] = ProjectPreferencesStore.shared.preferencesByPath
    private(set) var projectPreferencesRevision: Int = 0
    var selectedProjectPath: String? {
        didSet { host?.onSelectedProjectPathChanged() }
    }

    private(set) var projectRootURL: URL?

    private let preferencesStore: ProjectPreferencesStore
    private let lastSelectedProjectDefaultsKey = "lastSelectedProjectPath"

    init(preferencesStore: ProjectPreferencesStore) {
        self.preferencesStore = preferencesStore
        self.projectPreferencesByPath = preferencesStore.preferencesByPath
    }

    func loadPersistedSelection() {
        selectedProjectPath = UserDefaults.standard.string(forKey: lastSelectedProjectDefaultsKey)
        if let selectedProjectPath {
            projectRootURL = URL(fileURLWithPath: selectedProjectPath, isDirectory: true).standardizedFileURL
        }
    }

    func applyFromRefresh(discoveredProjects: [DiscoveredProject], preferencesByPath: [String: ProjectPreference]) {
        projectPreferencesByPath = preferencesByPath
        projectPreferencesRevision &+= 1
        self.discoveredProjects = discoveredProjects
    }

    func applySelectedProjectFromRefresh(url: URL, path: String) {
        projectRootURL = url
        selectedProjectPath = path
    }

    func clearSelectionFromRefresh() {
        projectRootURL = nil
        selectedProjectPath = nil
        persistSelectedProjectPath(nil)
    }

    var enabledProjects: [DiscoveredProject] {
        discoveredProjects.filter { projectPreference(for: $0.path).isEnabled }
    }

    var favoriteProjects: [DiscoveredProject] {
        enabledProjects.filter { projectPreference(for: $0.path).isFavorite }
    }

    var gitHubProjects: [DiscoveredProject] {
        enabledProjects.filter(\.isGitHubRepository)
    }

    var selectedDiscoveredProject: DiscoveredProject? {
        guard let selectedProjectPath else { return nil }
        return projectByPath[selectedProjectPath]
    }

    var selectedGitHubProject: DiscoveredProject? {
        guard let selectedDiscoveredProject, selectedDiscoveredProject.isGitHubRepository else { return nil }
        return selectedDiscoveredProject
    }

    var shouldWarnProjectSelection: Bool {
        enabledProjects.isEmpty
    }

    func projectPreference(for path: String) -> ProjectPreference {
        preferencesStore.preference(for: path)
    }

    func addProject(_ url: URL, selectingAfterAdd: Bool = false) {
        let standardizedURL = url.standardizedFileURL
        preferencesStore.addProjectPath(standardizedURL.path)
        preferencesStore.setEnabled(true, for: standardizedURL.path)
        projectPreferencesByPath = preferencesStore.preferencesByPath

        if selectingAfterAdd {
            projectRootURL = standardizedURL
            selectedProjectPath = standardizedURL.path
            persistSelectedProjectPath(standardizedURL.path)
        }

        host?.refreshAfterProjectDiscovery(
            includeModels: false,
            scanAllProjects: false,
            extraProjectPathsToScan: [standardizedURL.path]
        )
        if selectingAfterAdd {
            host?.resetGitHubProjectScopedState()
        }
    }

    func setSelectedProject(_ url: URL?) {
        guard let url else {
            clearProjectRoot()
            return
        }

        let standardizedURL = url.standardizedFileURL
        preferencesStore.addProjectPath(standardizedURL.path)
        projectPreferencesByPath = preferencesStore.preferencesByPath
        projectRootURL = standardizedURL
        selectedProjectPath = standardizedURL.path
        persistSelectedProjectPath(standardizedURL.path)
        host?.refreshAfterProjectDiscovery(
            includeModels: false,
            scanAllProjects: false,
            extraProjectPathsToScan: [standardizedURL.path]
        )
        host?.resetGitHubProjectScopedState()
    }

    func clearProjectRoot() {
        projectRootURL = nil
        selectedProjectPath = nil
        persistSelectedProjectPath(nil)
        host?.refreshAfterProjectDiscovery(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [])
        host?.resetGitHubProjectScopedState()
    }

    func setProjectEnabled(_ isEnabled: Bool, for project: DiscoveredProject) {
        preferencesStore.setEnabled(isEnabled, for: project.path)
        applyProjectPreferenceChanges()

        if !isEnabled, selectedProjectPath == project.path {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
        }

        if isEnabled {
            host?.refreshAfterProjectDiscovery(
                includeModels: false,
                scanAllProjects: false,
                extraProjectPathsToScan: [project.path]
            )
        } else if selectedProjectPath == nil {
            host?.setSnapshotToAggregate()
        }
        host?.resetGitHubProjectScopedState()
    }

    func setAllProjectsEnabled(_ isEnabled: Bool) {
        let paths = discoveredProjects.map(\.path)
        preferencesStore.setAllEnabled(isEnabled, for: paths)
        applyProjectPreferenceChanges()

        if !isEnabled, selectedProjectPath != nil {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
        }

        if isEnabled {
            host?.refreshAfterProjectDiscovery(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [])
        } else {
            host?.setSnapshotToAggregate()
        }
        host?.resetGitHubProjectScopedState()
    }

    func removeProjectFromLibrary(_ project: DiscoveredProject) {
        forgetProject(project)
        host?.resetGitHubProjectScopedState()
    }

    func forgetProject(_ project: DiscoveredProject) {
        preferencesStore.setHidden(true, for: project.path)
        applyProjectPreferenceChanges()
        host?.removeProjectSnapshot(for: project.path)

        if selectedProjectPath == project.path {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
        }

        if selectedProjectPath == nil {
            host?.setSnapshotToAggregate()
        }
    }

    func toggleProjectFavorite(_ project: DiscoveredProject) {
        preferencesStore.toggleFavorite(for: project.path)
        applyProjectPreferenceChanges()
    }

    func chooseCustomIcon(for project: DiscoveredProject) throws {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose Icon"
        panel.message = "Choose an image to use as this project's custom icon."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        try preferencesStore.setCustomIcon(from: url, for: project.path)
        applyProjectPreferenceChanges()
    }

    func clearCustomIcon(for project: DiscoveredProject) {
        preferencesStore.clearCustomIcon(for: project.path)
        applyProjectPreferenceChanges()
    }

    func applyProjectPreferenceChanges() {
        host?.invalidatePendingProjectRefresh()

        projectPreferencesByPath = preferencesStore.preferencesByPath
        projectPreferencesRevision &+= 1
        discoveredProjects = discoveredProjects.compactMap { project in
            let preference = preferencesStore.preference(for: project.path)
            guard !preference.isHidden else { return nil }
            return DiscoveredProject(
                url: project.url,
                gitHubRemote: project.gitHubRemote,
                isGitRepository: project.isGitRepository,
                iconFileURL: preference.customIconPath.flatMap { URL(fileURLWithPath: $0) },
                projectType: project.projectType,
                fallbackSymbolName: project.fallbackSymbolName,
                searchIndex: project.searchIndex
            )
        }
    }

    func setAssignedAgent(_ agentName: String, assigned: Bool, for path: String) {
        preferencesStore.setAssignedAgent(agentName, assigned: assigned, for: path)
    }

    func setAssignedPromptTemplate(_ promptName: String, assigned: Bool, for path: String) {
        preferencesStore.setAssignedPromptTemplate(promptName, assigned: assigned, for: path)
    }

    func setAssignedSkill(_ skillName: String, assigned: Bool, for path: String) {
        preferencesStore.setAssignedSkill(skillName, assigned: assigned, for: path)
    }

    private func rebuildProjectByPath() {
        projectByPath = Dictionary(uniqueKeysWithValues: discoveredProjects.map { ($0.path, $0) })
    }

    private func persistSelectedProjectPath(_ path: String?) {
        if let path {
            UserDefaults.standard.set(path, forKey: lastSelectedProjectDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastSelectedProjectDefaultsKey)
        }
    }
}
