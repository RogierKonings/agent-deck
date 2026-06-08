import Foundation

/// Shared atomic file writes for persistence services. Ensures parent directories
/// exist and appends a trailing newline for text payloads.
public enum AtomicFileWriter {
    public static func writeText(
        _ text: String,
        to path: String,
        fileManager: FileManager = .default,
        appendTrailingNewline: Bool = true
    ) throws {
        var payload = text
        if appendTrailingNewline, !payload.hasSuffix("\n") {
            payload.append("\n")
        }
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func writeJSON(
        _ object: [String: Any],
        to path: String,
        fileManager: FileManager = .default
    ) throws {
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { text.append("\n") }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
