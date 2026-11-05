import XCTest
@testable import BFAlgorithms

final class FaceFeatureAdjusterTests: XCTestCase {
    /// 与 FaceShapeAdjusterTests 同款合成脸：椭圆轮廓 + 双眼 / 眉 / 鼻 / 唇 / 瞳孔。
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

    private func table(
        _ parameters: FaceFeatureParameters,
        _ face: FaceGeometry = FaceFeatureAdjusterTests().makeFace()
    ) -> [Point2: Point2] {
        FaceFeatureAdjuster.displacements(for: face, parameters: parameters)
    }

    // MARK: - 恒等

    func testIdentityReturnsAnchors() {
        let face = makeFace()
        let controls = FaceFeatureAdjuster().controls(
            for: face,
            parameters: .none
        )
        XCTAssertFalse(controls.isEmpty)
        for control in controls {
            XCTAssertEqual(control.output, control.source)
        }
        // 覆盖所有五官点（排除轮廓）
        let contour = Set(face.contour)
        XCTAssertEqual(controls.count, face.allPoints.count - face.contour.count)
        for control in controls {
            XCTAssertFalse(contour.contains(control.source), "五官控制点不应包含轮廓点")
        }
    }

    // MARK: - 大眼

    func testEyeSizeEnlargesEyesRadially() {
        let face = makeFace()
        let result = table(.init(eyeSize: 1), face)

        for eye in [face.leftEye, face.rightEye] {
            let center = FaceMetrics.centroid(eye)
            for point in eye {
                let moved = point + (result[point] ?? .zero)
                let before = point.distanceSquared(to: center).squareRoot()
                let after = moved.distanceSquared(to: center).squareRoot()
                XCTAssertGreaterThan(
                    after,
                    before + 0.1,
                    "眼眶点应远离眼睛质心：\(point)"
                )
            }
            // 纵向系数（0.30）大于横向（0.18）：极上点的纵向生长比
            // 应大于极右点的横向生长比
            let verticalPoint = eye.max { abs($0.y - center.y) < abs($1.y - center.y) }!
            let horizontalPoint = eye.max { abs($0.x - center.x) < abs($1.x - center.x) }!
            let verticalBefore = abs(verticalPoint.y - center.y)
            let verticalAfter = abs((verticalPoint + (result[verticalPoint] ?? .zero)).y - center.y)
            let horizontalBefore = abs(horizontalPoint.x - center.x)
            let horizontalAfter = abs((horizontalPoint + (result[horizontalPoint] ?? .zero)).x - center.x)
            if verticalBefore > 0.5, horizontalBefore > 0.5 {
                XCTAssertGreaterThan(
                    verticalAfter / verticalBefore,
                    horizontalAfter / horizontalBefore,
                    "纵向放大应强于横向"
                )
            }
        }
        // 瞳孔（位于质心附近）几乎不动
        XCTAssertEqual(result[face.leftPupil!]?.length ?? 0, 0, accuracy: 1e-5)
    }

    // MARK: - 眼距

    func testEyeDistanceShiftsEachEyeTowardAxisWithoutDistortion() {
        let face = makeFace()
        let result = table(.init(eyeDistance: 1), face)
        let axisX = (FaceMetrics.centroid(face.leftEye).x
            + FaceMetrics.centroid(face.rightEye).x) * 0.5

        for (eye, pupil) in [(face.leftEye, face.leftPupil!), (face.rightEye, face.rightPupil!)] {
            let center = FaceMetrics.centroid(eye)
            let shift = (result[eye[0]] ?? .zero).x
            XCTAssertNotEqual(shift, 0)

            for point in eye {
                // 整眼同量平移：眼形不变
                XCTAssertEqual((result[point] ?? .zero).x, shift, accuracy: 1e-5)
                XCTAssertEqual((result[point] ?? .zero).y, 0, accuracy: 1e-5)
            }
            // 平移方向朝纵轴
            XCTAssertEqual(shift.sign == (axisX - center.x).sign, true)
            // 瞳孔随动
            XCTAssertEqual((result[pupil] ?? .zero).x, shift, accuracy: 1e-5)
        }
    }

    // MARK: - 眉间距 / 眉粗

    func testBrowSpacingShiftsBrowsTowardEachOther() {
        let face = makeFace()
        let result = table(.init(browSpacing: 1), face)
        let axisX = (FaceMetrics.centroid(face.leftEyebrow).x
            + FaceMetrics.centroid(face.rightEyebrow).x) * 0.5

        for brow in [face.leftEyebrow, face.rightEyebrow] {
            let center = FaceMetrics.centroid(brow)
            let shift = (result[brow[0]] ?? .zero).x
            XCTAssertEqual(shift.sign == (axisX - center.x).sign, true)
            for point in brow {
                XCTAssertEqual((result[point] ?? .zero).x, shift, accuracy: 1e-5)
            }
        }
        // 眉间距不影响眼睛
        for point in face.leftEye + face.rightEye {
            XCTAssertEqual(result[point] ?? .zero, .zero)
        }
    }

    func testBrowThicknessStretchesBrowsVertically() {
        let face = makeFace()
        let result = table(.init(browThickness: 1), face)

        for brow in [face.leftEyebrow, face.rightEyebrow] {
            let center = FaceMetrics.centroid(brow)
            for point in brow {
                let dy = (result[point] ?? .zero).y
                // 高于质心的点向上、低于质心的点向下：眉形纵向张开
                if point.y > center.y + 0.5 {
                    XCTAssertGreaterThan(dy, 0.05, "\(point)")
                } else if point.y < center.y - 0.5 {
                    XCTAssertLessThan(dy, -0.05, "\(point)")
                }
            }
        }
    }

