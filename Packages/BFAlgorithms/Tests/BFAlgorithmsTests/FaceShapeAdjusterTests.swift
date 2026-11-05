import XCTest
@testable import BFAlgorithms

final class FaceShapeAdjusterTests: XCTestCase {
    /// 合成一张脸：椭圆轮廓（17 点，y 向上）+ 双眼 / 眉 / 鼻 / 唇 / 瞳孔。
    private func makeFace() -> FaceGeometry {
        let center = Point2(200, 300)
        var contour: [Point2] = []
        for index in 0..<17 {
            // 从左侧太阳穴（180°）绕过下巴（270°）到右侧太阳穴（0°）
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

    private func metrics() -> FaceMetrics {
        FaceMetrics(makeFace())
    }

    private func displacement(
        _ parameters: FaceShapeParameters,
        _ face: FaceGeometry = FaceShapeAdjusterTests().makeFace()
    ) -> [Point2] {
        FaceShapeAdjuster().contourDisplacements(
            for: face,
            metrics: FaceMetrics(face),
            parameters: parameters
        )
    }

    func testIdentityParametersGiveZeroDisplacement() {
        let values = displacement(.none)
        for value in values {
            XCTAssertEqual(value.length, 0, accuracy: 1e-6)
        }
    }

    func testFaceSizeNarrowsTowardAxisAndShrinksVertically() {
        let face = makeFace()
        let values = displacement(FaceShapeParameters(faceSize: 1), face)
        let m = FaceMetrics(face)
        let centerY = m.minY + m.height * 0.5

        for (index, point) in face.contour.enumerated() {
            let lateral = point.x - m.axisX
            guard abs(lateral) > 10 else { continue }
            let t = (point.y - m.minY) / m.height

            let moved = (point + values[index]).x - m.axisX

            if t < 0.10 {
                // 底部：锥形接近 1，收窄约 10%
                XCTAssertEqual(moved, lateral * 0.9, accuracy: 1.0)
            } else if t > 0.95 {
                // 太阳穴顶端：锥形为 0，不动
                XCTAssertEqual(moved, lateral, accuracy: 1e-4)
            }

            // 纵向：向脸高中点轻缩 6%
            let movedY = (point + values[index]).y
            XCTAssertEqual(movedY, point.y + (centerY - point.y) * 0.06, accuracy: 0.5)
        }
    }

    func testJawSlimNarrowsGraduallyFromTempleToChin() {
        let face = makeFace()
        let values = displacement(FaceShapeParameters(jawSlim: 1), face)
        let metrics = FaceMetrics(face)

        var checked = 0
        for (index, point) in face.contour.enumerated() {
            let lateral = point.x - metrics.axisX
            guard abs(lateral) > 20 else { continue }

            let moved = (point + values[index]).x - metrics.axisX
            let ratio = moved / lateral
            checked += 1

            if (point.y - metrics.minY) / metrics.height > 0.92 {
                // 太阳穴顶端附近几乎不动
                XCTAssertGreaterThan(ratio, 0.99)
            } else if (point.y - metrics.minY) / metrics.height < 0.2 {
                // 下颌附近收窄约 10%
                XCTAssertLessThan(ratio, 0.92)
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 6)
    }

    /// 波浪回归：宽度剖面沿高度必须单调不增（从太阳穴到下巴），
    /// 且左右两侧一致。旧的「区段钟形叠加」模型会在这里失败。
    func testWidthProfileIsMonotonicFromTempleToChin() {
        let face = makeFace()
        let parameters = FaceShapeParameters(
            faceSize: 0.5,
            jawSlim: 1,
            faceNarrow: 0.6,
            vShape: 1,
            chin: 0.6,
            forehead: 0.4,
            cheekbone: 0.6
        )
        let values = displacement(parameters, face)
        let metrics = FaceMetrics(face)

        for sideSign in [Float(-1), Float(1)] {
            var samples: [(t: Float, ratio: Float)] = []
            for (index, point) in face.contour.enumerated() {
                let lateral = point.x - metrics.axisX
                // 只取与纵向轴有实际距离的点（排除下巴底端）
                guard lateral * sideSign > 15 else { continue }
                let t = (point.y - metrics.minY) / metrics.height
                let moved = (point + values[index]).x - metrics.axisX
                samples.append((t, moved / lateral))
            }
            // 按 t 从大到小（太阳穴 → 下巴）排列，收窄比例必须单调不增
            samples.sort { $0.t > $1.t }
            for index in 1..<samples.count {
                XCTAssertLessThanOrEqual(
                    samples[index].ratio,
                    samples[index - 1].ratio + 1e-5,
                    "side=\(sideSign) t=\(samples[index].t) 处宽度剖面出现反向（波浪）"
                )
            }
            // 底部收窄应明显强于顶部（V 型）
            if samples.count > 2 {
                XCTAssertLessThan(
                    samples.last!.ratio,
                    samples.first!.ratio - 0.05,
                    "底部收窄应明显强于顶部"
                )
            }
        }
    }

    func testChinLengthensAndNarrows() {
        let face = makeFace()
        let values = displacement(FaceShapeParameters(chin: 1), face)
        let height = FaceMetrics(face).height

        // 下巴底端（t = 0）：向下 0.05 × 脸高，横向不偏移
        guard let chinIndex = face.contour.indices.min(by: {
            face.contour[$0].y < face.contour[$1].y
        }) else {
            return XCTFail("轮廓不应为空")
        }
        XCTAssertEqual(values[chinIndex].y, -0.05 * height, accuracy: 0.5)
        XCTAssertEqual(values[chinIndex].x, 0, accuracy: 0.5)

        // 太阳穴不应被下巴参数移动
        guard let topIndex = face.contour.indices.max(by: {
            face.contour[$0].y < face.contour[$1].y
        }) else {
            return XCTFail("轮廓不应为空")
        }
        XCTAssertEqual(values[topIndex].length, 0, accuracy: 1e-5)
    }

    func testForeheadPressesTopContourDown() {
        let face = makeFace()
        let values = displacement(FaceShapeParameters(forehead: 1), face)
        let metrics = FaceMetrics(face)

        for (index, point) in face.contour.enumerated() {
            let t = (point.y - metrics.minY) / metrics.height
            if t > 0.95 {
                // 顶端点应下压 0.05 × 脸高
                XCTAssertEqual(values[index].y, -0.05 * metrics.height, accuracy: 0.5)
            } else if t < 0.5 {
                // 下半张脸不受影响
                XCTAssertEqual(values[index].length, 0, accuracy: 1e-5)
            }
        }
    }

    func testAllParametersCappedByFaceHeight() {
        let face = makeFace()
        let values = displacement(
            FaceShapeParameters(
                faceSize: 1,
                jawSlim: 1,
                faceNarrow: 1,
                vShape: 1,
                chin: 1,
                forehead: 1,
                cheekbone: 1
            ),
            face
        )
        let cap = 0.10 * FaceMetrics(face).height
        for value in values {
            XCTAssertLessThanOrEqual(value.length, cap + 1e-4)
        }
    }

    func testControlsDensifyContourAlongArcLength() {
        let face = makeFace()
        let adjuster = FaceShapeAdjuster(anchorDivisions: 8)
        let controls = adjuster.controls(
            for: face,
            imageBounds: (width: 800, height: 600),
            parameters: FaceShapeParameters(jawSlim: 1)
        )

        // 17 点轮廓应加密为 3×(n−1)+1 = 49 个轮廓控制点，
        // 且新增点的源位置落在原轮廓线段上。
        let contourSources = Set(face.contour.map { "\($0.x),\($0.y)" })
        var onSegment = 0
        for control in controls where contourSources.contains("\(control.source.x),\(control.source.y)") {
            onSegment += 1
        }
        // 原始 17 个顶点 + 非顶点的插值点（插值点不在顶点集合里，
        // 通过验证其位于相邻顶点的线段上来确认）
        var interpolatedOnSegments = 0
        for control in controls {
            guard !contourSources.contains("\(control.source.x),\(control.source.y)") else { continue }
            for index in 0..<(face.contour.count - 1) {
                if liesOnSegment(control.source, face.contour[index], face.contour[index + 1]) {
                    interpolatedOnSegments += 1
                    break
                }
            }
        }
        XCTAssertEqual(onSegment, face.contour.count, "原始顶点应全部保留")
        XCTAssertEqual(
            interpolatedOnSegments,
            (face.contour.count - 1) * 2,
            "每段应插入 2 个插值控制点"
        )
    }

    private func liesOnSegment(_ p: Point2, _ a: Point2, _ b: Point2) -> Bool {
        let ab = b - a
        let ap = p - a
        let cross = ab.x * ap.y - ab.y * ap.x
        let length = ab.length
        guard length > 0 else { return false }
        // 共线且在段内
        if abs(cross) / length > 1e-3 { return false }
        let dot = (ap.x * ab.x + ap.y * ab.y) / (length * length)
        return dot >= -1e-6 && dot <= 1 + 1e-6
    }

    func testControlsContainFeatureConstraintsAndAnchors() {
        let face = makeFace()
        let adjuster = FaceShapeAdjuster(anchorDivisions: 8)
        let controls = adjuster.controls(
            for: face,
            imageBounds: (width: 800, height: 600),
            parameters: FaceShapeParameters(jawSlim: 1)
        )

        // 轮廓点发生了位移
        let contourSources = Set(face.contour.map { "\($0.x),\($0.y)" })
        let movedContour = controls.filter {
            contourSources.contains("\($0.source.x),\($0.source.y)")
                && $0.source != $0.output
        }
        XCTAssertFalse(movedContour.isEmpty, "轮廓控制点应当带位移")

        // 五官点是零位移约束
        let eyeAnchor = controls.first {
            $0.source == Point2(160, 331)
        }
        XCTAssertNotNil(eyeAnchor)
        XCTAssertEqual(eyeAnchor?.output, eyeAnchor?.source)

        // 图像边框上有锚点
        let borderAnchors = controls.filter {
            $0.source == $0.output
                && ($0.source.x == 0 || $0.source.x == 800
                    || $0.source.y == 0 || $0.source.y == 600)
        }
        XCTAssertGreaterThanOrEqual(borderAnchors.count, 16)
    }
}

private extension Point2 {
    func distance(to other: Point2) -> Float {
        distanceSquared(to: other).squareRoot()
    }
}
