/// 粗网格位移场：把多张脸的控制点合入一次 MLS 求解，在网格节点上
/// 预先算好位移，供 GPU 重采样时双线性放大。
///
/// 为什么用粗网格（ADR-006）：MLS 在网格节点上一次求解，warp 时只需
/// 一次双线性采样，避免了逐像素求解；位移场本身是平滑场，粗网格 +
/// 双线性不会引入台阶。
///
/// 折叠防护（R-02）：对网格做有限差分求雅可比行列式，一旦出现 ≤ 0
/// （逆向映射发生翻转，输出会撕开），按比例整体回退位移并重新求解，
/// 直到全部为正或降到最低强度。
public struct DisplacementField {
    /// 网格横向节点数。
    public let columns: Int
    /// 网格纵向节点数。
    public let rows: Int
    /// 位移 x 分量（行优先，从上到下）。
    public let offsetX: [Float]
    /// 位移 y 分量。
    public let offsetY: [Float]
    /// 工作图像尺寸（像素）。
    public let imageSize: (width: Int, height: Int)
    /// 实际采用的强度（折叠回退后可能小于 1）。
    public let appliedStrength: Float

    public init(
        columns: Int,
        rows: Int,
        offsetX: [Float],
        offsetY: [Float],
        imageSize: (width: Int, height: Int),
        appliedStrength: Float
    ) {
        precondition(offsetX.count == columns * rows)
        precondition(offsetY.count == columns * rows)
        self.columns = columns
        self.rows = rows
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.imageSize = imageSize
        self.appliedStrength = appliedStrength
    }

    // MARK: - 求解

    public static func solve(
        faces: [FaceGeometry],
        imageSize: (width: Int, height: Int),
        parameters: FaceShapeParameters,
        config: Config = Config()
    ) -> DisplacementField? {
        guard parameters.isIdentity == false else { return nil }
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let adjuster = FaceShapeAdjuster(
            maxDisplacementFraction: config.maxDisplacementFraction,
            displacementScale: config.displacementScale
        )
        let bounds = (
            width: Float(imageSize.width),
            height: Float(imageSize.height)
        )

        var controls: [MLSSolver.ControlPoint] = []
        for face in faces {
            controls.append(contentsOf: adjuster.controls(
                for: face,
                imageBounds: bounds,
                parameters: parameters
            ))
        }
        guard !controls.isEmpty else { return nil }

        let solver = MLSSolver(controls: controls)
        let columns = max(2, Int(
            (Float(config.gridLongEdge)
                * Float(imageSize.width)
                / Float(max(imageSize.width, imageSize.height)))
                .rounded()
        ))
        let rows = max(2, Int(
            (Float(config.gridLongEdge)
                * Float(imageSize.height)
                / Float(max(imageSize.width, imageSize.height)))
                .rounded()
        ))

        // 距离衰减：锚点只能压制远场，不能保证归零；要让「背景严格不动」
        // 成立，必须在离脸足够远处把位移显式乘到 0。
        let falloff = Self.falloffTable(
            faces: faces,
            imageSize: imageSize,
            columns: columns,
            rows: rows,
            config: config
        )

        var strength: Float = 1
        var field: DisplacementField?
        for _ in 0..<config.maxRefinements {
            field = sampleField(
                solver: solver,
                falloff: falloff,
                imageSize: imageSize,
                columns: columns,
                rows: rows,
                strength: strength
            )
            guard let field else { return nil }
            if field.minimumJacobian() > 0 {
                return field
            }
            // 折叠：整体回退强度重新求解
            strength *= config.refinementDecay
        }

        // 连续回退仍折叠：保持最后一次（最弱）的场，但调用方可据此告警。
        // 实际上 linear 压缩已经把位移限制在脸高的 10%，走到这里的概率极低。
        return field
    }

    /// 在网格节点上求解位移：d(v) = (map(v) − v) × 衰减 × 强度。
    private static func sampleField(
        solver: MLSSolver,
        falloff: [Float],
        imageSize: (width: Int, height: Int),
        columns: Int,
        rows: Int,
        strength: Float
    ) -> DisplacementField? {
        var offsetX = [Float](repeating: 0, count: columns * rows)
        var offsetY = [Float](repeating: 0, count: columns * rows)
        let stepX = Float(imageSize.width - 1) / Float(columns - 1)
        let stepY = Float(imageSize.height - 1) / Float(rows - 1)

        for row in 0..<rows {
            let y = Float(row) * stepY
            for column in 0..<columns {
                let x = Float(column) * stepX
                let mapped = solver.map(Point2(x, y))
                let index = row * columns + column
                let weight = falloff[index] * strength
                offsetX[index] = (mapped.x - x) * weight
                offsetY[index] = (mapped.y - y) * weight
            }
        }

        return DisplacementField(
            columns: columns,
            rows: rows,
            offsetX: offsetX,
            offsetY: offsetY,
            imageSize: imageSize,
            appliedStrength: strength
        )
    }

