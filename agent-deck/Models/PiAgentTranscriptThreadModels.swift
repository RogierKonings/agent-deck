import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Shared `JSONDecoder` for view-layer payload decoding. Reused so SwiftUI
/// computed properties don't allocate a fresh decoder on every `body` eval.
let transcriptJSONDecoder = JSONDecoder()

/// Memoizes a parse done from a source string, so a SwiftUI computed property
/// doesn't re-decode JSON on every `body` evaluation. The result is a pure
/// function of the source string — the cache never goes stale — and keys carry
/// a call-site discriminator so different parses of the same string can't
/// collide. Bounded LRU. A cast miss simply recomputes, so it is always safe.
@MainActor
enum JSONParseMemo {
    private static var cache: [String: Any] = [:]
    private static var order: [String] = []
    private static let limit = 256

    /// Discriminator and source must be joined with this so a source string
    /// can never be confused for a different call site's key.
    static let separator = "\u{1}"

    static func value<T>(_ key: String, parse: () -> T) -> T {
        if let cached = cache[key], let typed = cached as? T {
            return typed
        }
        let value = parse()
        cache[key] = value
        order.append(key)
        if order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
        return value
    }
}

struct PiAgentThreadToolGroup: Hashable {
    var id: UUID
    var entries: [PiAgentTranscriptEntry]
    // Activities are computed once at thread-build time (per publish), not per render.
    // PiAgentTranscriptActivity.make is O(entries) and would otherwise run on every body
    // re-evaluation during streaming.
    var activities: [PiAgentTranscriptActivity]
}

enum PiAgentThreadChild: Hashable, Identifiable {
    case steering(PiAgentTranscriptEntry)
    case thinking(PiAgentTranscriptEntry)
    case assistant(PiAgentTranscriptEntry)
    case toolGroup(PiAgentThreadToolGroup)
    case status(PiAgentTranscriptEntry)
    case error(PiAgentTranscriptEntry)
    /// A Pi auto-retry burst, collapsed to one entry. `ProviderRetryInfo` is parsed
    /// once here at thread-build time so the card never re-parses during render.
    case retry(PiAgentTranscriptEntry, ProviderRetryInfo)

    var id: String {
        switch self {
        case .steering(let e): return "st-\(e.id.uuidString)"
        case .thinking(let e): return "th-\(e.id.uuidString)"
        case .assistant(let e): return "as-\(e.id.uuidString)"
        case .toolGroup(let g): return "tg-\(g.id.uuidString)"
        case .status(let e): return "ss-\(e.id.uuidString)"
        case .error(let e): return "er-\(e.id.uuidString)"
        case .retry(let e, _): return "rt-\(e.id.uuidString)"
        }
    }
}

struct PiAgentTranscriptThread: Identifiable, Hashable {
    var id: UUID
    var question: PiAgentTranscriptEntry?
    var steeringMessages: [PiAgentTranscriptEntry]
    // Thinking entries are kept as a list (not merged into one) so they can be rendered
    // at their actual timestamp position in the timeline. Merging the post-tool thinking
    // back to the top would push already-rendered tool activities down on every new
    // thinking_delta — the source of the "thinking block jumps content around" issue.
    var thinkingParts: [PiAgentTranscriptEntry]
    var assistantMessages: [PiAgentTranscriptEntry]
    var activities: [PiAgentTranscriptActivity]
    var statuses: [PiAgentTranscriptEntry]
    var errors: [PiAgentTranscriptEntry]
    // Chronological children for rendering. The card body iterates this list in order,
    // so each entry lands at the position it arrived. Consecutive tool/error entries fold
    // into a single `.toolGroup` so multi-tool bursts still aggregate into one summary
    // card. Anything else (thinking, assistant, status, non-tool error) renders as its
    // own row. This is what gives zero jumpiness: only the bottom-most child ever grows
    // because new arrivals always have a later timestamp.
    var children: [PiAgentThreadChild]

