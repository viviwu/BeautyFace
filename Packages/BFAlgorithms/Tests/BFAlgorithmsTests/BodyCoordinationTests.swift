import XCTest
@testable import BFAlgorithms

final class BodyCoordinationTests: XCTestCase {
    private let imageSize = (width: 400, height: 600)
    private let columns = 41
    private let rows = 61

    // MARK: - 构造

    /// 合成脸：中心 (200,300)，轮廓宽 200、高 130，下巴 y=170（y 向上）。
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

    private func solidMask(
        width: Int = 64,
        height: Int = 96,
        value: Float = 1
    ) -> PersonMaskGrid {
        PersonMaskGrid(
            width: width,
            height: height,
            values: [Float](repeating: value, count: width * height)
        )
    }

    private func weight(
        _ table: [Float],
        at point: Point2,
        columns: Int,
        rows: Int,
        imageSize: (width: Int, height: Int)
    ) -> Float {
        let stepX = Float(imageSize.width - 1) / Float(max(columns - 1, 1))
        let stepY = Float(imageSize.height - 1) / Float(max(rows - 1, 1))
        let column = min(max(Int((point.x / stepX).rounded()), 0), columns - 1)
        let row = min(max(Int((point.y / stepY).rounded()), 0), rows - 1)
        return table[row * columns + column]
    }

    private func table(
        faces: [FaceGeometry]? = nil,
        mask: PersonMaskGrid?,
        config: DisplacementField.Config = DisplacementField.Config(),
        columns: Int? = nil,
        rows: Int? = nil,
        imageSize: (width: Int, height: Int)? = nil
    ) -> [Float] {
        let size = imageSize ?? self.imageSize
        let c = columns ?? self.columns
        let r = rows ?? self.rows
        return BodyCoordination.weightTable(
            faces: faces ?? [makeFace()],
            imageSize: size,
            columns: c,
            rows: r,
            config: config,
            mask: mask
        )
    }

    // MARK: - 数据契约 / 配置

    func testPersonMaskGridUsesYUpSampling() {
        let mask = PersonMaskGrid(
            width: 2,
            height: 2,
            values: [1, 1, 0, 0]   // row 0 = 图像上沿
        )
        XCTAssertFalse(mask.isEmpty)
        XCTAssertGreaterThan(mask.sample(u: 0.5, v: 0.9), 0.9, "y 向上 v=0.9 应命中上沿")
        XCTAssertLessThan(mask.sample(u: 0.5, v: 0.1), 0.1, "y 向上 v=0.1 应命中下沿")
        XCTAssertEqual(mask.sampleTopDown(u: 0.5, v: 0.1), 1, accuracy: 0.05)
        XCTAssertEqual(mask.sampleTopDown(u: 0.5, v: 0.9), 0, accuracy: 0.05)
    }

    func testConfigDefaultsMatchExplicitInit() {
        let implicit = DisplacementField.Config()
        let explicit = DisplacementField.Config(
            gridLongEdge: 128,
            maxDisplacementFraction: 0.10,
            displacementScale: 1,
            falloffInnerFactor: 0.15,
            falloffOuterFactor: 0.45,
            refinementDecay: 0.7,
            maxRefinements: 12,
            neckCorridorInnerFactor: 0.25,
            neckCorridorOuterFactor: 0.50,
            neckRootDropFactor: 0.08,
            shoulderDropFactor: 0.90,
            shoulderWidthJump: 1.8,
            neckUpperCutFactor: 0.10,
            maskGateLow: 0.08,
            maskGateHigh: 0.85,
            maskEpsilon: 0.01,
            shoulderLineFactorOverride: nil
        )

        XCTAssertEqual(implicit.gridLongEdge, explicit.gridLongEdge)
        XCTAssertEqual(implicit.maxDisplacementFraction, explicit.maxDisplacementFraction)
        XCTAssertEqual(implicit.displacementScale, explicit.displacementScale)
        XCTAssertEqual(implicit.falloffInnerFactor, explicit.falloffInnerFactor)
        XCTAssertEqual(implicit.falloffOuterFactor, explicit.falloffOuterFactor)
        XCTAssertEqual(implicit.refinementDecay, explicit.refinementDecay)
        XCTAssertEqual(implicit.maxRefinements, explicit.maxRefinements)
        XCTAssertEqual(implicit.neckCorridorInnerFactor, explicit.neckCorridorInnerFactor)
        XCTAssertEqual(implicit.neckCorridorOuterFactor, explicit.neckCorridorOuterFactor)
        XCTAssertEqual(implicit.neckRootDropFactor, explicit.neckRootDropFactor)
        XCTAssertEqual(implicit.shoulderDropFactor, explicit.shoulderDropFactor)
        XCTAssertEqual(implicit.shoulderWidthJump, explicit.shoulderWidthJump)
        XCTAssertEqual(implicit.neckUpperCutFactor, explicit.neckUpperCutFactor)
        XCTAssertEqual(implicit.maskGateLow, explicit.maskGateLow)
        XCTAssertEqual(implicit.maskGateHigh, explicit.maskGateHigh)
        XCTAssertEqual(implicit.maskEpsilon, explicit.maskEpsilon)
        XCTAssertNil(implicit.shoulderLineFactorOverride)
        XCTAssertNil(explicit.shoulderLineFactorOverride)
    }

