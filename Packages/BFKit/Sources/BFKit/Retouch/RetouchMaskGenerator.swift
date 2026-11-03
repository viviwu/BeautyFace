import CoreGraphics

/// 根据关键点、肤色与局部亮度生成眼白、牙齿、眼下与痘印区域蒙版。
public struct RetouchMaskGenerator {
    /// 眼下区域羽化半径（蒙版像素）。
    public var featherRadius: Int

    public init(featherRadius: Int = 2) {
        self.featherRadius = max(featherRadius, 0)
    }

    public func generate(
        image: CGImage,
        detection: DetectionResult,
        skinMask: SkinMask
    ) throws -> RetouchMask {
        guard !skinMask.isEmpty else { return .empty }

        let width = skinMask.width
        let height = skinMask.height
        let bytes = try MaskImageRasterizer.rgbaBytes(
            from: image,
            width: width,
            height: height
        )

        var eye = [Float](repeating: 0, count: width * height)
        var teeth = [Float](repeating: 0, count: width * height)
        var darkCircle = [Float](repeating: 0, count: width * height)

        let averageSkinLuma = computeAverageSkinLuma(
            bytes: bytes,
            skinMask: skinMask
        )

        for face in detection.faces {
            guard let landmarks = face.landmarks else { continue }

            addEyeMask(
                points: landmarks.leftEye,
                bytes: bytes,
                width: width,
                height: height,
                output: &eye
            )
            addEyeMask(
                points: landmarks.rightEye,
                bytes: bytes,
                width: width,
                height: height,
                output: &eye
            )

            let mouthPoints = landmarks.innerLips.count >= 3
                ? landmarks.innerLips
                : landmarks.outerLips
            addTeethMask(
                points: mouthPoints,
                bytes: bytes,
                width: width,
                height: height,
                output: &teeth
            )

            addDarkCircleMask(
                eyePoints: landmarks.leftEye,
                bytes: bytes,
                skinMask: skinMask,
                averageSkinLuma: averageSkinLuma,
                output: &darkCircle
            )
            addDarkCircleMask(
                eyePoints: landmarks.rightEye,
                bytes: bytes,
                skinMask: skinMask,
                averageSkinLuma: averageSkinLuma,
                output: &darkCircle
            )
        }

        let darkRadius = max(2, featherRadius)
        eye = MaskFilters.boxBlur(eye, width: width, height: height, radius: 1)
        teeth = MaskFilters.boxBlur(teeth, width: width, height: height, radius: 1)
        darkCircle = MaskFilters.boxBlur(
            darkCircle,
            width: width,
            height: height,
            radius: darkRadius
        )

        for index in eye.indices {
            eye[index] = min(max(eye[index], 0), 1)
            teeth[index] = min(max(teeth[index], 0), 1)
            darkCircle[index] = min(
                max(darkCircle[index] - eye[index], 0),
                1
            )
        }

        return RetouchMask(
            width: width,
            height: height,
            eye: eye,
            teeth: teeth,
            darkCircle: darkCircle
        )
    }

    /// 眼白：同时使用绝对亮度与「相对眼内中位亮度」两个判据，取较大者。
    ///
    /// - 绝对判据负责正常光照：眼白通常显著亮于皮肤与虹膜。
    /// - 相对判据负责暗光、眯眼、小图：实测这类素材眼内最高亮度只有 0.35~0.55，
    ///   绝对阈值完全失效，但眼白仍是眼内最亮的部分。
    /// - 闭眼时眼内亮度分布平坦，相对值接近 1，两个判据都不成立，蒙版自然为空。
    private func addEyeMask(
        points: [CGPoint],
        bytes: [UInt8],
        width: Int,
        height: Int,
        output: inout [Float]
    ) {
        let inside = PolygonRasterizer.makeMask(
            points: points,
            width: width,
            height: height,
            expansion: 1.0
        )

        var sampledIndices: [Int] = []
        var lumas: [Float] = []
        for index in inside.indices where inside[index] > 0 {
            let offset = index * 4
            let r = Float(bytes[offset]) / 255
            let g = Float(bytes[offset + 1]) / 255
            let b = Float(bytes[offset + 2]) / 255
            sampledIndices.append(index)
            lumas.append(MaskMath.luma(r: r, g: g, b: b))
        }
        guard sampledIndices.count >= 8 else { return }

        let reference = max(MaskMath.percentile(lumas, 0.50), 0.05)

        for (sample, index) in sampledIndices.enumerated() {
            let offset = index * 4
            let r = Float(bytes[offset]) / 255
            let g = Float(bytes[offset + 1]) / 255
            let b = Float(bytes[offset + 2]) / 255
            let saturation = MaskMath.saturation(r: r, g: g, b: b)
            let luma = lumas[sample]

            let absolute = MaskMath.smoothstep(0.50, 0.72, luma)
            let relative = MaskMath.smoothstep(1.35, 2.00, luma / reference)
            let whiteness = max(absolute, relative)
                * (1 - MaskMath.smoothstep(0.12, 0.28, saturation))
            guard whiteness > 0 else { continue }
            output[index] = max(output[index], whiteness)
        }
    }

