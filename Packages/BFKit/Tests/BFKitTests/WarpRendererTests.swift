import CoreGraphics
import XCTest
import BFAlgorithms
@testable import BFKit

final class WarpRendererTests: XCTestCase {
    /// 合成人脸关键点（与 BFAlgorithmsTests 中相同的布局）。
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

        return FaceGeometry(
            contour: contour,
            leftEye: cluster(Point2(160, 330)),
            rightEye: cluster(Point2(240, 330)),
            leftEyebrow: cluster(Point2(160, 355)),
            rightEyebrow: cluster(Point2(240, 355)),
            nose: cluster(Point2(200, 290)),
            outerLips: cluster(Point2(200, 230)),
            leftPupil: Point2(160, 331),
            rightPupil: Point2(240, 331)
        )
    }

    /// 底图：皮肤底色 + 下颌处一条竖直深色条纹 + 远处棋盘格纹理。
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        try TestSupport.makeImage(width: width, height: height) { x, y in
            if x > 520 {
                // 远处纹理，用于检测背景是否被拖动
                let checker = ((x / 8) + (y / 8)) % 2 == 0
                return checker ? (60, 60, 60, 255) : (200, 200, 200, 255)
            }
            // 下颌条纹（x = 250），其余为肤色
            if abs(x - 250) < 3 {
                return (80, 58, 48, 255)
            }
            return (214, 168, 138, 255)
        }
    }

    func testZeroFieldReturnsOriginalImage() throws {
        guard let renderer = try? WarpRenderer() else {
            throw XCTSkip("Metal 不可用")
        }
        let image = try makeImage(width: 200, height: 150)
        let field = DisplacementField(
            columns: 8,
            rows: 6,
            offsetX: [Float](repeating: 0, count: 48),
            offsetY: [Float](repeating: 0, count: 48),
            imageSize: (width: 200, height: 150),
            appliedStrength: 1
        )

        let output = try renderer.render(image: image, field: field)
        let source = try TestSupport.rgbaBytes(from: image)
        let bytes = try TestSupport.rgbaBytes(from: output)
        let difference = zip(source, bytes).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(difference, 1)
    }

    func testStrongDeformationMovesFaceKeepsBackground() throws {
        guard let renderer = try? WarpRenderer() else {
            throw XCTSkip("Metal 不可用")
        }
        let size = (width: 800, height: 600)
        let image = try makeImage(width: size.width, height: size.height)
        guard let field = DisplacementField.solve(
            faces: [makeFace()],
            imageSize: size,
            parameters: FaceShapeParameters(
                faceSize: 1,
                jawSlim: 1,
                faceNarrow: 1,
                vShape: 1,
                cheekbone: 1
            )
        ) else {
            return XCTFail("应当能够求解位移场")
        }

        let output = try renderer.render(image: image, field: field)
        let source = try TestSupport.rgbaBytes(from: image)
        let bytes = try TestSupport.rgbaBytes(from: output)

        // 远处棋盘纹理不应被拖动
        var maxBackgroundDifference = 0
        for y in stride(from: 0, to: size.height, by: 2) {
            for x in stride(from: 540, to: size.width, by: 2) {
                let offset = (y * size.width + x) * 4
                for channel in 0..<3 {
                    maxBackgroundDifference = max(
                        maxBackgroundDifference,
                        abs(Int(source[offset + channel]) - Int(bytes[offset + channel]))
                    )
                }
            }
        }
        XCTAssertLessThanOrEqual(maxBackgroundDifference, 6, "背景纹理不应被形变拖动")

        // 脸部下颌区域应发生明显变化
        var changedPixels = 0
        for y in stride(from: 180, to: 300, by: 2) {
            for x in stride(from: 110, to: 300, by: 2) {
                let offset = (y * size.width + x) * 4
                let difference = abs(
                    Int(source[offset]) - Int(bytes[offset])
                )
                if difference > 8 {
                    changedPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(changedPixels, 40, "脸部应当被重新整形")
    }

    func testStrongDeformationDoesNotFold() throws {
        let size = (width: 800, height: 600)
        guard let field = DisplacementField.solve(
            faces: [makeFace()],
            imageSize: size,
            parameters: FaceShapeParameters(
                faceSize: 1,
                jawSlim: 1,
                faceNarrow: 1,
                vShape: 1,
                chin: 1,
                forehead: 1,
                cheekbone: 1
            )
        ) else {
            return XCTFail("应当能够求解位移场")
        }
        XCTAssertGreaterThan(field.minimumJacobian(), 0)
        XCTAssertGreaterThanOrEqual(field.appliedStrength, 1)
    }
}
