import XCTest
@testable import BFKit

final class WorkingLimitsTests: XCTestCase {
    func testMaxLongEdgeMatchesADR004() {
        XCTAssertEqual(WorkingLimits.maxLongEdge, 4096)
    }
}
