import AppKit
import Combine
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

import AppKit
import Combine
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Transcript render cache

@MainActor
final class PiAgentTranscriptRenderCache: ObservableObject {
    @Published private(set) var entries: [PiAgentTranscriptEntry] = []
    @Published private(set) var threads: [PiAgentTranscriptThread] = []
    @Published private(set) var renderRevision = 0
    @Published private(set) var streamingRevision = 0
    @Published private(set) var autoScrollTurnRevision = 0
    @Published private(set) var lastThreadID: UUID?

    // Memo for `PiAgentScreen.appKitTranscriptItems` (the 20-37ms O(N) items build).
    // Deliberately NOT @Published: written from the items getter during a body pass,
    // and publishing it would re-invalidate the host on every build. Lives here only
    // because this cache object is the screen's stable `@State` companion. Keyed by a
    // signature of every input the build reads — `renderRevision`/`streamingRevision`
    // cover all transcript content, the rest are settings/skills/subagent/session.
    internal var memoizedTranscriptItems: [PiAgentAppKitTranscriptItem] = []
    internal var memoizedTranscriptItemsSignature: Int?

    private var updateTask: Task<Void, Never>?
    private var lastSessionID: UUID?
    private var lastRevision = -1
    private var lastThreadSignature: [UUID] = []
    private var lastAutoScrollTurnEntryID: UUID?
    /// Cheap per-raw-entry signatures from the previous publish. Used to detect
    /// the common streaming shape — only entries after the last thread boundary
    /// changed — so `publish` can rebuild just the final thread instead of
    /// re-normalizing and re-threading the whole transcript every ~33ms.
    private var lastRawEntrySignatures: [Int] = []
    // Per-thread cached content revision keyed by a cheap signature (counts + last-entry
    // text length). Repeat lookups during the same body re-evaluation, or across unrelated
    // body re-evaluations (composer typing etc.), skip the full O(entries) walk.
    private var threadRevisionCache: [UUID: (signature: Int, revision: Int)] = [:]

    func cachedThreadRevision(for threadID: UUID, signature: Int, compute: () -> Int) -> Int {
        if let cached = threadRevisionCache[threadID], cached.signature == signature {
            return cached.revision
        }
        let revision = compute()
        threadRevisionCache[threadID] = (signature, revision)
        return revision
    }

    func scheduleUpdate(sessionID: UUID?, revision: Int, rawEntries: [PiAgentTranscriptEntry]) {
        guard let sessionID else {
            updateTask?.cancel()
            entries = []
            threads = []
            lastThreadID = nil
            lastSessionID = nil
            lastRevision = -1
            lastThreadSignature = []
            lastAutoScrollTurnEntryID = nil
            lastRawEntrySignatures = []
            threadRevisionCache.removeAll()
            renderRevision += 1
            return
        }
        guard sessionID != lastSessionID || revision != lastRevision else { return }
        let isSessionSwitch = sessionID != lastSessionID
        if isSessionSwitch {
            lastRawEntrySignatures = []
        }
        // Don't wipe threadRevisionCache on session switch — keys are per-thread UUIDs
        // which are globally unique, so cached revisions for a different session can't
        // collide. Persisting the cache means a return-visit to a previously-viewed
        // session reuses its thread revisions instead of re-hashing every entry.
        lastSessionID = sessionID
        lastRevision = revision
        updateTask?.cancel()

        if isSessionSwitch {
            publish(rawEntries)
            return
        }

        updateTask = Task { [weak self] in
            // Lowered from 66 ms (the previous safety value when each publish triggered
            // an expensive SwiftUI body rebuild) to 33 ms. With TextKit-based markdown
            // measurement and in-place NSTextStorage updates, each publish is cheap;
            // halving the coalesce window means streaming feels like smooth scroll
            // instead of discrete 66 ms steps.
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            self?.publish(rawEntries)
        }
    }

