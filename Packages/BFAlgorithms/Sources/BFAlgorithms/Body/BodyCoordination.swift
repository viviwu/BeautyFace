/// M8 组合权重表：`max(M5 径向衰减, 有向颈部走廊) × 人像蒙版门`。
///
/// - `personMask == nil` / 空蒙版：逐元素返回 M5 的 `falloffTable`，保证既有
///   测试与合成图断言位精确不变，也是分割失败 / `--no-mask` 的降级路径。
/// - 空间取 `max`：脸部内 M5 权重约为 1，不被改动；多脸走廊取并集。
/// - 蒙版取乘积：`m < maskEpsilon` 处严格 0，边界用 `smoothstep` 软阈值。
/// - 不新增 MLS 场、控制点、渲染 pass 或纹理；只在 `DisplacementField.solve`
///   里替换一次权重表。
public enum BodyCoordination {
    /// 便于调试 / 单测直接调用的入口：内部重算一次 M5 径向衰减。
    public static func weightTable(
        faces: [FaceGeometry],
        imageSize: (width: Int, height: Int),
        columns: Int,
        rows: Int,
        config: DisplacementField.Config,
        mask: PersonMaskGrid?
    ) -> [Float] {
        let radial = DisplacementField.falloffTable(
            faces: faces,
            imageSize: imageSize,
            columns: columns,
            rows: rows,
            config: config
        )
        return weightTable(
            radial: radial,
            faces: faces,
            imageSize: imageSize,
            columns: columns,
            rows: rows,
            config: config,
            mask: mask
        )
    }

    /// `DisplacementField.solve` 使用的入口：复用已经算好的径向表，避免重复求解。
    public static func weightTable(
        radial: [Float],
        faces: [FaceGeometry],
        imageSize: (width: Int, height: Int),
        columns: Int,
        rows: Int,
        config: DisplacementField.Config,
        mask: PersonMaskGrid?
    ) -> [Float] {
        guard columns > 0, rows > 0 else { return radial }
        guard radial.count == columns * rows else { return radial }
        guard let mask, !mask.isEmpty else { return radial }

        let models = NeckShoulderEstimator.models(
            faces: faces,
            imageSize: imageSize,
            config: config,
            mask: mask
        )
        guard !models.isEmpty else { return radial }

        let width = Float(max(imageSize.width - 1, 1))
        let height = Float(max(imageSize.height - 1, 1))
        let stepX = width / Float(max(columns - 1, 1))
        let stepY = height / Float(max(rows - 1, 1))
        var table = radial

        for row in 0..<rows {
            let y = Float(row) * stepY
            let v = y / height
            for column in 0..<columns {
                let x = Float(column) * stepX
                let u = x / width
                let index = row * columns + column

                var neck: Float = 0
                for model in models {
                    neck = max(neck, neckWeight(
                        model: model,
                        x: x,
                        y: y,
                        config: config
                    ))
                }
                // 门控只作用于**新增的颈部走廊**，不碰原有径向衰减：
                //   W = max(radial, neck × gate)
                // 第三轮调参（效果优先）。原方案 `max(radial, neck) × gate`
                // 会在人像分割边界把脸部原有的 radial 权重一并砍掉——
                // IMG_0789 是头部特写，蒙版在脸缘内缩，实测脸部最大位移
                // 从 38.8px 掉到 19.0px 并触发强度回退到 0.49，明显退化。
                // 新组合：
                // - 脸部内 radial≈1，与 M8 之前逐像素一致；
                // - 走廊内人像外 neck×gate=0，radial 本就为 0 → 严格 0；
                // - 肩线以下 neck=0、radial=0 → 严格 0。
                //
                // 羽化半径取约一个网格步长：Vision 分割接近硬二值，单点
                // 门控会在边界形成阶跃，把雅可比压到 ≤ 0。3×3 邻域平均
                // 摊成软过渡，中心值仍保证纯背景严格 0。
                let gate = maskGate(
                    mask,
                    u: u,
                    v: v,
                    config: config,
                    featherU: 1 / Float(max(columns - 1, 1)),
                    featherV: 1 / Float(max(rows - 1, 1))
                )
                table[index] = max(radial[index], neck * gate)
            }
        }
        return table
    }

    /// 单张脸的有向颈部走廊权重。只在下巴以下、窄横向走廊内非零，
    /// 肩线处为 0、颈根处为 1；`upperCut` 防止头顶出现竖直位移带。
    public static func neckWeight(
        model: NeckShoulderModel,
        x: Float,
        y: Float,
        config: DisplacementField.Config
    ) -> Float {
        guard model.neckRootY > model.shoulderY,
              model.faceHeight > 0,
              model.outerHalfWidth > 0 else { return 0 }

        let upperCut = Math.smoothstep(
            model.neckRootY + config.neckUpperCutFactor * model.faceHeight,
            model.neckRootY,
            y
        )
        let vTaper = Math.smoothstep(
            model.shoulderY,
            model.neckRootY,
            y
        ) * upperCut
        let lateral = abs(x - model.axisX)
        let lTaper = Math.smoothstep(
            model.outerHalfWidth,
            model.innerHalfWidth,
            lateral
        )
        return vTaper * lTaper
    }

    /// 人像蒙版门：蒙版外严格 0，蒙版内软阈值到 1。
    ///
    /// `featherU / featherV` 为非零时做 3×3 邻域平均。Vision 的
    /// `VNGeneratePersonSegmentationRequest` 输出接近硬二值，单点采样会让
    /// 门控在边界从 0 直接跳到 1；乘到位移上就是一阶不连续，有限差分
    /// 求雅可比时为负，触发 `DisplacementField.solve` 的整体强度回退。
    /// 邻域平均把边界摊成软过渡；中心值仍用于「蒙版外严格 0」的硬判据。
    public static func maskGate(
        _ mask: PersonMaskGrid?,
        u: Float,
        v: Float,
        config: DisplacementField.Config,
        featherU: Float = 0,
        featherV: Float = 0
    ) -> Float {
        guard let mask, !mask.isEmpty else { return 0 }
        let center = mask.sample(u: u, v: v)
        guard center >= config.maskEpsilon else { return 0 }

        let value: Float
        if featherU > 0 || featherV > 0 {
            var sum: Float = 0
            for dy in -1...1 {
                for dx in -1...1 {
                    sum += mask.sample(
                        u: u + Float(dx) * featherU,
                        v: v + Float(dy) * featherV
                    )
                }
            }
            value = sum / 9
        } else {
            value = center
        }
        return Math.smoothstep(
            config.maskGateLow,
            config.maskGateHigh,
            value
        )
    }
}
