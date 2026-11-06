/// 单张脸的 M8 颈肩几何模型（像素坐标，y 向上）。
public struct NeckShoulderModel: Sendable {
    /// 下巴最低点 y。
    public let chinY: Float
    /// 轮廓高度。
    public let faceHeight: Float
    /// 轮廓宽度。
    public let faceWidth: Float
    /// 颈部中轴 x：优先取蒙版颈段质心，否则瞳孔 / 轮廓中轴。
    public let axisX: Float
    /// 颈根：下巴下方 `neckRootDropFactor × faceHeight`。
    public let neckRootY: Float
    /// 肩线：位移在此严格归零；蒙版估计失败时走固定比例兜底。
    public let shoulderY: Float
    /// 走廊内半宽（该范围内权重不衰减）。
    public let innerHalfWidth: Float
    /// 走廊外半宽（该范围外权重为 0）。
    public let outerHalfWidth: Float
    /// 是否成功使用了人像蒙版宽度突变来定位肩线。
    public let usedMaskShoulder: Bool

    public init(
        chinY: Float,
        faceHeight: Float,
        faceWidth: Float,
        axisX: Float,
        neckRootY: Float,
        shoulderY: Float,
        innerHalfWidth: Float,
        outerHalfWidth: Float,
        usedMaskShoulder: Bool
    ) {
        self.chinY = chinY
        self.faceHeight = faceHeight
        self.faceWidth = faceWidth
        self.axisX = axisX
        self.neckRootY = neckRootY
        self.shoulderY = shoulderY
        self.innerHalfWidth = innerHalfWidth
        self.outerHalfWidth = outerHalfWidth
        self.usedMaskShoulder = usedMaskShoulder
    }
}

/// 由 76 点几何 + 人像蒙版推断颈根、颈部中轴与肩线（M8，A 级）。
///
/// 主方案：从颈根向下扫蒙版中包含颈部中轴的连通段宽度，颈段窄、肩线处
/// 突然展宽即为肩线。兜底链：硬界 → 固定脸高比例 → 图像下沿 / 蒙版缺失
/// 回退 M5。不引入人体姿态检测，也不需要新的用户参数。
public enum NeckShoulderEstimator {
    public static func models(
        faces: [FaceGeometry],
        imageSize: (width: Int, height: Int),
        config: DisplacementField.Config,
        mask: PersonMaskGrid?
    ) -> [NeckShoulderModel] {
        let imageWidth = Float(max(imageSize.width - 1, 1))
        let imageHeight = Float(max(imageSize.height - 1, 1))

        return faces.compactMap { face in
            guard let metrics = Metrics(face) else { return nil }

            let neckRootY = min(
                max(metrics.minY - config.neckRootDropFactor * metrics.height, 0),
                imageHeight
            )
            let fallbackShoulder = max(
                0,
                neckRootY - config.shoulderDropFactor * metrics.height
            )

            var axisX = metrics.axisX
            var shoulderY = fallbackShoulder
            var usedMaskShoulder = false

            if let override = config.shoulderLineFactorOverride {
                // 调参覆盖：直接按比例定位肩线，跳过蒙版推断与硬界，
                // 便于目视比较不同肩线位置对过渡的影响。
                shoulderY = max(0, neckRootY - max(0, override) * metrics.height)
            } else {
                if let mask, !mask.isEmpty,
                   metrics.height > 0, metrics.width > 0,
                   neckRootY > 1 {
                    let estimatedAxis = estimateNeckAxis(
                        metrics: metrics,
                        neckRootY: neckRootY,
                        imageWidth: imageWidth,
                        imageHeight: imageHeight,
                        mask: mask
                    )
                    axisX = estimatedAxis
                    if let estimated = estimateShoulderY(
                        metrics: metrics,
                        neckRootY: neckRootY,
                        axisX: estimatedAxis,
                        imageWidth: imageWidth,
                        imageHeight: imageHeight,
                        config: config,
                        mask: mask
                    ) {
                        shoulderY = estimated
                        usedMaskShoulder = true
                    }
                }

                // 硬界：[neckRootY − 2.2h, neckRootY − 0.5h]，并保证肩线严格在颈根下方。
                let hardLower = max(0, neckRootY - 2.2 * metrics.height)
                let hardUpper = max(0, neckRootY - 0.5 * metrics.height)
                let boundedUpper = max(hardLower, hardUpper)
                shoulderY = min(max(shoulderY, hardLower), boundedUpper)
                shoulderY = min(
                    shoulderY,
                    max(0, neckRootY - 0.05 * metrics.height)
                )
            }

            return NeckShoulderModel(
                chinY: metrics.minY,
                faceHeight: metrics.height,
                faceWidth: metrics.width,
                axisX: axisX,
                neckRootY: neckRootY,
                shoulderY: shoulderY,
                innerHalfWidth: config.neckCorridorInnerFactor * metrics.width,
                outerHalfWidth: config.neckCorridorOuterFactor * metrics.width,
                usedMaskShoulder: usedMaskShoulder
            )
        }
    }

    // MARK: - 蒙版推断

