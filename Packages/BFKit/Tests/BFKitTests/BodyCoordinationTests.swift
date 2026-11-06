import CoreGraphics
import XCTest
@testable import BFAlgorithms
@testable import BFKit

/// BFKit 层 M8 测试：跨层数据契约、蒙版方向、一键回退、美妆对齐。
///
/// 坐标约定（由 `testPersonMaskOrientation` 锁定）：
/// - `SegmentationMask.pixels` / `PersonMaskGrid.values`：row 0 = 图像上沿。
/// - `FaceGeometry` / `DisplacementField` 网格：y 向上，row 0 = 图像下沿。
/// - `PersonMaskGrid.sample(u:v:)` 的 `v` 为 y 向上，内部换算成行序；
///   `PersonMaskConverter` 因此**不做任何翻转**，只做 0...255 → 0...1。
final class BodyCoordinationTests: XCTestCase {

    // MARK: - 合成数据

    private let imageSize = (width: 400, height: 400)
    private let columns = 20
    private let rows = 20

    /// 轮廓 y 200...320、下巴在 y=200；瞳孔中轴 x=200。
    private func makeFace() -> FaceGeometry {
        var contour: [Point2] = []
        for index in 0..<17 {
            let theta = Float.pi * (1 - Float(index) / 16)
            contour.append(Point2(
                200 + 50 * cos(theta),
                260 - 60 * sin(theta)
            ))
        }
        func cluster(_ x: Float, _ y: Float) -> [Point2] {
            (0..<4).map { Point2(x + Float($0) * 2, y + Float($0 % 2) * 2) }
        }
        return FaceGeometry(
            contour: contour,
            leftEye: cluster(180, 280),
            rightEye: cluster(220, 280),
            leftEyebrow: cluster(180, 300),
            rightEyebrow: cluster(220, 300),
            nose: cluster(200, 260),
            outerLips: cluster(200, 225),
            innerLips: cluster(200, 225),
            leftPupil: Point2(180, 281),
            rightPupil: Point2(220, 281)
        )
    }

