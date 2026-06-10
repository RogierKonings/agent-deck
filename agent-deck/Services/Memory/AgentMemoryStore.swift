import Foundation
import Observation

enum AgentMemoryError: LocalizedError {
    case secretDetected(String)
    case missingProject
    case missingRecord(String)
    case sqlite(String)
    case invalidSupersession(String)

    var errorDescription: String? {
        switch self {
        case let .secretDetected(reason):
            return "Memory was not saved because it appears to contain sensitive data: \(reason)"
        case .missingProject:
            return "Select a project before saving project-scoped memory, or choose General scope."
        case let .missingRecord(id):
            return "Memory record \(id) could not be found."
        case let .sqlite(message):
            return message
        case let .invalidSupersession(message):
            return message
        }
    }
}

enum AgentMemorySupersessionChange: Equatable, Sendable {
    case noChange
    case set(String)
    case clear

    static func from(optional value: String?, wasProvided: Bool) -> AgentMemorySupersessionChange {
        guard wasProvided else { return .noChange }
        guard let value = value?.nilIfBlank else { return .clear }
        return .set(value)
    }
}

@MainActor
@Observable
final class AgentMemoryStore {
    private(set) var records: [AgentMemoryRecord] = []
    private(set) var lastError: String?
    private(set) var revision: Int = 0
    private(set) var isLoading: Bool = false

    private let fileManager: FileManager
    private let databaseURL: URL
    private let dreamLogOverrideURL: URL?
    private let scanner = AgentMemorySecretScanner()
    @ObservationIgnored private let database: AgentMemoryDatabase
    @ObservationIgnored private var pendingUsedMemoryCounts: [String: Int] = [:]
    @ObservationIgnored private var markUsedFlushTask: Task<Void, Never>?

