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

    private func makeRenderer() throws -> SkinRenderer {
        do {
            return try SkinRenderer()
        } catch {
            throw XCTSkip("Metal 不可用：\(error.localizedDescription)")
        }
    }
}
