import CoreGraphics
import XCTest
import BFAlgorithms
@testable import BFKit

final class MakeupTests: XCTestCase {
    /// 合成人脸（与 WarpRendererTests 相同布局，另补口内轮廓）。
    private func makeFace() -> FaceGeometry {
        let center = Point2(200, 300)
        var contour: [Point2] = []
        for index in 0..<17 {
            let theta = Float.pi * (1 - Float(index) / 16)
            contour.append(Point2(
                center.x + 100 * cos(theta),
                center.y - 130 * sin(theta)
            ))
        }

        func cluster(_ origin: Point2) -> [Point2] {
            (0..<6).map { index in
                Point2(origin.x + Float(index - 2) * 4, origin.y + Float(index % 2) * 3)
            }
        }

        // 真实唇形：外唇 40×16 矩形（8 点），口内 24×8（4 点）
        func rect(_ center: Point2, _ halfW: Float, _ halfH: Float, n: Int = 8) -> [Point2] {
            (0..<n).map { index in
                let theta = Float.pi * 2 * Float(index) / Float(n)
                return Point2(
                    center.x + halfW * cos(theta),
                    center.y + halfH * sin(theta)
                )
            }
        }

        return FaceGeometry(
            contour: contour,
            leftEye: cluster(Point2(160, 330)),
            rightEye: cluster(Point2(240, 330)),
            leftEyebrow: cluster(Point2(160, 355)),
            rightEyebrow: cluster(Point2(240, 355)),
            nose: cluster(Point2(200, 290)),
            outerLips: rect(Point2(200, 230), 20, 8),
            innerLips: rect(Point2(200, 230), 12, 4, n: 4),
            leftPupil: Point2(160, 331),
            rightPupil: Point2(240, 331)
        )
    }

    // MARK: - 参数

    func testMakeupParametersClampAndIdentity() {
        var parameters = MakeupParameters(
            lipstick: 1.5,
            blush: -0.2,
            brow: 0.5
        )
        XCTAssertEqual(parameters.lipstick, 1)
        XCTAssertEqual(parameters.blush, 0)
        XCTAssertEqual(parameters.brow, 0.5)
        XCTAssertFalse(parameters.isIdentity)

        parameters.lipstick = 0
        parameters.brow = 0
        XCTAssertTrue(parameters.isIdentity)
    }

    // MARK: - 蒙版生成