    init(rootURL: URL? = nil, databaseURL: URL? = nil, dreamLogURL: URL? = nil, fileManager: FileManager = .default, autoRefresh: Bool = true) {
        self.fileManager = fileManager
        self.dreamLogOverrideURL = dreamLogURL
        let resolvedDatabaseURL: URL
        if let databaseURL {
            resolvedDatabaseURL = databaseURL
        } else if let rootURL {
            resolvedDatabaseURL = rootURL.appendingPathComponent("memories.db")
        } else {
            resolvedDatabaseURL = Self.defaultDatabaseURL(fileManager: fileManager)
        }
        self.databaseURL = resolvedDatabaseURL
        self.database = AgentMemoryDatabase(databaseURL: resolvedDatabaseURL)
        if autoRefresh {
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    var activeRecords: [AgentMemoryRecord] { records.filter(\.isInjectable) }
    var staleRecords: [AgentMemoryRecord] { records.filter { $0.status == .stale } }

    func records(projectPath: String?) -> [AgentMemoryRecord] {
        let projectID = projectPath.map(Self.projectID(for:))
        return records.filter { record in
            record.scope == .general || (projectID != nil && record.projectID == projectID)
        }
    }

    func refresh() async {
        isLoading = true
        do {
            records = try await database.refreshRecords()
            sortRecords()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
        revision &+= 1
    }

    @discardableResult
    func createMemory(
        kind: AgentMemoryKind,
        status: AgentMemoryStatus = .active,
        title: String,
        summary: String,
        body: String,
        reasoning: String? = nil,
        weight: Double = 0.6,
        scope: AgentMemoryScope = .project,
        projectPath: String?,
        projectID explicitProjectID: String? = nil,
        sourceSessionID: UUID? = nil,
        sourceRunID: UUID? = nil,
        sourceAgentName: String? = nil,
        writeReason: String? = nil,
        tags: [String] = [],
        supersedes: String? = nil,
        synthesizedFrom: [String]? = nil
    ) async throws -> AgentMemoryRecord {
        if let finding = scanner.findSecret(in: title + "\n" + summary + "\n" + body + "\n" + (reasoning ?? "") + "\n" + (writeReason ?? "")) {
            throw AgentMemoryError.secretDetected(finding)
        }
        let canonicalProject: String
        let resolvedProjectPath: String?
        switch scope {
        case .general:
            canonicalProject = "general"
            resolvedProjectPath = nil
        case .project:
            if let projectPath = projectPath?.nilIfBlank {
                canonicalProject = explicitProjectID?.nilIfBlank ?? Self.projectID(for: projectPath)
                resolvedProjectPath = projectPath
            } else if let explicitProjectID = explicitProjectID?.nilIfBlank {
                canonicalProject = explicitProjectID
                resolvedProjectPath = nil
            } else {
                throw AgentMemoryError.missingProject
            }
        }

        let now = Date()
        let id = makeID()
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? summary.trimmingCharacters(in: .whitespacesAndNewlines) : body.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanReasoning = (reasoning ?? writeReason ?? summary).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTags = normalizeTags(tags)
        let sourceSession: String
        if let sourceSessionID, let sourceRunID {
            sourceSession = "\(sourceSessionID.uuidString):\(sourceRunID.uuidString)"
        } else {
            sourceSession = sourceSessionID?.uuidString ?? sourceAgentName ?? "agent-deck"
        }
        let synthesizedJSON = try encodeOptionalStringArray(synthesizedFrom)
        var updatedRecords = try await database.insertMemory(
            id: id,
            title: cleanTitle,
            content: cleanContent,
            reasoning: cleanReasoning,
            tags: cleanTags,
            weight: max(0, min(1, weight)),
            createdAt: now,
            lastAccessed: now,
            accessCount: 0,
            sourceSession: sourceSession,
            project: canonicalProject,
            type: kind,
            supersedes: supersedes?.nilIfBlank,
            synthesizedFromJSON: synthesizedJSON,
            requestedStatus: status
        )
        if let index = updatedRecords.firstIndex(where: { $0.id == id }) {
            updatedRecords[index].projectPath = resolvedProjectPath
        }
        applyDatabaseRecords(updatedRecords)
        guard let record = records.first(where: { $0.id == id }) else { throw AgentMemoryError.missingRecord(id) }
        return record
    }

    @discardableResult
    func updateMemory(
        id: String,
        title: String? = nil,
        summary: String? = nil,
        body: String? = nil,
        reasoning: String? = nil,
        kind: AgentMemoryKind? = nil,
        scope: AgentMemoryScope? = nil,
        projectPath: String? = nil,
        tags: [String]? = nil,
        weight: Double? = nil,
        supersession: AgentMemorySupersessionChange = .noChange
    ) async throws -> AgentMemoryRecord {
        let existing: AgentMemoryRecord
        if let cached = records.first(where: { $0.id == id }) {
            existing = cached
        } else if let loaded = try await database.record(id: id) {
            existing = loaded
        } else {
            throw AgentMemoryError.missingRecord(id)
        }
        let newTitle = title ?? existing.title
        let newContent = body ?? summary ?? existing.summary
        let newReasoning = reasoning ?? existing.writeReason ?? ""
        if let finding = scanner.findSecret(in: newTitle + "\n" + newContent + "\n" + newReasoning) {
            throw AgentMemoryError.secretDetected(finding)
        }
        let newProject: String
        switch scope ?? existing.scope {
        case .general:
            newProject = "general"
        case .project:
            if let projectPath, !projectPath.isEmpty {
                newProject = Self.projectID(for: projectPath)
            } else if existing.projectID != "general" {
                newProject = existing.projectID
            } else {
                throw AgentMemoryError.missingProject
            }
        }
        var updatedRecords = try await database.updateMemory(
            id: id,
            title: newTitle,
            content: newContent,
            reasoning: newReasoning,
            tags: tags.map(normalizeTags) ?? existing.tags,
            weight: weight.map { max(0, min(1, $0)) } ?? existing.weight,
            type: kind ?? existing.kind,
            project: newProject,
            supersession: supersession
        )
        if let projectPath = projectPath?.nilIfBlank,
           let index = updatedRecords.firstIndex(where: { $0.id == id }) {
            updatedRecords[index].projectPath = projectPath
        }
        applyDatabaseRecords(updatedRecords)
        guard let record = records.first(where: { $0.id == id }) else { throw AgentMemoryError.missingRecord(id) }
        return record
    }

    @discardableResult
    func updateMemory(id: String, title: String, summary: String, body: String, tags: [String]) async throws -> AgentMemoryRecord {
        try await updateMemory(id: id, title: title, summary: summary, body: body, tags: tags, supersession: .noChange)
    }

    func setStatus(id: String, status: AgentMemoryStatus) async {
        do {
            let updatedRecords = try await database.setStatus(id: id, status: status)
            applyDatabaseRecords(updatedRecords)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func deleteMemory(id: String) async throws -> AgentMemoryRecord {
        let result = try await database.deleteMemory(id: id)
        records.removeAll { $0.id == id }
        applyDatabaseRecords(result.affected, sort: true, bumpRevision: false)
        lastError = nil
        revision &+= 1
        return result.deleted
    }

    @discardableResult
    func reinforceMemory(id: String) async throws -> AgentMemoryRecord {
        let record = try await database.reinforceMemory(id: id)
        applyDatabaseRecords([record])
        return record
    }

    func document(for record: AgentMemoryRecord) -> AgentMemoryDocument {
        AgentMemoryDocument(record: record, body: record.summary)
    }

    func retrieve(projectPath: String?, query: String, maxItems: Int = 5, maxCharacters: Int = 6_000, includeSuperseded: Bool = false, projectOverride: String? = nil, type: AgentMemoryKind? = nil) async -> AgentMemoryRetrieval? {
        do {
            return try await database.retrieve(projectPath: projectPath, query: query, maxItems: maxItems, maxCharacters: maxCharacters, includeSuperseded: includeSuperseded, projectOverride: projectOverride, type: type)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func retrieveNow(projectPath: String?, query: String, maxItems: Int = 5, maxCharacters: Int = 6_000, includeSuperseded: Bool = false, projectOverride: String? = nil, type: AgentMemoryKind? = nil) -> AgentMemoryRetrieval? {
        Self.retrieve(from: records, projectPath: projectPath, query: query, maxItems: maxItems, maxCharacters: maxCharacters, includeSuperseded: includeSuperseded, projectOverride: projectOverride, type: type)
    }

    func memoryContextPrompt(for records: [AgentMemoryRecord], maxCharacters: Int = 6_000) -> String {
        AgentMemoryDatabase.memoryContextPrompt(for: records, maxCharacters: maxCharacters)
    }

    func markUsed(_ memoryIDs: [String]) {
        let counts = Dictionary(grouping: memoryIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, by: { $0 })
            .mapValues(\.count)
        guard !counts.isEmpty else { return }
        for (id, count) in counts {
            pendingUsedMemoryCounts[id, default: 0] += count
        }
        applyAccessDeltas(counts, at: Date())
        scheduleMarkUsedFlush()
    }

    func transcriptEvent(kind: AgentMemoryEventKind, records: [AgentMemoryRecord], summary: String) -> AgentMemoryTranscriptEvent {
        AgentMemoryTranscriptEvent(
            type: AgentMemoryTranscriptEvent.rawType,
            event: kind,
            memoryIDs: records.map(\.id),
            memoryTitles: records.map(\.title),
            scope: records.first?.scope,
            title: kind.displayTitle,
            summary: summary
        )
    }

    func applyDreamProposals(_ proposals: [PiMemoryDreamProposal]) async throws {
        let approved = proposals.filter { $0.action != .skip }
        guard !approved.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let explicitlyReweightedIDs = Set(approved.flatMap { proposal in
            proposal.action == .reweight ? Array(proposal.weightChanges.keys) : []
        })
        for proposal in approved {
            switch proposal.action {
            case .merge:
                guard !proposal.sourceMemoryIDs.isEmpty else { continue }
                let first = proposal.sourceMemoryIDs.compactMap { byID[$0] }.first
                let project = first?.projectID == "general" ? AgentMemoryScope.general : AgentMemoryScope.project
                let projectPath = first?.projectPath
                let merged = try await createMemory(
                    kind: proposal.type ?? first?.kind ?? .insight,
                    title: proposal.title,
                    summary: proposal.content,
                    body: proposal.content,
                    reasoning: proposal.reasoning,
                    weight: proposal.weight ?? 0.7,
                    scope: project,
                    projectPath: projectPath,
                    projectID: first?.projectID,
                    sourceSessionID: nil,
                    sourceAgentName: "dream-cycle",
                    tags: proposal.tags,
                    supersedes: proposal.sourceMemoryIDs.first,
                    synthesizedFrom: proposal.sourceMemoryIDs
                )
                for sourceID in proposal.sourceMemoryIDs.dropFirst() {
                    try await markSuperseded(memoryID: sourceID, supersededBy: merged.id)
                }
            case .synthesize, .discoverPattern:
                let first = proposal.sourceMemoryIDs.compactMap { byID[$0] }.first
                let scope: AgentMemoryScope = first?.projectID == "general" || first == nil ? .general : .project
                _ = try await createMemory(
                    kind: proposal.type ?? (proposal.action == .discoverPattern ? .insight : .insight),
                    title: proposal.title,
                    summary: proposal.content,
                    body: proposal.content,
                    reasoning: proposal.reasoning,
                    weight: proposal.weight ?? 0.75,
                    scope: scope,
                    projectPath: first?.projectPath,
                    projectID: first?.projectID,
                    sourceAgentName: "dream-cycle",
                    tags: proposal.tags,
                    synthesizedFrom: proposal.sourceMemoryIDs
                )
                if proposal.action == .synthesize {
                    for sourceID in proposal.sourceMemoryIDs where !explicitlyReweightedIDs.contains(sourceID) {
                        guard let source = byID[sourceID] else { continue }
                        try await updateMemory(id: sourceID, weight: max(0.3, source.weight * 0.85), supersession: .noChange)
                    }
                }
            case .reweight:
                for (id, weight) in proposal.weightChanges {
                    if records.contains(where: { $0.id == id }) {
                        try await updateMemory(id: id, weight: weight, supersession: .noChange)
                    }
                }
            case .flagContradiction, .skip:
                continue
            }
        }
        try persistDreamCycleLog(approved: approved, allProposals: proposals)
        if !approved.isEmpty {
            _ = try await createMemory(
                kind: .event,
                title: "Dream cycle — \(Self.dateFormatter.string(from: Date()))",
                summary: "Applied \(approved.count) approved dream action\(approved.count == 1 ? "" : "s"): \(approved.map { $0.action.rawValue }.joined(separator: ", ")).",
                body: "Applied dream actions:\n" + approved.map { "- [\($0.phase.rawValue)/\($0.action.rawValue)] \($0.title): \($0.reasoning)" }.joined(separator: "\n"),
                reasoning: "Records a completed native memory-consolidation run for audit/history.",
                weight: 0.3,
                scope: .general,
                projectPath: nil,
                sourceAgentName: "dream-cycle",
                tags: ["dream-cycle", "consolidation", "meta"],
                synthesizedFrom: approved.flatMap(\.sourceMemoryIDs)
            )
        }
    }

    static func projectID(for path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let pieces = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return pieces.joined(separator: "-").nilIfBlank ?? "project"
    }

    private func persistDreamCycleLog(approved: [PiMemoryDreamProposal], allProposals: [PiMemoryDreamProposal]) throws {
        let url = dreamLogURL()
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "id": UUID().uuidString,
            "createdAt": AgentMemoryDatabase.epochMilliseconds(Date()),
            "approvedCount": approved.count,
            "proposalCount": allProposals.count,
            "approved": approved.map { $0.id },
            "actions": approved.map { ["id": $0.id, "phase": $0.phase.rawValue, "action": $0.action.rawValue, "sources": $0.sourceMemoryIDs, "title": $0.title] }
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        if fileManager.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
            try handle.close()
        } else {
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        }
    }

    private func dreamLogURL() -> URL {
        if let dreamLogOverrideURL { return dreamLogOverrideURL }
        return URL.applicationSupportDirectory
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("Memory", isDirectory: true)
            .appendingPathComponent("dream-cycles.jsonl")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".pi/agent/memories/memories.db")
    }

    private func sortRecords() {
        records.sort { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func applyDatabaseRecords(_ updatedRecords: [AgentMemoryRecord], sort: Bool = true, bumpRevision: Bool = true) {
        guard !updatedRecords.isEmpty else { return }
        for updated in updatedRecords {
            if let index = records.firstIndex(where: { $0.id == updated.id }) {
                var merged = updated
                if merged.projectPath == nil {
                    merged.projectPath = records[index].projectPath
                }
                records[index] = merged
            } else {
                records.append(updated)
            }
        }
        if sort { sortRecords() }
        lastError = nil
        if bumpRevision { revision &+= 1 }
    }

    private func applyAccessDeltas(_ counts: [String: Int], at date: Date) {
        var didChange = false
        for index in records.indices {
            guard let count = counts[records[index].id], count > 0 else { continue }
            records[index].useCount += count
            records[index].lastUsedAt = date
            records[index].updatedAt = date
            records[index].effectiveWeight = Self.effectiveWeight(for: records[index])
            didChange = true
        }
        if didChange { revision &+= 1 }
    }

    private func scheduleMarkUsedFlush() {
        markUsedFlushTask?.cancel()
        markUsedFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await self?.flushPendingUsedMemoryIDs()
        }
    }

    private func flushPendingUsedMemoryIDs() async {
        let pending = pendingUsedMemoryCounts
        pendingUsedMemoryCounts = [:]
        markUsedFlushTask = nil
        guard !pending.isEmpty else { return }
        do {
            let updatedRecords = try await database.markUsed(pending)
            applyDatabaseRecords(updatedRecords, bumpRevision: false)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func markSuperseded(memoryID: String, supersededBy: String) async throws {
        let updatedRecords = try await database.markSuperseded(memoryID: memoryID, supersededBy: supersededBy)
        applyDatabaseRecords(updatedRecords)
    }

    private func makeID() -> String { "mem_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased() }
    private func normalizeTags(_ tags: [String]) -> [String] { tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }

    private func encodeOptionalStringArray(_ values: [String]?) throws -> String? {
        guard let values else { return nil }
        let data = try JSONEncoder().encode(values)
        return String(data: data, encoding: .utf8)
    }

    private static func retrieve(from records: [AgentMemoryRecord], projectPath: String?, query: String, maxItems: Int, maxCharacters: Int, includeSuperseded: Bool, projectOverride: String?, type: AgentMemoryKind?) -> AgentMemoryRetrieval? {
        let candidates: [AgentMemoryRecord]
        if let projectOverride, !projectOverride.isEmpty {
            candidates = records.filter { $0.projectID == projectOverride }
        } else {
            let projectID = projectPath.map(projectID(for:))
            candidates = records.filter { record in
                record.scope == .general || (projectID != nil && record.projectID == projectID)
            }
        }
        let scoped = candidates.filter { record in
            (includeSuperseded || record.isInjectable) && (type == nil || record.kind == type)
        }
        guard !scoped.isEmpty else { return nil }
        let terms = searchTerms(in: query)
        let sorted = scoped
            .map { record in (record, score(record: record, terms: terms)) }
            .filter { terms.isEmpty || $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.effectiveWeight != rhs.0.effectiveWeight { return lhs.0.effectiveWeight > rhs.0.effectiveWeight }
                return lhs.0.createdAt > rhs.0.createdAt
            }
            .prefix(maxItems)
            .map(\.0)
        guard !sorted.isEmpty else { return nil }
        return AgentMemoryRetrieval(records: sorted, prompt: AgentMemoryDatabase.memoryContextPrompt(for: sorted, maxCharacters: maxCharacters))
    }

    private static func searchTerms(in query: String) -> [String] {
        query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }
    }

    private static func score(record: AgentMemoryRecord, terms: [String]) -> Int {
        let haystack = ([record.title, record.summary, record.writeReason ?? "", record.kind.displayName, record.projectID] + record.tags).joined(separator: " ").lowercased()
        guard !terms.isEmpty else { return 1 }
        return terms.reduce(0) { $0 + (haystack.contains($1) ? 1 : 0) }
    }

    private static func effectiveWeight(for record: AgentMemoryRecord) -> Double {
        AgentMemoryDatabase.effectiveWeight(
            weight: record.weight,
            type: record.kind,
            ageDays: max(0, Date().timeIntervalSince(record.createdAt) / 86_400),
            accessCount: record.useCount,
            isSuperseded: record.supersededBy != nil
        )
    }
}

struct AgentMemorySecretScanner {
    func findSecret(in text: String) -> String? {
        let patterns: [(String, String)] = [
            ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
            ("GitHub token", #"gh[pousr]_[A-Za-z0-9_]{20,}"#),
            ("OpenAI API key", #"sk-[A-Za-z0-9_\-]{20,}"#),
            ("AWS access key", #"AKIA[0-9A-Z]{16}"#),
            ("password assignment", #"(?i)\b(password|passwd|pwd|token|secret|api[_-]?key)\s*[:=]\s*['"]?[^'"\s]{8,}"#)
        ]
        for (label, pattern) in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return label
        }
        return nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
