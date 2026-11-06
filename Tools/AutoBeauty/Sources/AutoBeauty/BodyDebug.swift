import CoreGraphics
import Foundation
import BFAlgorithms
import BFKit

// M8 颈肩调试：权重热图 `_body.png` 与 `--dump-neck` 数值探针。
//
// 坐标约定：权重表 / 位移场网格的 row 0 = y 向上坐标 0 = 图像下沿；
// 输出 PNG 的字节行 0 = 图像上沿。热图生成时按行倒序换算，避免把
// 颈部走廊画到头顶。

struct BodyDebugSnapshot {
    let models: [NeckShoulderModel]
    let weights: [Float]
    /// M5 基线权重（不给蒙版），用于区分「M8 新增」与「M5 原有」。
    let baseline: [Float]
    let columns: Int
    let rows: Int
    let imageSize: (width: Int, height: Int)
    let mask: PersonMaskGrid?
    let config: DisplacementField.Config
}

/// 按与 `DisplacementField.solve` 相同的规则推网格尺寸；有场时直接复用。
private func gridSize(
    field: DisplacementField?,
    imageSize: (width: Int, height: Int),
    config: DisplacementField.Config
) -> (columns: Int, rows: Int) {
    if let field { return (field.columns, field.rows) }
    let longEdge = Float(max(imageSize.width, imageSize.height))
    let scale = Float(config.gridLongEdge) / max(longEdge, 1)
    return (
        max(2, Int((scale * Float(imageSize.width)).rounded())),
        max(2, Int((scale * Float(imageSize.height)).rounded()))
    )
}

func makeBodyDebugSnapshot(
    detection: DetectionResult,
    imageSize: (width: Int, height: Int),
    field: DisplacementField?,
    config: DisplacementField.Config
) -> BodyDebugSnapshot? {
    let faces = FaceGeometryConverter.convert(detection: detection)
    guard !faces.isEmpty, let mask = PersonMaskConverter.convert(detection.personMask) else {
        return nil
    }
    let size = gridSize(field: field, imageSize: imageSize, config: config)
    let weights = BodyCoordination.weightTable(
        faces: faces,
        imageSize: imageSize,
        columns: size.columns,
        rows: size.rows,
        config: config,
        mask: mask
    )
    let baseline = BodyCoordination.weightTable(
        faces: faces,
        imageSize: imageSize,
        columns: size.columns,
        rows: size.rows,
        config: config,
        mask: nil
    )
    let models = NeckShoulderEstimator.models(
        faces: faces,
        imageSize: imageSize,
        config: config,
        mask: mask
    )
    return BodyDebugSnapshot(
        models: models,
        weights: weights,
        baseline: baseline,
        columns: size.columns,
        rows: size.rows,
        imageSize: imageSize,
        mask: mask,
        config: config
    )
}

private func sampleWeight(
    _ snapshot: BodyDebugSnapshot,
    gridX: Float,
    gridY: Float
) -> Float {
    let maxX = Float(snapshot.columns - 1)
    let maxY = Float(snapshot.rows - 1)
    let x = min(max(gridX, 0), maxX)
    let y = min(max(gridY, 0), maxY)
    let x0 = min(Int(x.rounded(.down)), snapshot.columns - 2)
    let y0 = min(Int(y.rounded(.down)), snapshot.rows - 2)
    let fx = x - Float(x0)
    let fy = y - Float(y0)
    func at(_ c: Int, _ r: Int) -> Float {
        snapshot.weights[r * snapshot.columns + c]
    }
    let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
    let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
    return top * (1 - fy) + bottom * fy
}

/// 把权重表渲染成彩色热图，并叠加下巴线 / 颈根 / 肩线 / 走廊边界。
func bodyDebugImage(_ snapshot: BodyDebugSnapshot) -> CGImage? {
    let scale = 6
    let width = snapshot.columns * scale
    let height = snapshot.rows * scale
    guard width > 0, height > 0 else { return nil }

    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for row in 0..<height {
        // 输出行 0 = 图像上沿；权重表 row 0 = 图像下沿
        let gridY = (1 - Float(row) / Float(max(height - 1, 1)))
            * Float(snapshot.rows - 1)
        for column in 0..<width {
            let gridX = Float(column) / Float(max(width - 1, 1))
                * Float(snapshot.columns - 1)
            let w = sampleWeight(snapshot, gridX: gridX, gridY: gridY)
            let offset = (row * width + column) * 4
            // 冷 → 暖：0 深蓝，0.5 品红，1 亮黄
            bytes[offset] = UInt8(min(255, 40 + 215 * w))
            bytes[offset + 1] = UInt8(min(255, 20 + 190 * w * w))
            bytes[offset + 2] = UInt8(min(255, 90 * (1 - w)))
            bytes[offset + 3] = 255
        }
    }

    let imageHeight = Float(max(snapshot.imageSize.height - 1, 1))
    let imageWidth = Float(max(snapshot.imageSize.width - 1, 1))

    func put(_ x: Int, _ y: Int, _ color: (UInt8, UInt8, UInt8)) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let offset = (y * width + x) * 4
        bytes[offset] = color.0
        bytes[offset + 1] = color.1
        bytes[offset + 2] = color.2
        bytes[offset + 3] = 255
    }

    for model in snapshot.models {
        func rasterRow(_ yUp: Float) -> Int {
            Int((1 - yUp / imageHeight) * Float(height - 1))
        }
        func rasterColumn(_ x: Float) -> Int {
            Int((x / imageWidth) * Float(width - 1))
        }
        let left = rasterColumn(model.axisX - model.outerHalfWidth)
        let right = rasterColumn(model.axisX + model.outerHalfWidth)

        func horizontal(_ yUp: Float, _ color: (UInt8, UInt8, UInt8)) {
            let r = rasterRow(yUp)
            for thickness in -1...1 {
                for x in min(left, right)...max(left, right) {
                    put(x, r + thickness, color)
                }
            }
        }
        horizontal(model.chinY, (60, 255, 90))
        horizontal(model.neckRootY, (40, 230, 255))
        horizontal(model.shoulderY, (255, 220, 40))

        let top = rasterRow(model.neckRootY)
        let bottom = rasterRow(model.shoulderY)
        for thickness in -1...1 {
            for y in min(top, bottom)...max(top, bottom) {
                put(left + thickness, y, (255, 255, 255))
                put(right + thickness, y, (255, 255, 255))
            }
        }
    }

    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        return nil
    }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: space,
        bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

