import CoreGraphics
import XCTest
import BFAlgorithms
@testable import BFKit

final class BeautyEngineTests: XCTestCase {
    func testPreviewPipelineProducesBeautyResultWhenAvailable() throws {
        let url = try TestSupport.sampleImageURL(named: "musk.jpeg")
        let engine = try makeEngine()
        let result = try engine.process(
            url: url,
            parameters: .natural,
            quality: .preview
        )

        XCTAssertEqual(result.quality, .preview)
        XCTAssertLessThanOrEqual(
            max(result.image.width, result.image.height),
            1024
        )
        XCTAssertEqual(
            max(result.skinMask.width, result.skinMask.height),
            256
        )
        XCTAssertGreaterThanOrEqual(result.detection.faces.count, 1)
        XCTAssertGreaterThan(result.skinMask.averageValue, 0.005)
        XCTAssertGreaterThan(result.image.width, 0)
        XCTAssertGreaterThan(result.image.height, 0)

        let debug = try XCTUnwrap(
            DetectionDebugRenderer.render(
                image: result.image,
                result: result.detection,
                skinMask: result.skinMask
            )
        )
        XCTAssertEqual(debug.width, result.image.width)
        XCTAssertEqual(debug.height, result.image.height)
    }

    func testPreviewKeepsBackgroundPixelsWhenAvailable() throws {
        let url = try TestSupport.sampleImageURL(named: "musk.jpeg")
        let engine = try makeEngine()
        let result = try engine.process(
            url: url,
            parameters: BeautyParameters(
                smoothing: 1,
                whitening: 1,
                brightening: 1
            ),
            quality: .preview
        )
        let original = try ImageDecoder.decode(
            url: url,
            maxLongEdge: BeautyQuality.preview.maxLongEdge
        ).image

        let sourceBytes = try TestSupport.rgbaBytes(from: original)
        let outputBytes = try TestSupport.rgbaBytes(from: result.image)
        XCTAssertEqual(sourceBytes.count, outputBytes.count)

        let width = result.image.width
        let height = result.image.height
        let mask = result.skinMask
        var checkedPixels = 0
        var maxDifference = 0

        for y in 0..<height {
            let v = (Float(y) + 0.5) / Float(height)
            let maskY = v * Float(mask.height) - 0.5
            let y0 = Int(floor(maskY))
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let maskX = u * Float(mask.width) - 0.5
                let x0 = Int(floor(maskX))

                func maskValue(_ x: Int, _ y: Int) -> Float {
                    let cx = min(max(x, 0), mask.width - 1)
                    let cy = min(max(y, 0), mask.height - 1)
                    return mask.value(x: cx, y: cy) ?? 0
                }

                let neighbors = [
                    maskValue(x0, y0),
                    maskValue(x0 + 1, y0),
                    maskValue(x0, y0 + 1),
                    maskValue(x0 + 1, y0 + 1),
                ]
                guard neighbors.allSatisfy({ $0 < 0.001 }) else {
                    continue
                }

                checkedPixels += 1
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    let difference = abs(
                        Int(sourceBytes[offset + channel])
                            - Int(outputBytes[offset + channel])
                    )
                    maxDifference = max(maxDifference, difference)
                }
            }
        }

        XCTAssertGreaterThan(checkedPixels, width * height / 5)
        XCTAssertLessThanOrEqual(maxDifference, 1)
    }

    func testFullPipelineKeepsWorkingLimitWhenAvailable() throws {
        let url = try TestSupport.sampleImageURL(named: "musk.jpeg")
        let engine = try makeEngine()
        let result = try engine.process(
            url: url,
            parameters: BeautyParameters(
                smoothing: 0.5,
                whitening: 0.4,
                brightening: 0.3
            ),
            quality: .full
        )

        XCTAssertEqual(result.quality, .full)
        XCTAssertLessThanOrEqual(
            max(result.image.width, result.image.height),
            WorkingLimits.maxLongEdge
        )
        XCTAssertEqual(
            max(result.skinMask.width, result.skinMask.height),
            min(512, max(result.image.width, result.image.height))
        )
        XCTAssertGreaterThanOrEqual(result.detection.faces.count, 1)
        XCTAssertGreaterThan(result.skinMask.averageValue, 0.005)
    }

    /// 全部参数拉满（含局部修饰）时，皮肤蒙版与局部蒙版之外的像素必须保持不变。
    func testLocalRetouchKeepsBackgroundWhenAvailable() throws {
        let url = try TestSupport.sampleImageURL(named: "musk.jpeg")
        let engine = try makeEngine()
        let result = try engine.process(
            url: url,
            parameters: BeautyParameters(
                smoothing: 1,
                whitening: 1,
                brightening: 1,
                eyeBrightening: 1,
                teethWhitening: 1,
                darkCircleRemoval: 1,
                blemishRemoval: 1
            ),
            quality: .preview
        )

        XCTAssertFalse(result.retouchMask.isEmpty, "应生成局部修饰蒙版")

        let original = try ImageDecoder.decode(
            url: url,
            maxLongEdge: BeautyQuality.preview.maxLongEdge
        ).image
        let sourceBytes = try TestSupport.rgbaBytes(from: original)
        let outputBytes = try TestSupport.rgbaBytes(from: result.image)
        XCTAssertEqual(sourceBytes.count, outputBytes.count)

        let width = result.image.width
        let height = result.image.height
        let skin = result.skinMask
        let retouch = result.retouchMask

        var checkedPixels = 0
        var maxDifference = 0

        for y in 0..<height {
            let v = (Float(y) + 0.5) / Float(height)
            let skinY = v * Float(skin.height) - 0.5
            let retouchY = v * Float(retouch.height) - 0.5
            let sy0 = Int(floor(skinY))
            let ry0 = Int(floor(retouchY))
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let skinX = u * Float(skin.width) - 0.5
                let retouchX = u * Float(retouch.width) - 0.5
                let sx0 = Int(floor(skinX))
                let rx0 = Int(floor(retouchX))

                // 与着色器一致：检查双线性采样的四个邻点，全部为 0 才算蒙版外
                func skinValue(_ x: Int, _ y: Int) -> Float {
                    let cx = min(max(x, 0), skin.width - 1)
                    let cy = min(max(y, 0), skin.height - 1)
                    return skin.value(x: cx, y: cy) ?? 0
                }
                func retouchValue(_ x: Int, _ y: Int) -> Float {
                    let cx = min(max(x, 0), retouch.width - 1)
                    let cy = min(max(y, 0), retouch.height - 1)
                    let index = cy * retouch.width + cx
                    return max(
                        retouch.eye[index],
                        max(retouch.teeth[index], retouch.darkCircle[index])
                    )
                }

                let skinNeighbors = [
                    skinValue(sx0, sy0), skinValue(sx0 + 1, sy0),
                    skinValue(sx0, sy0 + 1), skinValue(sx0 + 1, sy0 + 1),
                ]
                let retouchNeighbors = [
                    retouchValue(rx0, ry0), retouchValue(rx0 + 1, ry0),
                    retouchValue(rx0, ry0 + 1), retouchValue(rx0 + 1, ry0 + 1),
                ]
                guard skinNeighbors.allSatisfy({ $0 < 0.001 }),
                      retouchNeighbors.allSatisfy({ $0 < 0.001 }) else {
                    continue
                }

                checkedPixels += 1
                let offset = (y * width + x) * 4
                for channel in 0..<3 {
                    maxDifference = max(
                        maxDifference,
                        abs(
                            Int(sourceBytes[offset + channel])
                                - Int(outputBytes[offset + channel])
                        )
                    )
                }
            }
        }

        XCTAssertGreaterThan(checkedPixels, width * height / 5)
        XCTAssertLessThanOrEqual(maxDifference, 1)
    }

    private func makeEngine() throws -> BeautyEngine {
        do {
            return try BeautyEngine()
        } catch {
            throw XCTSkip("Metal 不可用：\(error.localizedDescription)")
        }
    }
}
