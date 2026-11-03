import CoreGraphics

public struct FaceObservation: Sendable {
    /// 归一化人脸框，原点在左下角（与 Vision 一致）。
    public let boundingBox: CGRect
    public let roll: CGFloat?
    public let yaw: CGFloat?
    public let confidence: Float
    public let landmarks: FaceLandmarks?

    public init(
        boundingBox: CGRect,
        roll: CGFloat?,
        yaw: CGFloat?,
        confidence: Float,
        landmarks: FaceLandmarks?
    ) {
        self.boundingBox = boundingBox
        self.roll = roll
        self.yaw = yaw
        self.confidence = confidence
        self.landmarks = landmarks
    }

    /// 像素坐标，原点在左下角。
    public func pixelBoundingBox(in size: CGSize) -> CGRect {
        CGRect(
            x: boundingBox.minX * size.width,
            y: boundingBox.minY * size.height,
            width: boundingBox.width * size.width,
            height: boundingBox.height * size.height
        )
    }

    /// 像素坐标，原点在左上角，便于 UI 与常见图像工具使用。
    public func topLeftPixelBoundingBox(in size: CGSize) -> CGRect {
        CGRect(
            x: boundingBox.minX * size.width,
            y: (1 - boundingBox.maxY) * size.height,
            width: boundingBox.width * size.width,
            height: boundingBox.height * size.height
        )
    }
}
