import Foundation
import os

/// One message from a Pi client's I/O callbacks, funneled through a single
/// `MainActorEventDrain` so stdout batches, stderr lines, and termination are
/// handled in FIFO order by one long-lived MainActor task instead of a fresh
/// `Task { @MainActor }` per callback.
enum PiClientMessage: Sendable {
    case events([PiRPCClient.EventLine])
    case stderr([String])
    case terminated(Int32)
}

/// Funnels `@Sendable` callback payloads into one long-lived MainActor task.
/// Spawning a new `Task { @MainActor }` per stdout batch creates heavy MainActor
/// enqueue churn under streaming load; a single drain task processes batches in
/// order with one suspension point. The stream finishes when `finish()` is
/// called (after `.terminated`) or when the drain is deallocated.
nonisolated final class MainActorEventDrain<Element: Sendable>: Sendable {
    private let continuation: AsyncStream<Element>.Continuation

    init(handler: @escaping @MainActor (Element) -> Void) {
        let (stream, continuation) = AsyncStream<Element>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        Task { @MainActor in
            for await element in stream {
                handler(element)
            }
        }
    }

    deinit {
        continuation.finish()
    }

    func send(_ element: Element) {
        continuation.yield(element)
    }

    func finish() {
        continuation.finish()
    }
}

final class PiRPCClient: @unchecked Sendable {
    nonisolated private static let logger = Logger(subsystem: "streetcoding.agent-deck", category: "PiRPC")
    struct EventLine: Sendable {
        let rawLine: String
        let event: PiAgentRPCEvent?
    }

    typealias EventHandler = @Sendable (_ lines: [EventLine]) -> Void
    typealias StderrHandler = @Sendable (_ lines: [String]) -> Void
    typealias TerminationHandler = @Sendable (_ exitCode: Int32) -> Void

    private let process: PiAgentProcess
    private let encoder = JSONEncoder()
    private var requestCounter = 0
    private let lock = NSLock()

    var launchCommand: String { process.launchCommand }
    var isRunning: Bool { process.isRunning }

    init(
        cwd: URL,
        sessionFile: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        modelArgument: String? = nil,
        thinkingLevel: String? = nil,
        extraArguments: [String] = [],
        environment: [String: String] = [:],
        onEvent: @escaping EventHandler,
        onStderr: @escaping StderrHandler,
        onTermination: @escaping TerminationHandler
    ) throws {
        let args = Self.launchArguments(
            sessionFile: sessionFile,
            provider: provider,
            model: model,
            modelArgument: modelArgument,
            thinkingLevel: thinkingLevel,
            extraArguments: extraArguments
        )

        // One decoder per client: the stdout reader invokes this callback serially,
        // and allocating a fresh JSONDecoder per line is measurable overhead during
        // token streaming (dozens to hundreds of lines per second).
        let decoder = LineDecoder()
        process = try PiAgentProcess(
            configuration: .init(arguments: args, currentDirectoryURL: cwd, environment: environment),
            onStdoutLines: { lines in
                let events = lines.map { line in
                    EventLine(rawLine: line, event: decoder.decodeEvent(from: line))
                }
                onEvent(events)
            },
            onStderrLines: onStderr,
            onTermination: onTermination
        )
    }

    /// Wraps a reusable `JSONDecoder` for the stdout line callback. Safe because
    /// `LineStreamReader` invokes its callback serially per file handle.
    private nonisolated final class LineDecoder: @unchecked Sendable {
        private let decoder = JSONDecoder()

        nonisolated func decodeEvent(from line: String) -> PiAgentRPCEvent? {
            try? decoder.decode(PiAgentRPCEvent.self, from: Data(line.utf8))
        }
    }

