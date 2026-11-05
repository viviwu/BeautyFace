import CoreGraphics
import BFAlgorithms

/// 根据关键点生成美妆区域蒙版（口红 / 腮红 / 眉毛加深 / 眼影）。
///
/// 关键点必须是**形变后**的（ADR-007）：传入前先用位移场把
/// `FaceGeometry` 各点映射到输出位置，否则美妆与形变后的五官错位。
///
/// 区域定义（ADR-008：程序化生成，无美术素材）：
///
/// - **口红**：`outerLips` 多边形填充，减去 `innerLips`（口内不上色）；
/// - **腮红**：眼睛质心与唇部质心连线中点、略向外的椭圆，软边衰减；
/// - **眉毛**：沿眉毛折线撒圆盘（半径相对脸高），补出厚度；
/// - **眼影**：上眼睑（高于眼睛质心的轮廓点）向上偏移撒圆盘。
public struct MakeupMaskGenerator {
    /// 蒙版长边。五官区域较小，512 足够，GPU 采样时双线性放大。
    public var maskLongEdge: Int
    /// 蒙版羽化半径（蒙版像素）。
    public var featherRadius: Int

    public init(maskLongEdge: Int = 512, featherRadius: Int = 2) {
        self.maskLongEdge = max(64, maskLongEdge)
        self.featherRadius = max(0, featherRadius)
    }

    // MARK: - 生成

    public func generate(
        faces: [FaceGeometry],
        imageSize: (width: Int, height: Int)
    ) -> MakeupMask {
        let scale = Float(maskLongEdge)
            / Float(max(imageSize.width, imageSize.height))
        let width = max(1, Int((Float(imageSize.width) * scale).rounded()))
        let height = max(1, Int((Float(imageSize.height) * scale).rounded()))

        var mask = MakeupMask(
            width: width,
            height: height,
            lip: [Float](repeating: 0, count: width * height),
            blush: [Float](repeating: 0, count: width * height),
            brow: [Float](repeating: 0, count: width * height),
            shadow: [Float](repeating: 0, count: width * height)
        )

        for face in faces {
            addLipMask(face: face, imageSize: imageSize, output: &mask)
            addBlushMask(face: face, imageSize: imageSize, output: &mask)
            addBrowMask(face: face, imageSize: imageSize, output: &mask)
            addShadowMask(face: face, imageSize: imageSize, output: &mask)
        }

        // 羽化：盒滤波近似高斯
        let radius = max(1, featherRadius)
        mask.lip = MaskFilters.boxBlur(mask.lip, width: width, height: height, radius: radius)
        mask.blush = MaskFilters.boxBlur(mask.blush, width: width, height: height, radius: radius + 1)
        mask.brow = MaskFilters.boxBlur(mask.brow, width: width, height: height, radius: max(1, radius - 1))
        mask.shadow = MaskFilters.boxBlur(mask.shadow, width: width, height: height, radius: radius)
        mask.clampAll()
        return mask
    }

    /// 把关键点经位移场映射到输出位置（ADR-007：美妆与形变对齐）。
    ///
    /// 逆向映射约定：原图内容 `p` 在输出中的位置 `v` 满足
    /// `v + d(v) = p`，即 `v ≈ p − d(p)`。
    public static func deformed(
        _ face: FaceGeometry,
        field: DisplacementField?
    ) -> FaceGeometry {
        guard let field else { return face }
        func map(_ points: [Point2]) -> [Point2] {
            points.map { point in
                let d = field.displacement(at: point)
                return Point2(point.x - d.x, point.y - d.y)
            }
        }
        func map(_ point: Point2?) -> Point2? {
            guard let point else { return nil }
            let d = field.displacement(at: point)
            return Point2(point.x - d.x, point.y - d.y)
        }
        return FaceGeometry(
            contour: map(face.contour),
            leftEye: map(face.leftEye),
            rightEye: map(face.rightEye),
            leftEyebrow: map(face.leftEyebrow),
            rightEyebrow: map(face.rightEyebrow),
            nose: map(face.nose),
            outerLips: map(face.outerLips),
            innerLips: map(face.innerLips),
            leftPupil: map(face.leftPupil),
            rightPupil: map(face.rightPupil)
        )
    }

    // MARK: - 各区域

    private func addLipMask(
        face: FaceGeometry,
        imageSize: (width: Int, height: Int),
        output: inout MakeupMask
    ) {
        guard face.outerLips.count >= 3 else { return }
        let outer = rasterize(
            face.outerLips,
            imageSize: imageSize,
            output: output,
            expansion: 1.0
        )
        // 口内（牙齿/口腔）不上色
        let inner: [Float]
        if face.innerLips.count >= 3 {
            inner = rasterize(
                face.innerLips,
                imageSize: imageSize,
                output: output,
                expansion: 1.0
            )
        } else {
            inner = [Float](repeating: 0, count: outer.count)
        }
        for index in outer.indices where outer[index] > 0 {
            output.lip[index] = max(output.lip[index], outer[index] - inner[index])
        }
    }

    private func addBlushMask(
        face: FaceGeometry,
        imageSize: (width: Int, height: Int),
        output: inout MakeupMask
    ) {
        let metrics = FaceMetricsBridge(face)
        guard metrics.height > 0, metrics.width > 0 else { return }
        guard !face.leftEye.isEmpty, !face.rightEye.isEmpty,
              !face.outerLips.isEmpty else { return }

        let mouthCenter = FaceMetricsBridge.centroid(face.outerLips)
        for eye in [face.leftEye, face.rightEye] {
            let center = FaceMetricsBridge.centroid(eye)
            // 腮红中心：眼与唇连线中点、略向脸缘外侧偏移
            let cx = center.x + (center.x - metrics.axisX) * 0.18
            let cy = (center.y + mouthCenter.y) * 0.5
            let radiusX = metrics.width * 0.13
            let radiusY = metrics.height * 0.075
            splatEllipse(
                centerX: cx, centerY: cy,
                radiusX: radiusX, radiusY: radiusY,
                imageSize: imageSize,
                output: &output,
                channel: \.blush
            )
        }
    }

