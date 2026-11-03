import CoreGraphics
import XCTest
import BFAlgorithms
@testable import BFKit

final class SkinRendererTests: XCTestCase {
    func testIdentityParametersKeepPixels() throws {
        let renderer = try makeRenderer()
        let image = try TestSupport.makeImage(
            width: 64,
            height: 48,
            pixel: { x, y in
                (
                    UInt8(40 + x * 3),
                    UInt8(60 + y * 3),
                    UInt8(160),
                    255
                )
            }
        )
        let mask = SkinMask(
            width: 32,
            height: 24,
            values: [Float](repeating: 1, count: 32 * 24)
        )

        let output = try renderer.render(
            image: image,
            skinMask: mask,
            parameters: .none
        )
        let sourceBytes = try TestSupport.rgbaBytes(from: image)
        let outputBytes = try TestSupport.rgbaBytes(from: output)
        XCTAssertEqual(sourceBytes.count, outputBytes.count)

        let maxDifference = zip(sourceBytes, outputBytes)
            .map { abs(Int($0) - Int($1)) }
            .max() ?? 0
        XCTAssertLessThanOrEqual(maxDifference, 1)
    }

    func testStrongBeautyKeepsBackgroundUnchanged() throws {
        let renderer = try makeRenderer()
        let skinRect = CGRect(x: 24, y: 18, width: 32, height: 24)
        let image = try TestSupport.makeImage(
            width: 80,
            height: 60,
            pixel: { x, y in
                if skinRect.contains(CGRect(x: x, y: y, width: 1, height: 1)) {
                    return (210, 160, 130, 255)
                }
                return (30, 80, 200, 255)
            }
        )

        var values = [Float](repeating: 0, count: 40 * 30)
        for y in 9..<21 {
            for x in 12..<28 {
                values[y * 40 + x] = 1
            }
        }
        let mask = SkinMask(width: 40, height: 30, values: values)

        let output = try renderer.render(
            image: image,
            skinMask: mask,
            parameters: BeautyParameters(
                smoothing: 1,
                whitening: 1,
                brightening: 1
            )
        )
        let sourceBytes = try TestSupport.rgbaBytes(from: image)
        let outputBytes = try TestSupport.rgbaBytes(from: output)

        var maxBackgroundDifference = 0
        for y in 0..<60 {
            for x in 0..<80 {
                let isSafeBackground = x < 18 || x >= 62 || y < 12 || y >= 48
                guard isSafeBackground else { continue }
                let offset = (y * 80 + x) * 4
                for channel in 0..<3 {
                    let difference = abs(
                        Int(sourceBytes[offset + channel])
                            - Int(outputBytes[offset + channel])
                    )
                    maxBackgroundDifference = max(
                        maxBackgroundDifference,
                        difference
                    )
                }
            }
        }
        XCTAssertLessThanOrEqual(maxBackgroundDifference, 2)

        let center = (30 * 80 + 40) * 4
        let centerDifference = (0..<3).map {
            abs(Int(sourceBytes[center + $0]) - Int(outputBytes[center + $0]))
        }.max() ?? 0
        XCTAssertGreaterThan(centerDifference, 10)
    }

    func testEmptyMaskReturnsOriginalImage() throws {
        let renderer = try makeRenderer()
        let image = try TestSupport.makeImage(
            width: 16,
            height: 12,
            pixel: { _, _ in (210, 160, 130, 255) }
        )
        let output = try renderer.render(
            image: image,
            skinMask: SkinMask(width: 0, height: 0, values: []),
            parameters: .natural
        )
        XCTAssertEqual(output.width, image.width)
        XCTAssertEqual(output.height, image.height)
    }

    // MARK: - 局部修饰

    func testLocalRetouchOnlyAffectsMaskedRegion() throws {
        let renderer = try makeRenderer()
        let image = try TestSupport.makeImage(
            width: 120,
            height: 90,
            pixel: { _, _ in (200, 155, 125, 255) }
        )
        let skinMask = SkinMask(
            width: 60,
            height: 45,
            values: [Float](repeating: 1, count: 60 * 45)
        )
        let rect = CGRect(x: 8, y: 8, width: 10, height: 10)

        let cases: [(BeautyParameters, RetouchMask, String)] = [
            (
                BeautyParameters(eyeBrightening: 1),
                makeRectMask(width: 60, height: 45, eye: rect),
                "亮眼"
            ),
            (
                BeautyParameters(teethWhitening: 1),
                makeRectMask(width: 60, height: 45, teeth: rect),
                "白牙"
            ),
            (
                BeautyParameters(darkCircleRemoval: 1),
                makeRectMask(width: 60, height: 45, darkCircle: rect),
                "去黑眼圈"
            ),
        ]

        let source = try TestSupport.rgbaBytes(from: image)
        for (parameters, retouch, label) in cases {
            let output = try renderer.render(
                image: image,
                skinMask: skinMask,
                retouchMask: retouch,
                parameters: parameters
            )
            let bytes = try TestSupport.rgbaBytes(from: output)

            let inside = luma(bytes, 120, x: 26, y: 26)
            let outside = luma(bytes, 120, x: 100, y: 70)
            let sourceInside = luma(source, 120, x: 26, y: 26)
            let sourceOutside = luma(source, 120, x: 100, y: 70)

            XCTAssertGreaterThan(
                inside - sourceInside,
                4,
                "\(label)：蒙版内应当被提亮"
            )
            XCTAssertLessThanOrEqual(
                abs(outside - sourceOutside),
                2,
                "\(label)：蒙版外不应变化"
            )
        }
    }

