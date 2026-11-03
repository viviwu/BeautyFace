enum MaskMath {
    static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
        guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func band(
        _ value: Float,
        low: Float,
        high: Float,
        feather: Float
    ) -> Float {
        smoothstep(low - feather, low, value)
            * (1 - smoothstep(high, high + feather, value))
    }

    static func luma(r: Float, g: Float, b: Float) -> Float {
        0.299 * r + 0.587 * g + 0.114 * b
    }

    static func saturation(r: Float, g: Float, b: Float) -> Float {
        max(r, max(g, b)) - min(r, min(g, b))
    }

    /// 取样本的百分位值（0...1），用于自适应阈值。
    static func percentile(_ values: [Float], _ fraction: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = Int((Float(sorted.count - 1) * clamped).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
