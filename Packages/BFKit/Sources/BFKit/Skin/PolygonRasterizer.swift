import CoreGraphics

enum PolygonRasterizer {
    /// 将归一化（左下原点）多边形转换为蒙版坐标（左上原点）并填充为 0/1。
    static func makeMask(
        points: [CGPoint],
        width: Int,
        height: Int,
        expansion: CGFloat
    ) -> [Float] {
        var mask = [Float](repeating: 0, count: width * height)
        guard points.count >= 3, width > 0, height > 0 else { return mask }

        var polygon = points.map {
            CGPoint(
                x: $0.x * CGFloat(width),
                y: (1 - $0.y) * CGFloat(height)
            )
        }

        let sum = polygon.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        let center = CGPoint(
            x: sum.x / CGFloat(polygon.count),
            y: sum.y / CGFloat(polygon.count)
        )
        polygon = polygon.map {
            CGPoint(
                x: center.x + ($0.x - center.x) * expansion,
                y: center.y + ($0.y - center.y) * expansion
            )
        }

        let xs = polygon.map(\.x)
        let ys = polygon.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return mask
        }

        let startX = max(0, Int(floor(minX)))
        let endX = min(width - 1, Int(ceil(maxX)))
        let startY = max(0, Int(floor(minY)))
        let endY = min(height - 1, Int(ceil(maxY)))
        guard startX <= endX, startY <= endY else { return mask }

        for y in startY...endY {
            for x in startX...endX {
                if contains(
                    x: CGFloat(x) + 0.5,
                    y: CGFloat(y) + 0.5,
                    polygon: polygon
                ) {
                    mask[y * width + x] = 1
                }
            }
        }
        return mask
    }

    private static func contains(
        x: CGFloat,
        y: CGFloat,
        polygon: [CGPoint]
    ) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            if (a.y > y) != (b.y > y) {
                let intersectX = (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x
                if x < intersectX {
                    inside.toggle()
                }
            }
            previous = current
        }
        return inside
    }
}
