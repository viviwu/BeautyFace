/// 五官形变参数。所有强度均为 0...1，超出范围会被裁剪；
/// 正方向即各项的「美化」方向（见各字段的注释）。
public struct FaceFeatureParameters: Equatable, Sendable {
    /// 大眼：眼眶控制点沿径向放大，纵向幅度大于横向（显有神）。
    public var eyeSize: Float
    /// 眼距：双眼整体向鼻梁靠拢（眼距变窄）。
    public var eyeDistance: Float
    /// 眉间距：双眉整体向眉心靠拢（眉间距变窄）。
    public var browSpacing: Float
    /// 眉毛粗细：眉部区域纵向拉伸（眉毛显浓）。
    public var browThickness: Float
    /// 鼻翼：鼻部控制点向鼻中轴收拢（鼻子显窄）。
    public var noseWidth: Float
    /// 嘴型：嘴角上扬并轻微收窄（显小巧微笑）。
    public var mouthShape: Float

    public init(
        eyeSize: Float = 0,
        eyeDistance: Float = 0,
        browSpacing: Float = 0,
        browThickness: Float = 0,
        noseWidth: Float = 0,
        mouthShape: Float = 0
    ) {
        self.eyeSize = BeautyParameters.clamp(eyeSize)
        self.eyeDistance = BeautyParameters.clamp(eyeDistance)
        self.browSpacing = BeautyParameters.clamp(browSpacing)
        self.browThickness = BeautyParameters.clamp(browThickness)
        self.noseWidth = BeautyParameters.clamp(noseWidth)
        self.mouthShape = BeautyParameters.clamp(mouthShape)
    }

    public static let none = FaceFeatureParameters()

    public var isIdentity: Bool {
        eyeSize == 0 && eyeDistance == 0 && browSpacing == 0
            && browThickness == 0 && noseWidth == 0 && mouthShape == 0
    }
}