    func testBlemishRemovalHealsDarkSpot() throws {
        let renderer = try makeRenderer()
        let width = 120
        let height = 90
        let spotCenter = (x: 60, y: 45)
        let spotRadius = 5.0

        let image = try TestSupport.makeImage(width: width, height: height) { x, y in
            let dx = Double(x - spotCenter.x)
            let dy = Double(y - spotCenter.y)
            if (dx * dx + dy * dy).squareRoot() <= spotRadius {
                return (138, 96, 74, 255)
            }
            return (214, 168, 138, 255)
        }
        let skinMask = SkinMask(
            width: 60,
            height: 45,
            values: [Float](repeating: 1, count: 60 * 45)
        )

        let output = try renderer.render(
            image: image,
            skinMask: skinMask,
            parameters: BeautyParameters(blemishRemoval: 1)
        )

        let source = try TestSupport.rgbaBytes(from: image)
        let bytes = try TestSupport.rgbaBytes(from: output)

        let spotBefore = luma(source, width, x: spotCenter.x, y: spotCenter.y)
        let spotAfter = luma(bytes, width, x: spotCenter.x, y: spotCenter.y)
        XCTAssertGreaterThan(spotAfter - spotBefore, 12, "痘印应当被提亮")

        let farBefore = luma(source, width, x: 12, y: 12)
        let farAfter = luma(bytes, width, x: 12, y: 12)
        XCTAssertLessThanOrEqual(abs(farAfter - farBefore), 2, "无瑕疵区域不应变化")
    }

    func testBlemishRemovalSurvivesWhitening() throws {
        let renderer = try makeRenderer()
        let width = 120
        let height = 90
        let spotCenter = (x: 60, y: 45)

        let image = try TestSupport.makeImage(width: width, height: height) { x, y in
            let dx = Double(x - spotCenter.x)
            let dy = Double(y - spotCenter.y)
            if (dx * dx + dy * dy).squareRoot() <= 5 {
                return (138, 96, 74, 255)
            }
            return (214, 168, 138, 255)
        }
        let skinMask = SkinMask(
            width: 60,
            height: 45,
            values: [Float](repeating: 1, count: 60 * 45)
        )

        let blemishOnly = try renderer.render(
            image: image,
            skinMask: skinMask,
            parameters: BeautyParameters(blemishRemoval: 1)
        )
        let withWhitening = try renderer.render(
            image: image,
            skinMask: skinMask,
            parameters: BeautyParameters(whitening: 1, blemishRemoval: 1)
        )

        let only = try TestSupport.rgbaBytes(from: blemishOnly)
        let both = try TestSupport.rgbaBytes(from: withWhitening)
        let source = try TestSupport.rgbaBytes(from: image)

        // 美白会整体抬亮，但痘印处的「相对提亮量」不应被抵消
        let spotGainOnly = luma(only, width, x: spotCenter.x, y: spotCenter.y)
            - luma(source, width, x: spotCenter.x, y: spotCenter.y)
        let referenceGain = luma(both, width, x: 12, y: 12)
            - luma(source, width, x: 12, y: 12)
        let spotGainBoth = luma(both, width, x: spotCenter.x, y: spotCenter.y)
            - luma(source, width, x: spotCenter.x, y: spotCenter.y)

        XCTAssertGreaterThan(spotGainOnly, 12)
        XCTAssertGreaterThan(
            spotGainBoth - referenceGain,
            6,
            "开启美白后痘印仍应相对被修复"
        )
    }

