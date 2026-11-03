import CoreGraphics

public enum FaceLandmarkRegion: CaseIterable, Sendable {
    case faceContour
    case leftEye
    case rightEye
    case leftEyebrow
    case rightEyebrow
    case nose
    case noseCrest
    case medianLine
    case outerLips
    case innerLips
    case leftPupil
    case rightPupil
}

/// 关键点坐标均为图像归一化坐标，原点在左下角（与 Vision 一致）。
public struct FaceLandmarks: Sendable {
    public let allPoints: [CGPoint]
    public let faceContour: [CGPoint]
    public let leftEye: [CGPoint]
    public let rightEye: [CGPoint]
    public let leftEyebrow: [CGPoint]
    public let rightEyebrow: [CGPoint]
    public let nose: [CGPoint]
    public let noseCrest: [CGPoint]
    public let medianLine: [CGPoint]
    public let outerLips: [CGPoint]
    public let innerLips: [CGPoint]
    public let leftPupil: [CGPoint]
    public let rightPupil: [CGPoint]

    public init(
        allPoints: [CGPoint],
        faceContour: [CGPoint],
        leftEye: [CGPoint],
        rightEye: [CGPoint],
        leftEyebrow: [CGPoint],
        rightEyebrow: [CGPoint],
        nose: [CGPoint],
        noseCrest: [CGPoint],
        medianLine: [CGPoint],
        outerLips: [CGPoint],
        innerLips: [CGPoint],
        leftPupil: [CGPoint],
        rightPupil: [CGPoint]
    ) {
        self.allPoints = allPoints
        self.faceContour = faceContour
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.leftEyebrow = leftEyebrow
        self.rightEyebrow = rightEyebrow
        self.nose = nose
        self.noseCrest = noseCrest
        self.medianLine = medianLine
        self.outerLips = outerLips
        self.innerLips = innerLips
        self.leftPupil = leftPupil
        self.rightPupil = rightPupil
    }

    public func points(for region: FaceLandmarkRegion) -> [CGPoint] {
        switch region {
        case .faceContour: return faceContour
        case .leftEye: return leftEye
        case .rightEye: return rightEye
        case .leftEyebrow: return leftEyebrow
        case .rightEyebrow: return rightEyebrow
        case .nose: return nose
        case .noseCrest: return noseCrest
        case .medianLine: return medianLine
        case .outerLips: return outerLips
        case .innerLips: return innerLips
        case .leftPupil: return leftPupil
        case .rightPupil: return rightPupil
        }
    }
}