    @MainActor
    static func make(from entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptThread] {
        var threads: [PiAgentTranscriptThread] = []
        var builder = Builder()

        func flush() {
            guard let thread = builder.makeThread() else { return }
            threads.append(thread)
            builder = Builder()
        }

        for entry in entries {
            if entry.role == .status && entry.title == "Compaction" {
                flush()
                builder.add(entry)
                flush()
            } else if entry.role == .user && entry.title != "Steering" {
                flush()
                builder.question = entry
            } else {
                builder.add(entry)
            }
        }
        flush()
        return threads
    }

    private struct Builder {
        // Category tag for arrival-order tracking. .toolError is split out from .error
        // so the renderer can fold tool-prefixed errors into adjacent tool groups while
        // non-tool errors (Launch Failed, Connection Error, etc.) stay as standalone
        // rows in their chronological position.
        enum ArrivalKind {
            case steering, thinking, assistant, tool, toolError, status, error
        }

        var question: PiAgentTranscriptEntry?
        var steeringMessages: [PiAgentTranscriptEntry] = []
        var thinkingParts: [PiAgentTranscriptEntry] = []
        var assistantMessages: [PiAgentTranscriptEntry] = []
        var toolEntries: [PiAgentTranscriptEntry] = []
        var statuses: [PiAgentTranscriptEntry] = []
        var errors: [PiAgentTranscriptEntry] = []
        // Same entries as above, kept in arrival order with a category tag. The renderer
        // walks this list to lay children out chronologically — preserving the order
        // events actually came off the RPC stream rather than re-sorting by timestamp
        // (which can tie or shift as entries get re-upserted during streaming).
        var arrivals: [(kind: ArrivalKind, entry: PiAgentTranscriptEntry)] = []

        mutating func add(_ entry: PiAgentTranscriptEntry) {
            switch entry.role {
            case .user where entry.title == "Steering":
                steeringMessages.append(entry)
                arrivals.append((.steering, entry))
            case .thinking:
                thinkingParts.append(entry)
                arrivals.append((.thinking, entry))
            case .assistant:
                assistantMessages.append(entry)
                arrivals.append((.assistant, entry))
            case .tool:
                toolEntries.append(entry)
                arrivals.append((.tool, entry))
            case .status, .stderr:
                statuses.append(entry)
                arrivals.append((.status, entry))
            case .error:
                errors.append(entry)
                arrivals.append((entry.title.hasPrefix("Tool: ") ? .toolError : .error, entry))
            case .user, .raw:
                statuses.append(entry)
                arrivals.append((.status, entry))
            }
        }

        @MainActor
        func makeThread() -> PiAgentTranscriptThread? {
            let activities = PiAgentTranscriptActivity.make(from: toolEntries)
            guard question != nil || !steeringMessages.isEmpty || !thinkingParts.isEmpty || !assistantMessages.isEmpty || !activities.isEmpty || !statuses.isEmpty || !errors.isEmpty else {
                return nil
            }
            let first = question ?? steeringMessages.first ?? thinkingParts.first ?? assistantMessages.first ?? activities.first?.representativeEntry ?? statuses.first ?? errors.first

            // Dedupe identical thinking texts (Pi sometimes re-emits a turn boundary's
            // prior thinking). Whitelisted ids drive both the per-role thinkingParts
            // array (used by the per-thread revision cache) and the chronological
            // children list (used by the renderer).
            var seenThinkingTexts = Set<String>()
            var allowedThinkingIDs = Set<UUID>()
            for entry in thinkingParts {
                let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, seenThinkingTexts.insert(trimmed).inserted else { continue }
                allowedThinkingIDs.insert(entry.id)
            }
            let dedupedThinking = thinkingParts.filter { allowedThinkingIDs.contains($0.id) }

            // Coalesce compaction status entries to the latest one only. Skip the rest
            // when building the chronological list so the user doesn't see "Compacting
            // context…" stacking up across retries.
            var latestCompactionID: UUID?
            for entry in statuses where entry.title == "Compaction" {
                latestCompactionID = entry.id
            }

            let children = chronologicalChildren(
                allowedThinkingIDs: allowedThinkingIDs,
                latestCompactionID: latestCompactionID
            )

            return PiAgentTranscriptThread(
                id: question?.id ?? first?.id ?? UUID(),
                question: question,
                steeringMessages: steeringMessages,
                thinkingParts: dedupedThinking,
                assistantMessages: assistantMessages,
                activities: activities,
                statuses: coalescedStatuses(statuses),
                errors: coalescedErrors(errors),
                children: children
            )
        }

