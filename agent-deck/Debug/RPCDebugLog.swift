import Foundation

/// Temporary diagnostic logger for the inbound RPC → transcript-entry path.
/// Off unless launched with `AGENTDECK_RPC_LOG=1`. Writes one line per event to
/// `/tmp/agentdeck-rpc.log` (truncated each launch). Used to capture exactly what
/// a provider emits at end-of-turn (e.g. duplicate end-events) — remove once the
/// duplicate/empty assistant-entry questions are settled.
@MainActor
enum RPCDebugLog {
#if DEBUG
    static let enabled = ProcessInfo.processInfo.environment["AGENTDECK_RPC_LOG"] != nil
    private static var handle: FileHandle? = {
        guard enabled else { return nil }
        FileManager.default.createFile(atPath: "/tmp/agentdeck-rpc.log", contents: nil)
        return FileHandle(forWritingAtPath: "/tmp/agentdeck-rpc.log")
    }()

    static func log(_ line: String) {
        guard enabled else { return }
        let out = line + "\n"
        FileHandle.standardError.write(Data("[rpc] \(out)".utf8))
        handle?.write(Data(out.utf8))
    }
#else
    static func log(_ line: String) {}
#endif
}
