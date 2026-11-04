/// 由五官关键点与五官参数生成 MLS 控制点位移。
///
/// 与 `FaceShapeAdjuster`（只有轮廓动）互补：这里只有五官点动，
/// 轮廓点由脸型调整器约束。两者合并进同一次 MLS 求解，一次 warp
/// 同时完成脸型与五官形变（ADR-006 / ADR-007）。
///
/// 各参数的作用方式：
///
/// 1. **大眼**：眼眶点绕眼睛质心径向外移，纵向系数大于横向
///    （眼裂加高比眼裂加宽更「有神」，且不会挤到内眦）；
///    瞳孔位于质心附近，天然近似零位移，保持为锚点即可。
/// 2. **眼距**：单只眼睛的**所有点做同一水平平移**（保持眼形不变），
///    瞳孔随动；平移量相对瞳距归一。
/// 3. **眉间距**：双眉整体向眉心平移，同样保持眉形。
/// 4. **眉毛粗细**：眉部点绕眉毛质心做纵向拉伸——眉形折线上下
///    张开后，MLS 把眉毛暗色带同步拉宽，观感即「变浓」。
///    Vision 眉毛只有单条折线、没有厚度轮廓，这是当前数据下的近似。
/// 5. **鼻翼**：鼻部点向鼻中轴按横向距离等比收拢。
/// 6. **嘴型**：唇部点向唇心水平收拢，同时按「离唇心的横向距离」
///    加权上扬——嘴角抬得最多，唇中不动，形成微笑嘴型。
///
/// 位移上限与脸型形变共用同一套逻辑（`applyDisplacementCap`）。
public struct FaceFeatureAdjuster: Sendable {
    /// 单点位移上限（相对该脸的轮廓高度），与脸型形变一致。
    public var maxDisplacementFraction: Float
    /// 全局位移倍率：叠加在所有参数之上，用于整体增强 / 抑制。
    public var displacementScale: Float

    public init(
        maxDisplacementFraction: Float = 0.10,
        displacementScale: Float = 1
    ) {
        self.maxDisplacementFraction = max(0.01, maxDisplacementFraction)
        self.displacementScale = max(0, displacementScale)
    }

    // MARK: - 控制点

    /// 为一张脸生成五官控制点。参数全为零时退化为零位移锚点，
    /// 与旧的「五官点零位移约束」行为完全一致。
    public func controls(
        for face: FaceGeometry,
        parameters: FaceFeatureParameters
    ) -> [MLSSolver.ControlPoint] {
        var points: [Point2] = []
        points.reserveCapacity(face.allPoints.count)
        for point in face.allPoints
        where !face.contour.contains(where: { $0 == point }) {
            points.append(point)
        }
        guard !points.isEmpty else { return [] }
        guard !parameters.isIdentity else {
            return points.map { .anchor($0) }
        }

        let displacementTable = Self.displacements(
            for: face,
            parameters: parameters
        )
        var displacements: [Point2] = []
        displacements.reserveCapacity(points.count)
        for point in points {
            displacements.append(displacementTable[point] ?? .zero)
        }
        // 位移上限与倍率复用脸型的实现
        FaceShapeAdjuster(
            maxDisplacementFraction: maxDisplacementFraction,
            displacementScale: displacementScale
        )
        .applyDisplacementCap(&displacements, metrics: FaceMetrics(face))

        return zip(points, displacements).map {
            MLSSolver.ControlPoint(output: $0.0 + $0.1, source: $0.0)
        }
    }

    // MARK: - 位移计算

