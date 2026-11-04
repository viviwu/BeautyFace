// MARK: - 二维点

/// 纯 Swift 二维点，供算法层使用；BFAlgorithms 不 import Apple 框架（ADR-005）。
public struct Point2: Equatable, Hashable, Sendable {
    public var x: Float
    public var y: Float

    public init(_ x: Float, _ y: Float) {
        self.x = x
        self.y = y
    }

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2(0, 0)

    public static func + (lhs: Point2, rhs: Point2) -> Point2 {
        Point2(lhs.x + rhs.x, lhs.y + rhs.y)
    }

    public static func - (lhs: Point2, rhs: Point2) -> Point2 {
        Point2(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    public static func * (lhs: Point2, rhs: Float) -> Point2 {
        Point2(lhs.x * rhs, lhs.y * rhs)
    }

    public var lengthSquared: Float { x * x + y * y }

    public var length: Float { (x * x + y * y).squareRoot() }

    /// 与另一点的欧氏距离平方。
    public func distanceSquared(to other: Point2) -> Float {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}

// MARK: - MLS 求解器

/// Moving Least Squares 图像变形（Schaefer et al. 2006，rigid 形式）。
///
/// 输入一组控制点对应关系：`output`（变形后位置）→ `source`（原图位置）。
/// `map(_:)` 对**输出空间**中的任意点返回它在**原图**中的采样位置，因此
/// 可以直接作为逆向映射喂给重采样器：`输出(v) = 原图(map(v))`。
///
/// 采用 rigid 形式（局部只做旋转 + 平移，不缩放），是三种 MLS 变体中
/// 最不容易产生折叠与「捏缩」伪影的；人脸缩窄依靠「轮廓控制点内移、
/// 五官控制点不动」在 MLS 插值下自然形成的压缩。
///
/// 远场行为： MLS 单独使用时，远离全部控制点的区域会退化为一个全局
/// 刚体变换而不是恒等，因此调用方必须补充「零位移锚点」（见
/// `MLSSolver.identityAnchors(around:)`）把边界钉住。
public struct MLSSolver: Sendable {
    /// 输出空间中的控制点位置（p_i）。
    private let outputX: [Float]
    private let outputY: [Float]
    /// 原图中的控制点位置（q_i）。
    private let sourceX: [Float]
    private let sourceY: [Float]

    /// 权重分母的阻尼项：避免查询点与控制点重合时权重发散。
    /// 取值相对场景尺度而言极小，不影响正常区域的插值。
    private let epsilonSquared: Float

    /// 控制点间的最小尺度，用于判断「查询点落在控制点上」。
    private let snapDistanceSquared: Float

    public init(controls: [ControlPoint], epsilon: Float = 0) {
        precondition(!controls.isEmpty, "MLS 至少需要一个控制点")

        var ox: [Float] = []
        var oy: [Float] = []
        var sx: [Float] = []
        var sy: [Float] = []
        ox.reserveCapacity(controls.count)
        oy.reserveCapacity(controls.count)
        sx.reserveCapacity(controls.count)
        sy.reserveCapacity(controls.count)
        var reference = Float(0)
        for control in controls {
            ox.append(control.output.x)
            oy.append(control.output.y)
            sx.append(control.source.x)
            sy.append(control.source.y)
            reference = max(reference, control.output.length)
        }
        reference = max(reference, 1)

        self.outputX = ox
        self.outputY = oy
        self.sourceX = sx
        self.sourceY = sy
        let damping = epsilon > 0 ? epsilon : reference * 1e-6
        self.epsilonSquared = damping * damping
        self.snapDistanceSquared = max(epsilonSquared, 1e-12)
    }

    public struct ControlPoint: Sendable {
        /// 变形后（输出空间）位置。
        public var output: Point2
        /// 原图位置。
        public var source: Point2

        public init(output: Point2, source: Point2) {
            self.output = output
            self.source = source
        }

        /// 零位移锚点：输出与原图位置相同。
        public static func anchor(_ point: Point2) -> ControlPoint {
            ControlPoint(output: point, source: point)
        }
    }

    /// 沿矩形边框生成一圈零位移锚点，把远离人脸的区域钉回恒等。
    ///
    /// MLS 的远场是一个全局刚体变换，若不加锚点，背景会被整体平移 / 旋转。
    /// 锚点沿边框等距布置，间距约为边长 / `divisions`；人脸控制点靠近边框时
    /// 锚点权重升高，会自然压低附近的形变量，这是预期行为。
    public static func identityAnchors(
        around rect: (minX: Float, minY: Float, maxX: Float, maxY: Float),
        divisions: Int = 16
    ) -> [ControlPoint] {
        var anchors: [ControlPoint] = []
        let n = max(2, divisions)
        let stepX = (rect.maxX - rect.minX) / Float(n)
        let stepY = (rect.maxY - rect.minY) / Float(n)
        for i in 0...n {
            let x = rect.minX + Float(i) * stepX
            anchors.append(.anchor(Point2(x, rect.minY)))
            anchors.append(.anchor(Point2(x, rect.maxY)))
        }
        for j in 1..<n {
            let y = rect.minY + Float(j) * stepY
            anchors.append(.anchor(Point2(rect.minX, y)))
            anchors.append(.anchor(Point2(rect.maxX, y)))
        }
        return anchors
    }

    /// 输出空间中的点 → 原图中的采样位置。
    ///
    /// 质心与 Procrustes 旋转分子在同一趟循环内以**查询点**为参考累加，
    /// 最后换算回以加权质心为参考，避免第二趟遍历：
    /// `Σ w·p̂·q̂ = Σ w·(p_i−v)·(q_i−v) − W·(p*−v)·(q*−v)`。
    public func map(_ point: Point2) -> Point2 {
        var weightSum: Float = 0
        var centroidOutputX: Float = 0
        var centroidOutputY: Float = 0
        var centroidSourceX: Float = 0
        var centroidSourceY: Float = 0
        var cosineNumerator: Float = 0
        var sineNumerator: Float = 0
        var nearestDistanceSquared = Float.infinity
        var nearestIndex = 0

        for index in outputX.indices {
            let dx = outputX[index] - point.x
            let dy = outputY[index] - point.y
            let distanceSquared = dx * dx + dy * dy
            if distanceSquared < nearestDistanceSquared {
                nearestDistanceSquared = distanceSquared
                nearestIndex = index
            }
            let weight = 1 / (distanceSquared + epsilonSquared)
            let ux = dx                // u_i = p_i − v
            let uy = dy
            let zx = sourceX[index] - point.x   // z_i = q_i − v
            let zy = sourceY[index] - point.y

            weightSum += weight
            centroidOutputX += weight * outputX[index]
            centroidOutputY += weight * outputY[index]
            centroidSourceX += weight * sourceX[index]
            centroidSourceY += weight * sourceY[index]
            cosineNumerator += weight * (ux * zx + uy * zy)
            sineNumerator += weight * (ux * zy - uy * zx)
        }

        // 查询点几乎落在控制点上：直接返回对应源位置，保证 f(p_i) = q_i。
        if nearestDistanceSquared <= snapDistanceSquared {
            return Point2(sourceX[nearestIndex], sourceY[nearestIndex])
        }

        let inverseWeightSum = 1 / weightSum
        let centroidOutput = Point2(
            centroidOutputX * inverseWeightSum,
            centroidOutputY * inverseWeightSum
        )
        let centroidSource = Point2(
            centroidSourceX * inverseWeightSum,
            centroidSourceY * inverseWeightSum
        )

        // 以查询点为参考换算到以质心为参考
        let uxStar = centroidOutput.x - point.x
        let uyStar = centroidOutput.y - point.y
        let zxStar = centroidSource.x - point.x
        let zyStar = centroidSource.y - point.y
        let cosine = cosineNumerator * inverseWeightSum
            - (uxStar * zxStar + uyStar * zyStar)
        let sine = sineNumerator * inverseWeightSum
            - (uxStar * zyStar - uyStar * zxStar)

        let radius = (cosine * cosine + sine * sine).squareRoot()
        let vx = point.x - centroidOutput.x
        let vy = point.y - centroidOutput.y

        // 所有控制点共线 / 重合时没有可确定的旋转，退化为纯平移。
        guard radius > 1e-9 else {
            return Point2(
                centroidSource.x + vx,
                centroidSource.y + vy
            )
        }

        let normalizedCosine = cosine / radius
        let normalizedSine = sine / radius
        return Point2(
            centroidSource.x + normalizedCosine * vx - normalizedSine * vy,
            centroidSource.y + normalizedSine * vx + normalizedCosine * vy
        )
    }
}