    static func launchArguments(
        sessionFile: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        modelArgument: String? = nil,
        thinkingLevel: String? = nil,
        extraArguments: [String] = []
    ) -> [String] {
        var args = ["--mode", "rpc"]
        args.append(contentsOf: extraArguments)
        if let sessionFile, !sessionFile.isEmpty {
            args.append(contentsOf: ["--session", sessionFile])
        }
        if let provider, !provider.isEmpty {
            args.append(contentsOf: ["--provider", provider])
        }
        if let modelArgument, !modelArgument.isEmpty {
            args.append(contentsOf: ["--model", modelArgument])
        } else if let model, !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        if let thinkingLevel, !thinkingLevel.isEmpty {
            args.append(contentsOf: ["--thinking", thinkingLevel])
        }
        return args
    }

    func getState() { send(type: "get_state") }
    func getMessages() { send(type: "get_messages") }
    func getSessionStats() { send(type: "get_session_stats") }
    func getCommands() { send(type: "get_commands") }
    func abort() { send(type: "abort") }
    func setSessionName(_ name: String) { send(type: "set_session_name", fields: ["name": name]) }
    func setModel(provider: String, modelID: String) { send(type: "set_model", fields: ["provider": provider, "modelId": modelID]) }
    func cycleModel() { send(type: "cycle_model") }
    func setThinkingLevel(_ level: String) { send(type: "set_thinking_level", fields: ["level": level]) }
    func cycleThinkingLevel() { send(type: "cycle_thinking_level") }
    func compact(customInstructions: String? = nil) {
        var fields: [String: Any] = [:]
        if let customInstructions, !customInstructions.isEmpty {
            fields["customInstructions"] = customInstructions
        }
        send(type: "compact", fields: fields)
    }
    func fork(entryId: String) { send(type: "fork", fields: ["entryId": entryId]) }
    func getForkMessages() { send(type: "get_fork_messages") }
    func prompt(_ message: String, images: [PiAgentImageAttachment] = [], streamingBehavior: String? = nil) {
        sendUserMessage(type: "prompt", message: message, images: images, streamingBehavior: streamingBehavior)
    }
    func steer(_ message: String, images: [PiAgentImageAttachment] = []) { sendUserMessage(type: "steer", message: message, images: images) }
    func followUp(_ message: String, images: [PiAgentImageAttachment] = []) { sendUserMessage(type: "follow_up", message: message, images: images) }
    func respondToExtensionUI(id: String, value: String) { sendExtensionUIResponse(["id": id, "value": value]) }
    func confirmExtensionUI(id: String, confirmed: Bool) { sendExtensionUIResponse(["id": id, "confirmed": confirmed]) }
    func cancelExtensionUI(id: String) { sendExtensionUIResponse(["id": id, "cancelled": true]) }

    private func sendUserMessage(type: String, message: String, images: [PiAgentImageAttachment], streamingBehavior: String? = nil) {
        var fields: [String: Any] = ["message": message]
        if let streamingBehavior {
            fields["streamingBehavior"] = streamingBehavior
        }
        if !images.isEmpty {
            fields["images"] = images.map(\.rpcPayload)
        }
        send(type: type, fields: fields)
    }

    func send(type: String, fields: [String: Any] = [:]) {
        lock.lock()
        requestCounter += 1
        let requestID = "pm-\(requestCounter)"
        lock.unlock()

        var command = fields
        command["id"] = requestID
        command["type"] = type
        write(command)
    }

    private func sendExtensionUIResponse(_ fields: [String: Any]) {
        var command = fields
        command["type"] = "extension_ui_response"
        write(command)
    }

    private func write(_ command: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(command),
              let data = try? JSONSerialization.data(withJSONObject: command),
              let line = String(data: data, encoding: .utf8) else { return }
#if DEBUG
        let type = command["type"] as? String ?? "unknown"
        let requestID = command["id"] as? String ?? "extension-ui"
        let streamingBehavior = command["streamingBehavior"] as? String ?? ""
        Self.logger.info("Sending RPC command type=\(type, privacy: .public) id=\(requestID, privacy: .public) hasMessage=\(command["message"] != nil) hasImages=\(command["images"] != nil) streamingBehavior=\(streamingBehavior, privacy: .public)")
#endif
        process.writeJSONLine(line)
    }

    func stop() {
        abort()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [process] in
            process.terminate()
        }
    }
}
