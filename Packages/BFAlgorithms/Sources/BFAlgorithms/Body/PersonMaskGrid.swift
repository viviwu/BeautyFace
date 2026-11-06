/// M8 人像分割蒙版的纯 Swift 网格（ADR-005：零 import）。
///
/// Vision 的 `CVPixelBuffer` 与 BFKit 的 `SegmentationMask` 都是**行优先、
/// 第 0 行为图像上沿**。本类型保留这个行序，避免跨层反复翻转；算法层
/// 统一用 `FaceGeometry` 的 y 向上坐标，因此 `sample(u:v:)` 的 `v` 也定义为
/// **y 向上归一化坐标**（0 = 下沿，1 = 上沿），内部只在采样时换算一次。
public struct PersonMaskGrid: Sendable {
    public let width: Int
    public let height: Int
    /// 0...1，行优先；`values[row * width + column]`，row 0 = 图像上沿。
    public let values: [Float]

    public var isEmpty: Bool {
        width <= 0 || height <= 0 || values.count != width * height
    }

    public init(width: Int, height: Int, values: [Float]) {
        self.width = max(0, width)
        self.height = max(0, height)
        let count = self.width * self.height
        if values.count == count {
            var clamped: [Float] = []
            clamped.reserveCapacity(count)
            for value in values {
                clamped.append(min(max(value, 0), 1))
            }
            self.values = clamped
        } else {
            // 尺寸不匹配时退化为全 0，调用方会走 M5 兼容路径。
            self.values = [Float](repeating: 0, count: count)
        }
    }

    /// 取整数网格点，越界按边缘截断。
    public func value(x: Int, y: Int) -> Float {
        guard !isEmpty else { return 0 }
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        return values[cy * width + cx]
    }

    /// 归一化双线性采样。`v` 为 y 向上坐标：0 = 图像下沿，1 = 图像上沿。
    public func sample(u: Float, v: Float) -> Float {
        sampleTopDown(u: u, v: 1 - min(max(v, 0), 1))
    }

    /// 归一化双线性采样。`v` 为光栅行序坐标：0 = 图像上沿，1 = 图像下沿。
    public func sampleTopDown(u: Float, v: Float) -> Float {
        guard !isEmpty else { return 0 }
        let uu = min(max(u, 0), 1)
        let vv = min(max(v, 0), 1)

        // 与 SkinMaskGenerator / 位移网格一致，使用像素中心对齐。
        let x = uu * Float(width) - 0.5
        let y = vv * Float(height) - 0.5
        let x0 = Int(x.rounded(.down))
        let y0 = Int(y.rounded(.down))
        let fx = x - Float(x0)
        let fy = y - Float(y0)

        let top = value(x: x0, y: y0) * (1 - fx)
            + value(x: x0 + 1, y: y0) * fx
        let bottom = value(x: x0, y: y0 + 1) * (1 - fx)
            + value(x: x0 + 1, y: y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }
}
