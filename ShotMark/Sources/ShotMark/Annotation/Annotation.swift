import AppKit

enum Annotation: Equatable {
    case rectangle(CGRect, StrokeStyle)
    case ellipse(CGRect, StrokeStyle)
    case line(CGPoint, CGPoint, StrokeStyle)
    case arrow(CGPoint, CGPoint, StrokeStyle)
    case brush([CGPoint], StrokeStyle)
    case text(String, CGPoint, TextStyle)
    case mosaic(CGRect, Int)
}

struct StrokeStyle: Equatable {
    let color: NSColor
    let width: CGFloat

    private let normalizedColor: RGBAColor?

    init(color: NSColor, width: CGFloat) {
        self.color = color
        self.width = width
        normalizedColor = RGBAColor(color)
    }

    static func == (lhs: StrokeStyle, rhs: StrokeStyle) -> Bool {
        colorValuesMatch(lhs.normalizedColor, lhs.color, rhs.normalizedColor, rhs.color) && lhs.width == rhs.width
    }
}

struct TextStyle: Equatable {
    let color: NSColor
    let pointSize: CGFloat
    let weight: NSFont.Weight

    private let normalizedColor: RGBAColor?

    init(color: NSColor, pointSize: CGFloat, weight: NSFont.Weight) {
        self.color = color
        self.pointSize = pointSize
        self.weight = weight
        normalizedColor = RGBAColor(color)
    }

    static func == (lhs: TextStyle, rhs: TextStyle) -> Bool {
        colorValuesMatch(lhs.normalizedColor, lhs.color, rhs.normalizedColor, rhs.color)
            && lhs.pointSize == rhs.pointSize
            && lhs.weight.rawValue == rhs.weight.rawValue
    }
}

private func colorValuesMatch(_ lhs: RGBAColor?, _ lhsColor: NSColor, _ rhs: RGBAColor?, _ rhsColor: NSColor) -> Bool {
    if let lhs, let rhs {
        return lhs == rhs
    }
    return lhsColor.isEqual(rhsColor)
}

private struct RGBAColor: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init?(_ color: NSColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        if let deviceColor = color.usingColorSpace(.deviceRGB) {
            deviceColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        } else {
            return nil
        }
    }
}