/// 颈部中线 33 点剖面 + 肩线 / 蒙版外位移必须为 0 的数值探针。
func bodyDebugLines(
    _ snapshot: BodyDebugSnapshot,
    field: DisplacementField?
) -> [String] {
    var lines: [String] = []
    lines.append("       颈肩（M8）：网格 \(snapshot.columns)×\(snapshot.rows)")

    if let mask = snapshot.mask {
        var histogram = [Int](repeating: 0, count: 11)
        for value in mask.values {
            let bucket = min(10, Int((value * 10).rounded(.down)))
            histogram[bucket] += 1
        }
        let total = Float(max(mask.values.count, 1))
        let distribution = histogram.enumerated().map {
            String(format: "%.1f%%", Float($1) / total * 100)
        }.joined(separator: "/")
        lines.append("         蒙版值分布(0.0→1.0 十档)：\(distribution)")
    }

    for (index, model) in snapshot.models.enumerated() {
        lines.append(String(
            format: "         脸 %d：下巴=%.1f 颈根=%.1f 肩线=%.1f 中轴=%.1f 走廊半宽=%.1f/%.1f 肩线来源=%@",
            index + 1,
            model.chinY,
            model.neckRootY,
            model.shoulderY,
            model.axisX,
            model.innerHalfWidth,
            model.outerHalfWidth,
            model.usedMaskShoulder ? "蒙版宽度突变" : "固定比例兜底"
        ))
        var profile: [String] = []
        for step in 0..<33 {
            let t = Float(step) / 32
            let y = model.neckRootY + (model.shoulderY - model.neckRootY) * t
            let gridY = y / Float(max(snapshot.imageSize.height - 1, 1))
                * Float(snapshot.rows - 1)
            let gridX = model.axisX / Float(max(snapshot.imageSize.width - 1, 1))
                * Float(snapshot.columns - 1)
            profile.append(String(
                format: "%.3f:%.3f", t,
                sampleWeight(snapshot, gridX: gridX, gridY: gridY)
            ))
        }
        lines.append("         颈部中线剖面（t=0 颈根 → 1 肩线，权重）："
            + profile.joined(separator: " "))
    }

    guard let field, field.columns == snapshot.columns,
          field.rows == snapshot.rows else {
        lines.append("         （未启用形变，跳过位移探针）")
        return lines
    }

    let height = Float(max(snapshot.imageSize.height - 1, 1))
    let width = Float(max(snapshot.imageSize.width - 1, 1))
    let stepY = height / Float(max(snapshot.rows - 1, 1))
    let stepX = width / Float(max(snapshot.columns - 1, 1))
    let lowestShoulder = snapshot.models.map(\.shoulderY).min() ?? 0
    var maxBelowShoulder: Float = 0
    var maxOutsideMaskDelta: Float = 0
    var maxOverall: Float = 0
    var maxGain: Float = 0

    for row in 0..<snapshot.rows {
        let y = Float(row) * stepY
        let v = y / height
        for column in 0..<snapshot.columns {
            let x = Float(column) * stepX
            let u = x / width
            let index = row * snapshot.columns + column
            let dx = field.offsetX[index]
            let dy = field.offsetY[index]
            let magnitude = (dx * dx + dy * dy).squareRoot()
            maxOverall = max(maxOverall, magnitude)
            if y < lowestShoulder {
                maxBelowShoulder = max(maxBelowShoulder, magnitude)
            }

            // M8 相对 M5 基线的**权重增量**：蒙版外必须严格 0。
            // 不检查绝对位移，因为 M5 原本就在脸缘有径向形变，那是允许的。
            let gain = max(0, snapshot.weights[index] - snapshot.baseline[index])
            maxGain = max(maxGain, gain)
            let gate = BodyCoordination.maskGate(
                snapshot.mask, u: u, v: v, config: snapshot.config,
                featherU: 1 / Float(max(snapshot.columns - 1, 1)),
                featherV: 1 / Float(max(snapshot.rows - 1, 1))
            )
            if gate <= 0 {
                maxOutsideMaskDelta = max(maxOutsideMaskDelta, gain)
            }
        }
    }
    lines.append(String(
        format: "         权重探针：M8 最大新增权重 %.4f；蒙版外新增 %.6f（须 =0）；肩线以下最大位移 %.4f px（须 ≈0）；全场最大位移 %.2f px",
        maxGain, maxOutsideMaskDelta, maxBelowShoulder, maxOverall
    ))
    if maxBelowShoulder > 0.5 || maxOutsideMaskDelta > 1e-5 {
        lines.append("         ⚠️ 约束未满足：肩线以下仍有位移，或蒙版外出现了 M8 新增权重")
    }
    return lines
}
