import XCTest
@testable import BFAlgorithms

final class VersionTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(BFAlgorithmsInfo.version.isEmpty)
    }
}
