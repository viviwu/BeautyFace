import CoreGraphics
import BFAlgorithms

/// 把 Vision 关键点转换为脸型形变所需的 `FaceGeometry`。
///
/// Vision 关键点是图像归一化坐标、左下角为原点；`FaceGeometry` 使用
/// 像素坐标且保持 y 向上，两者纵向一致，只需按宽高缩放。
public enum FaceGeometryConverter {
    public static func convert(
        _ face: FaceObservation,
        imageSize: CGSize
    ) -> FaceGeometry? {
        guard let landmarks = face.landmarks else { return nil }
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        func points(_ region: FaceLandmarkRegion) -> [Point2] {
            landmarks.points(for: region).map { point in
                Point2(
                    Float(point.x * imageSize.width),
                    Float(point.y * imageSize.height)
                )
            }
        }

        func first(_ region: FaceLandmarkRegion) -> Point2? {
            points(region).first
        }

        let geometry = FaceGeometry(
            contour: points(.faceContour),
            leftEye: points(.leftEye),
            rightEye: points(.rightEye),
            leftEyebrow: points(.leftEyebrow),
            rightEyebrow: points(.rightEyebrow),
            nose: points(.nose),
            outerLips: points(.outerLips),
            innerLips: points(.innerLips),
            leftPupil: first(.leftPupil),
            rightPupil: first(.rightPupil)
        )
        guard !geometry.contour.isEmpty else { return nil }
        return geometry
    }

    /// 批量转换，跳过无法转换的人脸。
    public static func convert(
        detection: DetectionResult
    ) -> [FaceGeometry] {
        detection.faces.compactMap {
            convert($0, imageSize: detection.imageSize)
        }
    }
}
