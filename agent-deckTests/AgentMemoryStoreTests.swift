import XCTest
@testable import agent_deck

@MainActor
final class AgentMemoryStoreTests: XCTestCase {
    func testLoadsGeneralAndCurrentProjectNewestFirst() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase())
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
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase())
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
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase())
        let old = try store.createMemory(kind: .fact, title: "v1", summary: "one", body: "one", reasoning: "one", scope: .general, projectPath: nil, tags: [])
        let newer = try store.createMemory(kind: .fact, title: "v2", summary: "two", body: "two", reasoning: "two", scope: .general, projectPath: nil, tags: [], supersedes: old.id)

        try store.updateMemory(id: newer.id, title: "v2 renamed")

        XCTAssertEqual(store.records.first(where: { $0.id == newer.id })?.supersedes, old.id)
        XCTAssertEqual(store.records.first(where: { $0.id == old.id })?.supersededBy, newer.id)
    }

    func testExplicitClearAndRelinkSupersedes() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase())
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
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase())
        let first = try store.createMemory(kind: .fact, title: "v1", summary: "one", body: "one", reasoning: "one", scope: .general, projectPath: nil, tags: [])
        let second = try store.createMemory(kind: .fact, title: "v2", summary: "two", body: "two", reasoning: "two", scope: .general, projectPath: nil, tags: [], supersedes: first.id)
        let third = try store.createMemory(kind: .fact, title: "v3", summary: "three", body: "three", reasoning: "three", scope: .general, projectPath: nil, tags: [])

        XCTAssertThrowsError(try store.updateMemory(id: second.id, supersession: .set(second.id)))
        XCTAssertThrowsError(try store.updateMemory(id: third.id, supersession: .set("mem_missing")))
        XCTAssertThrowsError(try store.updateMemory(id: third.id, supersession: .set(first.id)))
        XCTAssertThrowsError(try store.updateMemory(id: first.id, supersession: .set(second.id)))
    }

    func testDeleteRepairsSupersessionChainAndThrowsForMissingID() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase())
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

    func testRecallExcludesSupersededByDefault() async throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase())
        let old = try store.createMemory(kind: .fact, title: "Build command", summary: "Use npm test", body: "Use npm test", reasoning: "Old", scope: .general, projectPath: nil, tags: ["build"])
        _ = try store.createMemory(kind: .fact, title: "Build command", summary: "Use xcodebuild", body: "Use xcodebuild", reasoning: "New", scope: .general, projectPath: nil, tags: ["build"], supersedes: old.id)

        let current = await store.retrieve(projectPath: "/tmp/agent-deck", query: "build command", maxItems: 10)
        XCTAssertFalse(current?.records.contains(where: { $0.id == old.id }) ?? true)
        let withHistory = await store.retrieve(projectPath: "/tmp/agent-deck", query: "build command", maxItems: 10, includeSuperseded: true)
        XCTAssertTrue(withHistory?.records.contains(where: { $0.id == old.id }) ?? false)
    }

    func testFreshDatabaseFTSTriggersStaySynchronized() throws {
        let db = try temporaryDatabase()
        let store = AgentMemoryStore(databaseURL: db)
        let record = try store.createMemory(kind: .insight, title: "FTS topic", summary: "needle original", body: "needle original", reasoning: "searchable", scope: .general, projectPath: nil, tags: ["needle"])
        XCTAssertEqual(try sqliteScalar(db, "SELECT count(*) FROM memories_fts WHERE memories_fts MATCH 'needle';"), "1")

        try store.updateMemory(id: record.id, body: "updated haystack", tags: ["haystack"])
        XCTAssertEqual(try sqliteScalar(db, "SELECT count(*) FROM memories_fts WHERE memories_fts MATCH 'haystack';"), "1")
        XCTAssertEqual(try sqliteScalar(db, "SELECT count(*) FROM memories_fts WHERE memories_fts MATCH 'needle';"), "0")

        _ = try store.deleteMemory(id: record.id)
        XCTAssertEqual(try sqliteScalar(db, "SELECT count(*) FROM memories_fts WHERE memories_fts MATCH 'haystack';"), "0")
    }

    func testDreamApplyCreatesMergedMemory() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase())
        let a = try store.createMemory(kind: .insight, title: "Same topic", summary: "A", body: "A", reasoning: "A", scope: .general, projectPath: nil, tags: ["same"])
        let b = try store.createMemory(kind: .insight, title: "Same topic", summary: "B", body: "B", reasoning: "B", scope: .general, projectPath: nil, tags: ["same"])
        let proposal = PiMemoryDreamProposal(id: UUID().uuidString, action: .merge, sourceMemoryIDs: [a.id, b.id], title: "Same topic merged", content: "Merged", reasoning: "Test", tags: ["same"], weight: 0.8, type: .insight, weightChanges: [:])
        try store.applyDreamProposals([proposal])
        XCTAssertTrue(store.records.contains(where: { $0.title == "Same topic merged" }))
        XCTAssertNotNil(store.records.first(where: { $0.id == a.id })?.supersededBy)
        XCTAssertNotNil(store.records.first(where: { $0.id == b.id })?.supersededBy)
    }

    func testSecretScannerBlocksSensitiveMemory() throws {
        let store = AgentMemoryStore(databaseURL: try temporaryDatabase())
        XCTAssertThrowsError(try store.createMemory(kind: .fact, title: "Token", summary: "Do not save", body: "OPENAI_API_KEY=sk-123456789012345678901234567890", reasoning: "No", scope: .general, projectPath: nil, tags: []))
    }

    private func temporaryDatabase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-memory-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent("memories.db")
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