    /// `--shoulder-line` 调试钩子必须能真正改变肩线，且不影响其他配置。
    func testShoulderLineOverride() {
        let faces = [makeFace()]
        let imageSize = (width: 400, height: 400)
        let mask = solidMask(width: 32, height: 48)

        func shoulder(_ override: Float?) -> Float {
            var config = DisplacementField.Config()
            config.shoulderLineFactorOverride = override
            return NeckShoulderEstimator.models(
                faces: faces,
                imageSize: imageSize,
                config: config,
                mask: mask
            )[0].shoulderY
        }

        let auto = shoulder(nil)
        let near = shoulder(0.6)
        let far = shoulder(1.8)
        XCTAssertGreaterThan(near, far, "倍率越大肩线越靠下（y 越小）")
        XCTAssertNotEqual(auto, near)
        XCTAssertFalse(
            NeckShoulderEstimator.models(
                faces: faces, imageSize: imageSize,
                config: {
                    var c = DisplacementField.Config()
                    c.shoulderLineFactorOverride = 0.6
                    return c
                }(),
                mask: mask
            )[0].usedMaskShoulder,
            "覆盖时不应再声称使用了蒙版推断"
        )
    }

    func testNilMaskMatchesLegacyFalloff() {
        let faces = [makeFace()]
        let config = DisplacementField.Config()
        let radial = DisplacementField.falloffTable(
            faces: faces,
            imageSize: imageSize,
            columns: columns,
            rows: rows,
            config: config
        )
        let combined = BodyCoordination.weightTable(
            radial: radial,
            faces: faces,
            imageSize: imageSize,
            columns: columns,
            rows: rows,
            config: config,
            mask: nil
        )
        XCTAssertEqual(combined, radial, "nil 蒙版必须位精确回到 M5 行为")
    }

    func testShoulderEstimationFallback() throws {
        let config = DisplacementField.Config()
        let faces = [makeFace()]
        let models = NeckShoulderEstimator.models(
            faces: faces,
            imageSize: imageSize,
            config: config,
            mask: nil
        )
        let model = try XCTUnwrap(models.first)
        let expectedNeckRoot: Float = 170 - 0.08 * 130
        let expectedShoulder: Float = expectedNeckRoot - 0.90 * 130
        XCTAssertEqual(model.neckRootY, expectedNeckRoot, accuracy: 0.01)
        XCTAssertEqual(model.shoulderY, expectedShoulder, accuracy: 0.01)
        XCTAssertFalse(model.usedMaskShoulder)

        // 全 1 蒙版没有宽度突变，也应走固定比例兜底，而不是把肩线拉到扫描终点。
        let solidModels = NeckShoulderEstimator.models(
            faces: faces,
            imageSize: imageSize,
            config: config,
            mask: solidMask()
        )
        let solidModel = try XCTUnwrap(solidModels.first)
        XCTAssertEqual(solidModel.shoulderY, expectedShoulder, accuracy: 0.01)
        XCTAssertFalse(solidModel.usedMaskShoulder)
    }

    // MARK: - 权重分区

    func testWeightZones() {
        let weights = table(mask: solidMask())
        XCTAssertGreaterThan(weight(weights, at: Point2(200, 300), columns: columns, rows: rows, imageSize: imageSize), 0.9, "脸部内保持高权重")
        XCTAssertGreaterThan(weight(weights, at: Point2(200, 120), columns: columns, rows: rows, imageSize: imageSize), 0.2, "颈部走廊应有权重")
        XCTAssertEqual(weight(weights, at: Point2(50, 120), columns: columns, rows: rows, imageSize: imageSize), 0, accuracy: 1e-6, "走廊外侧应为 0")
        XCTAssertEqual(weight(weights, at: Point2(200, 20), columns: columns, rows: rows, imageSize: imageSize), 0, accuracy: 1e-6, "肩线以下应为 0")
    }

    func testShoulderLineIsStrictlyZero() throws {
        let config = DisplacementField.Config()
        let model = try XCTUnwrap(NeckShoulderEstimator.models(
            faces: [makeFace()],
            imageSize: imageSize,
            config: config,
            mask: solidMask()
        ).first)
        let weights = table(mask: solidMask(), config: config)
        let below = model.shoulderY - 5
        XCTAssertEqual(
            weight(weights, at: Point2(model.axisX, below), columns: columns, rows: rows, imageSize: imageSize),
            0,
            accuracy: 1e-6
        )
    }

