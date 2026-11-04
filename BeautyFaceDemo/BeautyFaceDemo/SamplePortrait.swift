import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 内置的默认示例人像：纯 CoreGraphics 程序化绘制，不依赖 bundle 资源、
/// 不受 App Sandbox 影响，也不含任何真实人物照片或第三方素材。
///
/// 这是一张示意插画，用于让 App 启动时立刻有可处理的画面；Vision 在
/// 插画上通常检测不到人脸，因此形变与局部修饰不生效。想看完整效果时，
/// 请用「选择照片 / 打开文件」换成真实人像。
enum SamplePortrait {
    static let width = 900
    static let height = 1200

    static func makeData() -> Data? {
        guard let image = makeImage(),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  output,
                  UTType.png.identifier as CFString,
                  1,
                  nil
              ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    static func makeImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 后续全部用「左上角原点、y 向下」的 UI 坐标绘制。
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(in: context, colorSpace: colorSpace)
        return context.makeImage()
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }

    private static func gradient(
        _ colors: [CGColor],
        space: CGColorSpace
    ) -> CGGradient? {
        CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)
    }

    private static func fillLinear(
        _ context: CGContext,
        from start: CGPoint,
        to end: CGPoint,
        colors: [CGColor],
        space: CGColorSpace,
        bounds: CGRect? = nil
    ) {
        guard let gradient = gradient(colors, space: space) else { return }
        context.saveGState()
        if let bounds { context.clip(to: bounds) }
        context.drawLinearGradient(
            gradient, start: start, end: end,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private static func fillRadial(
        _ context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        colors: [CGColor],
        space: CGColorSpace,
        clip: CGRect? = nil
    ) {
        guard let gradient = gradient(colors, space: space) else { return }
        context.saveGState()
        if let clip { context.clip(to: clip) }
        context.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: radius,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    private static func ellipse(_ context: CGContext, _ rect: CGRect, _ color: CGColor) {
        context.setFillColor(color)
        context.fillEllipse(in: rect)
    }

    private static func draw(in c: CGContext, colorSpace space: CGColorSpace) {
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)

        // 背景：柔和的冷灰 → 暖米色
        fillLinear(c, from: .zero, to: CGPoint(x: 0, y: height), colors: [
            rgb(0.87, 0.90, 0.92), rgb(0.80, 0.79, 0.76), rgb(0.71, 0.70, 0.69)
        ], space: space, bounds: canvas)

        // 背景光晕
        fillRadial(c, center: CGPoint(x: 450, y: 430), radius: 620, colors: [
            rgb(1, 0.98, 0.94, 0.55), rgb(1, 0.98, 0.94, 0)
        ], space: space, clip: canvas)

        // 头发后层
        fillRadial(c, center: CGPoint(x: 450, y: 400), radius: 360, colors: [
            rgb(0.30, 0.22, 0.19), rgb(0.16, 0.12, 0.11)
        ], space: space, clip: CGRect(x: 190, y: 130, width: 520, height: 760))

        // 肩部与衣服
        let shirt = CGMutablePath()
        shirt.move(to: CGPoint(x: 60, y: 1200))
        shirt.addCurve(to: CGPoint(x: 250, y: 980),
                       control1: CGPoint(x: 90, y: 1060), control2: CGPoint(x: 180, y: 1000))
        shirt.addQuadCurve(to: CGPoint(x: 450, y: 940), control: CGPoint(x: 350, y: 930))
        shirt.addQuadCurve(to: CGPoint(x: 650, y: 980), control: CGPoint(x: 550, y: 930))
        shirt.addCurve(to: CGPoint(x: 840, y: 1200),
                       control1: CGPoint(x: 720, y: 1000), control2: CGPoint(x: 810, y: 1060))
        shirt.closeSubpath()
        c.saveGState()
        c.addPath(shirt)
        c.clip()
        fillLinear(c, from: CGPoint(x: 0, y: 930), to: CGPoint(x: 0, y: 1200), colors: [
            rgb(0.97, 0.96, 0.94), rgb(0.84, 0.83, 0.81)
        ], space: space)
        c.restoreGState()

        // 颈部（含下颌投影）
        c.saveGState()
        c.addPath(CGPath(roundedRect: CGRect(x: 372, y: 720, width: 156, height: 280),
                         cornerWidth: 60, cornerHeight: 60, transform: nil))
        c.clip()
        fillLinear(c, from: CGPoint(x: 372, y: 720), to: CGPoint(x: 528, y: 1000), colors: [
            rgb(0.76, 0.55, 0.44), rgb(0.87, 0.66, 0.52)
        ], space: space)
        fillLinear(c, from: CGPoint(x: 450, y: 720), to: CGPoint(x: 450, y: 830), colors: [
            rgb(0.45, 0.30, 0.24, 0.55), rgb(0.45, 0.30, 0.24, 0)
        ], space: space)
        c.restoreGState()

        // 脸：径向肤色渐变 + 下颌收窄
        let face = CGRect(x: 255, y: 250, width: 390, height: 530)
        c.saveGState()
        c.addEllipse(in: face)
        c.clip()
        fillRadial(c, center: CGPoint(x: 450, y: 500), radius: 320, colors: [
            rgb(0.93, 0.76, 0.62), rgb(0.84, 0.62, 0.49), rgb(0.70, 0.48, 0.38)
        ], space: space, clip: face)
        // 鼻梁与额头高光
        fillRadial(c, center: CGPoint(x: 450, y: 410), radius: 150, colors: [
            rgb(1, 0.92, 0.82, 0.30), rgb(1, 0.92, 0.82, 0)
        ], space: space, clip: face)
        // 脸颊腮红
        fillRadial(c, center: CGPoint(x: 322, y: 570), radius: 105, colors: [
            rgb(0.88, 0.44, 0.42, 0.28), rgb(0.88, 0.44, 0.42, 0)
        ], space: space, clip: face)
        fillRadial(c, center: CGPoint(x: 578, y: 570), radius: 105, colors: [
            rgb(0.88, 0.44, 0.42, 0.28), rgb(0.88, 0.44, 0.42, 0)
        ], space: space, clip: face)
        // 眼下暗沉
        fillRadial(c, center: CGPoint(x: 355, y: 548), radius: 72, colors: [
            rgb(0.48, 0.34, 0.32, 0.30), rgb(0.48, 0.34, 0.32, 0)
        ], space: space, clip: face)
        fillRadial(c, center: CGPoint(x: 545, y: 548), radius: 72, colors: [
            rgb(0.48, 0.34, 0.32, 0.30), rgb(0.48, 0.34, 0.32, 0)
        ], space: space, clip: face)
        c.restoreGState()

        // 耳朵
        ellipse(c, CGRect(x: 240, y: 480, width: 46, height: 92), rgb(0.80, 0.58, 0.46))
        ellipse(c, CGRect(x: 614, y: 480, width: 46, height: 92), rgb(0.80, 0.58, 0.46))

        // 眉毛
        c.setLineCap(.round)
        c.setLineWidth(17)
        c.setStrokeColor(rgb(0.28, 0.19, 0.16))
        for x in [355, 545] {
            let brow = CGMutablePath()
            brow.move(to: CGPoint(x: CGFloat(x) - 52, y: 468))
            brow.addQuadCurve(to: CGPoint(x: CGFloat(x) + 54, y: 452),
                              control: CGPoint(x: CGFloat(x), y: 428))
            c.addPath(brow)
            c.strokePath()
        }

        // 眼睛
        for x in [355, 545] {
            let cx = CGFloat(x)
            ellipse(c, CGRect(x: cx - 52, y: 493, width: 104, height: 42), rgb(0.96, 0.95, 0.93))
            fillRadial(c, center: CGPoint(x: cx, y: 514), radius: 24, colors: [
                rgb(0.36, 0.27, 0.21), rgb(0.15, 0.11, 0.10)
            ], space: space, clip: CGRect(x: cx - 24, y: 490, width: 48, height: 48))
            ellipse(c, CGRect(x: cx - 9, y: 505, width: 18, height: 18), rgb(0.08, 0.06, 0.06))
            ellipse(c, CGRect(x: cx - 12, y: 497, width: 9, height: 9), rgb(1, 1, 1, 0.85))
            // 上眼睑线
            c.setLineWidth(6)
            c.setStrokeColor(rgb(0.30, 0.21, 0.18))
            let lid = CGMutablePath()
            lid.move(to: CGPoint(x: cx - 52, y: 496))
            lid.addQuadCurve(to: CGPoint(x: cx + 52, y: 496), control: CGPoint(x: cx, y: 474))
            c.addPath(lid)
            c.strokePath()
        }

        // 鼻子：鼻梁高光与鼻翼阴影
        fillLinear(c, from: CGPoint(x: 440, y: 520), to: CGPoint(x: 470, y: 620), colors: [
            rgb(1, 0.90, 0.80, 0.28), rgb(1, 0.90, 0.80, 0)
        ], space: space, bounds: CGRect(x: 430, y: 510, width: 55, height: 120))
        fillRadial(c, center: CGPoint(x: 450, y: 626), radius: 42, colors: [
            rgb(0.55, 0.36, 0.29, 0.35), rgb(0.55, 0.36, 0.29, 0)
        ], space: space, clip: face)

        // 嘴唇
        let lips = CGMutablePath()
        lips.move(to: CGPoint(x: 386, y: 676))
        lips.addQuadCurve(to: CGPoint(x: 450, y: 660), control: CGPoint(x: 414, y: 654))
        lips.addQuadCurve(to: CGPoint(x: 514, y: 676), control: CGPoint(x: 486, y: 654))
        lips.addQuadCurve(to: CGPoint(x: 450, y: 716), control: CGPoint(x: 450, y: 726))
        lips.closeSubpath()
        c.addPath(lips)
        c.setFillColor(rgb(0.72, 0.36, 0.36))
        c.fillPath()
        fillLinear(c, from: CGPoint(x: 450, y: 660), to: CGPoint(x: 450, y: 716), colors: [
            rgb(0.82, 0.45, 0.44), rgb(0.62, 0.28, 0.30)
        ], space: space, bounds: CGRect(x: 386, y: 654, width: 128, height: 66))
        ellipse(c, CGRect(x: 422, y: 672, width: 34, height: 8), rgb(1, 0.88, 0.86, 0.45))

        // 刘海（覆盖额头）
        let fringe = CGMutablePath()
        fringe.move(to: CGPoint(x: 258, y: 390))
        fringe.addCurve(to: CGPoint(x: 642, y: 390),
                        control1: CGPoint(x: 300, y: 210), control2: CGPoint(x: 600, y: 210))
        fringe.addQuadCurve(to: CGPoint(x: 450, y: 340), control: CGPoint(x: 450, y: 300))
        fringe.addQuadCurve(to: CGPoint(x: 258, y: 390), control: CGPoint(x: 340, y: 300))
        fringe.closeSubpath()
        c.addPath(fringe)
        c.setFillColor(rgb(0.22, 0.16, 0.14))
        c.fillPath()

        // 皮肤细纹与少量痘印：固定 seed，保证每次生成完全一致
        var seed: UInt64 = 20261104
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) % 1000) / 1000
        }
        c.saveGState()
        c.addEllipse(in: face)
        c.clip()
        for _ in 0..<5200 {
            let px = 255 + next() * 390
            let py = 250 + next() * 530
            let dark = next() > 0.5
            c.setFillColor(dark
                ? rgb(0.55, 0.36, 0.28, 0.10)
                : rgb(1, 0.94, 0.86, 0.12))
            c.fill(CGRect(x: px, y: py, width: 2, height: 2))
        }
        for spot in [(332, 612), (512, 596), (388, 636), (566, 650)] {
            c.setFillColor(rgb(0.52, 0.33, 0.27, 0.45))
            c.fillEllipse(in: CGRect(x: CGFloat(spot.0), y: CGFloat(spot.1), width: 7, height: 7))
        }
        c.restoreGState()
    }
}