    private func publish(_ rawEntries: [PiAgentTranscriptEntry]) {
        let newSignatures = rawEntries.map(Self.rawEntrySignature)
        let normalized: [PiAgentTranscriptEntry]
        let nextThreads: [PiAgentTranscriptThread]
        if let incremental = incrementalPublishResult(rawEntries, newSignatures: newSignatures) {
            normalized = incremental.entries
            nextThreads = incremental.threads
        } else {
            normalized = normalizedEntries(from: rawEntries)
            nextThreads = PiAgentTranscriptThread.make(from: normalized)
        }
        lastRawEntrySignatures = newSignatures

        let signature = nextThreads.map(\.id)
        let structurallyChanged = signature != lastThreadSignature
        let latestUserEntryID = normalized.last(where: { $0.role == .user })?.id
        let userTurnAdvanced = latestUserEntryID != nil && latestUserEntryID != lastAutoScrollTurnEntryID
        if structurallyChanged {
            let nextThreadIDs = Set(signature)
            threadRevisionCache = threadRevisionCache.filter { nextThreadIDs.contains($0.key) }
        }
        entries = normalized
        threads = nextThreads
        lastThreadID = nextThreads.last?.id
        lastThreadSignature = signature
        lastAutoScrollTurnEntryID = latestUserEntryID
        if userTurnAdvanced {
            autoScrollTurnRevision += 1
        }
        if structurallyChanged {
            renderRevision += 1
        } else {
            streamingRevision += 1
        }
    }

    /// The full normalization pipeline. Every step is entry-local except
    /// `coalescedCompactionEntries` (merges consecutive Compaction statuses) and
    /// `normalizeThinkingOrder` (swaps adjacent thinking/assistant pairs) — both
    /// of which only look at neighboring entries, which is what makes the
    /// segment-local fast path in `incrementalPublishResult` valid.
    private func normalizedEntries(from rawEntries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
        normalizeThinkingOrder(
            coalescedCompactionEntries(
                rawEntries.compactMap(normalizedTranscriptEntry).filter(isValuableTranscriptEntry)
            )
        )
    }

    /// Streaming fast path: when only raw entries AFTER the last user-question
    /// thread boundary changed (the shape of every assistant/thinking/tool
    /// streaming pulse), re-normalize and re-thread just that final segment and
    /// splice it onto the cached prefix — instead of walking the whole transcript
    /// every ~33ms. Returns `nil` (full rebuild) whenever the shape is anything
    /// else: prefix edits, truncation, session switches, compaction boundaries,
    /// or any mismatch between the cached entries/threads and the boundary entry.
    /// Behavior is identical to the full pipeline because every normalization
    /// step is local (see `normalizedEntries`), the boundary entry is a user
    /// question (so no compaction merge or thinking swap can cross the splice),
    /// and `PiAgentTranscriptThread.make` starts a fresh thread exactly at user
    /// questions.
    private func incrementalPublishResult(
        _ rawEntries: [PiAgentTranscriptEntry],
        newSignatures: [Int]
    ) -> (entries: [PiAgentTranscriptEntry], threads: [PiAgentTranscriptThread])? {
        guard !lastRawEntrySignatures.isEmpty, !threads.isEmpty else { return nil }
        guard rawEntries.count >= lastRawEntrySignatures.count else { return nil }

        var firstDifference = lastRawEntrySignatures.count
        for index in lastRawEntrySignatures.indices where lastRawEntrySignatures[index] != newSignatures[index] {
            firstDifference = index
            break
        }
        if firstDifference == newSignatures.count {
            return (entries, threads) // No raw change at all — reuse the cache.
        }

        // The fast path only handles segments that start at a user question.
        // A trailing Compaction boundary could merge with an earlier Compaction
        // across the splice, so it always takes the full rebuild.
        guard let boundaryIndex = rawEntries.lastIndex(where: { entry in
            (entry.role == .user && entry.title != "Steering") ||
                (entry.role == .status && entry.title == "Compaction")
        }) else { return nil }
        let boundary = rawEntries[boundaryIndex]
        guard boundary.role == .user, firstDifference > boundaryIndex else { return nil }

        guard let entrySplice = entries.lastIndex(where: { $0.id == boundary.id }),
              let threadSplice = threads.lastIndex(where: { $0.id == boundary.id }) else { return nil }

        let segment = normalizedEntries(from: Array(rawEntries[boundaryIndex...]))
        guard segment.first?.id == boundary.id else { return nil }
        let segmentThreads = PiAgentTranscriptThread.make(from: segment)
        guard segmentThreads.first?.id == boundary.id else { return nil }

        return (
            Array(entries[..<entrySplice]) + segment,
            Array(threads[..<threadSplice]) + segmentThreads
        )
    }