    func testOutsidePersonMaskIsStrictlyZero() {
        var values = [Float](repeating: 1, count: 64 * 96)
        // 在颈部中轴附近挖一个洞：x 150...250，y-up 80...160。
        for row in 0..<96 {
            let topDownV = (Float(row) + 0.5) / 96
            let yUp = (1 - topDownV) * Float(imageSize.height)
            guard yUp >= 80, yUp <= 160 else { continue }
            for column in 0..<64 {
                let x = (Float(column) + 0.5) / 64 * Float(imageSize.width)
                if x >= 150, x <= 250 {
                    values[row * 64 + column] = 0
                }
            }
        }
        let holed = PersonMaskGrid(width: 64, height: 96, values: values)

        let solid = table(mask: solidMask())
        let holedWeights = table(mask: holed)
        let m5Baseline = table(mask: nil)
        let probe = Point2(200, 120)
        XCTAssertGreaterThan(
            weight(solid, at: probe, columns: columns, rows: rows, imageSize: imageSize),
            0.2
        )
        // 组合公式 W = max(radial, neck × gate)：蒙版外不得出现**M8 新增**
        // 权重，但 M5 原有的径向衰减允许保留（这是「脸部与 M8 前逐像素
        // 一致」的必要条件，见 IMG_0789 头部特写的实测退化）。
        XCTAssertEqual(
            weight(holedWeights, at: probe, columns: columns, rows: rows, imageSize: imageSize),
            weight(m5Baseline, at: probe, columns: columns, rows: rows, imageSize: imageSize),
            accuracy: 1e-6,
            "蒙版外不得有任何 M8 新增权重"
        )
    }

    func testSideBackgroundUnaffected() {
        let weights = table(mask: solidMask())
        for x in [Float(50), Float(350)] {
            XCTAssertEqual(
                weight(weights, at: Point2(x, 120), columns: columns, rows: rows, imageSize: imageSize),
                0,
                accuracy: 1e-6,
                "走廊两侧不得因扩圈产生位移"
            )
        }
    }

    func testFaceZoneIdenticalToM5() {
        let faces = [makeFace()]
        let config = DisplacementField.Config()
        let radial = DisplacementField.falloffTable(
            faces: faces,
            imageSize: imageSize,
            columns: columns,
            rows: rows,
            config: config
        )
        let weights = table(faces: faces, mask: solidMask(), config: config)
        let faceCenter = Point2(200, 300)
        XCTAssertEqual(
            weight(weights, at: faceCenter, columns: columns, rows: rows, imageSize: imageSize),
            weight(radial, at: faceCenter, columns: columns, rows: rows, imageSize: imageSize),
            accuracy: 1e-6
        )
    }

    func testNeckProfileMonotonicDecay() throws {
        let config = DisplacementField.Config()
        let model = try XCTUnwrap(NeckShoulderEstimator.models(
            faces: [makeFace()],
            imageSize: imageSize,
            config: config,
            mask: solidMask()
        ).first)
        let weights = table(mask: solidMask(), config: config)

        var samples: [Float] = []
        for index in 0..<20 {
            let t = Float(index) / 19
            let y = model.neckRootY + (model.shoulderY - model.neckRootY) * t
            samples.append(weight(
                weights,
                at: Point2(model.axisX, y),
                columns: columns,
                rows: rows,
                imageSize: imageSize
            ))
        }
        let maximum = samples.max() ?? 0
        XCTAssertGreaterThan(maximum, 0.5)
        for index in 1..<samples.count {
            XCTAssertLessThanOrEqual(
                samples[index],
                samples[index - 1] + 0.02,
                "颈部中线权重不应反向增大"
            )
            XCTAssertLessThanOrEqual(
                abs(samples[index] - samples[index - 1]),
                0.15 * maximum + 0.02,
                "相邻网格点不应出现硬边"
            )
        }
    }

    func testMultiFaceCorridorsDoNotTruncate() {
        let faces = [
            face(at: Point2(100, 300), scale: 0.6),
            face(at: Point2(300, 300), scale: 0.6),
        ]
        let weights = table(faces: faces, mask: solidMask())
        XCTAssertGreaterThan(
            weight(weights, at: Point2(100, 200), columns: columns, rows: rows, imageSize: imageSize),
            0.3,
            "左脸颈段应有权重"
        )
        XCTAssertGreaterThan(
            weight(weights, at: Point2(300, 200), columns: columns, rows: rows, imageSize: imageSize),
            0.3,
            "右脸颈段应有权重"
        )
        XCTAssertEqual(
            weight(weights, at: Point2(200, 200), columns: columns, rows: rows, imageSize: imageSize),
            0,
            accuracy: 1e-6,
            "两脸之间不应连成一片"
        )
    }

    func testJacobianPositiveWithBodyConstraint() throws {
        var config = DisplacementField.Config()
        config.gridLongEdge = 64
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
            ),
            config: config,
            personMask: solidMask(width: 32, height: 48)
        ))
        XCTAssertGreaterThan(field.minimumJacobian(), 0)
        XCTAssertEqual(field.appliedStrength, 1, accuracy: 1e-6)
    }
}
