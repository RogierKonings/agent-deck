import Foundation

struct GitDiffCacheKey: Hashable {
    let projectPath: String
    let filePath: String
    let kind: GitDiffKind
}

struct RepositoryChangesCacheEntry {
    var snapshot: RepositoryChangesSnapshot?
    var fetchedAt: Date?
    var isLoading: Bool = false
    var error: String?
    var requestID: Int = 0
    var mergeSourceBranch: String?
    var mergeSessionBranch: String?
    var hasMergeableBranchChanges: Bool?
}
