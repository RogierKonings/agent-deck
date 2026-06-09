import Foundation

// MARK: - Env catalog view/API compatibility

extension AppViewModel {
    func makeEnvDraft(for record: EnvKeyRecord) -> EnvEditorDraft {
        envCatalog.makeEnvDraft(for: record)
    }

    func makeNewEnvDraft(scope: AgentEditingTarget.CustomAgentScope, prefilledKey: String? = nil) -> EnvEditorDraft {
        envCatalog.makeNewEnvDraft(scope: scope, prefilledKey: prefilledKey)
    }

    func saveEnvDrafts(_ drafts: [EnvEditorDraft]) throws {
        try envCatalog.saveEnvDrafts(drafts)
    }

    func deleteEnvKey(_ record: EnvKeyRecord) throws {
        try envCatalog.deleteEnvKey(record)
    }
}
