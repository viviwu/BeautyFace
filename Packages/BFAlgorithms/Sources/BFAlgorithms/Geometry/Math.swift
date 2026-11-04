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
}
