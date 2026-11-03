import CoreGraphics
import XCTest
@testable import BFKit

final class SkinMaskTests: XCTestCase {
    private let skin: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) = { _, _ in
        (210, 160, 130, 255)
    }

    func testSkinToneImageProducesMask() throws {
        let image = try TestSupport.makeImage(
            width: 120,
            height: 120,
            pixel: skin
        )
        let detection = DetectionResult(
            imageSize: CGSize(width: 120, height: 120),
            faces: [],
            personMask: SegmentationMask(
                width: 60,
                height: 60,
                pixels: [UInt8](repeating: 255, count: 60 * 60)
            )
        )

        let mask = try SkinMaskGenerator(
            targetLongEdge: 64,
            featherRadius: 2
        ).generate(image: image, detection: detection)

        XCTAssertEqual(mask.width, 64)
        XCTAssertEqual(mask.height, 64)
        XCTAssertGreaterThan(mask.averageValue, 0.5)
        XCTAssertGreaterThan(try XCTUnwrap(mask.value(x: 32, y: 32)), 0.9)
        XCTAssertNotNil(mask.makeCGImage())
    }

    func testMaskScalesToTargetLongEdge() throws {
        let image = try TestSupport.makeImage(
            width: 1200,
            height: 800,
            pixel: skin
        )
        let detection = DetectionResult(
            imageSize: CGSize(width: 1200, height: 800),
            faces: [],
            personMask: SegmentationMask(
                width: 60,
                height: 40,
                pixels: [UInt8](repeating: 255, count: 60 * 40)
            )
        )

        let mask = try SkinMaskGenerator(
            targetLongEdge: 512,
            featherRadius: 0
        ).generate(image: image, detection: detection)
        XCTAssertEqual(mask.width, 512)
        XCTAssertEqual(mask.height, 341)
    }

    func testNonSkinColorProducesEmptyMask() throws {
        let image = try TestSupport.makeImage(
            width: 120,
            height: 120,
            pixel: { _, _ in (30, 80, 200, 255) }
        )
        let detection = DetectionResult(
            imageSize: CGSize(width: 120, height: 120),
            faces: [],
            personMask: SegmentationMask(
                width: 60,
                height: 60,
                pixels: [UInt8](repeating: 255, count: 60 * 60)
            )
        )

        let mask = try SkinMaskGenerator(
            targetLongEdge: 64,
            featherRadius: 2
        ).generate(image: image, detection: detection)
        XCTAssertLessThan(mask.averageValue, 0.01)
    }

    func testPersonMaskProtectsBackground() throws {
        let image = try TestSupport.makeImage(
            width: 200,
            height: 200,
            pixel: skin
        )
        var pixels = [UInt8](repeating: 0, count: 100 * 100)
        for y in 35..<65 {
            for x in 35..<65 {
                pixels[y * 100 + x] = 255
            }
        }
        let detection = DetectionResult(
            imageSize: CGSize(width: 200, height: 200),
            faces: [],
            personMask: SegmentationMask(width: 100, height: 100, pixels: pixels)
        )

        let mask = try SkinMaskGenerator(
            targetLongEdge: 100,
            featherRadius: 3
        ).generate(image: image, detection: detection)

        XCTAssertGreaterThan(try XCTUnwrap(mask.value(x: 50, y: 50)), 0.9)
        XCTAssertLessThan(try XCTUnwrap(mask.value(x: 0, y: 0)), 0.01)
        XCTAssertLessThan(try XCTUnwrap(mask.value(x: 99, y: 0)), 0.01)
        XCTAssertLessThan(try XCTUnwrap(mask.value(x: 0, y: 99)), 0.01)
        XCTAssertLessThan(try XCTUnwrap(mask.value(x: 99, y: 99)), 0.01)
    }

    func testEyesAndLipsAreExcluded() throws {
        let image = try TestSupport.makeImage(
            width: 200,
            height: 200,
            pixel: skin
        )
        let landmarks = FaceLandmarks(
            allPoints: [],
            faceContour: [],
            leftEye: [
                CGPoint(x: 0.40, y: 0.50),
                CGPoint(x: 0.44, y: 0.52),
                CGPoint(x: 0.48, y: 0.50),
                CGPoint(x: 0.44, y: 0.48),
            ],
            rightEye: [
                CGPoint(x: 0.52, y: 0.50),
                CGPoint(x: 0.56, y: 0.52),
                CGPoint(x: 0.60, y: 0.50),
                CGPoint(x: 0.56, y: 0.48),
            ],
            leftEyebrow: [],
            rightEyebrow: [],
            nose: [],
            noseCrest: [],
            medianLine: [],
            outerLips: [
                CGPoint(x: 0.44, y: 0.36),
                CGPoint(x: 0.50, y: 0.39),
                CGPoint(x: 0.56, y: 0.36),
                CGPoint(x: 0.50, y: 0.33),
            ],
            innerLips: [],
            leftPupil: [],
            rightPupil: []
        )
        let face = FaceObservation(
            boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            roll: nil,
            yaw: nil,
            confidence: 1,
            landmarks: landmarks
        )
        let detection = DetectionResult(
            imageSize: CGSize(width: 200, height: 200),
            faces: [face],
            personMask: SegmentationMask(
                width: 100,
                height: 100,
                pixels: [UInt8](repeating: 255, count: 100 * 100)
            )
        )

        let mask = try SkinMaskGenerator(
            targetLongEdge: 100,
            featherRadius: 0
        ).generate(image: image, detection: detection)

        XCTAssertEqual(try XCTUnwrap(mask.value(x: 44, y: 50)), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(mask.value(x: 50, y: 61)), 0, accuracy: 0.001)
        XCTAssertGreaterThan(try XCTUnwrap(mask.value(x: 20, y: 20)), 0.9)
    }

    func testSampleImageMaskIsLocalizedWhenAvailable() throws {
        let url = try TestSupport.sampleImageURL(named: "musk.jpeg")
        let decoded = try ImageDecoder.decode(url: url)
        let detection = try FaceDetector().detect(image: decoded.image)
        let mask = try SkinMaskGenerator(
            targetLongEdge: 256,
            featherRadius: 3
        ).generate(image: decoded.image, detection: detection)

        XCTAssertFalse(mask.isEmpty)
        XCTAssertGreaterThan(mask.averageValue, 0.01)
        XCTAssertLessThan(try XCTUnwrap(mask.value(x: 0, y: 0)), 0.05)
        XCTAssertLessThan(try XCTUnwrap(mask.value(x: mask.width - 1, y: 0)), 0.05)
        XCTAssertLessThan(try XCTUnwrap(mask.value(x: 0, y: mask.height - 1)), 0.05)
        XCTAssertLessThan(
            try XCTUnwrap(mask.value(x: mask.width - 1, y: mask.height - 1)),
            0.05
        )
    }
}
