import AppKit

struct WindowCandidate {
    let id: CGWindowID
    let frame: CGRect
    let title: String
}

enum WindowSelection {
    /// CG window lists are ordered front to back. Convert their desktop coordinates once.
    static func appKitFrame(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func candidate(at localPoint: CGPoint, screenFrame: CGRect,
                          windows: [WindowCandidate]) -> WindowCandidate? {
        let point = CGPoint(x: screenFrame.minX + localPoint.x, y: screenFrame.minY + localPoint.y)
        guard let window = windows.first(where: { $0.frame.contains(point) }) else { return nil }
        let visible = window.frame.intersection(screenFrame)
        guard visible.width >= 2, visible.height >= 2 else { return nil }
        return WindowCandidate(id: window.id,
            frame: visible.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY), title: window.title)
    }

    @MainActor
    static func visibleWindows() -> [WindowCandidate] {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int, pid != Int(getpid()),
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width >= 2, bounds.height >= 2 else { return nil }
            let app = info[kCGWindowOwnerName as String] as? String ?? "窗口"
            return WindowCandidate(id: id, frame: appKitFrame(bounds, primaryHeight: primary.frame.maxY), title: app)
        }
    }
}