    func testLocalRetouchKeepsBackgroundUnchanged() throws {
        let renderer = try makeRenderer()
        let skinRect = CGRect(x: 24, y: 18, width: 32, height: 24)
        let image = try TestSupport.makeImage(
            width: 80,
            height: 60,
            pixel: { x, y in
                if skinRect.contains(CGRect(x: x, y: y, width: 1, height: 1)) {
                    return (210, 160, 130, 255)
                }
                return (30, 80, 200, 255)
            }
        )

        var skinValues = [Float](repeating: 0, count: 40 * 30)
        for y in 9..<21 {
            for x in 12..<28 {
                skinValues[y * 40 + x] = 1
            }
        }
        let skinMask = SkinMask(width: 40, height: 30, values: skinValues)
        let retouch = makeRectMask(
            width: 40,
            height: 30,
            eye: CGRect(x: 14, y: 11, width: 6, height: 5),
            teeth: CGRect(x: 20, y: 11, width: 6, height: 5),
            darkCircle: CGRect(x: 14, y: 17, width: 12, height: 4)
        )

        let output = try renderer.render(
            image: image,
            skinMask: skinMask,
            retouchMask: retouch,
            parameters: BeautyParameters(
                smoothing: 1,
                whitening: 1,
                brightening: 1,
                eyeBrightening: 1,
                teethWhitening: 1,
                darkCircleRemoval: 1,
                blemishRemoval: 1
            )
        )
        let source = try TestSupport.rgbaBytes(from: image)
        let bytes = try TestSupport.rgbaBytes(from: output)

        var maxBackgroundDifference = 0
        for y in 0..<60 {
            for x in 0..<80 {
                let isSafeBackground = x < 18 || x >= 62 || y < 12 || y >= 48
                guard isSafeBackground else { continue }
                let offset = (y * 80 + x) * 4
                for channel in 0..<3 {
                    maxBackgroundDifference = max(
                        maxBackgroundDifference,
                        abs(Int(source[offset + channel]) - Int(bytes[offset + channel]))
                    )
                }
            }
        }
        XCTAssertLessThanOrEqual(maxBackgroundDifference, 2)

        let eyeCenter = (22 * 80 + 34) * 4
        let eyeDifference = (0..<3).map {
            abs(Int(source[eyeCenter + $0]) - Int(bytes[eyeCenter + $0]))
        }.max() ?? 0
        XCTAssertGreaterThan(eyeDifference, 8, "蒙版内应当有明显变化")
    }

    func testSmoothingFlattensTextureButKeepsHighContrastDetail() throws {
        let renderer = try makeRenderer()
        let width = 200
        let height = 150
        let barRange = 30..<50

        // 左半：一条 20 像素宽的深色条（模拟眉毛 / 睫毛根部这类高对比结构）；
        // 右半：低幅度棋盘纹理（模拟毛孔，方差小）。
        // 磨皮只应压平后者，前者必须保留。
        let image = try TestSupport.makeImage(width: width, height: height) { x, y in
            if barRange.contains(x) {
                return (70, 52, 44, 255)
            }
            let texture = (x + y) % 2 == 0 ? 5 : -5
            return (
                UInt8(214 + texture),
                UInt8(168 + texture),
                UInt8(138 + texture),
                255
            )
        }
        let mask = SkinMask(
            width: width / 2,
            height: height / 2,
            values: [Float](repeating: 1, count: (width / 2) * (height / 2))
        )

        let output = try renderer.render(
            image: image,
            skinMask: mask,
            parameters: BeautyParameters(smoothing: 1)
        )
        let source = try TestSupport.rgbaBytes(from: image)
        let bytes = try TestSupport.rgbaBytes(from: output)

        func range(_ data: [UInt8], _ xs: Range<Int>, row: Int) -> Double {
            let values = xs.map { luma(data, width, x: $0, y: row) }
            return (values.max() ?? 0) - (values.min() ?? 0)
        }

        let textureBefore = range(source, 120..<180, row: 30)
        let textureAfter = range(bytes, 120..<180, row: 30)
        XCTAssertGreaterThan(textureBefore, 4, "合成图本身应当有可见纹理")
        XCTAssertLessThan(
            textureAfter,
            textureBefore * 0.5,
            "磨皮应当明显压平低幅度纹理"
        )

        // 深色条中心与远处皮肤的亮度差，磨皮后应当基本保留。
        // 实测最大强度下保留约 79%：滤波窗口比深色条略宽，窗口内混入两侧
        // 皮肤会把条中心抬亮一点，属预期。
        let edgeBefore = luma(source, width, x: 140, y: 30)
            - luma(source, width, x: 40, y: 30)
        let edgeAfter = luma(bytes, width, x: 140, y: 30)
            - luma(bytes, width, x: 40, y: 30)
        XCTAssertGreaterThan(edgeBefore, 80)
        XCTAssertGreaterThan(
            edgeAfter,
            edgeBefore * 0.75,
            "保边滤波不应把高对比结构一起抹掉"
        )
    }

    private func makeRectMask(
        width: Int,
        height: Int,
        eye: CGRect? = nil,
        teeth: CGRect? = nil,
        darkCircle: CGRect? = nil
    ) -> RetouchMask {
        func fill(_ rect: CGRect?) -> [Float] {
            var values = [Float](repeating: 0, count: width * height)
            guard let rect else { return values }
            for y in 0..<height {
                for x in 0..<width {
                    if rect.contains(CGRect(x: x, y: y, width: 1, height: 1)) {
                        values[y * width + x] = 1
                    }
                }
            }
            return values
        }
        return RetouchMask(
            width: width,
            height: height,
            eye: fill(eye),
            teeth: fill(teeth),
            darkCircle: fill(darkCircle)
        )
    }

    private func luma(_ bytes: [UInt8], _ width: Int, x: Int, y: Int) -> Double {
        let offset = (y * width + x) * 4
        return 0.299 * Double(bytes[offset])
            + 0.587 * Double(bytes[offset + 1])
            + 0.114 * Double(bytes[offset + 2])
    }

    private func makeRenderer() throws -> SkinRenderer {
        do {
            return try SkinRenderer()
        } catch {
            throw XCTSkip("Metal 不可用：\(error.localizedDescription)")
        }
    }
}
