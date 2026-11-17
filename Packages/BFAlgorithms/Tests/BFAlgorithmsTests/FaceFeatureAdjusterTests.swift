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

    // MARK: - 眼眶加密（大眼锯齿修复）

    /// 眼眶沿弧长加密：环上插值点成为控制点，位移等于端点位移的线性插值。
    func testEyeControlsDensifiedAlongArc() {
        let face = makeFace()
        let parameters = FaceFeatureParameters(eyeSize: 0.8)
        let adjuster = FaceFeatureAdjuster()
        let controls = adjuster.controls(for: face, parameters: parameters)
        let table = FaceFeatureAdjuster.displacements(for: face, parameters: parameters)

        // 数量：每只眼环 = 点数 × 6 等分，其余五官点各 1
        let ringTotal = (face.leftEye.count + face.rightEye.count) * 6
        let others = face.allPoints.count - face.contour.count
            - face.leftEye.count - face.rightEye.count
        XCTAssertEqual(controls.count, ringTotal + others)

        // 每段（含闭合段）中点存在，位移 = 端点位移线性插值
        for eye in [face.leftEye, face.rightEye] {
            for index in 0..<eye.count {
                let from = eye[index]
                let to = eye[(index + 1) % eye.count]
                let mid = (from + to) * 0.5
                let expected = ((table[from] ?? .zero) + (table[to] ?? .zero)) * 0.5
                let match = controls.first {
                    $0.source.distanceSquared(to: mid) < 1e-4
                }
                XCTAssertNotNil(match, "眼环段 \(from)→\(to) 的中点控制点缺失")
                XCTAssertEqual(
                    (match!.output - match!.source).x,
                    expected.x,
                    accuracy: 1e-4
                )
                XCTAssertEqual(
                    (match!.output - match!.source).y,
                    expected.y,
                    accuracy: 1e-4
                )
            }
        }
    }

    /// 位移上限触发时只做等比缩放，方向不得被改变。
    func testDisplacementCapPreservesDirection() {
        let face = makeFace()
        let parameters = FaceFeatureParameters(eyeSize: 1, eyeDistance: 1)
        let adjuster = FaceFeatureAdjuster(maxDisplacementFraction: 0.01)
        let controls = adjuster.controls(for: face, parameters: parameters)
        let table = FaceFeatureAdjuster.displacements(for: face, parameters: parameters)
        let cap = 0.01 * FaceMetrics(face).height

        var checked = 0
        for control in controls {
            guard let raw = table[control.source], raw.length > 1e-4 else { continue }
            let capped = control.output - control.source
            XCTAssertLessThanOrEqual(capped.length, cap + 1e-4)
            // 方向一致：叉积相对模长接近 0
            let cross = raw.x * capped.y - raw.y * capped.x
            XCTAssertLessThan(
                abs(cross),
                1e-2 * raw.length * capped.length + 1e-6,
                "位移方向被上限改变：\(control.source)"
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "应至少有一个点触发位移上限")
    }

    /// 大眼锯齿回归（核心）：解出的位移场沿过眼心的剖面必须平滑——
    /// 径向分量从眼心到眼缘单调增大、无符号翻转，剖面二阶差分有界，
    /// 不得出现「按矩形范围拉伸」的块状折痕。
    func testEyeFieldProfileSmooth() {
        let face = makeFaceWithRealisticEye()
        let field = DisplacementField.solve(
            faces: [face],
            imageSize: (width: 800, height: 600),
            parameters: .none,
            features: FaceFeatureParameters(eyeSize: 0.8)
        )!
        XCTAssertGreaterThan(field.minimumJacobian(), 0)

        let eye = face.leftEye
        let center = FaceMetrics.centroid(eye)
        let peak = eye.map { ($0 - center).length }.max()!

        // 沿 +x 从眼心采样到眼缘外
        var samples: [(x: Float, radial: Float)] = []
        var x = center.x
        while x <= center.x + peak + 15 {
            let d = field.displacement(at: Point2(x, center.y))
            samples.append((x, d.x))
            x += 1
        }
        let maxRadial = samples.map { abs($0.radial) }.max()!
        XCTAssertGreaterThan(maxRadial, 0.5, "眼区应有明显径向位移")

        let ringEdge = center.x + peak
        // 位移场存的是逆向映射偏移（输出像素 → 源图采样位置）：
        // 放大时偏移指向眼睛质心（向内），在 +x 剖面上 d.x < 0。
        // 「向内分量大小」 m = −d.x 从眼心 0 平滑增长到眼缘峰值。
        // 1) 眼心 → 眼缘：向内分量单调不减（允许微小数值噪声）
        var previous: Float = -1
        for sample in samples where sample.x <= ringEdge {
            let inward = -sample.radial
            XCTAssertGreaterThanOrEqual(
                inward,
                previous - 0.02 * maxRadial,
                "眼心到眼缘向内分量应单调不减：x=\(sample.x), m=\(inward)"
            )
            previous = inward
        }
        // 2) 全剖面平滑：显著区域（>20% 峰值）二阶差分有界
        for index in 1..<(samples.count - 1) {
            let a = -samples[index - 1].radial
            let b = -samples[index].radial
            let c = -samples[index + 1].radial
            guard max(abs(a), abs(b), abs(c)) > 0.2 * maxRadial else { continue }
            let second = abs(c - 2 * b + a)
            XCTAssertLessThan(
                second,
                0.25 * maxRadial,
                "剖面出现块状折痕：x=\(samples[index].x), d2=\(second)"
            )
        }
        // 3) 眼心到眼缘外一段内无符号翻转（向内分量保持朝内）
        for sample in samples where sample.x <= ringEdge + 4 {
            XCTAssertLessThan(
                sample.radial,
                0.05 * maxRadial,
                "逆向偏移在眼缘附近被反向拽出：x=\(sample.x)"
            )
        }
    }

    /// 8 点椭圆眼环（近似 Vision 眼眶分布），其余沿用合成脸。
    private func makeFaceWithRealisticEye() -> FaceGeometry {
        let center = Point2(200, 300)
        var contour: [Point2] = []
        for index in 0..<17 {
            let theta = Float.pi * (1 - Float(index) / 16)
            contour.append(Point2(
                center.x + 100 * cos(theta),
                center.y - 130 * sin(theta)
            ))
        }
        func ring(_ origin: Point2, rx: Float, ry: Float) -> [Point2] {
            (0..<8).map { index in
                let theta = Float(index) / 8 * 2 * Float.pi
                return Point2(
                    origin.x + rx * cos(theta),
                    origin.y + ry * sin(theta)
                )
            }
        }
        func cluster(_ origin: Point2) -> [Point2] {
            (0..<6).map { index in
                Point2(origin.x + Float(index - 2) * 4, origin.y + Float(index % 2) * 3)
            }
        }
        return FaceGeometry(
            contour: contour,
            leftEye: ring(Point2(160, 330), rx: 12, ry: 8),
            rightEye: ring(Point2(240, 330), rx: 12, ry: 8),
            leftEyebrow: cluster(Point2(160, 355)),
            rightEyebrow: cluster(Point2(240, 355)),
            nose: cluster(Point2(200, 290)),
            outerLips: cluster(Point2(200, 230)),
            leftPupil: Point2(160, 330),
            rightPupil: Point2(240, 330)
        )
    }
}
