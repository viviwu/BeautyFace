import XCTest
@testable import BFAlgorithms

final class DisplacementFieldTests: XCTestCase {
    /// 合成一张脸（与 FaceShapeAdjusterTests 相同的布局）。
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

    private let imageSize = (width: 800, height: 600)

    func testIdentityParametersReturnNil() {
        let field = DisplacementField.solve(
            faces: [makeFace()],
            imageSize: imageSize,
            parameters: .none
        )
        XCTAssertNil(field, "恒等参数不应产生位移场")
    }

    func testFarFieldStaysNearIdentity() throws {
        let field = try XCTUnwrap(DisplacementField.solve(
            faces: [makeFace()],
            imageSize: imageSize,
            parameters: FaceShapeParameters(
                faceSize: 1,
                jawSlim: 1,
                faceNarrow: 1,
                vShape: 1,
                chin: 1,
                forehead: 1,
                cheekbone: 1
            )
        ))

        XCTAssertGreaterThan(field.maximumDisplacement(), 5, "脸部应当发生形变")

        // 远离脸部的角落与边缘几乎不动
        for probe in [Point2(700, 60), Point2(760, 560), Point2(60, 560)] {
            let d = field.displacement(at: probe).length
            XCTAssertLessThan(d, 1.5, "背景点 \(probe) 位移应接近 0")
        }
    }

    func testJacobianStaysPositiveAtMaximumStrength() throws {
        let field = try XCTUnwrap(DisplacementField.solve(
            faces: [makeFace()],
            imageSize: imageSize,
            parameters: FaceShapeParameters(
                faceSize: 1,
                jawSlim: 1,
                faceNarrow: 1,
                vShape: 1,
                chin: 1,
                forehead: 1,
                cheekbone: 1
            )
        ))

        XCTAssertGreaterThan(field.minimumJacobian(), 0, "最大强度下不应折叠")
        XCTAssertEqual(field.appliedStrength, 1, accuracy: 1e-6, "不应触发回退")
    }

    func testExtremeDisplacementTriggersStrengthFallback() throws {
        // 全局位移倍率与位移上限同时放大，逼出折叠回退路径
        var config = DisplacementField.Config()
        config.displacementScale = 12
        config.maxDisplacementFraction = 1.0
        config.gridLongEdge = 96

        let field = try XCTUnwrap(DisplacementField.solve(
            faces: [makeFace()],
            imageSize: imageSize,
            parameters: FaceShapeParameters(faceSize: 1, jawSlim: 1),
            config: config
        ))

        XCTAssertLessThan(field.appliedStrength, 1, "极端位移应触发强度回退")
        XCTAssertGreaterThan(field.minimumJacobian(), 0, "回退后不应折叠")
    }

    func testDisplacementSamplingMatchesNodes() throws {
        let field = try XCTUnwrap(DisplacementField.solve(
            faces: [makeFace()],
            imageSize: imageSize,
            parameters: FaceShapeParameters(jawSlim: 1)
        ))

        // 网格节点处采样值应与节点值一致
        let stepX = Float(imageSize.width - 1) / Float(field.columns - 1)
        let stepY = Float(imageSize.height - 1) / Float(field.rows - 1)
        let row = field.rows / 2
        let column = field.columns / 3
        let node = Point2(Float(column) * stepX, Float(row) * stepY)
        let sampled = field.displacement(at: node)
        let index = row * field.columns + column

        XCTAssertEqual(sampled.x, field.offsetX[index], accuracy: 1e-3)
        XCTAssertEqual(sampled.y, field.offsetY[index], accuracy: 1e-3)
    }

    /// 把合成脸缩放并平移到指定中心。
    private func face(at center: Point2, scale: Float) -> FaceGeometry {
        let origin = Point2(200, 300)
        var face = makeFace()
        func move(_ point: Point2) -> Point2 {
            Point2(
                (point.x - origin.x) * scale + center.x,
                (point.y - origin.y) * scale + center.y
            )
        }
        face.contour = face.contour.map(move)
        face.leftEye = face.leftEye.map(move)
        face.rightEye = face.rightEye.map(move)
        face.leftEyebrow = face.leftEyebrow.map(move)
        face.rightEyebrow = face.rightEyebrow.map(move)
        face.nose = face.nose.map(move)
        face.outerLips = face.outerLips.map(move)
        face.leftPupil = face.leftPupil.map(move)
        face.rightPupil = face.rightPupil.map(move)
        return face
    }

    func testMultipleFacesAreIndependent() throws {
        let left = face(at: Point2(150, 300), scale: 0.6)
        let right = face(at: Point2(650, 300), scale: 0.6)

        let field = try XCTUnwrap(DisplacementField.solve(
            faces: [left, right],
            imageSize: imageSize,
            parameters: FaceShapeParameters(jawSlim: 1)
        ))

        // 两张脸的下颌角都应有明显位移
        XCTAssertGreaterThan(
            field.displacement(at: Point2(180, 232)).length,
            1.0,
            "左脸下颌应被收窄"
        )
        XCTAssertGreaterThan(
            field.displacement(at: Point2(680, 232)).length,
            1.0,
            "右脸下颌应被收窄"
        )

        // 两脸之间与两脸下方应几乎不动
        for probe in [Point2(400, 300), Point2(400, 480)] {
            XCTAssertLessThan(
                field.displacement(at: probe).length,
                2.0,
                "脸部之间 \(probe) 不应被拖动"
            )
        }
    }
}
