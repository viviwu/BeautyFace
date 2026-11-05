/// 脸型形变参数。所有强度均为 0...1，超出范围会被裁剪；
/// 正方向即各项的「增强」方向（见各字段的注释）。
public struct FaceShapeParameters: Equatable, Sendable {
    /// 小脸：整圈轮廓向脸部中心收缩。
    public var faceSize: Float
    /// 瘦脸：下颌区域向面部纵轴收窄。
    public var jawSlim: Float
    /// 窄脸：面颊中部向面部纵轴收窄。
    public var faceNarrow: Float
    /// V 脸：下半张脸向纵轴收窄，权重越靠近下巴越强。
    public var vShape: Float
    /// 下巴：下巴加长并收窄（显尖）。
    public var chin: Float
    /// 额头：上段轮廓下压，额头显小。
    public var forehead: Float
    /// 颧骨：颧骨区域向纵轴收窄。
    public var cheekbone: Float

    public init(
        faceSize: Float = 0,
        jawSlim: Float = 0,
        faceNarrow: Float = 0,
        vShape: Float = 0,
        chin: Float = 0,
        forehead: Float = 0,
        cheekbone: Float = 0
    ) {
        self.faceSize = BeautyParameters.clamp(faceSize)
        self.jawSlim = BeautyParameters.clamp(jawSlim)
        self.faceNarrow = BeautyParameters.clamp(faceNarrow)
        self.vShape = BeautyParameters.clamp(vShape)
        self.chin = BeautyParameters.clamp(chin)
        self.forehead = BeautyParameters.clamp(forehead)
        self.cheekbone = BeautyParameters.clamp(cheekbone)
    }

    public static let none = FaceShapeParameters()

    public var isIdentity: Bool {
        faceSize == 0 && jawSlim == 0 && faceNarrow == 0
            && vShape == 0 && chin == 0 && forehead == 0 && cheekbone == 0
    }
}

/// 脸型形变所需的人脸几何（像素坐标，y 向上）。
///
/// 只携带形变真正需要的区域；由 BFKit 在调用处从 Vision 关键点转换而来，
/// 避免算法层依赖 Apple 框架（ADR-005）。
public struct FaceGeometry: Sendable {
    /// 脸部轮廓：从一侧太阳穴绕下颌到另一侧太阳穴。
    public var contour: [Point2]
    public var leftEye: [Point2]
    public var rightEye: [Point2]
    public var leftEyebrow: [Point2]
    public var rightEyebrow: [Point2]
    public var nose: [Point2]
    public var outerLips: [Point2]
    /// 口内轮廓：仅用于美妆蒙版（口红排除口内），不参与 MLS 形变约束。
    public var innerLips: [Point2]
    public var leftPupil: Point2?
    public var rightPupil: Point2?

    public init(
        contour: [Point2],
        leftEye: [Point2] = [],
        rightEye: [Point2] = [],
        leftEyebrow: [Point2] = [],
        rightEyebrow: [Point2] = [],
        nose: [Point2] = [],
        outerLips: [Point2] = [],
        innerLips: [Point2] = [],
        leftPupil: Point2? = nil,
        rightPupil: Point2? = nil
    ) {
        self.contour = contour
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftEyebrow = leftEyebrow
        self.rightEyebrow = rightEyebrow
        self.nose = nose
        self.outerLips = outerLips
        self.innerLips = innerLips
        self.leftPupil = leftPupil
        self.rightPupil = rightPupil
    }

    /// 五官与轮廓的全部点位，用作 MLS 约束。
    public var allPoints: [Point2] {
        contour + leftEye + rightEye + leftEyebrow + rightEyebrow
            + nose + outerLips
            + [leftPupil, rightPupil].compactMap { $0 }
    }
}
