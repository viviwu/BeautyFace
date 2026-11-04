/// 由关键点与脸型参数生成 MLS 控制点位移。
///
/// 设计要点：
///
/// 1. **只有轮廓点位移，五官点不动**。五官（眼、眉、鼻、唇）作为零位移
///    控制点参与 MLS，既约束了脸的内部不被整体拖走，也让「轮廓内移」
///    在 MLS 插值下自然形成面颊压缩——这正是瘦脸的观感来源。
/// 2. **图像边框补零位移锚点**。MLS 的远场会退化为全局刚体变换，
///    锚点把背景钉回恒等，否则人脸一动整张图都跟着动。
/// 3. **宽度剖面驱动**：所有收窄参数合成一条单调 C1 锥形函数，保证
///    轮廓从太阳穴到下巴平滑渐进收窄，不产生波浪或局部外鼓。
/// 4. **位移上限**（R-02）：单点总位移超过 `maxDisplacementFraction × 脸高`
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
    ///
    /// 位移由**目标宽度剖面**驱动：所有收窄类参数（小脸 / 瘦脸 / 窄脸 /
    /// V 脸 / 颧骨）先线性合成一个总收窄量，再乘一条单调 C1 锥形函数，
    /// 逐点把横向距离按比例压向纵轴。由构造保证：
    ///
    /// 1. 宽度从太阳穴到下巴**单调不增**（V 型渐进收窄）；
    /// 2. 剖面 C1 平滑——**波浪与局部外鼓在数学上不可能出现**。
    ///
    /// 旧实现按参数各自定义 t 区段钟形函数再叠加，宽度剖面会出现振荡
    /// （两侧波浪）与「腮帮子宽过脸中部」的外鼓，已被此模型取代。
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

        // 总收窄量：各收窄参数线性合成（0.35 封顶防过度收窄）。
        let totalNarrow = min(
            0.10 * parameters.faceSize
                + 0.10 * parameters.jawSlim
                + 0.08 * parameters.faceNarrow
                + 0.10 * parameters.vShape
                + 0.06 * parameters.cheekbone,
            0.35
        )
        // V 脸把锥形函数向底部陡化：收窄越集中在下半张脸，V 感越强。
        let vBlend = parameters.vShape
        let centerY = metrics.minY + metrics.height * 0.5

        for (index, point) in face.contour.enumerated() {
            // t：0 = 下巴底端，1 = 太阳穴顶端；u：0 = 顶端，1 = 下巴
            let t = (point.y - metrics.minY) / metrics.height
            let u = 1 - t
            let lateral = point.x - metrics.axisX

            var displacement = Point2.zero

            // 收窄：锥形在太阳穴附近为 0，向下平滑增至 1；
            // 逐点按自身横向距离等比压缩，宽度剖面 = 原剖面 × (1 − 收窄量)。
            if totalNarrow > 0 {
                let taper = Math.smoothstep(0.10, 0.95, u)
                displacement.x += -lateral
                    * (totalNarrow * Math.sharpen(taper, blend: vBlend))
            }

            // 小脸：纵向向脸高中点轻缩（横向收窄已并入 totalNarrow）
            if parameters.faceSize > 0 {
                displacement.y += (centerY - point.y) * (0.06 * parameters.faceSize)
            }

            // 下巴：底部拉长并沿锥形方向加一点收窄（显尖）
            if parameters.chin > 0 {
                displacement.y += -0.05 * metrics.height * parameters.chin
                    * Math.smoothstep(0.15, 0.02, t)
                displacement.x += -lateral * (0.06 * parameters.chin)
                    * Math.smoothstep(0.25, 0.0, t)
            }

            // 额头：上段轮廓下压。只做纵向——顶部横向收窄会让宽度剖面
            // 在太阳穴附近反向变化，破坏单调性。
            if parameters.forehead > 0 {
                displacement.y += -0.05 * metrics.height * parameters.forehead
                    * Math.smoothstep(0.70, 1.00, t)
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
