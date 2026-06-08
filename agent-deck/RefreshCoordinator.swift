import Foundation

struct RefreshInputs: Sendable {
    let rootURLs: [URL]
    let selectedProjectPath: String?
    let preferencesByPath: [String: ProjectPreference]
    let externalSkillPaths: Set<String>
    let externalPromptPaths: Set<String>
    let scanAllProjects: Bool
    let extraProjectPathsToScan: Set<String>
}

// MARK: - Scan refresh scheduling

@MainActor
final class RefreshCoordinator {
    var isRefreshingProjects = false
    private var refreshTask: Task<Void, Never>?
    private var refreshRequestID = 0

    func scheduleRefresh(
        inputs: RefreshInputs,
        includeModels: Bool,
        silentlyReconcile: Bool,
        onComplete: @MainActor @escaping (AppRefreshSnapshot, Bool) -> Void
    ) {
        refreshRequestID += 1
        let requestID = refreshRequestID
        if !silentlyReconcile {
            isRefreshingProjects = true
        }

        refreshTask?.cancel()
        refreshTask = Task.detached(priority: .utility) {
            let result = AppRefreshService().loadSnapshot(
                rootURLs: inputs.rootURLs,
                selectedProjectPath: inputs.selectedProjectPath,
                preferencesByPath: inputs.preferencesByPath,
                externalSkillPaths: inputs.externalSkillPaths,
                externalPromptPaths: inputs.externalPromptPaths,
                scanAllProjects: inputs.scanAllProjects,
                extraProjectPathsToScan: inputs.extraProjectPathsToScan
            )

            await MainActor.run {
                guard !Task.isCancelled, requestID == self.refreshRequestID else { return }
                onComplete(result, includeModels)
                if requestID == self.refreshRequestID {
                    self.isRefreshingProjects = false
                }
            }
        }
    }

    func cancelPendingRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func invalidatePendingRefresh() {
        refreshRequestID += 1
        refreshTask?.cancel()
    }
}
