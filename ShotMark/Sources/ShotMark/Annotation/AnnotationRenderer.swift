import AppKit

enum AnnotationRenderer {
    static func render(baseImage: NSImage, annotations: [Annotation]) -> NSImage {
        guard let baseCGImage = cgImage(for: baseImage),
              baseImage.size.width > 0,
              baseImage.size.height > 0,
              let context = CGContext(
                  data: nil,
                  width: baseCGImage.width,
                  height: baseCGImage.height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return baseImage.copy() as! NSImage
        }

        let pointToPixelScale = CGFloat(baseCGImage.width) / baseImage.size.width
        context.scaleBy(x: pointToPixelScale, y: pointToPixelScale)
        context.draw(baseCGImage, in: CGRect(origin: .zero, size: baseImage.size))

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        for annotation in annotations {
            draw(
                annotation,
                baseCGImage: baseCGImage,
                baseImageSize: baseImage.size,
                pointToPixelScale: pointToPixelScale,
                in: context
            )
        }

        guard let renderedCGImage = context.makeImage() else {
            return baseImage.copy() as! NSImage
        }
        return NSImage(cgImage: renderedCGImage, size: baseImage.size)
    }

    private static func draw(
        _ annotation: Annotation,
        baseCGImage: CGImage,
        baseImageSize: NSSize,
        pointToPixelScale: CGFloat,
        in context: CGContext
    ) {
        switch annotation {
        case let .rectangle(rect, style):
            stroke(NSBezierPath(rect: rect), with: style)

        case let .ellipse(rect, style):
            stroke(NSBezierPath(ovalIn: rect), with: style)

        case let .line(start, end, style):
            stroke(path(from: start, to: end), with: style)

        case let .arrow(start, end, style):
            drawArrow(from: start, to: end, with: style)

        case let .brush(points, style):
            drawBrush(points, with: style)

        case let .text(string, point, style):
            let font = NSFont.systemFont(ofSize: style.pointSize, weight: style.weight)
            string.draw(at: point, withAttributes: [
                .font: font,
                .foregroundColor: style.color
            ])

        case let .mosaic(rect, blockSize):
            drawMosaic(
                in: rect,
                blockSize: blockSize,
                from: baseCGImage,
                imageSize: baseImageSize,
                pointToPixelScale: pointToPixelScale,
                in: context
            )
        }
    }

    private static func stroke(_ path: NSBezierPath, with style: StrokeStyle) {
        style.color.setStroke()
        path.lineWidth = style.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func drawBrush(_ points: [CGPoint], with style: StrokeStyle) {
        guard let firstPoint = points.first else { return }

        guard points.count > 1 else {
            style.color.setFill()
            NSBezierPath(
                ovalIn: CGRect(
                    x: firstPoint.x - style.width / 2,
                    y: firstPoint.y - style.width / 2,
                    width: style.width,
                    height: style.width
                )
            ).fill()
            return
        }

        let path = NSBezierPath()
        path.move(to: firstPoint)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        stroke(path, with: style)
    }

    private static func path(from start: CGPoint, to end: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        return path
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, with style: StrokeStyle) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.001 else {
            drawBrush([end], with: style)
            return
        }

        let unit = CGPoint(x: dx / length, y: dy / length)
        let headLength = min(max(14, style.width * 4), length * 0.75)
        let halfHeadWidth = min(max(6, style.width * 2.25), headLength * 0.5)
        let baseCenter = CGPoint(
            x: end.x - unit.x * headLength,
            y: end.y - unit.y * headLength
        )
        let normal = CGPoint(x: -unit.y, y: unit.x)
        let leftBase = CGPoint(
            x: baseCenter.x + normal.x * halfHeadWidth,
            y: baseCenter.y + normal.y * halfHeadWidth
        )
        let rightBase = CGPoint(
            x: baseCenter.x - normal.x * halfHeadWidth,
            y: baseCenter.y - normal.y * halfHeadWidth
        )

        stroke(path(from: start, to: baseCenter), with: style)

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: leftBase)
        head.line(to: rightBase)
        head.close()
        style.color.setFill()
        head.fill()
    }

    private static func drawMosaic(
        in requestedRect: CGRect,
        blockSize: Int,
        from baseCGImage: CGImage,
        imageSize: NSSize,
        pointToPixelScale: CGFloat,
        in context: CGContext
    ) {
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let rect = requestedRect.intersection(imageBounds)
        guard blockSize > 0, !rect.isNull, !rect.isEmpty else { return }

        let cropRect = CGRect(
            x: rect.minX * pointToPixelScale,
            y: rect.minY * pointToPixelScale,
            width: rect.width * pointToPixelScale,
            height: rect.height * pointToPixelScale
        ).integral
        guard let crop = baseCGImage.cropping(to: cropRect) else { return }

        let reducedWidth = max(1, Int((rect.width / CGFloat(blockSize)).rounded(.up)))
        let reducedHeight = max(1, Int((rect.height / CGFloat(blockSize)).rounded(.up)))
        guard let reducedContext = CGContext(
            data: nil,
            width: reducedWidth,
            height: reducedHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }

        reducedContext.interpolationQuality = .none
        reducedContext.draw(crop, in: CGRect(x: 0, y: 0, width: reducedWidth, height: reducedHeight))
        guard let reducedImage = reducedContext.makeImage() else { return }

        context.saveGState()
        context.interpolationQuality = .none
        context.draw(reducedImage, in: rect)
        context.restoreGState()
    }

    private static func cgImage(for image: NSImage) -> CGImage? {
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            ?? image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.cgImage }
    }
}
