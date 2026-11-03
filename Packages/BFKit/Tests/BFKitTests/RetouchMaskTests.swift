import CoreGraphics
import XCTest
@testable import BFKit

final class RetouchMaskTests: XCTestCase {
    // MARK: - 合成人像的几何校验

    func testEyeMaskCoversScleraAndExcludesIris() throws {
        let mask = try makeSyntheticMask()

        let sclera = value(mask.eye, mask.width, mask.height, at: CGPoint(x: 0.31, y: 0.64))
        let iris = value(mask.eye, mask.width, mask.height, at: CGPoint(x: 0.36, y: 0.64))
        let otherEye = value(mask.eye, mask.width, mask.height, at: CGPoint(x: 0.59, y: 0.64))

        XCTAssertGreaterThan(sclera, 0.6, "眼白应当被识别")
        XCTAssertGreaterThan(otherEye, 0.6, "另一只眼的眼白同样应当被识别")
        XCTAssertLessThan(iris, 0.15, "虹膜不应进入眼白蒙版")
    }

    func testTeethMaskCoversTeethAndNotLips() throws {
        let mask = try makeSyntheticMask()

        let teeth = value(mask.teeth, mask.width, mask.height, at: CGPoint(x: 0.50, y: 0.405))
        let upperLip = value(mask.teeth, mask.width, mask.height, at: CGPoint(x: 0.50, y: 0.355))
        let lowerLip = value(mask.teeth, mask.width, mask.height, at: CGPoint(x: 0.50, y: 0.455))

        XCTAssertGreaterThan(teeth, 0.8, "牙齿应当被识别")
        XCTAssertLessThan(upperLip, 0.05, "上唇不应进入牙齿蒙版")
        XCTAssertLessThan(lowerLip, 0.05, "下唇不应进入牙齿蒙版")
    }

    func testDarkCircleMaskSitsBelowEye() throws {
        let mask = try makeSyntheticMask()

        let underEye = value(
            mask.darkCircle,
            mask.width,
            mask.height,
            at: SyntheticFace.darkCircleCenters[0]
        )
        let sclera = value(mask.darkCircle, mask.width, mask.height, at: CGPoint(x: 0.31, y: 0.64))
        let cheek = value(mask.darkCircle, mask.width, mask.height, at: CGPoint(x: 0.36, y: 0.47))

        XCTAssertGreaterThan(underEye, 0.5, "眼下暗沉应当被识别")
        XCTAssertLessThan(sclera, 0.05, "眼白区域不应算作黑眼圈")
        XCTAssertLessThan(cheek, 0.05, "远离眼下的脸颊不应进入黑眼圈蒙版")
    }

    func testRetouchMasksStayInsideFaceAndBackground() throws {
        let mask = try makeSyntheticMask()

        let backgroundPoints = [
            CGPoint(x: 0.03, y: 0.97),
            CGPoint(x: 0.97, y: 0.97),
            CGPoint(x: 0.03, y: 0.03),
            CGPoint(x: 0.97, y: 0.03),
            CGPoint(x: 0.50, y: 0.98),
        ]
        for point in backgroundPoints {
            XCTAssertEqual(value(mask.eye, mask.width, mask.height, at: point), 0)
            XCTAssertEqual(value(mask.teeth, mask.width, mask.height, at: point), 0)
            XCTAssertEqual(value(mask.darkCircle, mask.width, mask.height, at: point), 0)
        }

        // 额头中央同样不应出现任何局部修饰
        let forehead = CGPoint(x: 0.50, y: 0.82)
        XCTAssertLessThan(value(mask.eye, mask.width, mask.height, at: forehead), 0.02)
        XCTAssertLessThan(value(mask.teeth, mask.width, mask.height, at: forehead), 0.02)
        XCTAssertLessThan(value(mask.darkCircle, mask.width, mask.height, at: forehead), 0.02)
    }

    func testMaskValuesAreNormalized() throws {
        let mask = try makeSyntheticMask()
        for channel in [mask.eye, mask.teeth, mask.darkCircle] {
            XCTAssertEqual(channel.count, mask.width * mask.height)
            for value in channel {
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    // MARK: - 真实素材冒烟

    func testSampleImagesProduceLocalizedMasks() throws {
        for name in ["musk.jpeg", "vivi.jpeg"] {
            let url = try TestSupport.sampleImageURL(named: name)
            let decoded = try ImageDecoder.decode(url: url)
            let detection = try FaceDetector().detect(image: decoded.image)
            let skin = try SkinMaskGenerator(targetLongEdge: 512, featherRadius: 3)
                .generate(image: decoded.image, detection: detection)
            let retouch = try RetouchMaskGenerator().generate(
                image: decoded.image,
                detection: detection,
                skinMask: skin
            )

            XCTAssertFalse(retouch.isEmpty, "\(name) 应生成局部蒙版")
            XCTAssertEqual(retouch.width, skin.width)
            XCTAssertEqual(retouch.height, skin.height)

            // 局部区域应当远小于整张图，避免整片误判
            let area = Float(retouch.width * retouch.height)
            for channel in [retouch.eye, retouch.teeth, retouch.darkCircle] {
                let covered = channel.filter { $0 > 0.1 }.count
                XCTAssertLessThan(
                    Float(covered) / area,
                    0.05,
                    "\(name) 局部蒙版覆盖率过高，疑似误判"
                )
            }
        }
    }

    // MARK: - 工具

    private func makeSyntheticMask() throws -> RetouchMask {
        let image = try SyntheticFace.makeImage()
        let detection = SyntheticFace.makeDetection()
        let skin = try SkinMaskGenerator(targetLongEdge: 512, featherRadius: 3)
            .generate(image: image, detection: detection)
        XCTAssertFalse(skin.isEmpty, "合成人像应生成皮肤蒙版")
        return try RetouchMaskGenerator().generate(
            image: image,
            detection: detection,
            skinMask: skin
        )
    }

    private func value(
        _ channel: [Float],
        _ width: Int,
        _ height: Int,
        at point: CGPoint
    ) -> Float {
        let x = min(max(Int(point.x * CGFloat(width)), 0), width - 1)
        let y = min(max(Int((1 - point.y) * CGFloat(height)), 0), height - 1)
        return channel[y * width + x]
    }
}
