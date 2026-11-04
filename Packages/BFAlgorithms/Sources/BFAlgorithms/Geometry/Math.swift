/// 一维平滑插值等基础数学工具。
public enum Math {
    /// GLSL 语义的 smoothstep。允许 `edge0 > edge1`（此时随 x 增大而衰减）。
    public static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let span = edge1 - edge0
        guard abs(span) > 1e-9 else { return x < edge0 ? 0 : 1 }
        var t = (x - edge0) / span
        t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 把单调递增的 `taper`（0...1）向「后段集中」陡化：blend 0 返回原函数，
    /// 1 返回其平方。两端固定为 0 / 1，单调性与 C1 连续性保持不变。
    /// 等价于在 t 与 t² 之间线性插值，避免引入 pow 依赖（ADR-005）。
    public static func sharpen(_ taper: Float, blend: Float) -> Float {
        let b = min(max(blend, 0), 1)
        return taper * (1 + b * (taper - 1))
    }
}
