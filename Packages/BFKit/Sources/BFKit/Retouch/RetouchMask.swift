import CoreGraphics

/// 局部修饰区域蒙版，值域 0...1，行优先、原点在左上角。
public struct RetouchMask: Sendable {
    public let width: Int
    public let height: Int
    public let eye: [Float]
    public let teeth: [Float]
    public let darkCircle: [Float]

    public init(
        width: Int,
        height: Int,
        eye: [Float],
        teeth: [Float],
        darkCircle: [Float]
    ) {
        precondition(width >= 0 && height >= 0)
        precondition(eye.count == width * height)
        precondition(teeth.count == width * height)
        precondition(darkCircle.count == width * height)
        self.width = width
        self.height = height
        self.eye = eye
        self.teeth = teeth
        self.darkCircle = darkCircle
    }

    public static let empty = RetouchMask(
        width: 0,
        height: 0,
        eye: [],
        teeth: [],
        darkCircle: []
    )

    public var isEmpty: Bool {
        width == 0 || height == 0 || eye.isEmpty
    }

    public func eyeValue(x: Int, y: Int) -> Float? {
        value(in: eye, x: x, y: y)
    }

    public func teethValue(x: Int, y: Int) -> Float? {
        value(in: teeth, x: x, y: y)
    }

    public func darkCircleValue(x: Int, y: Int) -> Float? {
        value(in: darkCircle, x: x, y: y)
    }

    private func value(in values: [Float], x: Int, y: Int) -> Float? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return values[y * width + x]
    }
}
