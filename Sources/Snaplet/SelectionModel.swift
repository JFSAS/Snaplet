import CoreGraphics

/// Releasing the mouse commits a selection, never the screenshot itself.
struct SelectionModel {
    enum Phase { case idle, dragging, ready }
    struct Handle { let x: Int; let y: Int }
    private enum Drag {
        case create(CGPoint)
        case move(CGPoint, CGRect)
        case resize(CGRect, Handle)
    }
    private(set) var phase: Phase = .idle
    private(set) var rect: CGRect = .zero
    private var drag: Drag?
    var canConfirm: Bool { phase == .ready && rect.width >= 2 && rect.height >= 2 }

    var handles: [(Handle, CGPoint)] {
        guard !rect.isEmpty else { return [] }
        return (0...2).flatMap { x in
            (0...2).compactMap { y in
                guard x != 1 || y != 1 else { return nil }
                return (Handle(x: x, y: y), CGPoint(x: rect.minX + rect.width * CGFloat(x) / 2,
                                                   y: rect.minY + rect.height * CGFloat(y) / 2))
            }
        }
    }

    mutating func begin(at point: CGPoint) {
        if canConfirm, let handle = handles.first(where: {
            abs($0.1.x - point.x) <= 7 && abs($0.1.y - point.y) <= 7
        })?.0 {
            drag = .resize(rect, handle)
        } else if canConfirm && rect.contains(point) {
            drag = .move(point, rect)
        } else {
            rect = .zero
            drag = .create(point)
        }
        phase = .dragging
    }

    mutating func update(to point: CGPoint, within bounds: CGRect) {
        guard let drag else { return }
        let point = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX),
                            y: min(max(point.y, bounds.minY), bounds.maxY))
        switch drag {
        case .create(let start):
            rect = Self.between(start, point).intersection(bounds)
        case .move(let start, let original):
            rect = CGRect(x: min(max(original.minX + point.x - start.x, bounds.minX), bounds.maxX - original.width),
                          y: min(max(original.minY + point.y - start.y, bounds.minY), bounds.maxY - original.height),
                          width: original.width, height: original.height)
        case .resize(let original, let handle):
            var a = original.origin
            var b = CGPoint(x: original.maxX, y: original.maxY)
            if handle.x == 0 { a.x = point.x }
            if handle.x == 2 { b.x = point.x }
            if handle.y == 0 { a.y = point.y }
            if handle.y == 2 { b.y = point.y }
            rect = Self.between(a, b).intersection(bounds)
        }
    }

    mutating func end() {
        drag = nil
        if rect.width >= 2 && rect.height >= 2 { phase = .ready } else { reset() }
    }

    mutating func reset() { phase = .idle; rect = .zero; drag = nil }
    mutating func restore(_ selection: CGRect) {
        rect = selection
        end()
    }
    private static func between(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum CaptureAction { case copy, save, quickSave, preview, pin }
