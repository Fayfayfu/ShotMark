import AppKit
import Testing
@testable import ShotMark

@Test
func renderingLinePreservesLogicalSizeAndSourcePixels() throws {
    let size = NSSize(width: 20, height: 20)
    let baseImage = makeImage(size: size, pixelsWide: 40, pixelsHigh: 40) { x, y in
        x == 34 && y == 6 ? .green : .clear
    }
    let annotation = Annotation.line(
        CGPoint(x: 2, y: 2),
        CGPoint(x: 18, y: 18),
        StrokeStyle(color: .red, width: 4)
    )

    let renderedImage = AnnotationRenderer.render(baseImage: baseImage, annotations: [annotation])

    #expect(renderedImage.size == size)
    let renderedCGImage = try #require(renderedImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
    #expect(renderedCGImage.width == 40)
    #expect(renderedCGImage.height == 40)

    let midpointPixels = (16...24).flatMap { x in
        (16...24).compactMap { y in colorAt(renderedImage, x: x, y: y) }
    }
    #expect(midpointPixels.contains { $0.alphaComponent > 0.5 && $0.redComponent > 0.6 })
    #expect(isApproximately(colorAt(renderedImage, x: 34, y: 6), .green))
}

@Test
func rendererUsesImagePointCoordinatesWithoutFlippingYAxis() {
    let baseImage = makeImage(size: NSSize(width: 8, height: 8), pixelsWide: 8, pixelsHigh: 8) { x, y in
        y == 1 ? .blue : .clear
    }
    let renderedImage = AnnotationRenderer.render(
        baseImage: baseImage,
        annotations: [.line(CGPoint(x: 1, y: 6), CGPoint(x: 3, y: 6), StrokeStyle(color: .red, width: 1))]
    )

    #expect(isApproximately(colorAt(renderedImage, x: 2, y: 6), .red))
    #expect(isApproximately(colorAt(renderedImage, x: 2, y: 1), .blue))
}

@Test
func rendererDrawsAnnotationsInArrayOrder() {
    let baseImage = makeImage(size: NSSize(width: 10, height: 10), pixelsWide: 10, pixelsHigh: 10) { _, _ in .clear }
    let renderedImage = AnnotationRenderer.render(
        baseImage: baseImage,
        annotations: [
            .brush([CGPoint(x: 5, y: 5)], StrokeStyle(color: .red, width: 4)),
            .brush([CGPoint(x: 5, y: 5)], StrokeStyle(color: .blue, width: 4))
        ]
    )

    #expect(isApproximately(colorAt(renderedImage, x: 5, y: 5), .blue))
}

@Test
func rendererPaintsSinglePointBrushAsRoundDot() {
    let baseImage = makeImage(size: NSSize(width: 10, height: 10), pixelsWide: 10, pixelsHigh: 10) { _, _ in .clear }
    let renderedImage = AnnotationRenderer.render(
        baseImage: baseImage,
        annotations: [.brush([CGPoint(x: 4, y: 7)], StrokeStyle(color: .red, width: 4))]
    )

    #expect(isApproximately(colorAt(renderedImage, x: 4, y: 7), .red))
    #expect(colorAt(renderedImage, x: 2, y: 7).alphaComponent > 0.5)
    #expect(colorAt(renderedImage, x: 1, y: 7).alphaComponent < 0.1)
}

@Test
func rendererDrawsArrowWithFilledSharpHead() {
    let baseImage = makeImage(size: NSSize(width: 100, height: 80), pixelsWide: 100, pixelsHigh: 80) { _, _ in .clear }
    let renderedImage = AnnotationRenderer.render(
        baseImage: baseImage,
        annotations: [
            .arrow(
                CGPoint(x: 10, y: 40),
                CGPoint(x: 80, y: 40),
                StrokeStyle(color: .red, width: 2)
            )
        ]
    )

    #expect(isApproximately(colorAt(renderedImage, x: 69, y: 42), .red))
    #expect(isApproximately(colorAt(renderedImage, x: 69, y: 38), .red))
    #expect(colorAt(renderedImage, x: 69, y: 47).alphaComponent < 0.1)
}

@Test
func rendererPixelatesMosaicRectUsingNearestNeighborBlocks() {
    let baseImage = makeImage(size: NSSize(width: 8, height: 8), pixelsWide: 8, pixelsHigh: 8) { x, y in
        guard (2...5).contains(x), (2...5).contains(y) else { return .clear }
        if x < 4 {
            return y < 4 ? .red : .blue
        }
        return y < 4 ? .green : .yellow
    }
    let renderedImage = AnnotationRenderer.render(
        baseImage: baseImage,
        annotations: [.mosaic(CGRect(x: 2, y: 2, width: 4, height: 4), 2)]
    )

    #expect(isApproximately(colorAt(renderedImage, x: 2, y: 2), .red))
    #expect(isApproximately(colorAt(renderedImage, x: 3, y: 3), .red))
    #expect(isApproximately(colorAt(renderedImage, x: 4, y: 2), .green))
    #expect(isApproximately(colorAt(renderedImage, x: 2, y: 4), .blue))
    #expect(isApproximately(colorAt(renderedImage, x: 4, y: 4), .yellow))
}

@Test
func nonRGBColorsDoNotCompareAsTransparentBlack() {
    let redPattern = NSColor(patternImage: makeImage(size: NSSize(width: 1, height: 1), pixelsWide: 1, pixelsHigh: 1) { _, _ in .red })
    let bluePattern = NSColor(patternImage: makeImage(size: NSSize(width: 1, height: 1), pixelsWide: 1, pixelsHigh: 1) { _, _ in .blue })

    #expect(StrokeStyle(color: redPattern, width: 2) != StrokeStyle(color: bluePattern, width: 2))
}

private func makeImage(
    size: NSSize,
    pixelsWide: Int,
    pixelsHigh: Int,
    colorAtPixel: (Int, Int) -> NSColor
) -> NSImage {
    let context = CGContext(
        data: nil,
        width: pixelsWide,
        height: pixelsHigh,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    for x in 0..<pixelsWide {
        for y in 0..<pixelsHigh {
            context.setFillColor(colorAtPixel(x, y).cgColor)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }

    return NSImage(cgImage: context.makeImage()!, size: size)
}

private func colorAt(_ image: NSImage, x: Int, y: Int) -> NSColor {
    let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    return NSBitmapImageRep(cgImage: cgImage).colorAt(x: x, y: y)!
}

private func isApproximately(_ actual: NSColor, _ expected: NSColor) -> Bool {
    let actual = actual.usingColorSpace(.deviceRGB)!
    let expected = expected.usingColorSpace(.deviceRGB)!
    return abs(actual.redComponent - expected.redComponent) < 0.05
        && abs(actual.greenComponent - expected.greenComponent) < 0.05
        && abs(actual.blueComponent - expected.blueComponent) < 0.05
        && abs(actual.alphaComponent - expected.alphaComponent) < 0.05
}