    /// 上/下不对称蒙版。`personInTopHalf` 为 true 时光栅上半为 1、下半为 0。
    private func splitMask(personInTopHalf: Bool) -> SegmentationMask {
        let width = 32, height = 48
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let isPerson = personInTopHalf ? y < height / 2 : y >= height / 2
            if isPerson {
                for x in 0..<width { pixels[y * width + x] = 255 }
            }
        }
        return SegmentationMask(width: width, height: height, pixels: pixels)
    }

    private func weightTable(mask: PersonMaskGrid?) -> [Float] {
        BodyCoordination.weightTable(
            faces: [makeFace()],
            imageSize: imageSize,
            columns: columns,
            rows: rows,
            config: DisplacementField.Config(),
            mask: mask
        )
    }

    private func corridorWeight(_ table: [Float]) -> Float {
        // 颈部中轴 x≈200、y≈168：位于颈根(195)与肩线(141)之间，走廊内。
        // 取 y≈120 会落到肩线以下，那里按设计权重就是 0。
        let column = Int((200 / 399 * Float(columns - 1)).rounded())
        let row = Int((168 / 399 * Float(rows - 1)).rounded())
        return table[row * columns + column]
    }

    // MARK: - Converter

    func testConverterMapsValuesAndRejectsInvalid() throws {
        XCTAssertNil(PersonMaskConverter.convert(nil))
        XCTAssertNil(PersonMaskConverter.convert(
            SegmentationMask(width: 0, height: 0, pixels: [])
        ))
        XCTAssertNil(PersonMaskConverter.convert(
            SegmentationMask(width: 4, height: 4, pixels: [UInt8](repeating: 255, count: 10))
        ))

        let mask = SegmentationMask(
            width: 2, height: 2,
            pixels: [0, 64, 128, 255]
        )
        let grid = try XCTUnwrap(PersonMaskConverter.convert(mask))
        XCTAssertEqual(grid.width, 2)
        XCTAssertEqual(grid.height, 2)
        XCTAssertFalse(grid.isEmpty)
        XCTAssertEqual(grid.value(x: 0, y: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(grid.value(x: 1, y: 0), 64 / 255, accuracy: 1e-6)
        XCTAssertEqual(grid.value(x: 1, y: 1), 1, accuracy: 1e-6)
    }

    // MARK: - 方向锁定（本方案最关键的实测项）

    func testPersonMaskGridYUpSampling() throws {
        let top = try XCTUnwrap(PersonMaskConverter.convert(splitMask(personInTopHalf: true)))
        // y 向上：v→1 是图像上沿（人像内），v→0 是图像下沿（人像外）
        XCTAssertGreaterThan(top.sample(u: 0.5, v: 0.90), 0.9)
        XCTAssertLessThan(top.sample(u: 0.5, v: 0.10), 0.1)
        // 行序坐标反过来看，确认不是双重翻转
        XCTAssertGreaterThan(top.sampleTopDown(u: 0.5, v: 0.10), 0.9)
        XCTAssertLessThan(top.sampleTopDown(u: 0.5, v: 0.90), 0.1)
    }

    /// 上半为人像时，颈部走廊（图像下半）必须被门控为 0；
    /// 下半为人像时走廊必须有非零权重。若 v 方向反了，两条断言会同时翻转。
    func testPersonMaskOrientation() throws {
        let topGrid = try XCTUnwrap(PersonMaskConverter.convert(splitMask(personInTopHalf: true)))
        let bottomGrid = try XCTUnwrap(PersonMaskConverter.convert(splitMask(personInTopHalf: false)))

        let gated = corridorWeight(weightTable(mask: topGrid))
        let ungated = corridorWeight(weightTable(mask: bottomGrid))
        XCTAssertEqual(gated, 0, accuracy: 1e-6,
                       "人像蒙版外（图像下半）的颈部走廊必须严格为 0")
        XCTAssertGreaterThan(ungated, 0.1,
                             "人像蒙版内（图像下半）的颈部走廊必须保留权重")
    }

    func testNoMaskFallsBackToM5Radial() {
        let radial = DisplacementField.falloffTable(
            faces: [makeFace()],
            imageSize: imageSize,
            columns: columns,
            rows: rows,
            config: DisplacementField.Config()
        )
        XCTAssertEqual(weightTable(mask: nil), radial,
                       "分割缺失时必须逐元素回到 M5 行为")
    }

    // MARK: - 管线开关与美妆

    func testBodyCoordinationFlagSwitchesField() throws {
        let url = try TestSupport.sampleImageURL(named: "IMG_0291.jpg")
        let decoded = try ImageDecoder.decode(url: url, maxLongEdge: 512)
        let engine: BeautyEngine
        do {
            engine = try BeautyEngine()
        } catch {
            throw XCTSkip("Metal 不可用：\(error.localizedDescription)")
        }
        let analysis = try engine.analyze(decoded: decoded, quality: .preview)
        guard analysis.detection.personMask != nil else {
            throw XCTSkip("该设备无法生成人像分割蒙版")
        }
        let parameters = BeautyParameters(
            faceShape: FaceShapeParameters(
                faceSize: 1, jawSlim: 1, vShape: 1
            )
        )
        let enabled = try engine.render(
            analysis: analysis, parameters: parameters, bodyCoordination: true
        )
        let disabled = try engine.render(
            analysis: analysis, parameters: parameters, bodyCoordination: false
        )
        let on = try XCTUnwrap(enabled.displacementField)
        let off = try XCTUnwrap(disabled.displacementField)
        XCTAssertEqual(on.columns, off.columns)
        XCTAssertEqual(on.rows, off.rows)
        XCTAssertNotEqual(on.offsetX, off.offsetX,
                          "M8 开启时权重表应与人像蒙版约束不同")

        // 关闭开关必须逐位等于不含蒙版的 M5 求解
        let faces = FaceGeometryConverter.convert(detection: analysis.detection)
        let baseline = try XCTUnwrap(DisplacementField.solve(
            faces: faces,
            imageSize: (width: decoded.image.width, height: decoded.image.height),
            parameters: parameters.faceShape,
            features: parameters.faceFeature
        ))
        XCTAssertEqual(off.offsetX, baseline.offsetX)
        XCTAssertEqual(off.offsetY, baseline.offsetY)
    }

    func testMakeupUsesDeformedGeometryFromBodyField() throws {
        let mask = try XCTUnwrap(PersonMaskConverter.convert(splitMask(personInTopHalf: false)))
        let field = DisplacementField.solve(
            faces: [makeFace()],
            imageSize: imageSize,
            parameters: FaceShapeParameters(faceSize: 1, jawSlim: 1),
            personMask: mask
        )
        let deformed = MakeupMaskGenerator.deformed(makeFace(), field: field)
        XCTAssertEqual(deformed.contour.count, makeFace().contour.count)
        // 美妆走的是同一个总场：形变后的关键点必须仍落在图像内
        for point in deformed.contour {
            XCTAssertGreaterThan(point.x, 0)
            XCTAssertLessThan(point.x, Float(imageSize.width))
            XCTAssertGreaterThan(point.y, 0)
            XCTAssertLessThan(point.y, Float(imageSize.height))
        }
    }
}
