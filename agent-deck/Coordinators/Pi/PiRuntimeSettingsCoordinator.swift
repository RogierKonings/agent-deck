import Foundation
import Observation

@MainActor
@Observable
final class PiRuntimeSettingsCoordinator {
    weak var host: PiRuntimeSettingsHost?

    /// Bumped when `~/.pi/agent/settings.json` defaults change so SwiftUI bodies
    /// that read Pi runtime defaults re-render.
    private(set) var settingsRevision = 0

    @ObservationIgnored private var cachedSettingsObject: [String: Any]?
    @ObservationIgnored private var cachedSettingsModificationDate: Date?
    @ObservationIgnored private var lastSettingsStatCheck: Date?

    func attach(host: PiRuntimeSettingsHost) {
        self.host = host
    }

    func readDefaults() -> (provider: String?, model: String?, thinkingLevel: String?) {
        guard let object = settingsObject() else { return (nil, nil, nil) }
        let provider = nonEmptySetting(object["defaultProvider"])
        var model = nonEmptySetting(object["defaultModel"])
        var parsedProvider = provider
        if let rawModel = model, rawModel.contains("/") {
            let parts = rawModel.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                parsedProvider = parsedProvider ?? parts[0]
                model = parts[1]
            }
        }
        let rawThinking = nonEmptySetting(object["defaultThinkingLevel"])
        let thinking = (rawThinking ?? "medium") == "none" ? "off" : rawThinking
        return (parsedProvider, model, thinking)
    }

    func setDefaultModel(_ model: AvailableModel?) {
        guard writeDefaults(provider: model?.provider, model: model?.model, thinkingLevel: nil) else { return }
        settingsRevision += 1
    }

    func setDefaultThinkingLevel(_ level: String) {
        guard writeDefaults(provider: nil, model: nil, thinkingLevel: level) else { return }
        settingsRevision += 1
    }

    private func writeDefaults(provider: String?, model: String?, thinkingLevel: String?) -> Bool {
        var object = settingsObject() ?? [:]
        if let provider, let model {
            object["defaultProvider"] = provider
            object["defaultModel"] = model
        }
        if let thinkingLevel {
            let normalized = thinkingLevel == "none" ? "off" : thinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
            object["defaultThinkingLevel"] = normalized.isEmpty ? "medium" : normalized
        }
        do {
            let url = settingsURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            cachedSettingsObject = object
            cachedSettingsModificationDate = settingsModificationDate(force: true)
            lastSettingsStatCheck = Date()
            return true
        } catch {
            host?.reportPiRuntimeSettingsWriteError("Could not update Pi settings: \(error.localizedDescription)")
            return false
        }
    }

    private func settingsObject() -> [String: Any]? {
        let modificationDate = settingsModificationDate()
        guard let modificationDate else {
            cachedSettingsObject = nil
            cachedSettingsModificationDate = nil
            return nil
        }
        if cachedSettingsModificationDate == modificationDate {
            return cachedSettingsObject
        }
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cachedSettingsObject = nil
            cachedSettingsModificationDate = modificationDate
            return nil
        }
        cachedSettingsObject = object
        cachedSettingsModificationDate = modificationDate
        return object
    }

    private func settingsModificationDate(force: Bool = false) -> Date? {
        let now = Date()
        if !force,
           let lastSettingsStatCheck,
           now.timeIntervalSince(lastSettingsStatCheck) < 1,
           let cachedSettingsModificationDate {
            return cachedSettingsModificationDate
        }
        lastSettingsStatCheck = now
        return (try? FileManager.default.attributesOfItem(atPath: settingsURL.path)[.modificationDate]) as? Date
    }

    private var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json")
    }

    private func nonEmptySetting(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
