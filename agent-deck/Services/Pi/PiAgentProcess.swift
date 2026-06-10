import Foundation

nonisolated final class PiAgentProcess: @unchecked Sendable {
    struct Configuration {
        var arguments: [String]
        var currentDirectoryURL: URL
        var environment: [String: String] = [:]
        /// Executable to launch. When `nil`, the `pi` binary is resolved. Set
        /// it to run a different tool (e.g. `node` for the OAuth login bridge)
        /// over the same streaming stdin/stdout plumbing.
        var executableURL: URL? = nil
    }

    enum ProcessError: LocalizedError {
        case executableNotFound
        case launchFailed(Error)
        case stdinUnavailable

        var errorDescription: String? {
            switch self {
            case .executableNotFound:
                return "Could not find pi. Install it with `npm install -g @earendil-works/pi-coding-agent` or configure AGENT_DECK_PI_PATH."
            case let .launchFailed(error):
                return "Failed to launch pi: \(error.localizedDescription)"
            case .stdinUnavailable:
                return "Pi process stdin is unavailable."
            }
        }
    }

    let launchCommand: String
    private let process: Process
    private let stdin: FileHandle
    private let stdoutReader: LineStreamReader
    private let stderrReader: LineStreamReader
    private let writeQueue = DispatchQueue(label: "agent-deck.agent.stdin")
    private let lock = NSLock()
    private var didTerminate = false
    private var didCleanupIO = false

    init(configuration: Configuration, onStdoutLines: @escaping @Sendable ([StreamedLine]) -> Void, onStderrLines: @escaping @Sendable ([String]) -> Void, onTermination: @escaping @Sendable (Int32) -> Void) throws {
        let executable = try configuration.executableURL ?? Self.resolvePiExecutable()
        let process = Process()
        process.executableURL = executable
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.currentDirectoryURL
        process.environment = Self.processEnvironment(extra: configuration.environment, executableURL: executable)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdoutReader = LineStreamReader(handle: stdoutPipe.fileHandleForReading, callback: onStdoutLines)
        self.stderrReader = LineStreamReader(handle: stderrPipe.fileHandleForReading, callback: onStderrLines)
        self.process = process
        self.launchCommand = ([executable.path] + configuration.arguments).map(Self.shellEscape).joined(separator: " ")

        stdoutReader.start()
        stderrReader.start()

        process.terminationHandler = { [weak self] process in
            self?.cleanupIO()
            onTermination(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.launchFailed(error)
        }
    }

    deinit {
        terminate()
    }

    var isRunning: Bool { process.isRunning }

    func writeJSONLine(_ json: String) {
        writeQueue.async { [stdin] in
            guard let data = (json + "\n").data(using: .utf8) else { return }
            do {
                try stdin.write(contentsOf: data)
            } catch {
                // The reader/termination path will surface process failure.
            }
        }
    }

    func terminate() {
        lock.lock()
        let shouldTerminate = !didTerminate
        didTerminate = true
        lock.unlock()
        guard shouldTerminate else { return }

        writeQueue.async { [stdin, process] in
            try? stdin.close()
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                    if process.isRunning {
                        process.interrupt()
                    }
                }
            }
        }
        // cleanupIO closes pipes and tears down the readers. The terminationHandler
        // also runs it once the child actually exits — both paths are idempotent.
        // Run it off the caller's thread so a slow close() can never freeze main.
        DispatchQueue.global().async { [weak self] in
            self?.cleanupIO()
        }
    }

    private func cleanupIO() {
        lock.lock()
        let shouldCleanup = !didCleanupIO
        didCleanupIO = true
        lock.unlock()
        guard shouldCleanup else { return }

        stdoutReader.stop()
        stderrReader.stop()
    }

    private static func resolvePiExecutable() throws -> URL {
        guard let url = PiExecutableResolver().resolve() else {
            throw ProcessError.executableNotFound
        }
        return url
    }

    private static func processEnvironment(extra: [String: String], executableURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        var pathParts = [executableURL.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let existing = environment["PATH"] {
            pathParts.append(existing)
        }
        environment["PATH"] = pathParts.joined(separator: ":")
        return environment
    }

    private nonisolated static func shellEscape(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-_/.:,=".contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// One complete stdout line: the raw bytes (for JSON decoding without a
/// `String → Data` re-encode) plus the decoded text (for rawLine storage and
/// debug logging).
nonisolated struct StreamedLine: Sendable {
    let data: Data
    let text: String
}

/// Buffers a `FileHandle`'s bytes and emits complete, non-empty lines.
/// Shared by `PiAgentProcess` and `ManagedProcess`.
nonisolated final class LineStreamReader: @unchecked Sendable {
    private let handle: FileHandle
    private let callback: @Sendable ([StreamedLine]) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var isStopped = false

    init(handle: FileHandle, callback: @escaping @Sendable ([StreamedLine]) -> Void) {
        self.handle = handle
        self.callback = callback
    }

    /// Text-only convenience for consumers that never need the raw bytes.
    convenience init(handle: FileHandle, callback: @escaping @Sendable ([String]) -> Void) {
        self.init(handle: handle) { lines in
            callback(lines.map(\.text))
        }
    }

    deinit {
        stop()
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData)
        }
    }

    func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        lock.unlock()

        handle.readabilityHandler = nil
        flushBufferedLine()
        try? handle.close()
    }

    private func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        buffer.append(data)
        var lines: [StreamedLine] = []
        var lineStart = buffer.startIndex
        // firstIndex(of:) scans with the optimized contiguous-bytes path instead
        // of a per-byte Data subscript loop.
        while let newlineIndex = buffer[lineStart...].firstIndex(of: 0x0A) {
            if let line = Self.normalizedLine(from: buffer[lineStart..<newlineIndex]) {
                lines.append(line)
            }
            lineStart = buffer.index(after: newlineIndex)
        }
        if lineStart > buffer.startIndex {
            buffer.removeSubrange(..<lineStart)
        }
        lock.unlock()

        if !lines.isEmpty {
            callback(lines)
        }
    }

    private func flushBufferedLine() {
        lock.lock()
        let line = buffer.isEmpty ? nil : Self.normalizedLine(from: buffer)
        buffer.removeAll()
        lock.unlock()
        if let line {
            callback([line])
        }
    }

    private static func normalizedLine(from slice: Data) -> StreamedLine? {
        var slice = slice
        if slice.last == 0x0D { slice = slice.dropLast() }
        // Copy out of the shared buffer so the emitted line doesn't pin (or get
        // invalidated by) subsequent buffer mutations.
        let data = Data(slice)
        let text = String(data: data, encoding: .utf8) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return StreamedLine(data: data, text: text)
    }
}