    private func addBrowMask(
        face: FaceGeometry,
        imageSize: (width: Int, height: Int),
        output: inout MakeupMask
    ) {
        let metrics = FaceMetricsBridge(face)
        let radius = max(2, metrics.height * 0.016)
        for brow in [face.leftEyebrow, face.rightEyebrow] {
            for point in brow {
                splatDisc(
                    centerX: point.x, centerY: point.y,
                    radius: radius,
                    imageSize: imageSize,
                    output: &output,
                    channel: \.brow
                )
            }
        }
    }

    private func addShadowMask(
        face: FaceGeometry,
        imageSize: (width: Int, height: Int),
        output: inout MakeupMask
    ) {
        let metrics = FaceMetricsBridge(face)
        let radius = max(2, metrics.height * 0.020)
        for eye in [face.leftEye, face.rightEye] {
            guard !eye.isEmpty else { continue }
            let center = FaceMetricsBridge.centroid(eye)
            for point in eye where point.y > center.y {
                // 上眼睑点向上偏移半个半径，让眼影盖在眼睑上方
                splatDisc(
                    centerX: point.x, centerY: point.y + radius * 0.6,
                    radius: radius,
                    imageSize: imageSize,
                    output: &output,
                    channel: \.shadow
                )
            }
        }
    }

    // MARK: - 光栅化工具

    private func rasterize(
        _ points: [Point2],
        imageSize: (width: Int, height: Int),
        output: MakeupMask,
        expansion: Float
    ) -> [Float] {
        let normalized = points.map { point in
            CGPoint(
                x: CGFloat(point.x / Float(imageSize.width)),
                y: CGFloat(point.y / Float(imageSize.height))
            )
        }
        return PolygonRasterizer.makeMask(
            points: normalized,
            width: output.width,
            height: output.height,
            expansion: CGFloat(expansion)
        )
    }

    private func splatDisc(
        centerX: Float,
        centerY: Float,
        radius: Float,
        imageSize: (width: Int, height: Int),
        output: inout MakeupMask,
        channel: WritableKeyPath<MakeupMask, [Float]>
    ) {
        splatEllipse(
            centerX: centerX, centerY: centerY,
            radiusX: radius, radiusY: radius,
            imageSize: imageSize,
            output: &output,
            channel: channel
        )
    }

    /// 软边椭圆：`1 − smoothstep(0.55, 1.0, 归一化距离)`。
    ///
    /// 坐标与半径各自按轴换算（x 用 maskW/imgW、y 用 maskH/imgH），
    /// 非方形蒙版下不会错位。
    private func splatEllipse(
        centerX: Float,
        centerY: Float,
        radiusX: Float,
        radiusY: Float,
        imageSize: (width: Int, height: Int),
        output: inout MakeupMask,
        channel: WritableKeyPath<MakeupMask, [Float]>
    ) {
        let scaleX = Float(output.width) / Float(imageSize.width)
        let scaleY = Float(output.height) / Float(imageSize.height)
        let mx = centerX * scaleX
        let my = (Float(imageSize.height) - centerY) * scaleY
        let mrx = max(radiusX * scaleX, 1.5)
        let mry = max(radiusY * scaleY, 1.5)

        let startX = max(0, Int(floor(mx - mrx)))
        let endX = min(output.width - 1, Int(ceil(mx + mrx)))
        let startY = max(0, Int(floor(my - mry)))
        let endY = min(output.height - 1, Int(ceil(my + mry)))
        guard startX <= endX, startY <= endY else { return }

        for y in startY...endY {
            for x in startX...endX {
                let dx = (Float(x) + 0.5 - mx) / mrx
                let dy = (Float(y) + 0.5 - my) / mry
                let distance = (dx * dx + dy * dy).squareRoot()
                let shape = 1 - MaskMath.smoothstep(Float(0.55), Float(1.0), distance)
                guard shape > 0 else { continue }
                let index = y * output.width + x
                let current = output[keyPath: channel][index]
                output[keyPath: channel][index] = max(current, shape)
            }
        }
    }
}

/// 蒙版生成用的脸部度量（BFAlgorithms 的 FaceMetrics 是 internal）。
struct FaceMetricsBridge {
    let minX: Float
    let maxX: Float
    let minY: Float
    let maxY: Float
    let width: Float
    let height: Float
    let axisX: Float

    static func centroid(_ points: [Point2]) -> Point2 {
        guard !points.isEmpty else { return Point2(0, 0) }
        var sum = Point2(0, 0)
        for point in points {
            sum = Point2(sum.x + point.x, sum.y + point.y)
        }
        let inverse = 1 / Float(points.count)
        return Point2(sum.x * inverse, sum.y * inverse)
    }

    init(_ face: FaceGeometry) {
        guard let first = face.contour.first else {
            minX = 0; maxX = 0; minY = 0; maxY = 0; width = 0; height = 0; axisX = 0
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
            axisX = (left.x + right.x) * 0.5
        } else if !face.leftEye.isEmpty, !face.rightEye.isEmpty {
            axisX = (Self.centroid(face.leftEye).x
                + Self.centroid(face.rightEye).x) * 0.5
        } else {
            axisX = (minX + maxX) * 0.5
        }
    }
}
