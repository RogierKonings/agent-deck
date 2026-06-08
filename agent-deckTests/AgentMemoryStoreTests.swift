import XCTest
@testable import agent_deck

@MainActor
final class AgentMemoryStoreTests: XCTestCase {
    func testLoadsGeneralAndCurrentProjectNewestFirst() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        let old = try store.createMemory(kind: .insight, title: "General note", summary: "General content", body: "General content", reasoning: "Useful globally", scope: .general, projectPath: nil, tags: ["general"])
        Thread.sleep(forTimeInterval: 0.01)
        let newest = try store.createMemory(kind: .fact, title: "Project fact", summary: "Project content", body: "Project content", reasoning: "Useful here", scope: .project, projectPath: "/tmp/agent-deck", tags: ["project"])
        let other = try store.createMemory(kind: .fact, title: "Other project", summary: "Other", body: "Other", reasoning: "Other", scope: .project, projectPath: "/tmp/other", tags: [])

        let visible = store.records(projectPath: "/tmp/agent-deck")
        XCTAssertEqual(visible.map(\.id), [newest.id, old.id])
        XCTAssertFalse(visible.contains(where: { $0.id == other.id }))
        XCTAssertEqual(AgentMemoryStore.projectID(for: "/Users/rogierkonings/Projects/agent-deck"), "agent-deck")
    }

    func testUpdateMetadataAndReinforce() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        let record = try store.createMemory(kind: .insight, title: "Original", summary: "Body", body: "Body", reasoning: "Why", scope: .general, projectPath: nil, tags: [])
        try store.updateMemory(id: record.id, title: "Updated", body: "New body", reasoning: "Better reason", kind: .procedure, scope: .general, tags: ["swift"], weight: 0.9)
        let updated = try XCTUnwrap(store.records.first(where: { $0.id == record.id }))
        XCTAssertEqual(updated.title, "Updated")
        XCTAssertEqual(updated.kind, .procedure)
        XCTAssertEqual(updated.tags, ["swift"])
        XCTAssertEqual(updated.weight, 0.9, accuracy: 0.001)

        let reinforced = try store.reinforceMemory(id: record.id)
        XCTAssertEqual(reinforced.useCount, updated.useCount + 1)
        XCTAssertGreaterThan(reinforced.effectiveWeight, 0)
    }

    func testTitleOnlyUpdatePreservesSupersedesLink() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        let old = try store.createMemory(kind: .fact, title: "v1", summary: "one", body: "one", reasoning: "one", scope: .general, projectPath: nil, tags: [])
        let newer = try store.createMemory(kind: .fact, title: "v2", summary: "two", body: "two", reasoning: "two", scope: .general, projectPath: nil, tags: [], supersedes: old.id)

        try store.updateMemory(id: newer.id, title: "v2 renamed")

        XCTAssertEqual(store.records.first(where: { $0.id == newer.id })?.supersedes, old.id)
        XCTAssertEqual(store.records.first(where: { $0.id == old.id })?.supersededBy, newer.id)
    }

    func testExplicitClearAndRelinkSupersedes() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        let first = try store.createMemory(kind: .fact, title: "v1", summary: "one", body: "one", reasoning: "one", scope: .general, projectPath: nil, tags: [])
        let second = try store.createMemory(kind: .fact, title: "v2", summary: "two", body: "two", reasoning: "two", scope: .general, projectPath: nil, tags: [])
        let third = try store.createMemory(kind: .fact, title: "v3", summary: "three", body: "three", reasoning: "three", scope: .general, projectPath: nil, tags: [], supersedes: first.id)

        try store.updateMemory(id: third.id, supersession: .clear)
        XCTAssertNil(store.records.first(where: { $0.id == third.id })?.supersedes)
        XCTAssertNil(store.records.first(where: { $0.id == first.id })?.supersededBy)

        try store.updateMemory(id: third.id, supersession: .set(second.id))
        XCTAssertEqual(store.records.first(where: { $0.id == third.id })?.supersedes, second.id)
        XCTAssertEqual(store.records.first(where: { $0.id == second.id })?.supersededBy, third.id)
    }

    func testSupersessionValidationRejectsInvalidLinks() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        let first = try store.createMemory(kind: .fact, title: "v1", summary: "one", body: "one", reasoning: "one", scope: .general, projectPath: nil, tags: [])
        let second = try store.createMemory(kind: .fact, title: "v2", summary: "two", body: "two", reasoning: "two", scope: .general, projectPath: nil, tags: [], supersedes: first.id)
        let third = try store.createMemory(kind: .fact, title: "v3", summary: "three", body: "three", reasoning: "three", scope: .general, projectPath: nil, tags: [])

        XCTAssertThrowsError(try store.updateMemory(id: second.id, supersession: .set(second.id)))
        XCTAssertThrowsError(try store.updateMemory(id: third.id, supersession: .set("mem_missing")))
        XCTAssertThrowsError(try store.updateMemory(id: third.id, supersession: .set(first.id)))
        XCTAssertThrowsError(try store.updateMemory(id: first.id, supersession: .set(second.id)))
    }

    func testDeleteRepairsSupersessionChainAndThrowsForMissingID() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        let first = try store.createMemory(kind: .fact, title: "v1", summary: "one", body: "one", reasoning: "one", scope: .general, projectPath: nil, tags: [])
        let second = try store.createMemory(kind: .fact, title: "v2", summary: "two", body: "two", reasoning: "two", scope: .general, projectPath: nil, tags: [], supersedes: first.id)
        let third = try store.createMemory(kind: .fact, title: "v3", summary: "three", body: "three", reasoning: "three", scope: .general, projectPath: nil, tags: [], supersedes: second.id)

        let deleted = try store.deleteMemory(id: second.id)
        XCTAssertEqual(deleted.id, second.id)
        let repairedFirst = try XCTUnwrap(store.records.first(where: { $0.id == first.id }))
        let repairedThird = try XCTUnwrap(store.records.first(where: { $0.id == third.id }))
        XCTAssertEqual(repairedFirst.supersededBy, third.id)
        XCTAssertEqual(repairedThird.supersedes, first.id)
        XCTAssertThrowsError(try store.deleteMemory(id: second.id))
    }

    func testRecallExcludesSupersededByDefault() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        let old = try store.createMemory(kind: .fact, title: "Build command", summary: "Use npm test", body: "Use npm test", reasoning: "Old", scope: .general, projectPath: nil, tags: ["build"])
        _ = try store.createMemory(kind: .fact, title: "Build command", summary: "Use xcodebuild", body: "Use xcodebuild", reasoning: "New", scope: .general, projectPath: nil, tags: ["build"], supersedes: old.id)

        let current = store.retrieveNow(projectPath: "/tmp/agent-deck", query: "build command", maxItems: 10)
        XCTAssertFalse(current?.records.contains(where: { $0.id == old.id }) ?? true)
        let withHistory = store.retrieveNow(projectPath: "/tmp/agent-deck", query: "build command", maxItems: 10, includeSuperseded: true)
        XCTAssertTrue(withHistory?.records.contains(where: { $0.id == old.id }) ?? false)
    }

    func testFreshDatabaseFTSTriggersStaySynchronized() throws {
        let db = try temporaryDatabase()
        let store = AgentMemoryStore(databaseURL: db, autoRefresh: false)
        let record = try store.createMemory(kind: .insight, title: "FTS topic", summary: "needle original", body: "needle original", reasoning: "searchable", scope: .general, projectPath: nil, tags: ["needle"])
        XCTAssertEqual(try sqliteScalar(db, "SELECT count(*) FROM memories_fts WHERE memories_fts MATCH 'needle';"), "1")

        try store.updateMemory(id: record.id, body: "updated haystack", tags: ["haystack"])
        XCTAssertEqual(try sqliteScalar(db, "SELECT count(*) FROM memories_fts WHERE memories_fts MATCH 'haystack';"), "1")
        XCTAssertEqual(try sqliteScalar(db, "SELECT count(*) FROM memories_fts WHERE memories_fts MATCH 'needle';"), "0")

        _ = try store.deleteMemory(id: record.id)
        XCTAssertEqual(try sqliteScalar(db, "SELECT count(*) FROM memories_fts WHERE memories_fts MATCH 'haystack';"), "0")
    }

    func testDreamApplyCreatesMergedMemory() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        let a = try store.createMemory(kind: .insight, title: "Same topic", summary: "A", body: "A", reasoning: "A", scope: .general, projectPath: nil, tags: ["same"])
        let b = try store.createMemory(kind: .insight, title: "Same topic", summary: "B", body: "B", reasoning: "B", scope: .general, projectPath: nil, tags: ["same"])
        let proposal = PiMemoryDreamProposal(id: UUID().uuidString, action: .merge, sourceMemoryIDs: [a.id, b.id], title: "Same topic merged", content: "Merged", reasoning: "Test", tags: ["same"], weight: 0.8, type: .insight, weightChanges: [:])
        try store.applyDreamProposals([proposal])
        XCTAssertTrue(store.records.contains(where: { $0.title == "Same topic merged" }))
        XCTAssertNotNil(store.records.first(where: { $0.id == a.id })?.supersededBy)
        XCTAssertNotNil(store.records.first(where: { $0.id == b.id })?.supersededBy)
    }

    func testDreamServiceFakeReviewerCoversCanonicalPhases() async throws {
        let records = [
            dreamRecord(id: "merge-a", title: "Duplicate merge A", tags: ["merge"]),
            dreamRecord(id: "merge-b", title: "Duplicate merge B", tags: ["merge"]),
            dreamRecord(id: "synth-a", title: "Workflow lesson A", tags: ["synth"]),
            dreamRecord(id: "synth-b", title: "Workflow lesson B", tags: ["synth"]),
            dreamRecord(id: "weight-low", title: "Used often", kind: .procedure, weight: 0.4, useCount: 6, tags: ["weight"]),
            dreamRecord(id: "fact-a", title: "Database is Postgres", kind: .fact, tags: ["db"]),
            dreamRecord(id: "fact-b", title: "Database is MySQL", kind: .fact, tags: ["db"]),
            dreamRecord(id: "event-a", title: "Incident one", kind: .event, createdAt: Date().addingTimeInterval(-3_600), tags: ["incident"]),
            dreamRecord(id: "event-b", title: "Incident two", kind: .event, createdAt: Date().addingTimeInterval(-1_800), tags: ["incident"]),
            dreamRecord(id: "event-c", title: "Incident three", kind: .event, createdAt: Date(), tags: ["incident"]),
        ]
        let result = try await PiMemoryDreamService(reviewer: FakeDreamReviewer()).propose(memories: records)
        XCTAssertTrue(result.proposals.contains { $0.action == .merge && $0.phase == .clusterReview })
        XCTAssertTrue(result.proposals.contains { $0.action == .synthesize && $0.phase == .schemaSynthesis })
        XCTAssertTrue(result.proposals.contains { $0.action == .reweight && $0.phase == .weightRebalance })
        XCTAssertTrue(result.proposals.contains { $0.action == .flagContradiction && $0.phase == .contradictionScan })
        XCTAssertTrue(result.proposals.contains { $0.action == .discoverPattern && $0.phase == .temporalPatterns })
        XCTAssertGreaterThanOrEqual(result.proposals.filter { $0.action == .skip }.count, 1)
        XCTAssertEqual(result.contradictionsFound, 1)
        XCTAssertEqual(result.patternsDiscovered, 1)
    }

    func testDreamApplySelectedApprovedSubsetUsesExactObjects() throws {
        let root = try temporaryDirectory()
        let store = AgentMemoryStore(databaseURL: root.appendingPathComponent("memories.db"), dreamLogURL: root.appendingPathComponent("dream.jsonl"), autoRefresh: false)
        let a = try store.createMemory(kind: .insight, title: "A", summary: "A", body: "A", reasoning: "A", scope: .general, projectPath: nil, tags: ["topic"])
        let b = try store.createMemory(kind: .insight, title: "B", summary: "B", body: "B", reasoning: "B", scope: .general, projectPath: nil, tags: ["topic"])
        let merge = PiMemoryDreamProposal(id: "approved-merge", action: .merge, sourceMemoryIDs: [a.id, b.id], title: "Approved merged memory", content: "Merged exact content", reasoning: "Approved", tags: ["topic"], weight: 0.81, type: .insight, weightChanges: [:])
        let unapproved = PiMemoryDreamProposal(id: "unapproved-synthesis", phase: .schemaSynthesis, action: .synthesize, sourceMemoryIDs: [a.id, b.id], title: "Must not be created", content: "No", reasoning: "No", tags: ["topic"], weight: 0.7, type: .insight, weightChanges: [:])

        try store.applyDreamProposals([merge])

        XCTAssertTrue(store.records.contains { $0.title == "Approved merged memory" && $0.summary == "Merged exact content" })
        XCTAssertFalse(store.records.contains { $0.title == unapproved.title })
        XCTAssertTrue((try String(contentsOf: root.appendingPathComponent("dream.jsonl"), encoding: .utf8)).contains("approved-merge"))
        XCTAssertFalse((try String(contentsOf: root.appendingPathComponent("dream.jsonl"), encoding: .utf8)).contains("unapproved-synthesis"))
    }

    func testDreamApplyCanonicalActionsAndAuditLog() throws {
        let root = try temporaryDirectory()
        let store = AgentMemoryStore(databaseURL: root.appendingPathComponent("memories.db"), dreamLogURL: root.appendingPathComponent("dream.jsonl"), autoRefresh: false)
        let synthA = try store.createMemory(kind: .insight, title: "Synth A", summary: "A", body: "A", reasoning: "A", weight: 0.8, scope: .general, projectPath: nil, tags: ["synth"])
        let synthB = try store.createMemory(kind: .insight, title: "Synth B", summary: "B", body: "B", reasoning: "B", weight: 0.6, scope: .general, projectPath: nil, tags: ["synth"])
        let reweight = try store.createMemory(kind: .procedure, title: "Reweight me", summary: "R", body: "R", reasoning: "R", weight: 0.4, scope: .general, projectPath: nil, tags: ["weight"])
        let eventA = try store.createMemory(kind: .event, title: "Event A", summary: "EA", body: "EA", reasoning: "EA", scope: .general, projectPath: nil, tags: ["event"])
        let eventB = try store.createMemory(kind: .event, title: "Event B", summary: "EB", body: "EB", reasoning: "EB", scope: .general, projectPath: nil, tags: ["event"])
        let factA = try store.createMemory(kind: .fact, title: "Fact A", summary: "FA", body: "FA", reasoning: "FA", scope: .general, projectPath: nil, tags: ["fact"])
        let factB = try store.createMemory(kind: .fact, title: "Fact B", summary: "FB", body: "FB", reasoning: "FB", scope: .general, projectPath: nil, tags: ["fact"])
        let synthesize = PiMemoryDreamProposal(id: "synthesize", phase: .schemaSynthesis, action: .synthesize, sourceMemoryIDs: [synthA.id, synthB.id], title: "Synthesized principle", content: "Principle", reasoning: "Higher-level pattern", tags: ["synth"], weight: 0.9, type: .insight, weightChanges: [:])
        let reweightProposal = PiMemoryDreamProposal(id: "reweight", phase: .weightRebalance, action: .reweight, sourceMemoryIDs: [reweight.id], title: "Reweight", content: "Reweight", reasoning: "Usage", tags: ["dream-cycle"], weight: nil, type: nil, weightChanges: [reweight.id: 0.92])
        let contradiction = PiMemoryDreamProposal(id: "contradiction", phase: .contradictionScan, action: .flagContradiction, sourceMemoryIDs: [factA.id, factB.id], title: "Contradiction report only", content: "Report", reasoning: "Conflicting facts", tags: ["contradiction"], weight: nil, type: nil, weightChanges: [:], contradictionPairs: [[factA.id, factB.id]])
        let pattern = PiMemoryDreamProposal(id: "pattern", phase: .temporalPatterns, action: .discoverPattern, sourceMemoryIDs: [eventA.id, eventB.id], title: "Incident pattern", content: "Reusable incident insight", reasoning: "Recurring event pattern", tags: ["dream-pattern"], weight: 0.77, type: .insight, weightChanges: [:])
        let skip = PiMemoryDreamProposal(id: "skip", phase: .clusterReview, action: .skip, sourceMemoryIDs: [], title: "No-op", content: "No-op", reasoning: "No changes", tags: ["skip"], weight: nil, type: nil, weightChanges: [:])

        try store.applyDreamProposals([synthesize, reweightProposal, contradiction, pattern, skip])

        let synthesized = try XCTUnwrap(store.records.first { $0.title == "Synthesized principle" })
        XCTAssertEqual(synthesized.synthesizedFrom, [synthA.id, synthB.id])
        XCTAssertEqual(store.records.first { $0.id == synthA.id }?.weight ?? 0, 0.68, accuracy: 0.001)
        XCTAssertEqual(store.records.first { $0.id == synthB.id }?.weight ?? 0, 0.51, accuracy: 0.001)
        XCTAssertEqual(store.records.first { $0.id == reweight.id }?.weight ?? 0, 0.92, accuracy: 0.001)
        XCTAssertTrue(store.records.contains { $0.title == "Incident pattern" && $0.kind == .insight && $0.synthesizedFrom == [eventA.id, eventB.id] })
        XCTAssertFalse(store.records.contains { $0.title == "Contradiction report only" })
        XCTAssertTrue(store.records.contains { $0.kind == .event && $0.title.hasPrefix("Dream cycle —") })
        let log = try String(contentsOf: root.appendingPathComponent("dream.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("synthesize"))
        XCTAssertTrue(log.contains("contradiction"))
        XCTAssertFalse(log.contains("skip"))
    }

    func testDreamApplyCancelNoOpMakesNoChangesWhenNotCalled() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        _ = try store.createMemory(kind: .insight, title: "Original", summary: "Body", body: "Body", reasoning: "Reason", scope: .general, projectPath: nil, tags: [])
        let before = store.records
        // Cancel in the UI intentionally does not call applyDreamProposals(_:), so proposal objects are not rerun or mutated.
        XCTAssertEqual(store.records, before)
    }

    func testSecretScannerBlocksSensitiveMemory() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase(), autoRefresh: false)
        XCTAssertThrowsError(try store.createMemory(kind: .fact, title: "Token", summary: "Do not save", body: "OPENAI_API_KEY=sk-123456789012345678901234567890", reasoning: "No", scope: .general, projectPath: nil, tags: []))
    }

    private func temporaryDatabase() throws -> URL {
        try temporaryDirectory().appendingPathComponent("memories.db")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-memory-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func dreamRecord(id: String, title: String, kind: AgentMemoryKind = .insight, weight: Double = 0.6, useCount: Int = 0, createdAt: Date = Date(), tags: [String] = []) -> AgentMemoryRecord {
        AgentMemoryRecord(
            id: id,
            kind: kind,
            scope: .general,
            status: .active,
            title: title,
            summary: title,
            filePath: "",
            projectPath: nil,
            sourceSessionID: nil,
            sourceRunID: nil,
            sourceAgentName: nil,
            writeReason: "test",
            createdAt: createdAt,
            updatedAt: createdAt,
            lastUsedAt: nil,
            useCount: useCount,
            tags: tags,
            weight: weight,
            effectiveWeight: weight,
            projectID: "general",
            supersedes: nil,
            supersededBy: nil,
            synthesizedFrom: nil,
            sourceSession: nil
        )
    }

    private func sqliteScalar(_ db: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path, sql]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        return (String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct FakeDreamReviewer: PiMemoryDreamReviewing {
    func reviewClusterForMerge(cluster: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        let ids = cluster.map(\.id)
        if ids.contains("merge-a"), ids.contains("merge-b") {
            return [PiMemoryDreamProposal(id: "fake-merge", phase: .clusterReview, action: .merge, sourceMemoryIDs: ["merge-a", "merge-b"], title: "Merged duplicate", content: "Merged", reasoning: "Near duplicate", tags: ["merge"], weight: 0.8, type: .insight, weightChanges: [:])]
        }
        return [PiMemoryDreamJSONParser.skip(.clusterReview, cluster, "Distinct memories.")]
    }

    func synthesizeCluster(cluster: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        let ids = cluster.map(\.id)
        if ids.contains("synth-a"), ids.contains("synth-b") {
            return [PiMemoryDreamProposal(id: "fake-synthesis", phase: .schemaSynthesis, action: .synthesize, sourceMemoryIDs: ["synth-a", "synth-b"], title: "Synthesized workflow", content: "Reusable workflow", reasoning: "Higher-level pattern", tags: ["synth"], weight: 0.82, type: .insight, weightChanges: [:])]
        }
        return [PiMemoryDreamJSONParser.skip(.schemaSynthesis, cluster, "No synthesis.")]
    }

    func rebalanceWeights(candidates: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        guard candidates.contains(where: { $0.id == "weight-low" }) else { return [] }
        return [PiMemoryDreamProposal(id: "fake-reweight", phase: .weightRebalance, action: .reweight, sourceMemoryIDs: ["weight-low"], title: "Reweight", content: "Adjust weight", reasoning: "High use", tags: ["dream-cycle"], weight: nil, type: nil, weightChanges: ["weight-low": 0.75])]
    }

    func scanContradictions(facts: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        let ids = Set(facts.map(\.id))
        guard ids.contains("fact-a"), ids.contains("fact-b") else { return [] }
        return [PiMemoryDreamProposal(id: "fake-contradiction", phase: .contradictionScan, action: .flagContradiction, sourceMemoryIDs: ["fact-a", "fact-b"], title: "Database contradiction", content: "Conflicting database facts", reasoning: "Postgres and MySQL cannot both be canonical.", tags: ["contradiction"], weight: nil, type: nil, weightChanges: [:], contradictionPairs: [["fact-a", "fact-b"]])]
    }

    func discoverTemporalPatterns(events: [AgentMemoryRecord]) async throws -> [PiMemoryDreamProposal] {
        let ids = Set(events.map(\.id))
        guard ids.isSuperset(of: ["event-a", "event-b", "event-c"]) else { return [] }
        return [PiMemoryDreamProposal(id: "fake-pattern", phase: .temporalPatterns, action: .discoverPattern, sourceMemoryIDs: ["event-a", "event-b", "event-c"], title: "Recurring incidents", content: "Investigate recurring incidents as a pattern.", reasoning: "Three incidents appeared in sequence.", tags: ["dream-pattern"], weight: 0.7, type: .insight, weightChanges: [:])]
    }
}
