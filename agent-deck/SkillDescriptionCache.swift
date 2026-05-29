import CryptoKit
import Foundation

/// On-disk cache of AI-generated SKILL.md summaries keyed by SHA-256 of the
/// SKILL.md byte contents. Survives app restarts and repo re-syncs; entries
/// auto-invalidate when the underlying SKILL.md changes (different hash).
@MainActor
enum SkillDescriptionCache {
    nonisolated struct Entry: Codable, Hashable, Sendable {
        let summary: String
        let modelIdentifier: String
        let generatedAt: Date
    }

    private static let maxEntries = 500
    private static var loaded = false
    private static var entries: [String: Entry] = [:]
    /// Tracks insertion / last-access order for LRU eviction.
    private static var accessOrder: [String] = []

    static func get(hash: String) -> Entry? {
        ensureLoaded()
        guard let entry = entries[hash] else { return nil }
        if isBailout(entry.summary) {
            entries.removeValue(forKey: hash)
            accessOrder.removeAll { $0 == hash }
            schedulePersist()
            return nil
        }
        touch(hash)
        // Pure read no longer triggers a write. Touch updates in-memory LRU
        // order; persistence catches up on the next put() or bailout-evict.
        return entry
    }

    private static func isBailout(_ summary: String) -> Bool {
        let lowered = summary.lowercased()
        return lowered.contains("insufficient information")
            || lowered.hasPrefix("i cannot summari")
            || lowered.hasPrefix("i can't summari")
    }

    static func put(hash: String, summary: String, modelIdentifier: String) {
        ensureLoaded()
        entries[hash] = Entry(summary: summary, modelIdentifier: modelIdentifier, generatedAt: Date())
        touch(hash)
        evictIfNeeded()
        schedulePersist()
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Storage

    private static var storeURL: URL {
        let appSupport = URL.applicationSupportDirectory
        let directory = appSupport
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("skill-summaries.json")
    }

    nonisolated private struct StoredFile: Codable, Sendable {
        var entries: [String: Entry]
        var order: [String]
    }

    private static func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(StoredFile.self, from: data) else { return }
        entries = decoded.entries
        accessOrder = decoded.order.filter { entries[$0] != nil }
        for key in entries.keys where !accessOrder.contains(key) {
            accessOrder.append(key)
        }
    }

    private static func touch(_ hash: String) {
        accessOrder.removeAll { $0 == hash }
        accessOrder.append(hash)
    }

    private static func evictIfNeeded() {
        while accessOrder.count > maxEntries {
            let oldest = accessOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    /// Debounced off-main persistence. Coalesces bursts of put()/eviction
    /// calls into one encode + atomic write per ~1s window. Reads no longer
    /// trigger persistence at all (the in-memory LRU order is sufficient until
    /// the next write).
    private static var persistTask: Task<Void, Never>?
    private static let persistDebounceNanoseconds: UInt64 = 1_000_000_000

    private static func schedulePersist() {
        persistTask?.cancel()
        let snapshot = StoredFile(entries: entries, order: accessOrder)
        let url = storeURL
        persistTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: persistDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