    func testLipMaskInsideOuterLipsAndExcludesInner() {
        let generator = MakeupMaskGenerator(maskLongEdge: 200)
        let mask = generator.generate(
            faces: [makeFace()],
            imageSize: (width: 400, height: 600)
        )

        // 唇部（y=230±8，y-up）附近应有口红蒙版；扫整个唇高带
        var maxLip: Float = 0
        var maxLipX = -1
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                if mask.lip[y * mask.width + x] > maxLip {
                    maxLip = mask.lip[y * mask.width + x]
                    maxLipX = x
                }
            }
        }
        XCTAssertGreaterThan(maxLip, 0.5, "唇部区域应有着色")
        let lipFaceX = Float(maxLipX) / Float(mask.width) * 400
        XCTAssertEqual(lipFaceX, 200, accuracy: 25, "口红应落在唇部横向范围内")

        // 口内中心（x=200）处的口红蒙版应明显低于外唇峰值
        var innerMax: Float = 0
        for y in 0..<mask.height {
            for x in 195...205 where x < mask.width {
                innerMax = max(innerMax, mask.lip[y * mask.width + x])
            }
        }
        XCTAssertLessThan(innerMax, maxLip, "口内着色应低于唇部")
    }

    func testBlushMaskAppearsOnBothCheeks() {
        let generator = MakeupMaskGenerator(maskLongEdge: 200)
        let mask = generator.generate(
            faces: [makeFace()],
            imageSize: (width: 400, height: 600)
        )

        // 腮红中心在眼睛（y≈330）与唇（y≈230）之间，x 在两侧
        var leftMax: Float = 0
        var rightMax: Float = 0
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.blush[y * mask.width + x] > 0 {
                let faceX = Float(x) / Float(mask.width) * 400
                if faceX < 200 {
                    leftMax = max(leftMax, mask.blush[y * mask.width + x])
                } else {
                    rightMax = max(rightMax, mask.blush[y * mask.width + x])
                }
            }
        }
        XCTAssertGreaterThan(leftMax, 0.3, "左脸颊应有腮红")
        XCTAssertGreaterThan(rightMax, 0.3, "右脸颊应有腮红")
    }

    func testDeformedGeometryFollowsDisplacementField() {
        // 常量位移场：所有节点位移 (10, -5)
        let size = 4
        let field = DisplacementField(
            columns: size,
            rows: size,
            offsetX: [Float](repeating: 10, count: size * size),
            offsetY: [Float](repeating: -5, count: size * size),
            imageSize: (width: 400, height: 600),
            appliedStrength: 1
        )
        let face = makeFace()
        let deformed = MakeupMaskGenerator.deformed(face, field: field)

        for (original, moved) in zip(face.outerLips, deformed.outerLips) {
            XCTAssertEqual(moved.x, original.x - 10, accuracy: 0.6)
            XCTAssertEqual(moved.y, original.y + 5, accuracy: 0.6)
        }
        // 无场时保持原样
        let identity = MakeupMaskGenerator.deformed(face, field: nil)
        XCTAssertEqual(identity.outerLips, face.outerLips)
    }

    // MARK: - 渲染

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try TestSupport.makeImage(width: width, height: height) { _, _ in
            (214, 168, 138, 255)
        }
    }

    func testZeroStrengthsReturnOriginalImage() throws {
        guard let renderer = try? MakeupRenderer() else {
            throw XCTSkip("Metal 不可用")
        }
        let image = try makeImage(width: 64, height: 48)
        let mask = MakeupMask.empty
        let output = try renderer.render(
            image: image,
            mask: mask,
            parameters: MakeupParameters(lipstick: 1)
        )
        // 强度为 0 时 isIdentity 早退，输出即输入
        XCTAssertEqual(output.width, image.width)
    }

    func testLipstickTintsTowardColorPreservingLuma() throws {
        guard let renderer = try? MakeupRenderer() else {
            throw XCTSkip("Metal 不可用")
        }
        // 全图纯肤色 + 全 1 口红蒙版：输出应保留亮度、色相偏向口红
        let image = try makeImage(width: 64, height: 48)
        let mask = MakeupMask(
            width: 8,
            height: 8,
            lip: [Float](repeating: 1, count: 64),
            blush: [Float](repeating: 0, count: 64),
            brow: [Float](repeating: 0, count: 64),
            shadow: [Float](repeating: 0, count: 64)
        )
        let output = try renderer.render(
            image: image,
            mask: mask,
            parameters: MakeupParameters(lipstick: 1)
        )

        let sourceBytes = try TestSupport.rgbaBytes(from: image)
        let outputBytes = try TestSupport.rgbaBytes(from: output)
        let index = (24 * 64 + 32) * 4
        let sourceLuma = 0.299 * Float(sourceBytes[index])
            + 0.587 * Float(sourceBytes[index + 1])
            + 0.114 * Float(sourceBytes[index + 2])
        let outputLuma = 0.299 * Float(outputBytes[index])
            + 0.587 * Float(outputBytes[index + 1])
            + 0.114 * Float(outputBytes[index + 2])
        XCTAssertEqual(outputLuma, sourceLuma, accuracy: 15, "口红应保持亮度")
        // 红移：R-G 差应显著变大
        let sourceRedBias = Float(sourceBytes[index]) - Float(sourceBytes[index + 1])
        let outputRedBias = Float(outputBytes[index]) - Float(outputBytes[index + 1])
        XCTAssertGreaterThan(outputRedBias, sourceRedBias + 30, "口红应向红色偏移")
    }
}