    /// Cheap change-detection signature for one raw entry. Mirrors the fields
    /// `hashEntryRevision` uses for row revisions: any mutation `upsert`/
    /// `updateEntry` can make to an entry changes at least one of these.
    private static func rawEntrySignature(_ entry: PiAgentTranscriptEntry) -> Int {
        var hasher = Hasher()
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.title)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
        hasher.combine(entry.timestamp)
        return hasher.finalize()
    }

    private enum AssistantContentInterpretation {
        case assistant(String)
        case thinking(String)
        case drop
    }

    private func normalizedTranscriptEntry(_ entry: PiAgentTranscriptEntry) -> PiAgentTranscriptEntry? {
        var copy = entry
        if copy.role == .assistant {
            if let interpretation = assistantContentInterpretation(fromRawJSON: copy.rawJSON) {
                switch interpretation {
                case let .assistant(text):
                    copy.text = sanitizedAssistantText(text)
                case let .thinking(text):
                    copy.role = .thinking
                    copy.title = "Thinking"
                    copy.text = sanitizedAssistantText(text)
                case .drop:
                    return nil
                }
            } else {
                copy.text = sanitizedAssistantText(copy.text)
            }
            if copy.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
        }
        return copy
    }

    private func assistantContentInterpretation(fromRawJSON rawJSON: String?) -> AssistantContentInterpretation? {
        guard let event = PiAgentRPCEventRenderCache.event(from: rawJSON),
              event.type == "message_end",
              let message = event.message,
              message["role"]?.stringValue == "assistant",
              let content = message["content"] else {
            return nil
        }

        switch content {
        case let .string(value):
            return .assistant(value)
        case let .array(blocks):
            let textParts = blocks.compactMap { block -> String? in
                let blockType = block["type"]?.stringValue
                guard blockType == nil || blockType == "text" || blockType == "output_text" || blockType == "message" else { return nil }
                return block["text"]?.stringValue
            }
            if !textParts.isEmpty { return .assistant(textParts.joined(separator: "\n")) }

            let thinkingParts = blocks.compactMap { block -> String? in
                guard block["type"]?.stringValue == "thinking" else { return nil }
                return block["thinking"]?.stringValue
            }
            if !thinkingParts.isEmpty { return .thinking(thinkingParts.joined(separator: "\n\n")) }

            let hasToolCall = blocks.contains { block in
                let blockType = block["type"]?.stringValue
                return blockType == "toolCall" || blockType == "tool_call" || block["name"]?.stringValue != nil
            }
            return hasToolCall ? .drop : nil
        default:
            return .drop
        }
    }

    private func sanitizedAssistantText(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !piAgentLeakedToolNames.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func coalescedCompactionEntries(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
        var output: [PiAgentTranscriptEntry] = []
        for entry in entries {
            guard entry.role == .status && entry.title == "Compaction" else {
                output.append(entry)
                continue
            }
            if let last = output.last,
               last.role == .status,
               last.title == "Compaction",
               abs(entry.timestamp.timeIntervalSince(last.timestamp)) < 600 {
                output[output.count - 1] = entry
            } else {
                output.append(entry)
            }
        }
        return output
    }

    private func normalizeThinkingOrder(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
        var normalized: [PiAgentTranscriptEntry] = []
        for entry in entries {
            if entry.role == .thinking,
               let previous = normalized.last,
               previous.role == .assistant,
               abs(entry.timestamp.timeIntervalSince(previous.timestamp)) < 180 {
                normalized.removeLast()
                normalized.append(entry)
                normalized.append(previous)
            } else {
                normalized.append(entry)
            }
        }
        return normalized
    }

    private func isValuableTranscriptEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        switch entry.role {
        case .raw:
            return false
        case .assistant:
            return isMeaningfulAssistantEntry(entry)
        case .status:
            return entry.isNativeSubagentCard
                || entry.agentMemoryEvent != nil
                || entry.title == "Compaction"
                || entry.title == "Retry"
                || entry.title == "Subagent Started"
                || PiAgentGitEventKind.from(title: entry.title) != nil
        case .tool:
            return !(entry.title == "Tool Call" && entry.text.localizedCaseInsensitiveContains("preparing tool call"))
        case .stderr:
            return !entry.text.localizedCaseInsensitiveContains("ready for input") && !entry.text.contains(";notify;Pi;")
        default:
            return true
        }
    }

    private func isMeaningfulAssistantEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return !piAgentLeakedToolNames.contains(text.lowercased())
    }
}

