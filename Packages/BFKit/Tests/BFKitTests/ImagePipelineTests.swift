import XCTest
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
@testable import BFKit

final class ImagePipelineTests: XCTestCase {
    func testIdentityRoundTripKeepsPixelsWithinOneGrayLevel() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "Metal 不可用")
        let source = try makeTestImage(width: 96, height: 64)
        let sourceData = try rawEncode(source, type: .png, properties: [:])
        let decodedSource = try ImageDecoder.decode(data: sourceData)

        let converter = try TextureConverter()
        let pipeline = ImagePipeline(converter: converter)
        let processed = try pipeline.process(decodedSource)
        XCTAssertTrue(processed.usedWorkingTexture)

        let outputData = try ImageEncoder.data(
            processed.image,
            metadata: processed.metadata,
            type: .png
        )
        let decodedOutput = try ImageDecoder.decode(data: outputData)

        let sourceBytes = rgbaBytes(of: decodedSource.image)
        let outputBytes = rgbaBytes(of: decodedOutput.image)
        XCTAssertEqual(sourceBytes.count, outputBytes.count)

        var maxDifference = 0
        for index in 0..<sourceBytes.count {
            maxDifference = max(
                maxDifference,
                abs(Int(sourceBytes[index]) - Int(outputBytes[index]))
            )
        }
        XCTAssertLessThanOrEqual(maxDifference, 1)
    }

    func testDownscalesToConfiguredLongEdge() throws {
        let source = try makeTestImage(width: 2000, height: 500)
        let data = try rawEncode(source, type: .png, properties: [:])
        let decoded = try ImageDecoder.decode(data: data, maxLongEdge: 1000)

        XCTAssertTrue(decoded.wasDownscaled)
        XCTAssertEqual(decoded.originalSize, CGSize(width: 2000, height: 500))
        XCTAssertEqual(decoded.image.width, 1000)
        XCTAssertEqual(decoded.image.height, 250)
    }

    func testDoesNotUpscaleSmallImage() throws {
        let source = try makeTestImage(width: 120, height: 80)
        let data = try rawEncode(source, type: .png, properties: [:])
        let decoded = try ImageDecoder.decode(data: data, maxLongEdge: 4096)

        XCTAssertFalse(decoded.wasDownscaled)
        XCTAssertEqual(decoded.image.width, 120)
        XCTAssertEqual(decoded.image.height, 80)
    }

    func testOrientationIsAppliedAndResetOnEncode() throws {
        let source = try makeTestImage(width: 80, height: 40)
        let fixture = try rawEncode(
            source,
            type: .jpeg,
            properties: [kCGImagePropertyOrientation: 6]
        )

        let decoded = try ImageDecoder.decode(data: fixture)
        XCTAssertEqual(decoded.metadata.orientation, .right)
        XCTAssertEqual(decoded.originalSize, CGSize(width: 40, height: 80))
        XCTAssertEqual(decoded.image.width, 40)
        XCTAssertEqual(decoded.image.height, 80)

        let processed = try ImagePipeline().process(decoded)
        let output = try ImageEncoder.data(
            processed.image,
            metadata: processed.metadata,
            type: .jpeg
        )
        let outputProperties = try properties(of: output)
        XCTAssertEqual(
            (outputProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue,
            1
        )
        XCTAssertEqual(
            (outputProperties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            40
        )
        XCTAssertEqual(
            (outputProperties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            80
        )
    }

    func testEXIFMetadataIsPreservedAndDimensionsUpdated() throws {
        let source = try makeTestImage(width: 120, height: 90)
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "BeautyFace"]
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2026:11:03 12:00:00",
        ]
        let sourceProperties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: tiff,
            kCGImagePropertyExifDictionary: exif,
        ]
        let fixture = try rawEncode(source, type: .jpeg, properties: sourceProperties)
        let decoded = try ImageDecoder.decode(data: fixture)
        let processed = try ImagePipeline().process(decoded)
        let output = try ImageEncoder.data(
            processed.image,
            metadata: processed.metadata,
            type: .jpeg,
            quality: 1.0
        )
        let outputProperties = try properties(of: output)

        let outputTIFF = outputProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(outputTIFF?[kCGImagePropertyTIFFMake] as? String, "BeautyFace")

        let outputEXIF = outputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertEqual(
            outputEXIF?[kCGImagePropertyExifDateTimeOriginal] as? String,
            "2026:11:03 12:00:00"
        )
        XCTAssertEqual(
            (outputEXIF?[kCGImagePropertyExifPixelXDimension] as? NSNumber)?.intValue,
            120
        )
        XCTAssertEqual(
            (outputEXIF?[kCGImagePropertyExifPixelYDimension] as? NSNumber)?.intValue,
            90
        )
    }

    private func makeTestImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8((x * 255) / max(width - 1, 1))
                pixels[index + 1] = UInt8((y * 255) / max(height - 1, 1))
                pixels[index + 2] = UInt8(((x + y) * 255) / max(width + height - 2, 1))
                pixels[index + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
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
            throw TestError.cannotCreateImage
        }
        return image
    }

    private func rawEncode(
        _ image: CGImage,
        type: UTType,
        properties: [CFString: Any]
    ) throws -> Data {
        guard let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                output,
                type.identifier as CFString,
                1,
                nil
              ) else {
            throw TestError.cannotEncode
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TestError.cannotEncode
        }
        return output as Data
    }

    private func properties(of data: Data) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            throw TestError.cannotDecode
        }
        return properties
    }

    private func rgbaBytes(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        let colorSpace = image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
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
                return
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}

private enum TestError: Error {
    case cannotCreateImage
    case cannotEncode
    case cannotDecode
}