    /// 五官点位移，键为点的原图坐标（五官点不与轮廓重合）。
    static func displacements(
        for face: FaceGeometry,
        parameters: FaceFeatureParameters
    ) -> [Point2: Point2] {
        var table: [Point2: Point2] = [:]
        func add(_ point: Point2, _ delta: Point2) {
            guard delta != .zero else { return }
            table[point, default: .zero] = table[point, default: .zero] + delta
        }

        // -- 眼睛：径向放大 + 眼距平移 --------------------------------
        let leftCenter = FaceMetrics.centroid(face.leftEye)
        let rightCenter = FaceMetrics.centroid(face.rightEye)
        let eyeAxisX = (leftCenter.x + rightCenter.x) * 0.5

        for (eye, center, pupil) in [
            (face.leftEye, leftCenter, face.leftPupil),
            (face.rightEye, rightCenter, face.rightPupil)
        ] {
            guard !eye.isEmpty else { continue }

            for point in eye {
                var delta = Point2.zero
                // 大眼：绕眼睛质心径向外移（纵向 1.67 倍于横向）
                if parameters.eyeSize > 0 {
                    delta.x += (point.x - center.x) * 0.18 * parameters.eyeSize
                    delta.y += (point.y - center.y) * 0.30 * parameters.eyeSize
                }
                // 眼距：整眼平移（相对瞳距归一，p=1 时约移动 10% 瞳距）
                if parameters.eyeDistance > 0 {
                    delta.x += (eyeAxisX - center.x) * 0.20 * parameters.eyeDistance
                }
                add(point, delta)
            }
            // 瞳孔随眼距平移；大眼时瞳孔近似质心、位移≈0，不必动
            if let pupil, parameters.eyeDistance > 0 {
                add(pupil, Point2(
                    (eyeAxisX - center.x) * 0.20 * parameters.eyeDistance,
                    0
                ))
            }
        }

        // -- 眉毛：眉间距平移 + 粗细纵向拉伸 ---------------------------
        let leftBrowCenter = FaceMetrics.centroid(face.leftEyebrow)
        let rightBrowCenter = FaceMetrics.centroid(face.rightEyebrow)
        let browAxisX = (leftBrowCenter.x + rightBrowCenter.x) * 0.5

        for (brow, center) in [
            (face.leftEyebrow, leftBrowCenter),
            (face.rightEyebrow, rightBrowCenter)
        ] {
            guard !brow.isEmpty else { continue }
            var radius: Float = 0
            for point in brow {
                radius = max(radius, point.distanceSquared(to: center).squareRoot())
            }

            for point in brow {
                var delta = Point2.zero
                if parameters.browSpacing > 0 {
                    delta.x += (browAxisX - center.x) * 0.20 * parameters.browSpacing
                }
                if parameters.browThickness > 0 {
                    delta.y += (point.y - center.y) * 0.30 * parameters.browThickness
                }
                add(point, delta)
            }
        }

        // -- 鼻子：向鼻中轴收拢 ----------------------------------------
        if parameters.noseWidth > 0, !face.nose.isEmpty {
            let center = FaceMetrics.centroid(face.nose)
            for point in face.nose {
                add(point, Point2(
                    -(point.x - center.x) * 0.18 * parameters.noseWidth,
                    0
                ))
            }
        }

        // -- 嘴：水平收拢 + 嘴角按横向距离加权上扬 ----------------------
        if parameters.mouthShape > 0, !face.outerLips.isEmpty {
            let center = FaceMetrics.centroid(face.outerLips)
            var halfWidth: Float = 0
            var height: Float = 0
            for point in face.outerLips {
                halfWidth = max(halfWidth, abs(point.x - center.x))
                height = max(height, abs(point.y - center.y))
            }
            // 唇形很扁时以唇宽兜底，保证嘴角仍有可见抬升
            let liftReference = max(height, halfWidth * 0.3)
            if halfWidth > 0, liftReference > 0 {
                for point in face.outerLips {
                    var delta = Point2.zero
                    delta.x += -(point.x - center.x) * 0.10 * parameters.mouthShape
                    let weight = (point.x - center.x) / halfWidth
                    delta.y += liftReference * 0.22 * parameters.mouthShape
                        * weight * weight
                    add(point, delta)
                }
            }
        }

        return table
    }
}