        // Walks arrivals in arrival order and produces the chronological children list.
        // Consecutive `.tool` and `.toolError` arrivals fold into a single `.toolGroup`;
        // any other kind seals the current group and emits its own child.
        private func chronologicalChildren(
            allowedThinkingIDs: Set<UUID>,
            latestCompactionID: UUID?
        ) -> [PiAgentThreadChild] {
            var children: [PiAgentThreadChild] = []
            var groupEntries: [PiAgentTranscriptEntry] = []

            func flushGroup() {
                guard !groupEntries.isEmpty else { return }
                let firstID = groupEntries.first?.id ?? UUID()
                let groupActivities = PiAgentTranscriptActivity.make(from: groupEntries)
                children.append(.toolGroup(PiAgentThreadToolGroup(
                    id: firstID,
                    entries: groupEntries,
                    activities: groupActivities
                )))
                groupEntries = []
            }

            for arrival in arrivals {
                switch arrival.kind {
                case .tool, .toolError:
                    groupEntries.append(arrival.entry)
                case .thinking:
                    guard allowedThinkingIDs.contains(arrival.entry.id) else { continue }
                    flushGroup()
                    children.append(.thinking(arrival.entry))
                case .steering:
                    flushGroup()
                    children.append(.steering(arrival.entry))
                case .assistant:
                    // Empty placeholders are filtered upstream in normalizedTranscriptEntry,
                    // so any assistant arrival that reaches here has visible text and is
                    // worth rendering.
                    flushGroup()
                    children.append(.assistant(arrival.entry))
                case .status:
                    if arrival.entry.title == "Compaction" && arrival.entry.id != latestCompactionID {
                        continue
                    }
                    flushGroup()
                    let normalized = arrival.entry.title == "Compaction"
                        ? normalizedCompaction(arrival.entry)
                        : arrival.entry
                    if normalized.title == "Retry", let retryInfo = ProviderRetryInfo(entry: normalized) {
                        // Collapse a consecutive run of Pi auto-retry statuses into one
                        // card — only the last (the auto_retry_end marker) is kept. Keyed
                        // on the Pi retry envelope, so this holds for every provider, and
                        // parsed here at thread-build time so the card never re-parses
                        // during render.
                        if case .retry? = children.last { children.removeLast() }
                        children.append(.retry(normalized, retryInfo))
                    } else {
                        children.append(.status(normalized))
                    }
                case .error:
                    flushGroup()
                    children.append(.error(arrival.entry))
                }
            }
            flushGroup()
            return children
        }

        private func coalescedStatuses(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
            var output: [PiAgentTranscriptEntry] = []
            var latestCompaction: PiAgentTranscriptEntry?
            for entry in entries {
                if entry.title == "Compaction" {
                    latestCompaction = entry
                } else {
                    output.append(entry)
                }
            }
            if let latestCompaction {
                output.append(normalizedCompaction(latestCompaction))
            }
            return output.sorted { $0.timestamp < $1.timestamp }
        }

        private func normalizedCompaction(_ entry: PiAgentTranscriptEntry) -> PiAgentTranscriptEntry {
            var copy = entry
            let text = entry.text
            if text.localizedCaseInsensitiveContains("nothing to compact") {
                copy.text = "Nothing to compact."
            } else if text.localizedCaseInsensitiveContains("compaction finished") || text.localizedCaseInsensitiveContains("compaction complete") {
                copy.text = text.localizedCaseInsensitiveContains("retrying turn") ? "Context compacted · retrying turn" : "Context compacted."
            } else if text.localizedCaseInsensitiveContains("is compacting") || text.localizedCaseInsensitiveContains("compacting conversation context") {
                copy.text = "Compacting context…"
            }
            return copy
        }

        private func coalescedErrors(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
            var output: [PiAgentTranscriptEntry] = []
            var latestByTool: [String: PiAgentTranscriptEntry] = [:]
            var toolOrder: [String] = []
            for entry in entries {
                let key = PiAgentTranscriptActivity.toolName(for: entry)
                if entry.title.hasPrefix("Tool: ") {
                    if latestByTool[key] == nil { toolOrder.append(key) }
                    latestByTool[key] = normalizedToolError(entry)
                } else {
                    output.append(entry)
                }
            }
            output.append(contentsOf: toolOrder.compactMap { latestByTool[$0] })
            return output.sorted { $0.timestamp < $1.timestamp }
        }

