import Combine
import Foundation
import Observation

@MainActor
@Observable
final class CatalogAutoRefreshCoordinator {
    weak var host: CatalogAutoRefreshHost?

    @ObservationIgnored private var autoRefreshCancellable: AnyCancellable?
    @ObservationIgnored private var watchFingerprintTask: Task<Void, Never>?
    @ObservationIgnored private var watchEventDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var fileWatchEventMonitor: FileWatchEventMonitor?
    @ObservationIgnored private var lastWatchFingerprint: String = ""
    @ObservationIgnored private var watchedURLsForAutoRefresh: [URL] = []

    private let fallbackAutoRefreshInterval: TimeInterval = 300
    private let watchEventDebounceNanoseconds: UInt64 = 1_000_000_000

    func attach(host: CatalogAutoRefreshHost) {
        self.host = host
    }

    func applyRefreshSnapshot(watchedURLs: [URL], watchFingerprint: String, includesWatchFingerprint: Bool) {
        watchedURLsForAutoRefresh = watchedURLs
        if includesWatchFingerprint {
            lastWatchFingerprint = watchFingerprint
        }
        updateWatchList()
    }

    func start() {
        guard host?.isShutdown != true else { return }
        if fileWatchEventMonitor == nil {
            fileWatchEventMonitor = FileWatchEventMonitor { [weak self] in
                Task { @MainActor in
                    self?.scheduleRefreshForWatchedFileEvent()
                }
            }
        }
        updateWatchList()

        // Always cancel-and-reassign instead of `guard == nil else return`.
        // The latter silently leaks the prior subscription if anyone ever
        // calls `start()` twice without an intervening `stop()`.
        autoRefreshCancellable?.cancel()
        autoRefreshCancellable = Timer.publish(every: fallbackAutoRefreshInterval, tolerance: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshIfWatchedFilesChanged()
            }
    }

    func stop(cancelPendingScan: Bool) {
        fileWatchEventMonitor?.stop()
        fileWatchEventMonitor = nil
        watchEventDebounceTask?.cancel()
        watchEventDebounceTask = nil
        autoRefreshCancellable?.cancel()
        autoRefreshCancellable = nil
        if cancelPendingScan {
            watchFingerprintTask?.cancel()
            watchFingerprintTask = nil
        }
    }

    func refreshIfWatchedFilesChanged() {
        guard watchFingerprintTask == nil else { return }
        let previousFingerprint = lastWatchFingerprint
        let urls = currentWatchedURLs()
        watchFingerprintTask = Task.detached(priority: .utility) { [weak self, previousFingerprint, urls] in
            let fingerprint = FileWatchFingerprint.make(urls: urls)
            guard !Task.isCancelled else { return }
            await self?.applyWatchFingerprint(fingerprint, previousFingerprint: previousFingerprint)
        }
    }

    private func updateWatchList() {
        guard let fileWatchEventMonitor else { return }
        fileWatchEventMonitor.updateWatchedURLs(currentWatchedURLs())
    }

    private func currentWatchedURLs() -> [URL] {
        if watchedURLsForAutoRefresh.isEmpty {
            return host?.fallbackWatchedURLs() ?? []
        }
        return watchedURLsForAutoRefresh
    }

    private func scheduleRefreshForWatchedFileEvent() {
        guard host?.isShutdown != true else { return }
        watchEventDebounceTask?.cancel()
        let delay = watchEventDebounceNanoseconds
        watchEventDebounceTask = Task { @MainActor [weak self, delay] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, self.host?.isShutdown != true else { return }
            self.watchEventDebounceTask = nil
            self.refreshIfWatchedFilesChanged()
        }
    }

    private func applyWatchFingerprint(_ fingerprint: String, previousFingerprint: String) {
        guard !Task.isCancelled else { return }
        watchFingerprintTask = nil
        guard fingerprint != previousFingerprint else { return }
        lastWatchFingerprint = fingerprint
        host?.triggerCatalogRefresh(includeModels: false)
    }
}
