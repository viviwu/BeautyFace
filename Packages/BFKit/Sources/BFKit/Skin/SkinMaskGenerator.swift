import CoreGraphics
import Foundation

public enum SkinMaskError: Error, LocalizedError {
    case invalidTargetSize
    case cannotCreateContext

    public var errorDescription: String? {
        switch self {
        case .invalidTargetSize:
            return "皮肤蒙版目标尺寸无效"
        case .cannotCreateContext:
            return "无法创建皮肤蒙版上下文"
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

        let bytes = try rgbaBytes(from: image, width: size.width, height: size.height)
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

                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 0.5
                let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 0.5
                let saturation = max(r, max(g, b)) - min(r, min(g, b))

                var score = band(cb, low: cbLow, high: cbHigh, feather: 0.04)
                score *= band(cr, low: crLow, high: crHigh, feather: 0.04)
                score *= smoothstep(0.06, 0.18, luma)
                score *= smoothstep(0.02, 0.08, saturation)

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
            values = boxBlur(
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

    private func rgbaBytes(
        from image: CGImage,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drawn else {
            throw SkinMaskError.cannotCreateContext
        }
        return bytes
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
        guard points.count >= 3 else { return }

        var polygon = points.map {
            CGPoint(
                x: $0.x * CGFloat(width),
                y: (1 - $0.y) * CGFloat(height)
            )
        }

        let centroid = polygon.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let center = CGPoint(
            x: centroid.x / CGFloat(polygon.count),
            y: centroid.y / CGFloat(polygon.count)
        )
        polygon = polygon.map {
            CGPoint(
                x: center.x + ($0.x - center.x) * expansion,
                y: center.y + ($0.y - center.y) * expansion
            )
        }

        let xs = polygon.map(\.x)
        let ys = polygon.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return
        }

        let startX = max(0, Int(floor(minX)))
        let endX = min(width - 1, Int(ceil(maxX)))
        let startY = max(0, Int(floor(minY)))
        let endY = min(height - 1, Int(ceil(maxY)))
        guard startX <= endX, startY <= endY else { return }

        for y in startY...endY {
            for x in startX...endX {
                if contains(
                    x: CGFloat(x) + 0.5,
                    y: CGFloat(y) + 0.5,
                    polygon: polygon
                ) {
                    values[y * width + x] = 0
                }
            }
        }
    }

    private func contains(
        x: CGFloat,
        y: CGFloat,
        polygon: [CGPoint]
    ) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            if (a.y > y) != (b.y > y) {
                let intersectX = (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x
                if x < intersectX {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }

    private func band(
        _ value: Float,
        low: Float,
        high: Float,
        feather: Float
    ) -> Float {
        smoothstep(low - feather, low, value)
            * (1 - smoothstep(high, high + feather, value))
    }

    private func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func boxBlur(
        _ values: [Float],
        width: Int,
        height: Int,
        radius: Int
    ) -> [Float] {
        guard radius > 0, width > 0, height > 0 else { return values }

        let diameter = Float(radius * 2 + 1)
        var horizontal = [Float](repeating: 0, count: values.count)
        var output = [Float](repeating: 0, count: values.count)

        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for offset in -radius...radius {
                sum += values[row + min(max(offset, 0), width - 1)]
            }
            for x in 0..<width {
                horizontal[row + x] = sum / diameter
                let removeX = min(max(x - radius, 0), width - 1)
                let addX = min(max(x + radius + 1, 0), width - 1)
                sum += values[row + addX] - values[row + removeX]
            }
        }

        for x in 0..<width {
            var sum: Float = 0
            for offset in -radius...radius {
                let y = min(max(offset, 0), height - 1)
                sum += horizontal[y * width + x]
            }
            for y in 0..<height {
                output[y * width + x] = sum / diameter
                let removeY = min(max(y - radius, 0), height - 1)
                let addY = min(max(y + radius + 1, 0), height - 1)
                sum += horizontal[addY * width + x] - horizontal[removeY * width + x]
            }
        }

        return output
    }
}