        private func normalizedToolError(_ entry: PiAgentTranscriptEntry) -> PiAgentTranscriptEntry {
            var copy = entry
            copy.text = entry.text
                .replacingOccurrences(of: "\n\nCommand exited with code", with: " · exit")
                .replacingOccurrences(of: "Validation failed for tool", with: "Validation failed")
            return copy
        }
    }
}

struct PiAgentWebLink: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var url: String

    var domain: String {
        URL(string: url)?.host(percentEncoded: false)?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? url
    }
}

struct PiAgentTranscriptActivity: Identifiable, Hashable {
    var id: UUID
    var name: String
    var entries: [PiAgentTranscriptEntry]
    var isError: Bool
    var compactDetail: String?
    var webLinks: [PiAgentWebLink]
    var subagentSummary: PiAgentSubagentSummary?

    var representativeEntry: PiAgentTranscriptEntry? { entries.first }
    nonisolated var count: Int { entries.count }
    nonisolated var isWebActivity: Bool {
        switch name.lowercased() {
        case "web_search", "fetch_content", "get_search_content", "web_fetch": return true
        default: return false
        }
    }

    @MainActor
    static func make(from entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptActivity] {
        var orderedNames: [String] = []
        var grouped: [String: [PiAgentTranscriptEntry]] = [:]
        for entry in entries {
            let name = toolName(for: entry)
            if grouped[name] == nil { orderedNames.append(name) }
            grouped[name, default: []].append(entry)
        }
        return orderedNames.compactMap { name in
            guard let entries = grouped[name], !entries.isEmpty else { return nil }
            let subagentSummary = entries.lazy.compactMap(PiAgentSubagentSummary.init(entry:)).first { $0.total > 0 }
            return PiAgentTranscriptActivity(
                id: entries.first?.id ?? UUID(),
                name: name,
                entries: entries,
                isError: entries.contains { $0.role == .error },
                compactDetail: compactDetail(for: name, entries: entries),
                webLinks: webLinks(for: name, entries: entries),
                subagentSummary: subagentSummary
            )
        }
    }

    static func toolName(for entry: PiAgentTranscriptEntry) -> String {
        if entry.title.hasPrefix("Tool: ") {
            return entry.title.replacingOccurrences(of: "Tool: ", with: "")
        }
        return entry.title
    }

    @MainActor
    private static func webLinks(for name: String, entries: [PiAgentTranscriptEntry]) -> [PiAgentWebLink] {
        switch name.lowercased() {
        case "web_search":
            let curated = entries.flatMap { entry in
                curatedSourceLinks(from: toolDetails(from: entry))
            }
            if !curated.isEmpty { return Array(uniqueLinks(curated).prefix(20)) }
            let links = entries.flatMap { entry in
                extractedLinks(from: toolDetails(from: entry)) + parseSourceLinks(from: entry.text)
            }
            return Array(uniqueLinks(links).prefix(20))
        case "fetch_content", "web_fetch":
            let links = entries.flatMap(fetchContentLinks)
            if !links.isEmpty { return Array(uniqueLinks(links).prefix(20)) }
            return Array(uniqueLinks(entries.flatMap { extractedLinks(from: toolDetails(from: $0)) + parseSourceLinks(from: $0.text) }).prefix(20))
        case "get_search_content":
            let links = entries.compactMap { entry -> PiAgentWebLink? in
                let details = toolDetails(from: entry)
                let textMetadata = contentFrontMatter(from: entry.text)
                guard let url = details?["url"]?.stringValue ?? textMetadata["source"] else { return nil }
                let title = details?["title"]?.stringValue ?? textMetadata["title"] ?? domain(from: url) ?? url
                return PiAgentWebLink(title: title, url: url)
            }
            return Array(uniqueLinks(links).prefix(20))
        default:
            return []
        }
    }

