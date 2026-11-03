import CoreGraphics
import Foundation

public enum SkinMaskError: Error, LocalizedError {
    case invalidTargetSize

    public var errorDescription: String? {
        switch self {
        case .invalidTargetSize:
            return "皮肤蒙版目标尺寸无效"
        }
    }
}

/// 结合人像分割、肤色判据与五官排除生成面部皮肤蒙版。
///
/// 肤色判据有两种模式：
///
/// 1. **有人脸时（首选）**：从人脸框内采样得到该图自身的肤色参考，再按
///    「亮度归一化色度距离」判定每个像素。
///
///    归一化方式为 `((Cb - 0.5) / luma, (Cr - 0.5) / luma)`。漫反射光照下
///    RGB 同比缩放，Cb/Cr 与 luma 同比变化，因此该比值对阴影与高光不敏感，
///    只在肤色真正改变时才移动。这解决了绝对 YCbCr 阈值无法区分
///    「暖白色衣物」与「偏暖肤色」的问题（两者 Cb/Cr 都落在肤色带内）。
///
/// 2. **没有人脸时**：退回绝对 YCbCr 阈值带，保证仅凭肤色也能工作。
public struct SkinMaskGenerator {
    /// 蒙版长边，默认 512；预览可使用更小值。
    public var targetLongEdge: Int
    /// 羽化半径（蒙版像素），用于消除硬边。
    public var featherRadius: Int
    /// 肤色容差，0...1；越大越宽松。
    public var tolerance: Float

    public init(
        targetLongEdge: Int = 512,
        featherRadius: Int = 4,
        tolerance: Float = 0.5
    ) {
        self.targetLongEdge = targetLongEdge
        self.featherRadius = featherRadius
        self.tolerance = min(max(tolerance, 0), 1)
    }

    public func generate(
        image: CGImage,
        detection: DetectionResult
    ) throws -> SkinMask {
        let size = maskSize(for: image)
        guard size.width > 0, size.height > 0 else {
            throw SkinMaskError.invalidTargetSize
        }

        let bytes = try MaskImageRasterizer.rgbaBytes(
            from: image,
            width: size.width,
            height: size.height
        )
        var values = [Float](repeating: 0, count: size.width * size.height)

        let reference = makeReference(
            bytes: bytes,
            width: size.width,
            height: size.height,
            detection: detection
        )

        for y in 0..<size.height {
            let v = (Float(y) + 0.5) / Float(size.height)
            for x in 0..<size.width {
                let u = (Float(x) + 0.5) / Float(size.width)
                let offset = (y * size.width + x) * 4
                let r = Float(bytes[offset]) / 255
                let g = Float(bytes[offset + 1]) / 255
                let b = Float(bytes[offset + 2]) / 255

                let luma = MaskMath.luma(r: r, g: g, b: b)
                let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 0.5
                let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 0.5

                var score: Float
                if let reference {
                    score = relativeScore(
                        cb: cb,
                        cr: cr,
                        luma: luma,
                        reference: reference
                    )
                } else {
                    score = absoluteScore(
                        cb: cb,
                        cr: cr,
                        luma: luma,
                        saturation: MaskMath.saturation(r: r, g: g, b: b)
                    )
                }

                if score > 0 {
                    score *= samplePersonMask(detection.personMask, u: u, v: v)
                }
                values[y * size.width + x] = min(max(score, 0), 1)
            }
        }

        excludeFeatures(
            detection.faces,
            values: &values,
            width: size.width,
            height: size.height
        )

        if featherRadius > 0 {
            values = MaskFilters.boxBlur(
                values,
                width: size.width,
                height: size.height,
                radius: featherRadius
            )
        }

        return SkinMask(width: size.width, height: size.height, values: values)
    }

    // MARK: - 肤色参考

    /// 人脸肤色参考：亮度归一化后的色度中心。
    private struct ChromaReference {
        let cb: Float
        let cr: Float
    }

    private func makeReference(
        bytes: [UInt8],
        width: Int,
        height: Int,
        detection: DetectionResult
    ) -> ChromaReference? {
        guard !detection.faces.isEmpty else { return nil }

        // 采样时比最终蒙版更严格地排除五官与眉毛，避免把眼线、唇色、眉毛算进肤色
        let excluded = makeExclusionMask(
            detection.faces,
            width: width,
            height: height,
            eyeExpansion: 1.30,
            lipExpansion: 1.20,
            eyebrowExpansion: 1.25
        )

        var cbSamples: [Float] = []
        var crSamples: [Float] = []

        for face in detection.faces {
            let box = face.boundingBox
            guard box.width > 0, box.height > 0 else { continue }

            // 内缩 12%，避开发际线与轮廓边缘
            let inner = box.insetBy(dx: box.width * 0.12, dy: box.height * 0.12)
            let startX = max(0, Int(floor(inner.minX * CGFloat(width))))
            let endX = min(width - 1, Int(ceil(inner.maxX * CGFloat(width))))
            let startY = max(0, Int(floor((1 - inner.maxY) * CGFloat(height))))
            let endY = min(height - 1, Int(ceil((1 - inner.minY) * CGFloat(height))))
            guard startX <= endX, startY <= endY else { continue }

            for y in startY...endY {
                let v = (Float(y) + 0.5) / Float(height)
                for x in startX...endX {
                    let index = y * width + x
                    guard excluded[index] == 0 else { continue }

                    let offset = index * 4
                    let r = Float(bytes[offset]) / 255
                    let g = Float(bytes[offset + 1]) / 255
                    let b = Float(bytes[offset + 2]) / 255
                    let luma = MaskMath.luma(r: r, g: g, b: b)
                    guard luma > 0.12 else { continue }

                    let u = (Float(x) + 0.5) / Float(width)
                    guard samplePersonMask(detection.personMask, u: u, v: v) > 0.5 else {
                        continue
                    }

                    let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 0.5
                    let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 0.5
                    let inverse = 1 / luma
                    cbSamples.append((cb - 0.5) * inverse)
                    crSamples.append((cr - 0.5) * inverse)
                }
            }
        }

        guard cbSamples.count >= 40 else { return nil }

        // 中位数对头发丝、鼻孔、痣等离群点稳健
        return ChromaReference(
            cb: MaskMath.percentile(cbSamples, 0.5),
            cr: MaskMath.percentile(crSamples, 0.5)
        )
    }

