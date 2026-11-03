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

    /// 暖白色衣物与偏暖肤色的 Cb/Cr 都落在传统肤色带内，
    /// 必须靠「人脸肤色参考 + 亮度归一化色度距离」区分。
    func testWarmWhiteClothingIsNotSkin() throws {
        // 取自真实照片 IMG_0789.HEIC 的实测值
        let skinColor: (UInt8, UInt8, UInt8) = (179, 107, 87)
        let shadowColor: (UInt8, UInt8, UInt8) = (107, 64, 52)   // 同一肤色压暗 40%
        let clothingColor: (UInt8, UInt8, UInt8) = (189, 158, 135)

        let image = try TestSupport.makeImage(width: 200, height: 200) { _, y in
            switch y {
            case 20..<70:
                return (skinColor.0, skinColor.1, skinColor.2, 255)
            case 70..<110:
                return (shadowColor.0, shadowColor.1, shadowColor.2, 255)
            case 130..<200:
                return (clothingColor.0, clothingColor.1, clothingColor.2, 255)
            default:
                return (30, 60, 120, 255)
            }
        }

        let landmarks = FaceLandmarks(
            allPoints: [],
            faceContour: [],
            leftEye: [
                CGPoint(x: 0.38, y: 0.74),
                CGPoint(x: 0.42, y: 0.76),
                CGPoint(x: 0.46, y: 0.74),
                CGPoint(x: 0.42, y: 0.72),
            ],
            rightEye: [
                CGPoint(x: 0.54, y: 0.74),
                CGPoint(x: 0.58, y: 0.76),
                CGPoint(x: 0.62, y: 0.74),
                CGPoint(x: 0.58, y: 0.72),
            ],
            leftEyebrow: [],
            rightEyebrow: [],
            nose: [],
            noseCrest: [],
            medianLine: [],
            outerLips: [
                CGPoint(x: 0.42, y: 0.50),
                CGPoint(x: 0.50, y: 0.53),
                CGPoint(x: 0.58, y: 0.50),
                CGPoint(x: 0.50, y: 0.47),
            ],
            innerLips: [],
            leftPupil: [],
            rightPupil: []
        )
        let face = FaceObservation(
            boundingBox: CGRect(x: 0.20, y: 0.45, width: 0.60, height: 0.45),
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
            targetLongEdge: 200,
            featherRadius: 0
        ).generate(image: image, detection: detection)

        XCTAssertGreaterThan(
            try XCTUnwrap(mask.value(x: 60, y: 40)),
            0.9,
            "受光肤色应当被识别"
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(mask.value(x: 60, y: 90)),
            0.9,
            "同一肤色压暗后仍应被识别（亮度归一化应对阴影不敏感）"
        )
        XCTAssertLessThan(
            try XCTUnwrap(mask.value(x: 100, y: 170)),
            0.1,
            "暖白色衣物不应算作皮肤"
        )
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
