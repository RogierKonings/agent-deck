import XCTest
@testable import AgentDeckCore

final class AtomicFileWriterTests: XCTestCase {
    func testAppendsTrailingNewline() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("sample.txt").path
        try AtomicFileWriter.writeText("hello", to: path)

        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(contents, "hello\n")
    }
}
