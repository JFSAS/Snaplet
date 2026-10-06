import AppKit

enum AnnotationTool: Int, CaseIterable {
    case select, rectangle, ellipse, line, arrow, pen, text, number
    var title: String {
        switch self {
        case .select: "调整选区"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .line: "直线"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .text: "文字"
        case .number: "序号"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .number: "1.circle"
        }
    }
}

@MainActor
struct Annotation {
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    var rect: CGRect {
        guard let a = points.first, let b = points.last else { return .zero }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    func draw() {
        guard let first = points.first, let last = points.last else { return }
        color.setStroke()
        color.setFill()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch tool {
        case .select: return
        case .rectangle: path.appendRect(rect)
        case .ellipse: path.appendOval(in: rect)
        case .line, .arrow, .pen:
            path.move(to: first)
            for point in points.dropFirst() { path.line(to: point) }
            if tool == .arrow {
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(12, width * 4)
                for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    path.move(to: last)
                    path.line(to: CGPoint(x: last.x - length * cos(angle + offset),
                                          y: last.y - length * sin(angle + offset)))
                }
            }
        case .text:
            (text as NSString).draw(at: first, withAttributes: [
                .font: NSFont.systemFont(ofSize: max(16, width * 6), weight: .semibold),
                .foregroundColor: color])
            return
        case .number:
            let diameter = max(24, width * 8)
            let circle = CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2,
                                width: diameter, height: diameter)
            NSBezierPath(ovalIn: circle).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: diameter * 0.58, weight: .bold),
                .foregroundColor: NSColor.white]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: first.x - size.width / 2,
                                               y: first.y - size.height / 2), withAttributes: attributes)
            return
        }
        path.stroke()
    }
}

@MainActor
struct AnnotationDocument {
    private(set) var items: [Annotation] = []
    private(set) var undone: [Annotation] = []
    mutating func append(_ annotation: Annotation) { items.append(annotation); undone.removeAll() }
    mutating func undo() { if let item = items.popLast() { undone.append(item) } }
    mutating func redo() { if let item = undone.popLast() { items.append(item) } }
    mutating func reset() { items.removeAll(); undone.removeAll() }
    var nextNumber: Int { items.filter { $0.tool == .number }.count + 1 }

    func render(on image: CGImage, selection: CGRect, screenSize: CGSize,
                sourceSize: CGSize) throws -> CGImage {
        guard !items.isEmpty else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.encodingFailed
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let scaleX = sourceSize.width / screenSize.width
        let scaleY = sourceSize.height / screenSize.height
        let crop = CaptureGeometry.pixelRect(selection: selection, screenSize: screenSize, imageSize: sourceSize)
        context.translateBy(x: -crop.minX, y: -(sourceSize.height - crop.maxY))
        context.scaleBy(x: scaleX, y: scaleY)
        context.clip(to: selection)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        items.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw CaptureError.encodingFailed }
        return result
    }
}