    @MainActor
    private static func compactDetail(for name: String, entries: [PiAgentTranscriptEntry]) -> String? {
        switch name.lowercased() {
        case "web_search":
            return webSearchDetail(from: entries)
        case "fetch_content", "web_fetch":
            return fetchContentDetail(from: entries)
        case "get_search_content":
            return retrievedContentDetail(from: entries)
        default:
            return nil
        }
    }

    @MainActor
    private static func webSearchDetail(from entries: [PiAgentTranscriptEntry]) -> String? {
        let details = entries.lazy.compactMap(toolDetails).last
        let args = entries.lazy.compactMap(toolArgs).last
        let queries = stringArray(details?["queries"]) ?? stringArray(args?["queries"]) ?? args?["query"]?.stringValue.map { [$0] } ?? []
        let resultCount = intValue(details?["totalResults"])

        var parts: [String] = []
        if queries.count == 1, let query = queries.first {
            parts.append("“\(query.truncatedMiddle(max: 56))”")
        } else if queries.count > 1 {
            parts.append("\(queries.count) queries")
        }
        if let resultCount {
            parts.append(resultCount == 1 ? "1 result" : "\(resultCount) results")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor
    private static func fetchContentDetail(from entries: [PiAgentTranscriptEntry]) -> String? {
        let details = entries.lazy.compactMap(toolDetails).last
        let args = entries.lazy.compactMap(toolArgs).last
        let urls = stringArray(details?["urls"]) ?? stringArray(args?["urls"]) ?? args?["url"]?.stringValue.map { [$0] } ?? []
        let title = details?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let successful = intValue(details?["successful"])
        let urlCount = intValue(details?["urlCount"]) ?? urls.count
        let domains = domains(from: urls)

        var parts: [String] = []
        let fetchedTitles = entries.flatMap(fetchContentLinks).map(\.title).filter { !$0.isEmpty }
        if let title, !title.isEmpty, urlCount <= 1 {
            parts.append(title.truncatedMiddle(max: 44))
        } else if urlCount == 1, let fetchedTitle = fetchedTitles.first {
            parts.append(fetchedTitle.truncatedMiddle(max: 44))
        } else if urlCount > 0 {
            parts.append(urlCount == 1 ? "1 page" : "\(urlCount) pages")
        }
        if let successful, urlCount > 1, successful != urlCount {
            parts.append("\(successful)/\(urlCount) fetched")
        }
        if !domains.isEmpty {
            parts.append(domains.prefix(3).joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor
    private static func retrievedContentDetail(from entries: [PiAgentTranscriptEntry]) -> String? {
        // The inline source bullets already show what was read. Keep this row quiet
        // instead of adding a redundant title/source-count summary after "Read content".
        return nil
    }

    @MainActor
    private static func toolDetails(from entry: PiAgentTranscriptEntry) -> JSONValue? {
        toolEvent(from: entry)?.result?["details"]
    }

    @MainActor
    private static func toolArgs(from entry: PiAgentTranscriptEntry) -> JSONValue? {
        toolEvent(from: entry)?.args
    }

    @MainActor
    private static func toolEvent(from entry: PiAgentTranscriptEntry) -> PiAgentRPCEvent? {
        PiAgentRPCEventRenderCache.event(from: entry.rawJSON)
    }

    nonisolated private static func stringArray(_ value: JSONValue?) -> [String]? {
        guard case let .array(items)? = value else { return nil }
        let strings = items.compactMap(\.stringValue).filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }

    nonisolated private static func intValue(_ value: JSONValue?) -> Int? {
        value?.numberValue.map(Int.init)
    }

    nonisolated private static func curatedSourceURLs(from details: JSONValue?) -> [String] {
        curatedSourceLinks(from: details).map(\.url)
    }

    nonisolated private static func uniqueLinks(_ links: [PiAgentWebLink]) -> [PiAgentWebLink] {
        var seen = Set<String>()
        return links.filter { link in
            seen.insert(link.url).inserted
        }
    }

    nonisolated private static func curatedSourceLinks(from details: JSONValue?) -> [PiAgentWebLink] {
        guard case let .array(queries)? = details?["curatedQueries"] else { return [] }
        return queries.flatMap { query -> [PiAgentWebLink] in
            guard case let .array(sources)? = query["sources"] else { return [] }
            return sources.compactMap { source in
                guard let url = source["url"]?.stringValue else { return nil }
                return PiAgentWebLink(title: source["title"]?.stringValue ?? domain(from: url) ?? url, url: url)
            }
        }
    }

    @MainActor
    private static func fetchContentLinks(from entry: PiAgentTranscriptEntry) -> [PiAgentWebLink] {
        let details = toolDetails(from: entry)
        let args = toolArgs(from: entry)
        let urls = stringArray(details?["urls"]) ?? stringArray(args?["urls"]) ?? args?["url"]?.stringValue.map { [$0] } ?? []
        guard !urls.isEmpty else { return [] }

        let titles = fetchedURLTitles(from: entry.text)
        let fallbackTitle = details?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return urls.enumerated().map { index, url in
            let parsedTitle = index < titles.count ? titles[index] : nil
            let displayTitle: String
            if let parsedTitle, !parsedTitle.isEmpty {
                displayTitle = parsedTitle
            } else if let fallbackTitle, !fallbackTitle.isEmpty {
                displayTitle = fallbackTitle
            } else {
                displayTitle = domain(from: url) ?? url
            }
            return PiAgentWebLink(title: displayTitle, url: url)
        }
    }

    nonisolated private static func fetchedURLTitles(from text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = trimmed.firstMatch(of: /^-\s+(.+?)\s+\(\d+\s+chars\)$/) else { return nil }
            return String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    nonisolated private static func contentFrontMatter(from text: String) -> [String: String] {
        var metadata: [String: String] = [:]
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) else { return metadata }
        for line in lines.dropFirst(start + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" { break }
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !value.isEmpty { metadata[key] = value }
        }
        return metadata
    }

    nonisolated private static func extractedLinks(from value: JSONValue?) -> [PiAgentWebLink] {
        guard let value else { return [] }
        switch value {
        case let .object(object):
            var output: [PiAgentWebLink] = []
            if let url = object["url"]?.stringValue ?? object["href"]?.stringValue ?? object["source"]?.stringValue {
                let title = object["title"]?.stringValue ?? object["name"]?.stringValue ?? object["path"]?.stringValue ?? domain(from: url) ?? url
                output.append(PiAgentWebLink(title: title, url: url))
            }
            output += object.values.flatMap(extractedLinks)
            return output
        case let .array(items):
            return items.flatMap(extractedLinks)
        case let .string(string):
            return parseSourceLinks(from: string)
        default:
            return []
        }
    }

    nonisolated private static func parseSourceLinks(from text: String) -> [PiAgentWebLink] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [PiAgentWebLink] = []
        var pendingTitle: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = trimmed.firstMatch(of: /^\d+\.\s+(.+)$/) {
                pendingTitle = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if let match = trimmed.firstMatch(of: /^[-*]\s+\[(.+?)\]\((https?:\/\/[^\s)]+)\)/) {
                output.append(PiAgentWebLink(title: String(match.1), url: String(match.2)))
                pendingTitle = nil
            } else if let match = trimmed.firstMatch(of: /\[(.+?)\]\((https?:\/\/[^\s)]+)\)/) {
                output.append(PiAgentWebLink(title: String(match.1), url: String(match.2)))
                pendingTitle = nil
            } else if let match = trimmed.firstMatch(of: /(https?:\/\/[^\s)>,]+)[),.]?/) {
                let url = String(match.1)
                output.append(PiAgentWebLink(title: pendingTitle ?? domain(from: url) ?? url, url: url))
                pendingTitle = nil
            }
            if output.count >= 20 { break }
        }
        return output
    }

    nonisolated private static func domains(from urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.compactMap(domain).filter { seen.insert($0).inserted }
    }

    nonisolated private static func domain(from url: String) -> String? {
        guard let host = URL(string: url)?.host(percentEncoded: false) else { return nil }
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }
}

extension String {
    nonisolated func truncatedMiddle(max: Int) -> String {
        guard count > max, max > 1 else { return self }
        let headCount = max / 2
        let tailCount = max - headCount - 1
        return String(prefix(headCount)) + "…" + String(suffix(tailCount))
    }
}
