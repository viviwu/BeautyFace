import XCTest
@testable import BFAlgorithms

final class BeautyParametersTests: XCTestCase {
    func testParametersAreClamped() {
        let params = BeautyParameters(
            smoothing: 1.8,
            whitening: -0.4,
            brightening: 0.5
        )
        XCTAssertEqual(params.smoothing, 1)
        XCTAssertEqual(params.whitening, 0)
        XCTAssertEqual(params.brightening, 0.5)
    }

    func testNaturalPresetIsNotIdentity() {
        XCTAssertFalse(BeautyParameters.natural.isIdentity)
        XCTAssertTrue(BeautyParameters.none.isIdentity)
    }

    func testNonFiniteValuesBecomeZero() {
        let params = BeautyParameters(
            smoothing: .nan,
            whitening: .infinity,
            brightening: -.infinity
        )
        XCTAssertEqual(params.smoothing, 0)
        XCTAssertEqual(params.whitening, 0)
        XCTAssertEqual(params.brightening, 0)
    }
}
