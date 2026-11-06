import BFAlgorithms

/// M8：把 Vision 人像分割结果转成算法层的纯 Swift 网格（ADR-005）。
///
/// 行序约定（由 `BFKitTests.BodyCoordinationTests.testPersonMaskOrientation` 锁定）：
/// - `SegmentationMask.pixels` 与 `PersonMaskGrid.values` 都是行优先，
///   **row 0 = 图像上沿**，与 `SkinMaskGenerator.samplePersonMask` 的既有用法一致。
/// - 算法层 `FaceGeometry` 与位移网格用 y 向上坐标；`PersonMaskGrid.sample(u:v:)`
///   内部会把 y 向上的 `v` 换算成行序，因此这里**只做 0...255 → 0...1 映射，
///   不做任何翻转**。方向若需修正，只允许改这一处，并同步改测试。
///
/// 分割失败 / 尺寸不一致时返回 nil，`DisplacementField.solve` 会逐元素回退到
/// M5/M6 的 `falloffTable`（R-04 不强行处理）。
public enum PersonMaskConverter {
    public static func convert(_ mask: SegmentationMask?) -> PersonMaskGrid? {
        guard let mask, !mask.isEmpty,
              mask.pixels.count == mask.width * mask.height else {
            return nil
        }

        let scale: Float = 1 / 255
        var values = [Float]()
        values.reserveCapacity(mask.pixels.count)
        for pixel in mask.pixels {
            values.append(Float(pixel) * scale)
        }
        return PersonMaskGrid(
            width: mask.width,
            height: mask.height,
            values: values
        )
    }
}
