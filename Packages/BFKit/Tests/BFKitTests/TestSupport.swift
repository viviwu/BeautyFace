import CoreGraphics
import Foundation
import XCTest
@testable import BFKit

enum TestSupport {
    static func sampleImageURL(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("SampleImages/\(name)")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path),
            "SampleImages 不可用"
        )
        return url
    }

    static func makeImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = r
                bytes[offset + 1] = g
                bytes[offset + 2] = b
                bytes[offset + 3] = a
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw TestSupportError.cannotCreateImage
        }
        return image
    }

    static func rgbaBytes(from image: CGImage) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard drawn else {
            throw TestSupportError.cannotCreateImage
        }
        return bytes
    }
}

enum TestSupportError: Error {
    case cannotCreateImage
}

/// 合成人像：肤色椭圆脸 + 眼白/虹膜 + 口内牙齿 + 眼下暗沉。
///
/// 全部使用归一化坐标（原点左下角，与 Vision 一致），便于直接构造关键点；
/// 用于在没有人脸素材的情况下稳定验证局部修饰蒙版的几何位置。
enum SyntheticFace {
    static let width = 240
    static let height = 240

    static let leftEyeRect = CGRect(x: 0.28, y: 0.60, width: 0.16, height: 0.08)
    static let rightEyeRect = CGRect(x: 0.56, y: 0.60, width: 0.16, height: 0.08)
    static let innerLipsRect = CGRect(x: 0.38, y: 0.385, width: 0.24, height: 0.040)
    static let outerLipsRect = CGRect(x: 0.34, y: 0.340, width: 0.32, height: 0.130)

    static let irisRadius: CGFloat = 0.017
    /// 眼下暗沉椭圆，位置需落在去黑眼圈判据的搜索范围内。
    static let darkCircleCenters = [
        CGPoint(x: 0.36, y: 0.544),
        CGPoint(x: 0.64, y: 0.544),
    ]
    static let darkCircleRadius = CGSize(width: 0.062, height: 0.026)

    static let skinColor: (UInt8, UInt8, UInt8) = (214, 168, 138)
    static let scleraColor: (UInt8, UInt8, UInt8) = (238, 238, 238)
    static let irisColor: (UInt8, UInt8, UInt8) = (55, 42, 33)
    static let teethColor: (UInt8, UInt8, UInt8) = (232, 230, 225)
    static let lipsColor: (UInt8, UInt8, UInt8) = (185, 95, 90)
    static let darkCircleColor: (UInt8, UInt8, UInt8) = (170, 120, 95)
    static let backgroundColor: (UInt8, UInt8, UInt8) = (30, 60, 120)

    static func makeImage() throws -> CGImage {
        let w = width
        let h = height
        return try TestSupport.makeImage(width: w, height: h) { x, y in
            let u = (CGFloat(x) + 0.5) / CGFloat(w)
            let v = 1 - (CGFloat(y) + 0.5) / CGFloat(h)

            func inEllipse(_ center: CGPoint, _ radius: CGSize) -> Bool {
                let dx = (u - center.x) / radius.width
                let dy = (v - center.y) / radius.height
                return dx * dx + dy * dy <= 1
            }

            for rect in [leftEyeRect, rightEyeRect] where rect.contains(CGPoint(x: u, y: v)) {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                if inEllipse(center, CGSize(width: irisRadius, height: irisRadius * 1.4)) {
                    return (irisColor.0, irisColor.1, irisColor.2, 255)
                }
                return (scleraColor.0, scleraColor.1, scleraColor.2, 255)
            }

            if innerLipsRect.contains(CGPoint(x: u, y: v)) {
                return (teethColor.0, teethColor.1, teethColor.2, 255)
            }
            if outerLipsRect.contains(CGPoint(x: u, y: v)) {
                return (lipsColor.0, lipsColor.1, lipsColor.2, 255)
            }
            for center in darkCircleCenters
            where inEllipse(center, darkCircleRadius) {
                return (darkCircleColor.0, darkCircleColor.1, darkCircleColor.2, 255)
            }

            let faceCenter = CGPoint(x: 0.5, y: 0.55)
            if inEllipse(faceCenter, CGSize(width: 0.30, height: 0.34)) {
                return (skinColor.0, skinColor.1, skinColor.2, 255)
            }
            return (backgroundColor.0, backgroundColor.1, backgroundColor.2, 255)
        }
    }

    static func makeDetection() -> DetectionResult {
        func corners(_ rect: CGRect) -> [CGPoint] {
            [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
            ]
        }

        let leftEye = corners(leftEyeRect)
        let rightEye = corners(rightEyeRect)
        let outerLips = corners(outerLipsRect)
        let innerLips = corners(innerLipsRect)

        let landmarks = FaceLandmarks(
            allPoints: leftEye + rightEye + outerLips + innerLips,
            faceContour: [],
            leftEye: leftEye,
            rightEye: rightEye,
            leftEyebrow: [],
            rightEyebrow: [],
            nose: [],
            noseCrest: [],
            medianLine: [],
            outerLips: outerLips,
            innerLips: innerLips,
            leftPupil: [CGPoint(x: leftEyeRect.midX, y: leftEyeRect.midY)],
            rightPupil: [CGPoint(x: rightEyeRect.midX, y: rightEyeRect.midY)]
        )

        let face = FaceObservation(
            boundingBox: CGRect(x: 0.2, y: 0.21, width: 0.6, height: 0.68),
            roll: 0,
            yaw: 0,
            confidence: 1,
            landmarks: landmarks
        )

        return DetectionResult(
            imageSize: CGSize(width: width, height: height),
            faces: [face],
            personMask: nil
        )
    }

    /// 将归一化（左下原点）坐标换算为图像像素坐标（左上原点）。
    static func pixel(_ point: CGPoint, in size: CGSize) -> (x: Int, y: Int) {
        (
            Int((point.x * size.width).rounded(.down)),
            Int(((1 - point.y) * size.height).rounded(.down))
        )
    }
}
