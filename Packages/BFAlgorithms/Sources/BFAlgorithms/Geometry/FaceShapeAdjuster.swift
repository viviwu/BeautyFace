/// 由关键点与脸型参数生成 MLS 控制点位移。
///
/// 设计要点：
///
/// 1. **只有轮廓点位移，五官点不动**。五官（眼、眉、鼻、唇）作为零位移
///    控制点参与 MLS，既约束了脸的内部不被整体拖走，也让「轮廓内移」
///    在 MLS 插值下自然形成面颊压缩——这正是瘦脸的观感来源。
/// 2. **图像边框补零位移锚点**。MLS 的远场会退化为全局刚体变换，
///    锚点把背景钉回恒等，否则人脸一动整张图都跟着动。
/// 3. **位移上限**（R-02）：单点总位移超过 `maxDisplacementFraction × 脸高`
///    时线性压缩，防止参数拉满时把轮廓拉穿。
public struct FaceShapeAdjuster: Sendable {
    /// 单点位移上限（相对该脸的轮廓高度）。
    public var maxDisplacementFraction: Float
    /// 边框锚点沿长边的分割数。
    public var anchorDivisions: Int
    /// 全局位移倍率：叠加在所有参数之上，用于整体增强 / 抑制。
    public var displacementScale: Float

    public init(
        maxDisplacementFraction: Float = 0.10,
        anchorDivisions: Int = 16,
        displacementScale: Float = 1
    ) {
        self.maxDisplacementFraction = max(0.01, maxDisplacementFraction)
        self.anchorDivisions = max(2, anchorDivisions)
        self.displacementScale = max(0, displacementScale)
    }

    // MARK: - 单脸

    /// 为一张脸生成控制点。`imageBounds` 为工作图像的像素范围。
    public func controls(
        for face: FaceGeometry,
        imageBounds: (width: Float, height: Float),
        parameters: FaceShapeParameters
    ) -> [MLSSolver.ControlPoint] {
        guard !face.contour.isEmpty else { return [] }

        let metrics = FaceMetrics(face)
        let displacements = contourDisplacements(
            for: face,
            metrics: metrics,
            parameters: parameters
        )

        var controls: [MLSSolver.ControlPoint] = []
        controls.reserveCapacity(face.allPoints.count + anchorDivisions * 4)

        // 轮廓点：带位移
        for (index, point) in face.contour.enumerated() {
            controls.append(MLSSolver.ControlPoint(
                output: point + displacements[index],
                source: point
            ))
        }
        // 五官点：零位移约束
        for point in face.allPoints where !face.contour.contains(where: { $0 == point }) {
            controls.append(.anchor(point))
        }
        // 图像边框锚点
        controls.append(contentsOf: MLSSolver.identityAnchors(
            around: (0, 0, imageBounds.width, imageBounds.height),
            divisions: anchorDivisions
        ))
        return controls
    }

    // MARK: - 轮廓位移

    /// 各轮廓点的位移，y 向上；「向下」为 −y。
    func contourDisplacements(
        for face: FaceGeometry,
        metrics: FaceMetrics,
        parameters: FaceShapeParameters
    ) -> [Point2] {
        var result = [Point2](
            repeating: .zero,
            count: face.contour.count
        )
        guard metrics.height > 0, metrics.width > 0 else { return result }

        for (index, point) in face.contour.enumerated() {
            // t：0 = 下巴底端，1 = 太阳穴顶端
            let t = (point.y - metrics.minY) / metrics.height
            // 横向离纵轴的距离（带符号）
            let lateral = point.x - metrics.axisX

            var displacement = Point2.zero

            // 小脸：整圈向中心收缩
            if parameters.faceSize > 0 {
                let center = Point2(
                    metrics.axisX,
                    metrics.minY + metrics.height * 0.5
                )
                displacement = displacement + (center - point) * (0.10 * parameters.faceSize)
            }

            // 瘦脸：下颌向纵轴收窄，权重峰值在下颌角（t ≈ 0.22）
            if parameters.jawSlim > 0 {
                let weight = bump(t, center: 0.22, radius: 0.25)
                displacement.x += -lateral * 0.10 * parameters.jawSlim * weight
            }

            // 窄脸：面颊中部收窄
            if parameters.faceNarrow > 0 {
                let weight = bump(t, center: 0.60, radius: 0.28)
                displacement.x += -lateral * 0.08 * parameters.faceNarrow * weight
            }

            // V 脸：下半张脸收窄，越靠近下巴越强
            if parameters.vShape > 0 {
                let weight = Math.smoothstep(0.50, 0.10, t)
                displacement.x += -lateral * 0.10 * parameters.vShape * weight
            }

            // 下巴：底部拉长并收窄（显尖）
            if parameters.chin > 0 {
                let weight = Math.smoothstep(0.15, 0.02, t)
                displacement.y += -0.05 * metrics.height * parameters.chin * weight
                displacement.x += -lateral * 0.06 * parameters.chin * weight
            }

            // 额头：上段轮廓下压，额头显小
            if parameters.forehead > 0 {
                let weight = Math.smoothstep(0.70, 1.00, t)
                displacement.y += -0.05 * metrics.height * parameters.forehead * weight
                displacement.x += -lateral * 0.04 * parameters.forehead * weight
            }

            // 颧骨：颧骨区域收窄
            if parameters.cheekbone > 0 {
                let weight = bump(t, center: 0.72, radius: 0.18)
                displacement.x += -lateral * 0.06 * parameters.cheekbone * weight
            }

            result[index] = displacement
        }

        applyDisplacementCap(&result, metrics: metrics)
        return result
    }

    /// 位移上限与线性压缩（R-02）。
    func applyDisplacementCap(
        _ displacements: inout [Point2],
        metrics: FaceMetrics
    ) {
        let cap = maxDisplacementFraction * metrics.height
        guard cap > 0 else { return }

        let scale = displacementScale
        for index in displacements.indices {
            var value = displacements[index] * scale
            let length = value.length
            if length > cap {
                value = value * (cap / length)
            }
            displacements[index] = value
        }
    }

    /// 以 `center` 为峰、`radius` 为半宽的平滑钟形权重。
    private func bump(_ t: Float, center: Float, radius: Float) -> Float {
        let distance = abs(t - center)
        return Math.smoothstep(radius, 0, distance)
    }
}

/// 单张脸的几何度量。纵轴取瞳孔中点，比轮廓质心更贴近面部中轴。
struct FaceMetrics {
    let minX: Float
    let maxX: Float
    let minY: Float
    let maxY: Float
    let width: Float
    let height: Float
    let axisX: Float

    init(_ face: FaceGeometry) {
        guard let first = face.contour.first else {
            self.minX = 0
            self.maxX = 0
            self.minY = 0
            self.maxY = 0
            self.width = 0
            self.height = 0
            self.axisX = 0
            return
        }

        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in face.contour {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.width = maxX - minX
        self.height = maxY - minY

        if let left = face.leftPupil, let right = face.rightPupil {
            self.axisX = (left.x + right.x) * 0.5
        } else if !face.leftEye.isEmpty, !face.rightEye.isEmpty {
            let leftCenter = FaceMetrics.centroid(face.leftEye)
            let rightCenter = FaceMetrics.centroid(face.rightEye)
            self.axisX = (leftCenter.x + rightCenter.x) * 0.5
        } else {
            self.axisX = (minX + maxX) * 0.5
        }
    }

    static func centroid(_ points: [Point2]) -> Point2 {
        guard !points.isEmpty else { return .zero }
        var sum = Point2.zero
        for point in points {
            sum = sum + point
        }
        return sum * (1 / Float(points.count))
    }
}