    /// 每个网格节点的距离衰减权重。
    ///
    /// 对每张脸取「到该脸最近关键点的距离」，按脸自身的半径归一：
    /// `r0 = 1.0 × R` 以内不衰减，`r1 = 1.6 × R` 以外为 0。多张脸取最大值，
    /// 保证各自的影响范围互不截断。
    private static func falloffTable(
        faces: [FaceGeometry],
        imageSize: (width: Int, height: Int),
        columns: Int,
        rows: Int,
        config: Config
    ) -> [Float] {
        var table = [Float](repeating: 0, count: columns * rows)
        let stepX = Float(imageSize.width - 1) / Float(columns - 1)
        let stepY = Float(imageSize.height - 1) / Float(rows - 1)

        struct Influence {
            let points: [Point2]
            let inner: Float
            let outer: Float
        }
        let influences: [Influence] = faces.compactMap { face -> Influence? in
            let points = face.allPoints
            guard let first = points.first else { return nil }
            var center = Point2.zero
            for point in points {
                center = center + point
            }
            center = center * (1 / Float(points.count))
            var radius: Float = 0
            for point in points {
                radius = max(radius, point.distanceSquared(to: center).squareRoot())
            }
            guard radius > 0 else { return nil }
            return Influence(
                points: points,
                inner: radius * config.falloffInnerFactor,
                outer: radius * config.falloffOuterFactor
            )
        }
        guard !influences.isEmpty else {
            return [Float](repeating: 1, count: columns * rows)
        }

        for row in 0..<rows {
            let y = Float(row) * stepY
            for column in 0..<columns {
                let x = Float(column) * stepX
                var weight: Float = 0
                for influence in influences {
                    var nearest = Float.infinity
                    for point in influence.points {
                        nearest = min(nearest, point.distanceSquared(to: Point2(x, y)))
                    }
                    nearest = nearest.squareRoot()
                    weight = max(weight, Math.smoothstep(
                        influence.outer,
                        influence.inner,
                        nearest
                    ))
                }
                table[row * columns + column] = weight
            }
        }
        return table
    }

    // MARK: - 折叠检查

    public struct Config: Sendable {
        /// 网格沿长边的节点数。
        public var gridLongEdge: Int = 128
        /// 单点位移上限（相对脸高）。
        public var maxDisplacementFraction: Float = 0.10
        /// 全局位移倍率。
        public var displacementScale: Float = 1
        /// 距离衰减起点（相对脸半径）。脸内部因五官控制点密集而始终接近 1。
        public var falloffInnerFactor: Float = 0.15
        /// 距离衰减终点（相对脸半径），之外位移为 0。
        public var falloffOuterFactor: Float = 0.45
        /// 折叠时强度回退的比例。
        public var refinementDecay: Float = 0.7
        /// 最多回退次数。
        public var maxRefinements: Int = 12

        public init(
            gridLongEdge: Int = 128,
            maxDisplacementFraction: Float = 0.10,
            displacementScale: Float = 1,
            falloffInnerFactor: Float = 0.15,
            falloffOuterFactor: Float = 0.45,
            refinementDecay: Float = 0.7,
            maxRefinements: Int = 12
        ) {
            self.gridLongEdge = gridLongEdge
            self.maxDisplacementFraction = maxDisplacementFraction
            self.displacementScale = displacementScale
            self.falloffInnerFactor = falloffInnerFactor
            self.falloffOuterFactor = falloffOuterFactor
            self.refinementDecay = refinementDecay
            self.maxRefinements = maxRefinements
        }
    }

    /// 网格上逆向映射 f(v) = v + d(v) 的最小雅可比行列式。
    ///
    /// 用中心差分近似偏导；行列式 ≤ 0 意味着重采样时发生翻转（撕裂）。
    public func minimumJacobian() -> Float {
        guard columns > 2, rows > 2 else { return 1 }

        let cellWidth = Float(imageSize.width - 1) / Float(columns - 1)
        let cellHeight = Float(imageSize.height - 1) / Float(rows - 1)
        guard cellWidth > 0, cellHeight > 0 else { return 1 }

        var minimum = Float.infinity
        for row in 1..<(rows - 1) {
            for column in 1..<(columns - 1) {
                let index = row * columns + column
                let dxx = (offsetX[index + 1] - offsetX[index - 1]) / (2 * cellWidth)
                let dxy = (offsetX[index + columns] - offsetX[index - columns]) / (2 * cellHeight)
                let dyx = (offsetY[index + 1] - offsetY[index - 1]) / (2 * cellWidth)
                let dyy = (offsetY[index + columns] - offsetY[index - columns]) / (2 * cellHeight)

                let determinant = (1 + dxx) * (1 + dyy) - dxy * dyx
                minimum = min(minimum, determinant)
            }
        }
        return minimum.isFinite ? minimum : 1
    }

    // MARK: - 采样

    /// 双线性采样位移场。坐标为像素坐标，超出范围按边缘截断。
    public func displacement(at point: Point2) -> Point2 {
        let maxX = Float(columns - 1)
        let maxY = Float(rows - 1)
        let gridX = min(max(point.x * Float(columns - 1)
            / Float(max(imageSize.width - 1, 1)), 0), maxX)
        let gridY = min(max(point.y * Float(rows - 1)
            / Float(max(imageSize.height - 1, 1)), 0), maxY)

        let x0 = min(Int(gridX), columns - 2)
        let y0 = min(Int(gridY), rows - 2)
        let fx = gridX - Float(x0)
        let fy = gridY - Float(y0)

        let i00 = y0 * columns + x0
        let i10 = i00 + 1
        let i01 = i00 + columns
        let i11 = i01 + 1

        let topX = offsetX[i00] * (1 - fx) + offsetX[i10] * fx
        let bottomX = offsetX[i01] * (1 - fx) + offsetX[i11] * fx
        let topY = offsetY[i00] * (1 - fx) + offsetY[i10] * fx
        let bottomY = offsetY[i01] * (1 - fx) + offsetY[i11] * fx

        return Point2(
            topX * (1 - fy) + bottomX * fy,
            topY * (1 - fy) + bottomY * fy
        )
    }

    /// 全场最大位移（像素），用于调试与验收。
    public func maximumDisplacement() -> Float {
        var maximum: Float = 0
        for index in offsetX.indices {
            maximum = max(maximum, Point2(offsetX[index], offsetY[index]).length)
        }
        return maximum
    }
}
