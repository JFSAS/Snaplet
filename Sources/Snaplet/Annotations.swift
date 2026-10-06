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
    var font: NSFont { .systemFont(ofSize: max(16, width * 6), weight: .semibold) }
    var textBounds: CGRect {
        guard let origin = points.first else { return .zero }
        let size = (text as NSString).size(withAttributes: [.font: font])
        return CGRect(origin: origin, size: size)
    }
    func translated(by delta: CGPoint) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        return copy
    }
    /// Drawing, bounds, and hit testing share the same geometry, including arrowheads.
    private var strokePath: CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        switch tool {
        case .rectangle: path.addRect(rect)
        case .ellipse: path.addEllipse(in: rect)
        case .line, .arrow, .pen:
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            if tool == .arrow {
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(12, width * 4)
                for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                    path.move(to: last)
                    path.addLine(to: CGPoint(x: last.x - length * cos(angle + offset),
                                            y: last.y - length * sin(angle + offset)))
                }
            }
        default: break
        }
        return path
    }
    var bounds: CGRect {
        switch tool {
        case .text: return textBounds
        case .number:
            guard let center = points.first else { return .zero }
            let radius = max(12, width * 4)
            return CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        case .select: return .zero
        default: return strokePath.boundingBoxOfPath.insetBy(dx: -width / 2, dy: -width / 2)
        }
    }
    func contains(_ point: CGPoint) -> Bool {
        switch tool {
        case .select: return false
        case .text: return textBounds.insetBy(dx: -5, dy: -5).contains(point)
        case .number:
            guard let center = points.first else { return false }
            return hypot(point.x - center.x, point.y - center.y) <= bounds.width / 2 + 4
        default:
            let tolerance = max(10, width + 8)
            if tool == .pen, let first = points.first, points.allSatisfy({ $0 == first }) {
                return hypot(point.x - first.x, point.y - first.y) <= tolerance / 2
            }
            return strokePath.copy(strokingWithWidth: tolerance, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
        }
    }
    func draw() {
        guard let first = points.first else { return }
        color.setFill()
        switch tool {
        case .select: return
        case .text:
            (text as NSString).draw(at: first, withAttributes: [
                .font: font,
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
        default:
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(strokePath)
            context.strokePath()
            context.restoreGState()
        }
    }
}

@MainActor
struct AnnotationDocument {
    private(set) var items: [Annotation] = []
    private var history: [[Annotation]] = []
    private(set) var undone: [[Annotation]] = []
    private mutating func checkpoint() { history.append(items); undone.removeAll() }
    mutating func append(_ annotation: Annotation) { checkpoint(); items.append(annotation) }
    mutating func replace(at index: Int, with annotation: Annotation) {
        guard items.indices.contains(index) else { return }
        checkpoint()
        items[index] = annotation
    }
    mutating func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        checkpoint()
        items.remove(at: index)
    }
    mutating func undo() {
        guard let previous = history.popLast() else { return }
        undone.append(items)
        items = previous
    }
    mutating func redo() {
        guard let next = undone.popLast() else { return }
        history.append(items)
        items = next
    }
    mutating func reset() { items.removeAll(); history.removeAll(); undone.removeAll() }
    var nextNumber: Int {
        (items.filter { $0.tool == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1
    }
    func index(at point: CGPoint) -> Int? {
        items.indices.reversed().first { items[$0].contains(point) }
    }

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