    // MARK: - 鼻翼

    func testNoseWidthNarrowsNoseTowardAxis() {
        let face = makeFace()
        let result = table(.init(noseWidth: 1), face)
        let axisX = FaceMetrics.centroid(face.nose).x

        for point in face.nose {
            let delta = result[point] ?? .zero
            XCTAssertEqual(delta.y, 0, accuracy: 1e-5)
            XCTAssertEqual(delta.x.sign == (axisX - point.x).sign, true, "\(point)")
            // 收窄量与横向距离成正比
            XCTAssertEqual(delta.x, -(point.x - axisX) * 0.32, accuracy: 1e-5)
        }
    }

    // MARK: - 嘴型

    func testMouthShapeLiftsCornersAndNarrows() {
        let face = makeFace()
        let result = table(.init(mouthShape: 1), face)
        let center = FaceMetrics.centroid(face.outerLips)
        let halfWidth = face.outerLips.map { abs($0.x - center.x) }.max()!

        for point in face.outerLips {
            let delta = result[point] ?? .zero
            // 水平收拢
            XCTAssertEqual(delta.x, -(point.x - center.x) * 0.08, accuracy: 1e-5)
            // 嘴角抬升最强，唇中不动
            let expectedLift = 0.30 * max(
                face.outerLips.map { abs($0.y - center.y) }.max()!,
                halfWidth * 0.3
            ) * ((point.x - center.x) / halfWidth) * ((point.x - center.x) / halfWidth)
            XCTAssertEqual(delta.y, expectedLift, accuracy: 1e-4)
        }
    }

    // MARK: - 上限

    func testControlsCappedByFaceHeight() {
        let face = makeFace()
        let controls = FaceFeatureAdjuster().controls(
            for: face,
            parameters: FaceFeatureParameters(
                eyeSize: 1,
                eyeDistance: 1,
                browSpacing: 1,
                browThickness: 1,
                noseWidth: 1,
                mouthShape: 1
            )
        )
        let cap = 0.10 * FaceMetrics(face).height
        for control in controls {
            XCTAssertLessThanOrEqual(
                (control.output - control.source).length,
                cap + 1e-4
            )
        }
    }

    // MARK: - 端到端

    func testSolveWithOnlyFeatureParametersProducesValidField() {
        let face = makeFace()
        let field = DisplacementField.solve(
            faces: [face],
            imageSize: (width: 800, height: 600),
            parameters: .none,
            features: FaceFeatureParameters(eyeSize: 0.8, mouthShape: 0.6)
        )
        XCTAssertNotNil(field, "仅五官参数也应产出位移场")
        XCTAssertGreaterThan(field!.minimumJacobian(), 0, "不得出现折叠")
        XCTAssertGreaterThan(field!.maximumDisplacement(), 0.5)

        // 远角（背景）位移应接近 0
        let corner = field!.displacement(at: Point2(20, 20))
        XCTAssertLessThan(corner.length, 0.5)
    }

    func testSolveReturnsNilWhenAllParametersIdentity() {
        let field = DisplacementField.solve(
            faces: [makeFace()],
            imageSize: (width: 800, height: 600),
            parameters: .none,
            features: .none
        )
        XCTAssertNil(field)
    }

    /// 波浪根治回归：五官位移再大也不能把脸缘拽动——场 B 的轮廓
    /// 逐点锚定为零，叠加后边缘位移 = 纯脸型剖面。
    func testFeatureDisplacementDoesNotReachSilhouette() {
        var face = makeFace()
        face.leftEye = (0..<8).map { i in
            Point2(160 + Float(i) * 3, 330 + Float(i % 2) * 6)
        }
        face.rightEye = (0..<8).map { i in
            Point2(240 + Float(i) * 3, 330 + Float(i % 2) * 6)
        }
        let field = DisplacementField.solve(
            faces: [face],
            imageSize: (width: 800, height: 600),
            parameters: .none,
            features: FaceFeatureParameters(
                eyeSize: 1,
                eyeDistance: 1,
                browSpacing: 1,
                browThickness: 1,
                noseWidth: 1,
                mouthShape: 1
            )
        )
        XCTAssertNotNil(field)

        let metrics = FaceMetrics(face)
        for point in face.contour {
            let d = field!.displacement(at: point)
            XCTAssertLessThan(
                d.length,
                2.0,
                "轮廓点 \(point) 被五官形变拽动 \(d.length)px"
            )
        }
        // 五官区域本身仍有明显位移
        let eyeTop = face.leftEye.max { $0.y < $1.y }!
        XCTAssertGreaterThan(
            field!.displacement(at: eyeTop).length,
            2.0,
            "眼部区域应有位移"
        )
        _ = metrics
    }

    /// 脸型 + 五官同时启用：叠加场的雅可比仍为正（无折叠）。
    func testCombinedShapeAndFeatureFieldHasNoFolding() {
        let field = DisplacementField.solve(
            faces: [makeFace()],
            imageSize: (width: 800, height: 600),
            parameters: FaceShapeParameters(
                faceSize: 0.5,
                jawSlim: 1,
                vShape: 1
            ),
            features: FaceFeatureParameters(
                eyeSize: 1,
                eyeDistance: 1,
                noseWidth: 1,
                mouthShape: 1
            )
        )
        XCTAssertNotNil(field)
        XCTAssertGreaterThan(field!.minimumJacobian(), 0)
    }
}