    /// 相对判据：亮度归一化色度距离越小越像该人脸的肤色。
    ///
    /// 归一化用 `(Cb - 0.5) / luma`，对乘性光照（阴影、明暗过渡）不敏感。
    /// 注意不要在这里对镜面高光做额外补偿：高光会让色度与亮度同时缩小，
    /// 放大色度向量会把方向相同的正常肤色也推离参考，反而造成大片漏判。
    private func relativeScore(
        cb: Float,
        cr: Float,
        luma: Float,
        reference: ChromaReference
    ) -> Float {
        let lumaFloor = MaskMath.smoothstep(0.06, 0.18, luma)
        guard lumaFloor > 0 else { return 0 }

        let inverse = 1 / max(luma, 0.05)
        let dcb = (cb - 0.5) * inverse - reference.cb
        let dcr = (cr - 0.5) * inverse - reference.cr
        let distance = (dcb * dcb + dcr * dcr).squareRoot()

        let inner = 0.050 + 0.020 * tolerance
        let outer = 0.090 + 0.040 * tolerance
        let chroma = 1 - MaskMath.smoothstep(inner, outer, distance)
        return chroma * lumaFloor
    }

    /// 绝对判据：没有人脸时的兜底。
    private func absoluteScore(
        cb: Float,
        cr: Float,
        luma: Float,
        saturation: Float
    ) -> Float {
        let extra = 0.02 + 0.03 * tolerance

        var score = MaskMath.band(
            cb,
            low: 0.30 - extra,
            high: 0.50 + extra,
            feather: 0.04
        )
        score *= MaskMath.band(
            cr,
            low: 0.52 - extra,
            high: 0.70 + extra,
            feather: 0.04
        )
        score *= MaskMath.smoothstep(0.06, 0.18, luma)
        score *= MaskMath.smoothstep(0.02, 0.08, saturation)
        return score
    }

    // MARK: - 尺寸与人像蒙版

    private func maskSize(for image: CGImage) -> (width: Int, height: Int) {
        let longEdge = max(image.width, image.height)
        guard longEdge > 0, targetLongEdge > 0 else { return (0, 0) }

        let scale = min(1, CGFloat(targetLongEdge) / CGFloat(longEdge))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        return (width, height)
    }

    private func samplePersonMask(
        _ mask: SegmentationMask?,
        u: Float,
        v: Float
    ) -> Float {
        guard let mask, !mask.isEmpty else { return 1 }

        let x = u * Float(mask.width) - 0.5
        let y = v * Float(mask.height) - 0.5
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let fx = x - Float(x0)
        let fy = y - Float(y0)

        func value(_ px: Int, _ py: Int) -> Float {
            let cx = min(max(px, 0), mask.width - 1)
            let cy = min(max(py, 0), mask.height - 1)
            return Float(mask.pixels[cy * mask.width + cx]) / 255
        }

        let top = value(x0, y0) * (1 - fx) + value(x0 + 1, y0) * fx
        let bottom = value(x0, y0 + 1) * (1 - fx) + value(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    // MARK: - 五官排除

    private func excludeFeatures(
        _ faces: [FaceObservation],
        values: inout [Float],
        width: Int,
        height: Int
    ) {
        let mask = makeExclusionMask(
            faces,
            width: width,
            height: height,
            eyeExpansion: 1.15,
            lipExpansion: 1.05,
            eyebrowExpansion: 0
        )
        for index in values.indices where mask[index] > 0 {
            values[index] = 0
        }
    }

    /// 生成五官排除蒙版，1 表示该像素属于需要排除的区域。
    private func makeExclusionMask(
        _ faces: [FaceObservation],
        width: Int,
        height: Int,
        eyeExpansion: CGFloat,
        lipExpansion: CGFloat,
        eyebrowExpansion: CGFloat
    ) -> [Float] {
        var mask = [Float](repeating: 0, count: width * height)

        func add(_ points: [CGPoint], expansion: CGFloat) {
            guard expansion > 0, points.count >= 3 else { return }
            let polygon = PolygonRasterizer.makeMask(
                points: points,
                width: width,
                height: height,
                expansion: expansion
            )
            for index in polygon.indices where polygon[index] > 0 {
                mask[index] = 1
            }
        }

        for face in faces {
            guard let landmarks = face.landmarks else { continue }
            add(landmarks.leftEye, expansion: eyeExpansion)
            add(landmarks.rightEye, expansion: eyeExpansion)
            add(landmarks.outerLips, expansion: lipExpansion)
            add(landmarks.leftEyebrow, expansion: eyebrowExpansion)
            add(landmarks.rightEyebrow, expansion: eyebrowExpansion)
        }
        return mask
    }
}