    /// 牙齿：口内低饱和、低红偏的亮区。
    private func addTeethMask(
        points: [CGPoint],
        bytes: [UInt8],
        width: Int,
        height: Int,
        output: inout [Float]
    ) {
        let inside = PolygonRasterizer.makeMask(
            points: points,
            width: width,
            height: height,
            expansion: 0.92
        )

        for index in inside.indices where inside[index] > 0 {
            let offset = index * 4
            let r = Float(bytes[offset]) / 255
            let g = Float(bytes[offset + 1]) / 255
            let b = Float(bytes[offset + 2]) / 255
            let luma = MaskMath.luma(r: r, g: g, b: b)
            let saturation = MaskMath.saturation(r: r, g: g, b: b)
            let redBias = max(r - g, 0)

            let whiteness = MaskMath.smoothstep(0.34, 0.60, luma)
                * (1 - MaskMath.smoothstep(0.10, 0.30, saturation))
                * (1 - MaskMath.smoothstep(0.06, 0.18, redBias))
            guard whiteness > 0 else { continue }
            output[index] = max(output[index], whiteness)
        }
    }

    private func addDarkCircleMask(
        eyePoints: [CGPoint],
        bytes: [UInt8],
        skinMask: SkinMask,
        averageSkinLuma: Float,
        output: inout [Float]
    ) {
        guard eyePoints.count >= 3 else { return }

        let xs = eyePoints.map { $0.x * CGFloat(skinMask.width) }
        let ys = eyePoints.map { (1 - $0.y) * CGFloat(skinMask.height) }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return
        }

        let eyeWidth = max(maxX - minX, 1)
        let eyeHeight = max(maxY - minY, 1)
        let centerX = (minX + maxX) * 0.5
        let centerY = maxY + eyeHeight * 0.70
        let radiusX = max(eyeWidth * 0.70, 1)
        let radiusY = max(eyeHeight * 0.55, 1)

        let startX = max(0, Int(floor(centerX - radiusX)))
        let endX = min(skinMask.width - 1, Int(ceil(centerX + radiusX)))
        let startY = max(0, Int(floor(centerY - radiusY)))
        let endY = min(skinMask.height - 1, Int(ceil(centerY + radiusY)))
        guard startX <= endX, startY <= endY else { return }

        let reference = max(averageSkinLuma, 0.05)

        for y in startY...endY {
            for x in startX...endX {
                let dx = (CGFloat(x) + 0.5 - centerX) / radiusX
                let dy = (CGFloat(y) + 0.5 - centerY) / radiusY
                let distance = (dx * dx + dy * dy).squareRoot()
                let shape = 1 - MaskMath.smoothstep(
                    Float(0.70),
                    Float(1.05),
                    Float(distance)
                )
                guard shape > 0 else { continue }

                let index = y * skinMask.width + x
                let skin = skinMask.values[index]
                guard skin > 0 else { continue }

                let offset = index * 4
                let r = Float(bytes[offset]) / 255
                let g = Float(bytes[offset + 1]) / 255
                let b = Float(bytes[offset + 2]) / 255
                let luma = MaskMath.luma(r: r, g: g, b: b)
                let relative = luma / reference
                let darkness = 1 - MaskMath.smoothstep(0.82, 1.02, relative)

                let value = shape * skin * darkness
                output[index] = max(output[index], value)
            }
        }
    }

    private func computeAverageSkinLuma(
        bytes: [UInt8],
        skinMask: SkinMask
    ) -> Float {
        var sum: Float = 0
        var count = 0
        for index in skinMask.values.indices where skinMask.values[index] > 0.3 {
            let offset = index * 4
            let r = Float(bytes[offset]) / 255
            let g = Float(bytes[offset + 1]) / 255
            let b = Float(bytes[offset + 2]) / 255
            sum += MaskMath.luma(r: r, g: g, b: b)
            count += 1
        }
        return count > 0 ? sum / Float(count) : 0.5
    }
}
