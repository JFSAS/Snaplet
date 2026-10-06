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
        }
        path.stroke()
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
    func textIndex(at point: CGPoint) -> Int? {
        items.indices.reversed().first { items[$0].tool == .text && items[$0].textBounds.insetBy(dx: -5, dy: -5).contains(point) }
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
