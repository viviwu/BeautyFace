enum MaskFilters {
    static func boxBlur(
        _ values: [Float],
        width: Int,
        height: Int,
        radius: Int
    ) -> [Float] {
        guard radius > 0, width > 0, height > 0 else { return values }

        let diameter = Float(radius * 2 + 1)
        var horizontal = [Float](repeating: 0, count: values.count)
        var output = [Float](repeating: 0, count: values.count)

        for y in 0..<height {
            let row = y * width
            var sum: Float = 0
            for offset in -radius...radius {
                sum += values[row + min(max(offset, 0), width - 1)]
            }
            for x in 0..<width {
                horizontal[row + x] = sum / diameter
                let removeX = min(max(x - radius, 0), width - 1)
                let addX = min(max(x + radius + 1, 0), width - 1)
                sum += values[row + addX] - values[row + removeX]
            }
        }

        for x in 0..<width {
            var sum: Float = 0
            for offset in -radius...radius {
                let y = min(max(offset, 0), height - 1)
                sum += horizontal[y * width + x]
            }
            for y in 0..<height {
                output[y * width + x] = sum / diameter
                let removeY = min(max(y - radius, 0), height - 1)
                let addY = min(max(y + radius + 1, 0), height - 1)
                sum += horizontal[addY * width + x] - horizontal[removeY * width + x]
            }
        }

        return output
    }
}
