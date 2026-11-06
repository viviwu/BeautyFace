/// 粗网格位移场：脸型与五官各建独立 MLS 场、在网格节点上分别求解后
/// 逐点叠加，供 GPU 重采样时双线性放大。
///
/// 为什么用粗网格（ADR-006）：MLS 在网格节点上一次求解，warp 时只需
/// 一次双线性采样，避免了逐像素求解；位移场本身是平滑场，粗网格 +
/// 双线性不会引入台阶。
///
/// 为什么拆成两个场：脸型（轮廓位移）与五官（内部点位移）合入同一个
/// 场时，五官大位移会把脸缘拽出波浪；拆分后五官场的轮廓逐点锚定为零，
/// 叠加结果的边缘 = 纯脸型剖面，与五官强度无关。
///
/// 折叠防护（R-02）：对网格做有限差分求雅可比行列式，一旦出现 ≤ 0
/// （逆向映射发生翻转，输出会撕开），按比例整体回退位移并重新求解，
/// 直到全部为正或降到最低强度。
public struct DisplacementField {
    /// 网格横向节点数。
    public let columns: Int
    /// 网格纵向节点数。
    public let rows: Int
    /// 位移 x 分量（行优先；row 0 对应 y = 0，y 向上递增）。
    public let offsetX: [Float]
    /// 位移 y 分量（同上）。
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
        features: FaceFeatureParameters = .none,
        config: Config = Config(),
        personMask: PersonMaskGrid? = nil
    ) -> DisplacementField? {
        guard !parameters.isIdentity || !features.isIdentity else { return nil }
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let adjuster = FaceShapeAdjuster(
            maxDisplacementFraction: config.maxDisplacementFraction,
            displacementScale: config.displacementScale
        )
        let featureAdjuster = FaceFeatureAdjuster(
            maxDisplacementFraction: config.maxDisplacementFraction,
            displacementScale: config.displacementScale
        )
        let bounds = (
            width: Float(imageSize.width),
            height: Float(imageSize.height)
        )

        // 场拆分（轮廓波浪根治）：脸型与五官各建**独立** MLS 场再叠加。
        //
        // 之前两者合入同一个场：五官大位移会在脸缘附近与轮廓收窄位移
        // 互相拉扯，边缘被拽出波浪。拆分后：
        //
        // - 场 A（脸型）：轮廓带位移（单调锥形）、五官零位移锚定；
        // - 场 B（五官）：五官带位移、**轮廓逐点锚定为零**——五官形变
        //   在 MLS 插值下到不了轮廓，边缘处严格衰减到 ≈ 0。
        //
        // 叠加后边缘位移 = 纯锥形剖面，与五官强度无关，波浪在构造上
        // 不可能出现；五官与轮廓各自的行为也互不干扰，便于分别调参。
        var controlsShape: [MLSSolver.ControlPoint] = []
        var controlsFeature: [MLSSolver.ControlPoint] = []
        if !parameters.isIdentity {
            for face in faces {
                controlsShape.append(contentsOf: adjuster.controls(
                    for: face,
                    imageBounds: bounds,
                    parameters: parameters
                ))
            }
        }
        if !features.isIdentity {
            for face in faces {
                controlsFeature.append(contentsOf: featureAdjuster.controls(
                    for: face,
                    parameters: features
                ))
                // 场 B 的轮廓锚：把脸缘钉死。必须**沿弧长加密**——只锚
                // 顶点时，顶点之间（间距 ~200px）是无锚区，五官位移会
                // 在段间漏出，形成以轮廓段为波长的残余波浪。
                for point in Self.densifiedContour(face.contour, subdivisions: 8) {
                    controlsFeature.append(.anchor(point))
                }
            }
            // 仅五官形变时，场 B 自带边框锚
            if controlsShape.isEmpty {
                controlsFeature.append(contentsOf: MLSSolver.identityAnchors(
                    around: (0, 0, bounds.width, bounds.height),
                    divisions: adjuster.anchorDivisions
                ))
            }
        }
        guard !controlsShape.isEmpty || !controlsFeature.isEmpty else { return nil }

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
        //
        // M8：personMask == nil 时逐元素保留原 M5 / M6 行为；有蒙版时只在
        // 人像内部把径向衰减与有向颈部走廊合并。权重表只在这里算一次，
        // 折叠回退循环不重算（ADR-006）。
        let radial = Self.falloffTable(
            faces: faces,
            imageSize: imageSize,
            columns: columns,
            rows: rows,
            config: config
        )
        let falloff: [Float]
        if let personMask {
            falloff = BodyCoordination.weightTable(
                radial: radial,
                faces: faces,
                imageSize: imageSize,
                columns: columns,
                rows: rows,
                config: config,
                mask: personMask
            )
        } else {
            falloff = radial
        }

        var strength: Float = 1
        var field: DisplacementField?
        for _ in 0..<config.maxRefinements {
            var offsetX: [Float]?
            var offsetY: [Float]?

            func accumulate(_ controls: [MLSSolver.ControlPoint]) {
                let solver = MLSSolver(controls: controls)
                let sampled = sampleOffsets(
                    solver: solver,
                    falloff: falloff,
                    imageSize: imageSize,
                    columns: columns,
                    rows: rows,
                    strength: strength
                )
                if var x = offsetX, var y = offsetY {
                    for index in x.indices {
                        x[index] += sampled.offsetX[index]
                        y[index] += sampled.offsetY[index]
                    }
                    offsetX = x
                    offsetY = y
                } else {
                    offsetX = sampled.offsetX
                    offsetY = sampled.offsetY
                }
            }

            if !controlsShape.isEmpty { accumulate(controlsShape) }
            if !controlsFeature.isEmpty { accumulate(controlsFeature) }

            guard let offsetX, let offsetY else { return nil }
            field = DisplacementField(
                columns: columns,
                rows: rows,
                offsetX: offsetX,
                offsetY: offsetY,
                imageSize: imageSize,
                appliedStrength: strength
            )
            if field!.minimumJacobian() > 0 {
                return field
            }
            // 折叠：整体回退强度重新求解
            strength *= config.refinementDecay
        }

        // 连续回退仍折叠：保持最后一次（最弱）的场，但调用方可据此告警。
        // 实际上 linear 压缩已经把位移限制在脸高的 10%，走到这里的概率极低。
        return field
    }

    /// 沿折线等弧长加密：每段插 `subdivisions` 个点（含段起点，不含
    /// 共享终点，末段终点单独补上）。
    public static func densifiedContour(
        _ contour: [Point2],
        subdivisions: Int
    ) -> [Point2] {
        guard contour.count > 1, subdivisions > 0 else { return contour }
        var result: [Point2] = []
        result.reserveCapacity(contour.count * subdivisions)
        for index in 0..<(contour.count - 1) {
            let from = contour[index]
            let to = contour[index + 1]
            for step in 0..<subdivisions {
                let t = Float(step) / Float(subdivisions)
                result.append(from + (to - from) * t)
            }
        }
        result.append(contour[contour.count - 1])
        return result
    }

    /// 在网格节点上求解位移：d(v) = (map(v) − v) × 衰减 × 强度。
    private static func sampleOffsets(
        solver: MLSSolver,
        falloff: [Float],
        imageSize: (width: Int, height: Int),
        columns: Int,
        rows: Int,
        strength: Float
    ) -> (offsetX: [Float], offsetY: [Float]) {
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

        return (offsetX, offsetY)
    }

    /// 每个网格节点的距离衰减权重。
    ///
    /// 对每张脸取「到该脸最近关键点的距离」，按脸自身的半径归一：
    /// `Config.falloffInnerFactor × R` 以内不衰减，
    /// `Config.falloffOuterFactor × R` 以外为 0（取值以 `Config` 的属性
    /// 默认值为准，勿在此处重复硬编码）。多张脸取最大值，
    /// 保证各自的影响范围互不截断。
    /// BodyCoordination 需要复用这张表做 `max(radial, neck)`，因此保持 internal。
    static func falloffTable(
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
            guard !points.isEmpty else { return nil }
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

        // MARK: M8 颈肩协调
        /// 颈部走廊内半宽（相对脸宽），该范围内横向不衰减。
        public var neckCorridorInnerFactor: Float = 0.25
        /// 颈部走廊外半宽（相对脸宽），该范围外横向权重为 0。
        public var neckCorridorOuterFactor: Float = 0.50
        /// 颈根相对下巴的下沉量（相对脸高）。
        public var neckRootDropFactor: Float = 0.08
        /// 肩线兜底位置：颈根下方多少倍脸高。
        public var shoulderDropFactor: Float = 0.90
        /// 肩线宽度突变倍率（相对颈段中位宽度）。
        public var shoulderWidthJump: Float = 1.8
        /// 颈根上方竖直切断带（相对脸高），防头顶位移带。
        public var neckUpperCutFactor: Float = 0.10
        /// 人像蒙版软阈值下界。第一轮调参由 0.5 放宽到 0.08：
        /// 原值会让 m∈(0.02,0.5) 全部硬置 0，在人像边界形成陡峭权重阶跃，
        /// 触发雅可比 ≤0 的折叠回退（IMG_0789 强度掉到 0.49）。
        /// 放宽后仍由 maskEpsilon 保证纯背景严格 0。
        public var maskGateLow: Float = 0.08
        /// 人像蒙版软阈值上界。
        public var maskGateHigh: Float = 0.85
        /// 低于该蒙版值严格置 0。
        public var maskEpsilon: Float = 0.01

        /// 调试钩子：非 nil 时跳过蒙版肩线推断，强制
        /// `shoulderY = neckRootY − factor × faceHeight`。
        /// 仅供 AutoBeauty `--shoulder-line` 调参使用；默认 nil，
        /// 产品路径（App / 默认 CLI）行为完全不变。
        public var shoulderLineFactorOverride: Float? = nil

        /// 注意：M5 曾因「属性默认值改了、显式 init 默认值漏改」导致背景
        /// 大面积形变（台账 3.7）。新增字段必须同步改这里的默认参数，
        /// `BodyCoordinationTests.testConfigDefaultsMatchExplicitInit` 会守护。
        public init(
            gridLongEdge: Int = 128,
            maxDisplacementFraction: Float = 0.10,
            displacementScale: Float = 1,
            falloffInnerFactor: Float = 0.15,
            falloffOuterFactor: Float = 0.45,
            refinementDecay: Float = 0.7,
            maxRefinements: Int = 12,
            neckCorridorInnerFactor: Float = 0.25,
            neckCorridorOuterFactor: Float = 0.50,
            neckRootDropFactor: Float = 0.08,
            shoulderDropFactor: Float = 0.90,
            shoulderWidthJump: Float = 1.8,
            neckUpperCutFactor: Float = 0.10,
            maskGateLow: Float = 0.08,
            maskGateHigh: Float = 0.85,
            maskEpsilon: Float = 0.01,
            shoulderLineFactorOverride: Float? = nil
        ) {
            self.gridLongEdge = gridLongEdge
            self.maxDisplacementFraction = maxDisplacementFraction
            self.displacementScale = displacementScale
            self.falloffInnerFactor = falloffInnerFactor
            self.falloffOuterFactor = falloffOuterFactor
            self.refinementDecay = refinementDecay
            self.maxRefinements = maxRefinements
            self.neckCorridorInnerFactor = neckCorridorInnerFactor
            self.neckCorridorOuterFactor = neckCorridorOuterFactor
            self.neckRootDropFactor = neckRootDropFactor
            self.shoulderDropFactor = shoulderDropFactor
            self.shoulderWidthJump = shoulderWidthJump
            self.neckUpperCutFactor = neckUpperCutFactor
            self.maskGateLow = maskGateLow
            self.maskGateHigh = maskGateHigh
            self.maskEpsilon = maskEpsilon
            self.shoulderLineFactorOverride = shoulderLineFactorOverride
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
