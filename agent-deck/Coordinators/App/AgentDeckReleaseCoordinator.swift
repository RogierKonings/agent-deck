import Foundation
import Observation

@MainActor
@Observable
final class AgentDeckReleaseCoordinator {
    weak var host: AgentDeckReleaseHost?

    let service: ReleaseService

    private let gitRepositoryService: GitRepositoryService
    private let releaseNotesGenerator: ReleaseNotesGenerationService

    init(
        gitRepositoryService: GitRepositoryService,
        releaseNotesGenerator: ReleaseNotesGenerationService
    ) {
        self.gitRepositoryService = gitRepositoryService
        self.releaseNotesGenerator = releaseNotesGenerator
        self.service = ReleaseService(gitRepositoryService: gitRepositoryService)
    }

    func attach(host: AgentDeckReleaseHost) {
        self.host = host
    }

    /// Whether the dedicated "Release" toolbar button should appear: only when the
    /// selected session's repo is agent-deck itself. Matches the session's recorded
    /// `repository` (owner/repo), falling back to the project's GitHub remote.
    var shouldShowReleaseAction: Bool {
        guard let session = host?.selectedReleaseSession else { return false }
        let target = ReleaseService.repository
        if let repository = session.repository,
           repository.caseInsensitiveCompare(target) == .orderedSame {
            return true
        }
        if let remote = host?.gitHubRemoteName(forProjectPath: session.projectPath),
           remote.caseInsensitiveCompare(target) == .orderedSame {
            return true
        }
        return false
    }

    /// The main checkout to tag against — the project path, never a worktree, so the
    /// release lands on `main` rather than a session's feature branch.
    var releaseProjectURL: URL? {
        guard let session = host?.selectedReleaseSession else { return nil }
        return URL(fileURLWithPath: session.projectPath, isDirectory: true)
    }

    /// Draft friendly release notes for the pending Agent Deck release using the
    /// default model (thinking off), from the commits since `sinceTag`. The
    /// returned markdown body is shown — and editable — in the release sheet, then
    /// rides the annotated tag into CI. Throws if no default model/project is
    /// available; the sheet treats that as "fall back to CI commit listing".
    func generateReleaseNotes(version: String, sinceTag: String?) async throws -> String {
        guard let model = host?.defaultReleaseModel() else {
            throw ReleaseNotesGenerationService.GenerationError.rpc("No default model is configured.")
        }
        guard let projectURL = releaseProjectURL else {
            throw ReleaseNotesGenerationService.GenerationError.rpc("No project is selected.")
        }
        let commits = try await gitRepositoryService.commitSubjects(sinceTag: sinceTag, in: projectURL)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectURL)
        return try await releaseNotesGenerator.generate(
            version: version,
            commitSubjects: commits,
            model: model,
            projectURL: projectURL,
            environment: environment
        )
    }

    /// Record a successful release in the selected session's transcript.
    func recordReleaseSucceeded(tag: String) {
        guard let session = host?.selectedReleaseSession else { return }
        host?.appendReleaseSucceededStatus(sessionID: session.id, tag: tag)
    }
}
