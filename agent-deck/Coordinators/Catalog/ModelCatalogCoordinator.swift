import Foundation
import Observation

@MainActor
@Observable
final class ModelCatalogCoordinator {
    weak var host: ModelCatalogHost?

    var availableModels: [AvailableModel] = [] {
        didSet { host?.availableModelsDidUpdate() }
    }
    var modelsLastUpdatedAt: Date?

    /// Providers with a credential in `~/.pi/agent/auth.json` (== signed in).
    private(set) var signedInProviders: Set<String> = []
    /// Provider id → credential type (`"api_key"`/`"oauth"`) for UI labelling.
    private(set) var providerAuthTypes: [String: String] = [:]
    /// Every provider PI can connect to (from pi-ai `getProviders()`), powering
    /// the Add Provider picker — independent of what the model catalog shows.
    private(set) var connectableProviders: [String] = []
    /// Drives the Add Provider picker sheet (opened from the Models toolbar `+`).
    var isAddProviderPresented = false

    @ObservationIgnored private var isRefreshingModels = false

    func attach(host: ModelCatalogHost) {
        self.host = host
    }

    /// Loads the full connectable-provider list once (cached).
    func ensureConnectableProvidersLoaded() {
        guard connectableProviders.isEmpty else { return }
        Task.detached(priority: .utility) {
            let providers = await PiProviderCatalogService().loadConnectableProviders()
            await MainActor.run { [weak self] in
                self?.connectableProviders = providers
            }
        }
    }

    /// Reloads sign-in state from auth.json off the main thread.
    func refreshProviderAuthState() {
        Task.detached(priority: .utility) {
            let types = PiAuthCredentialStore().signedInTypes()
            await MainActor.run { [weak self] in
                self?.applyProviderAuthState(types)
            }
        }
    }

    /// Writes an API key into auth.json, then refreshes auth + catalog. Throws
    /// surface as an inline error in the sign-in sheet.
    func signInWithAPIKey(_ key: String, provider: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try PiAuthCredentialStore().setAPIKey(trimmed, provider: provider)
        reloadAfterProviderAuthChange()
    }

    func signOutProvider(_ provider: String) throws {
        try PiAuthCredentialStore().removeProvider(provider)
        reloadAfterProviderAuthChange()
    }

    /// Re-reads sign-in state and re-queries the model catalog so newly
    /// authorized (or removed) providers appear/disappear. Called after an
    /// API-key write and on OAuth login completion.
    func reloadAfterProviderAuthChange() {
        refreshProviderAuthState()
        refreshAvailableModels()
    }

    func refreshModels() {
        refreshAvailableModels()
    }

    func ensureAvailableModelsLoaded() {
        ensurePiAgentModelCatalogLoaded()
    }

    func refreshAvailableModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true

        Task.detached(priority: .utility) { [weak self] in
            let models = await PiModelDiscoveryService().loadAvailableModels()
            await self?.applyAvailableModelsRefresh(models, markRefreshComplete: true)
        }
    }

    /// Launch path: populate the catalog from the on-disk discovery cache
    /// immediately, then run the real `pi --list-models` discovery only after
    /// launch settles so it doesn't compete with the catalog scan and
    /// session-store load. First-ever launch (no cache) starts discovery right
    /// away (still detached at `.utility`).
    func loadModelsFromCacheThenDeferredRefresh() {
        Task.detached(priority: .utility) { [weak self] in
            let cached = AvailableModelsDiskCache.load()
            if let cached, !cached.models.isEmpty {
                await MainActor.run { [weak self] in
                    guard let self, self.availableModels.isEmpty else { return }
                    self.availableModels = cached.models
                    self.modelsLastUpdatedAt = cached.fetchedAt
                }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            await MainActor.run { [weak self] in
                self?.refreshAvailableModels()
            }
        }
    }

    func ensurePiAgentModelCatalogLoaded() {
        guard availableModels.isEmpty else { return }
        refreshAvailableModels()
    }

    func isProviderEnabled(_ provider: String) -> Bool {
        guard let host else { return false }
        return !host.appSettings.disabledProviders.contains(provider)
    }

    func isModelEnabled(_ model: AvailableModel) -> Bool {
        guard let host else { return false }
        return !host.appSettings.disabledModelIdentifiers.contains(model.identifier)
    }

    func isModelAvailable(_ model: AvailableModel) -> Bool {
        isProviderEnabled(model.provider) && isModelEnabled(model)
    }

    func isOpenAIFastModeEnabled(_ model: AvailableModel) -> Bool {
        guard let host else { return false }
        return host.appSettings.openAIFastModeModelIdentifiers.contains(model.identifier)
    }

    private func applyProviderAuthState(_ types: [String: String]) {
        providerAuthTypes = types
        signedInProviders = Set(types.keys)
    }

    private func applyAvailableModelsRefresh(_ models: [AvailableModel], markRefreshComplete: Bool) {
        availableModels = models
        modelsLastUpdatedAt = Date()
        if markRefreshComplete {
            isRefreshingModels = false
        }
        // Keep the launch cache fresh; skip empty results (failed discovery)
        // so a transient failure doesn't wipe a good cache.
        if !models.isEmpty {
            AvailableModelsDiskCache.save(models: models)
        }
    }
}
