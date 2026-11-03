import XCTest
@testable import BFAlgorithms

final class BeautyParametersTests: XCTestCase {
    func testParametersAreClamped() {
        let params = BeautyParameters(
            smoothing: 1.8,
            whitening: -0.4,
            brightening: 0.5,
            eyeBrightening: 1.2,
            teethWhitening: -1,
            darkCircleRemoval: 0.6,
            blemishRemoval: 2
        )
        XCTAssertEqual(params.smoothing, 1)
        XCTAssertEqual(params.whitening, 0)
        XCTAssertEqual(params.brightening, 0.5)
        XCTAssertEqual(params.eyeBrightening, 1)
        XCTAssertEqual(params.teethWhitening, 0)
        XCTAssertEqual(params.darkCircleRemoval, 0.6)
        XCTAssertEqual(params.blemishRemoval, 1)
    }

    func testNaturalPresetIsNotIdentity() {
        XCTAssertFalse(BeautyParameters.natural.isIdentity)
        XCTAssertTrue(BeautyParameters.none.isIdentity)
    }

    func testNonFiniteValuesBecomeZero() {
        let params = BeautyParameters(
            smoothing: .nan,
            whitening: .infinity,
            brightening: -.infinity,
            eyeBrightening: .nan,
            teethWhitening: .infinity,
            darkCircleRemoval: -.infinity,
            blemishRemoval: .nan
        )
        XCTAssertTrue(params.isIdentity)
    }

    func testLocalParametersAreNotIdentity() {
        let params = BeautyParameters(eyeBrightening: 0.2)
        XCTAssertFalse(params.isIdentity)
    }
}
