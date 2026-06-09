import Foundation
import Observation

@MainActor
@Observable
final class EnvCatalogCoordinator {
    weak var host: EnvCatalogHost?
    private let persistence: EnvPersistence

    init(persistence: EnvPersistence) {
        self.persistence = persistence
    }

    func attach(host: EnvCatalogHost) {
        self.host = host
    }

    func makeEnvDraft(for record: EnvKeyRecord) -> EnvEditorDraft {
        persistence.makeDraft(for: record)
    }

    func makeNewEnvDraft(scope: AgentEditingTarget.CustomAgentScope, prefilledKey: String? = nil) -> EnvEditorDraft {
        persistence.makeNewDraft(
            scope: scope,
            projectRoot: host?.selectedProjectPath,
            prefilledKey: prefilledKey
        )
    }

    func saveEnvDrafts(_ drafts: [EnvEditorDraft]) throws {
        guard !drafts.isEmpty else { return }
        var written: [(scope: ResourceScopeKind, path: String)] = []
        defer {
            for file in written {
                host?.refreshAfterEnvFileChange(sourceKind: file.scope, filePath: file.path)
            }
        }
        for draft in drafts {
            try persistence.save(draft)
            if !written.contains(where: { $0.path == draft.path }) {
                written.append((draft.scope, draft.path))
            }
        }
    }

    func deleteEnvKey(_ record: EnvKeyRecord) throws {
        try persistence.delete(record)
        host?.refreshAfterEnvFileChange(sourceKind: record.source.kind, filePath: record.source.path)
    }
}
