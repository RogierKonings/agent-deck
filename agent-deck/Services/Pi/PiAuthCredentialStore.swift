import Foundation

/// Reads and writes PI's shared credential file (`~/.pi/agent/auth.json`).
///
/// PI stores every provider credential in this one JSON object, keyed by
/// provider id, each entry being either `{ "type":"api_key", "key":"..." }` or
/// `{ "type":"oauth", "access":..., "refresh":..., "expires":..., ... }`.
/// Writing an entry here *is* signing in as far as PI is concerned — `pi`
/// reads it on launch and on `pi --list-models`.
///
/// We never model-decode the whole file: OAuth entries carry tokens (refreshed
/// later by PI under its own file lock) and arbitrary extra fields, so we
/// operate on the raw dictionary and touch only the one provider key we're
/// changing. Every other entry round-trips byte-for-byte.
struct PiAuthCredentialStore: Sendable {
    enum StoreError: LocalizedError {
        case corrupt(path: String)
        case writeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .corrupt(path):
                return "\(path) is not valid JSON. Fix or remove it, then try again."
            case let .writeFailed(error):
                return "Couldn't update auth.json: \(error.localizedDescription)"
            }
        }
    }

    /// `~/.pi/agent/auth.json` — matches PI's `getAgentDir()` and the rest of
    /// the app's hardcoded `~/.pi/agent` usage (see `EnvPersistence`).
    nonisolated static var authFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/auth.json")
    }

    private let fileURL: URL

    nonisolated init(fileURL: URL = PiAuthCredentialStore.authFileURL) {
        self.fileURL = fileURL
    }

    /// Provider ids that currently have any credential. Presence == signed in.
    nonisolated func signedInProviders() -> Set<String> {
        (try? load()).map { Set($0.keys) } ?? []
    }

    /// `"api_key"`, `"oauth"`, or `nil` if the provider isn't signed in.
    nonisolated func credentialType(for provider: String) -> String? {
        ((try? load())?[provider]?["type"] as? String)
    }

    /// Provider id → credential type (`"api_key"`/`"oauth"`) in a single read.
    nonisolated func signedInTypes() -> [String: String] {
        guard let data = try? load() else { return [:] }
        return data.reduce(into: [:]) { $0[$1.key] = $1.value["type"] as? String }
    }

    /// Merge an API-key credential for `provider`, preserving all other entries.
    nonisolated func setAPIKey(_ key: String, provider: String) throws {
        var data = try load()
        data[provider] = ["type": "api_key", "key": key]
        try write(data)
    }

    /// Remove a provider's credential (sign out). Works for api_key and oauth.
    nonisolated func removeProvider(_ provider: String) throws {
        var data = try load()
        guard data[provider] != nil else { return }
        data.removeValue(forKey: provider)
        try write(data)
    }

    // MARK: - Disk

    /// Returns `{}` when the file is absent; throws `.corrupt` rather than
    /// silently overwriting an unreadable file.
    nonisolated private func load() throws -> [String: [String: Any]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let raw = try Data(contentsOf: fileURL)
        guard !raw.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: raw),
              let dictionary = object as? [String: [String: Any]]
        else {
            throw StoreError.corrupt(path: (fileURL.path as NSString).abbreviatingWithTildeInPath)
        }
        return dictionary
    }

    /// Atomic write with PI's permissions: dir `0700`, file `0600`.
    nonisolated private func write(_ data: [String: [String: Any]]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try ensureDirectory(directory)

            let payload = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            let tempURL = directory.appendingPathComponent("auth.json.tmp-\(UUID().uuidString)")
            try payload.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            // replaceItemAt can drop the temp's attributes onto the destination;
            // re-assert 0600 so the credential file is never world-readable.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.writeFailed(underlying: error)
        }
    }

    nonisolated private func ensureDirectory(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