extension PiAgentTranscriptEntry {
    var isNativeSubagentCard: Bool {
        guard let rawJSON,
              let data = rawJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return false }
        return type == "agent_deck_subagent_started" || type == "agent_deck_subagent_card"
    }
}

// MARK: - Transcript timeline (SwiftUI fallback)

struct PiAgentTranscriptTimelineItem: Identifiable {
    enum Kind {
        case thread(PiAgentTranscriptThread)
    }

    let id: String
    let timestamp: Date
    let kind: Kind
}

struct PiAgentTranscriptTimelineSnapshot {
    let allItems: [PiAgentTranscriptTimelineItem]
    let visibleItems: [PiAgentTranscriptTimelineItem]
    let mainVisibleItems: [PiAgentTranscriptTimelineItem]
    let earlierVisibleItems: [PiAgentTranscriptTimelineItem]
    let preCompactionArchive: (hiddenCount: Int, compactedAt: Date)?
    let recentWindowArchive: (hiddenCount: Int, limit: Int)?
}

/// How a transcript row is rendered. Every row is now fully native AppKit (no
/// per-row SwiftUI / `NSHostingView`); the spec knows how to build/configure/
/// measure the concrete view.
// MARK: - AppKit transcript cell kinds

enum PiAgentTranscriptCellKind {
    case native(NativeRowSpec)
}

extension PiAgentTranscriptCellKind {
    /// Convenience for a native message bubble.
    static func bubble(_ payload: NativeBubblePayload) -> PiAgentTranscriptCellKind {
        .native(.of(PiAgentNativeBubbleView.self) { view, width in
            view.configure(payload: payload, width: width)
        })
    }
}

struct PiAgentAppKitTranscriptItem {
    let id: String
    let kind: PiAgentTranscriptCellKind
    let contentRevision: Int
    /// Vertical spacing baked into the row, applied as padding inside the cell.
    /// `NSTableView.intercellSpacing` is uniform, but the transcript needs
    /// different gaps (question↔reply, sibling, thread↔thread) — so each gap is
    /// split in half across the two adjacent rows' facing insets. Folded into
    /// `contentRevision` so an inset change re-tiles the row.
    let topInset: CGFloat
    let bottomInset: CGFloat
    /// Fast height estimate used by `heightOfRow` before the cell renders.
    /// Closer estimates produce smoother first paint — the cell self-measures
    /// after it renders and reports its actual height back via callback.
    /// Includes the row insets so the estimate matches the measured height.
    let estimatedHeight: (CGFloat) -> CGFloat

    init(
        id: String,
        kind: PiAgentTranscriptCellKind,
        contentRevision: Int = 0,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0,
        estimatedHeight: @escaping (CGFloat) -> CGFloat = { _ in 120 }
    ) {
        self.id = id
        self.kind = kind
        self.contentRevision = contentRevision
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.estimatedHeight = estimatedHeight
    }
}