    private static func estimateNeckAxis(
        metrics: Metrics,
        neckRootY: Float,
        imageWidth: Float,
        imageHeight: Float,
        mask: PersonMaskGrid
    ) -> Float {
        let yTop = min(neckRootY, imageHeight)
        let yBottom = max(0, neckRootY - 0.30 * metrics.height)
        let halfSpan = 0.45 * metrics.width
        let ySteps = 10
        let xSteps = 24
        var weightedX: Float = 0
        var totalWeight: Float = 0

        for yi in 0...ySteps {
            let t = Float(yi) / Float(ySteps)
            let y = yTop + (yBottom - yTop) * t
            let v = y / imageHeight
            for xi in 0...xSteps {
                let x = metrics.axisX - halfSpan
                    + 2 * halfSpan * Float(xi) / Float(xSteps)
                let value = mask.sample(u: x / imageWidth, v: v)
                weightedX += x * value
                totalWeight += value
            }
        }

        guard totalWeight > 0.001 else { return metrics.axisX }
        return weightedX / totalWeight
    }

    private static func estimateShoulderY(
        metrics: Metrics,
        neckRootY: Float,
        axisX: Float,
        imageWidth: Float,
        imageHeight: Float,
        config: DisplacementField.Config,
        mask: PersonMaskGrid
    ) -> Float? {
        let yStart = neckRootY - 0.08 * metrics.height
        let yEnd = max(0, neckRootY - 2.2 * metrics.height)
        guard yStart > yEnd else { return nil }

        let sampleCount = 64
        let yStep = (yStart - yEnd) / Float(sampleCount - 1)
        let maxHalfWidth = 2.5 * metrics.width
        let threshold = config.maskGateLow

        var widths: [Float] = []
        widths.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let y = yStart - Float(index) * yStep
            widths.append(personWidth(
                atY: y,
                axisX: axisX,
                maxHalfWidth: maxHalfWidth,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                threshold: threshold,
                mask: mask
            ))
        }

        // 颈段基线：紧邻颈根的若干行取中位数，避免单发丝 / 衣领噪点。
        let baselineCount = min(8, widths.count)
        var baselineSamples: [Float] = []
        for index in 0..<baselineCount where widths[index] > 0 {
            baselineSamples.append(widths[index])
        }
        guard baselineSamples.count >= 3 else { return nil }
        let baseline = median(baselineSamples)
        guard baseline > 0 else { return nil }

        let jumpWidth = config.shoulderWidthJump * baseline
        var consecutive = 0
        var candidate: Int?
        for index in 1..<widths.count {
            if widths[index] > jumpWidth {
                consecutive += 1
                if consecutive >= 3 {
                    candidate = index - 2
                    break
                }
            } else {
                consecutive = 0
            }
        }
        guard let first = candidate else { return nil }

        // 在突变点附近用一阶差分最大处微调，定位真正展宽的一行。
        let lower = max(1, first - 3)
        let upper = min(widths.count - 1, first + 3)
        guard lower <= upper else { return nil }
        var best = first
        var bestDelta = -Float.infinity
        for index in lower...upper {
            let delta = widths[index] - widths[index - 1]
            if delta > bestDelta {
                bestDelta = delta
                best = index
            }
        }
        return yStart - Float(best) * yStep
    }

    /// 在给定 y 上，量出包含 `axisX` 的人像连通段宽度（像素）。
    private static func personWidth(
        atY y: Float,
        axisX: Float,
        maxHalfWidth: Float,
        imageWidth: Float,
        imageHeight: Float,
        threshold: Float,
        mask: PersonMaskGrid
    ) -> Float {
        let v = y / imageHeight
        func isPerson(_ x: Float) -> Bool {
            mask.sample(u: x / imageWidth, v: v) > threshold
        }
        guard isPerson(axisX) else { return 0 }

        let step = max(1, maxHalfWidth / 64)
        var left = axisX
        while left - step >= axisX - maxHalfWidth,
              isPerson(left - step) {
            left -= step
        }
        var right = axisX
        while right + step <= axisX + maxHalfWidth,
              isPerson(right + step) {
            right += step
        }
        return right - left
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 { return sorted[count / 2] }
        return (sorted[count / 2 - 1] + sorted[count / 2]) * 0.5
    }

    // MARK: - 脸型度量（独立于 FaceShapeAdjuster 的 internal FaceMetrics）

    private struct Metrics {
        let minX: Float
        let maxX: Float
        let minY: Float
        let maxY: Float
        let width: Float
        let height: Float
        let axisX: Float

        init?(_ face: FaceGeometry) {
            guard let first = face.contour.first else { return nil }
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
                self.axisX = (
                    Self.centroid(face.leftEye).x + Self.centroid(face.rightEye).x
                ) * 0.5
            } else {
                self.axisX = (minX + maxX) * 0.5
            }
        }

        private static func centroid(_ points: [Point2]) -> Point2 {
            guard !points.isEmpty else { return .zero }
            var sum = Point2.zero
            for point in points {
                sum = sum + point
            }
            return sum * (1 / Float(points.count))
        }
    }
}
