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

/// 结合人像分割、肤色阈值与五官排除生成面部皮肤蒙版。
public struct SkinMaskGenerator {
    /// 蒙版长边，默认 512；预览可使用更小值。
    public var targetLongEdge: Int
    /// 羽化半径（蒙版像素），用于消除硬边。
    public var featherRadius: Int
    /// 肤色阈值额外放宽量，0...1。
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

        let extra = 0.02 + 0.03 * tolerance
        let cbLow = 0.30 - extra
        let cbHigh = 0.50 + extra
        let crLow = 0.52 - extra
        let crHigh = 0.70 + extra

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
                let saturation = MaskMath.saturation(r: r, g: g, b: b)

                var score = MaskMath.band(
                    cb,
                    low: cbLow,
                    high: cbHigh,
                    feather: 0.04
                )
                score *= MaskMath.band(
                    cr,
                    low: crLow,
                    high: crHigh,
                    feather: 0.04
                )
                score *= MaskMath.smoothstep(0.06, 0.18, luma)
                score *= MaskMath.smoothstep(0.02, 0.08, saturation)

                if score > 0 {
                    let person = samplePersonMask(detection.personMask, u: u, v: v)
                    score *= person
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

    private func excludeFeatures(
        _ faces: [FaceObservation],
        values: inout [Float],
        width: Int,
        height: Int
    ) {
        for face in faces {
            guard let landmarks = face.landmarks else { continue }

            exclude(
                points: landmarks.leftEye,
                values: &values,
                width: width,
                height: height,
                expansion: 1.15
            )
            exclude(
                points: landmarks.rightEye,
                values: &values,
                width: width,
                height: height,
                expansion: 1.15
            )
            exclude(
                points: landmarks.outerLips,
                values: &values,
                width: width,
                height: height,
                expansion: 1.05
            )
        }
    }

    private func exclude(
        points: [CGPoint],
        values: inout [Float],
        width: Int,
        height: Int,
        expansion: CGFloat
    ) {
        let mask = PolygonRasterizer.makeMask(
            points: points,
            width: width,
            height: height,
            expansion: expansion
        )
        for index in values.indices where mask[index] > 0 {
            values[index] = 0
        }
    }
}
