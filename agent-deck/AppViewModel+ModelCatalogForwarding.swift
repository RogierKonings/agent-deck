import Foundation

// MARK: - Model catalog host

extension AppViewModel: ModelCatalogHost {
    func availableModelsDidUpdate() {
        rebuildAutomationModelCaches()
    }
}

// MARK: - Model catalog view/API compatibility

extension AppViewModel {
    var availableModels: [AvailableModel] { modelCatalog.availableModels }

    var modelsLastUpdatedAt: Date? { modelCatalog.modelsLastUpdatedAt }

    var signedInProviders: Set<String> { modelCatalog.signedInProviders }

    var providerAuthTypes: [String: String] { modelCatalog.providerAuthTypes }

    var connectableProviders: [String] { modelCatalog.connectableProviders }

    var isAddProviderPresented: Bool {
        get { modelCatalog.isAddProviderPresented }
        set { modelCatalog.isAddProviderPresented = newValue }
    }

    func ensureConnectableProvidersLoaded() {
        modelCatalog.ensureConnectableProvidersLoaded()
    }

    func refreshProviderAuthState() {
        modelCatalog.refreshProviderAuthState()
    }

    func signInWithAPIKey(_ key: String, provider: String) throws {
        try modelCatalog.signInWithAPIKey(key, provider: provider)
    }

    func signOutProvider(_ provider: String) throws {
        try modelCatalog.signOutProvider(provider)
    }

    func reloadAfterProviderAuthChange() {
        modelCatalog.reloadAfterProviderAuthChange()
    }

    func refreshModels() {
        modelCatalog.refreshModels()
    }

    func ensureAvailableModelsLoaded() {
        modelCatalog.ensureAvailableModelsLoaded()
    }

    func ensurePiAgentModelCatalogLoaded() {
        modelCatalog.ensurePiAgentModelCatalogLoaded()
    }

    func refreshAvailableModels() {
        modelCatalog.refreshAvailableModels()
    }
}
