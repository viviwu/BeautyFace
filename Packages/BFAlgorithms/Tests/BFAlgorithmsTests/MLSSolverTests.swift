import XCTest
@testable import BFAlgorithms

final class MLSSolverTests: XCTestCase {
    func testIdentityWhenSourceEqualsOutput() throws {
        let controls = (0..<16).map { index -> MLSSolver.ControlPoint in
            let x = Float(index % 4) * 100
            let y = Float(index / 4) * 100
            let point = Point2(x, y)
            return .anchor(point)
        }
        let solver = MLSSolver(controls: controls)

        for probe in [Point2(0, 0), Point2(137, 262), Point2(50, 350)] {
            let mapped = solver.map(probe)
            XCTAssertEqual(mapped.x, probe.x, accuracy: 1e-3)
            XCTAssertEqual(mapped.y, probe.y, accuracy: 1e-3)
        }
    }

    func testControlPointsMapExactlyToSources() throws {
        // 一个角点被挪动、其余钉住的经典布局
        let corners = [
            Point2(0, 0), Point2(200, 0),
            Point2(0, 200), Point2(200, 200),
        ]
        let sources = corners
        var outputs = corners
        outputs[3] = Point2(230, 170)  // 右下角向外拉

        let controls = zip(outputs, sources).map {
            MLSSolver.ControlPoint(output: $0, source: $1)
        }
        let solver = MLSSolver(controls: controls)

        for (output, source) in zip(outputs, sources) {
            let mapped = solver.map(output)
            XCTAssertEqual(mapped.x, source.x, accuracy: 1e-2)
            XCTAssertEqual(mapped.y, source.y, accuracy: 1e-2)
        }
    }

    func testInteriorFollowsNearestControlPoint() throws {
        // 中心点右移 30，边界全部钉住：控制点新位置应精确映射回原位，
        // 其邻域则按权重平滑过渡
        var controls: [MLSSolver.ControlPoint] = []
        for gx in 0...6 {
            for gy in 0...6 {
                let x = Float(gx) * 50
                let y = Float(gy) * 50
                let isCenter = gx == 3 && gy == 3
                let target = Point2(x + (isCenter ? 30 : 0), y)
                controls.append(MLSSolver.ControlPoint(
                    output: target,
                    source: Point2(x, y)
                ))
            }
        }
        let solver = MLSSolver(controls: controls)

        // 控制点的输出位置 → 必须精确回到它的源位置
        let atControl = solver.map(Point2(180, 150))
        XCTAssertEqual(atControl.x, 150, accuracy: 1e-2)
        XCTAssertEqual(atControl.y, 150, accuracy: 1e-2)

        // 与中心点重合的输出点应被明显带向中心位移方向（负 x）
        let between = solver.map(Point2(165, 150))
        XCTAssertLessThan(between.x, 163.0)
        XCTAssertEqual(between.y, 150, accuracy: 1.0)
    }

    func testAnchoredFarFieldStaysNearIdentity() throws {
        // 脸部控制点整体收缩 10%，边框锚点钉住：远离脸部处应当几乎不动
        var controls: [MLSSolver.ControlPoint] = []
        let center = Point2(500, 400)
        for index in 0..<24 {
            let angle = Float(index) / 24 * Float.pi * 2
            let radius: Float = 150
            let original = Point2(
                center.x + radius * cos(angle),
                center.y + radius * sin(angle)
            )
            let moved = center + (original - center) * 0.9
            controls.append(MLSSolver.ControlPoint(
                output: moved,
                source: original
            ))
        }
        controls.append(contentsOf: MLSSolver.identityAnchors(
            around: (0, 0, 1000, 800)
        ))
        let solver = MLSSolver(controls: controls)

        // 远离脸部的角落与边缘：位移应当远小于形变本身（15 像素）
        for probe in [Point2(20, 20), Point2(980, 780), Point2(20, 780), Point2(500, 20)] {
            let mapped = solver.map(probe)
            XCTAssertLessThan(
                mapped.distance(to: probe),
                2.0,
                "锚点应当把远场钉回恒等：\(probe)"
            )
        }

        // 脸部轮廓处：应当有明显的收缩位移
        let contour = Point2(center.x + 150, center.y)
        let mapped = solver.map(contour)
        XCTAssertGreaterThan(
            mapped.distance(to: contour),
            8.0,
            "脸部轮廓处应当发生收缩"
        )
    }

    func testRotationIsCaptured() throws {
        // 控制点整体绕中心正转 30 度（source → output）；
        // 逆向映射应把输出空间的点转回原位，即按 −30 度旋转
        let angle = Float.pi / 6
        let center = Point2(300, 300)
        let radius: Float = 100
        var controls: [MLSSolver.ControlPoint] = []
        for index in 0..<8 {
            let theta = Float(index) / 8 * Float.pi * 2
            let original = Point2(
                center.x + radius * cos(theta),
                center.y + radius * sin(theta)
            )
            let offset = original - center
            let rotated = Point2(
                center.x + offset.x * cos(angle) - offset.y * sin(angle),
                center.y + offset.x * sin(angle) + offset.y * cos(angle)
            )
            controls.append(MLSSolver.ControlPoint(
                output: rotated,
                source: original
            ))
        }
        let solver = MLSSolver(controls: controls)

        let mapped = solver.map(center + Point2(radius * 0.5, 0))
        let expected = Point2(
            center.x + radius * 0.5 * cos(angle),
            center.y - radius * 0.5 * sin(angle)
        )
        XCTAssertLessThan(mapped.distance(to: expected), 3.0)
    }
}

private extension Point2 {
    func distance(to other: Point2) -> Float {
        distanceSquared(to: other).squareRoot()
    }
}
