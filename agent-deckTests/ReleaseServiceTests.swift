import XCTest
@testable import agent_deck

final class ReleaseServiceTests: XCTestCase {
    func testNextVersionsFromTwoPartTag() {
        let next = ReleaseService.nextVersions(from: "v1.7")

        XCTAssertEqual(next.patch, "v1.7.1")
        XCTAssertEqual(next.minor, "v1.8")
        XCTAssertEqual(next.major, "v2.0")
    }

    func testNextVersionsFromThreePartTag() {
        let next = ReleaseService.nextVersions(from: "v1.7.1")

        XCTAssertEqual(next.patch, "v1.7.2")
        XCTAssertEqual(next.minor, "v1.8")
        XCTAssertEqual(next.major, "v2.0")
    }

    func testParseVersionAcceptsTwoAndThreePartTags() {
        XCTAssertEqual(ReleaseService.parseVersion("v1.7")?.major, 1)
        XCTAssertEqual(ReleaseService.parseVersion("v1.7")?.minor, 7)
        XCTAssertEqual(ReleaseService.parseVersion("v1.7")?.patch, 0)
        XCTAssertEqual(ReleaseService.parseVersion("v1.7.1")?.patch, 1)
        XCTAssertNil(ReleaseService.parseVersion("v1"))
        XCTAssertNil(ReleaseService.parseVersion("v1.7.beta"))
    }
}
