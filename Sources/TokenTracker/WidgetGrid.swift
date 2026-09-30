import AppKit
import SwiftUI

/// The macOS desktop widget grid: 164pt cells with 16pt gutters and margins, starting at the
/// top-left of each screen's usable area. A medium widget spans two cells side by side.
@MainActor
enum WidgetGrid {
    static let cell: CGFloat = 164
    static let gutter: CGFloat = 16
    static var pitch: CGFloat { cell + gutter }

    /// Top-left-anchored slot origin (AppKit coordinates) for a widget at column/row.
    static func origin(column: Int, row: Int, on screen: NSScreen, size: CGSize = Theme.widgetSize) -> NSPoint {
        let area = screen.visibleFrame
        return NSPoint(x: area.minX + gutter + CGFloat(column) * pitch,
                       y: area.maxY - gutter - CGFloat(row) * pitch - size.height)
    }

    /// Every slot on `screen` where a widget of `size` fits entirely.
    static func slots(on screen: NSScreen, size: CGSize = Theme.widgetSize) -> [NSPoint] {
        let area = screen.visibleFrame
        var result: [NSPoint] = []
        var row = 0
        while true {
            let first = origin(column: 0, row: row, on: screen, size: size)
            if first.y < area.minY + gutter { break }
            var column = 0
            while true {
                let point = origin(column: column, row: row, on: screen, size: size)
                if point.x + size.width > area.maxX - gutter { break }
                result.append(point)
                column += 1
            }
            row += 1
        }
        return result
    }

    /// The free slot closest to `frame`, on the screen under its center. Slots overlapping
    /// Apple's own desktop widgets or any frame in `occupied` are skipped.
    static func nearestFreeSlot(to frame: NSRect, occupied: [NSRect]) -> NSPoint? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) }
            ?? NSScreen.screens.min { distance($0.frame, center) < distance($1.frame, center) }
        guard let screen else { return nil }
        let taken = (nativeWidgetFrames() + occupied).map { $0.insetBy(dx: 2, dy: 2) }
        return slots(on: screen, size: frame.size)
            .filter { slot in !taken.contains { $0.intersects(NSRect(origin: slot, size: frame.size)) } }
            .min { hypot($0.x - frame.minX, $0.y - frame.minY) < hypot($1.x - frame.minX, $1.y - frame.minY) }
    }

    private static func distance(_ rect: NSRect, _ point: NSPoint) -> CGFloat {
        hypot(max(rect.minX - point.x, 0, point.x - rect.maxX), max(rect.minY - point.y, 0, point.y - rect.maxY))
    }

    /// Where Apple's desktop widgets are, from Notification Center's saved layout.
    static func nativeWidgetFrames() -> [NSRect] {
        // Notification Center is sandboxed, so its preferences live in its container.
        let domains = [NSHomeDirectory() + "/Library/Containers/com.apple.notificationcenterui/Data/Library/Preferences/com.apple.notificationcenterui",
                       "com.apple.notificationcenterui"]
        guard let widgets = domains.lazy.compactMap({
                  CFPreferencesCopyAppValue("widgets" as CFString, $0 as CFString) as? [String: Any]
              }).first,
              let data = widgets["DesktopWidgetPlacementStorage"] as? Data,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let displays = root["NumberedDisplays"] as? [[String: Any]] else { return [] }

        var frames: [NSRect] = []
        for display in displays {
            for resolution in (display["Resolutions"] as? [[String: Any]]) ?? [] {
                // Layouts are stored per screen size (width × height below the menu bar).
                guard let size = resolution["Size"] as? [Double], size.count == 2,
                      let screen = NSScreen.screens.first(where: {
                          abs($0.frame.width - size[0]) < 1 && abs($0.visibleFrame.maxY - $0.frame.minY - size[1]) < 1
                      }) else { continue }
                for group in (resolution["Groups"] as? [[String: Any]]) ?? [] {
                    let groupOrigin = (group["Origin"] as? [Double]) ?? [8, 8]
                    for item in (group["Items"] as? [[String: Any]]) ?? [] {
                        guard let column = item["Column"] as? Int, let row = item["Row"] as? Int else { continue }
                        let (columns, rows) = span((item["Size"] as? [String: Any])?.keys.first ?? "Small")
                        // The stored origin is measured from an 8pt inset (8 → the 16pt margin).
                        let left = screen.frame.minX + groupOrigin[0] + 8 + CGFloat(column) * pitch
                        let top = screen.visibleFrame.maxY - (groupOrigin[1] + 8) - CGFloat(row) * pitch
                        let height = CGFloat(rows) * pitch - gutter
                        frames.append(NSRect(x: left, y: top - height,
                                             width: CGFloat(columns) * pitch - gutter, height: height))
                    }
                }
            }
        }
        return frames
    }

    private static func span(_ family: String) -> (columns: Int, rows: Int) {
        switch family {
        case "Medium": return (2, 1)
        case "Large": return (2, 2)
        case "ExtraLarge": return (4, 2)
        default: return (1, 1)
        }
    }
}

/// The translucent placeholder shown under a widget while it's dragged, like macOS's own.
@MainActor
final class SnapPreview {
    static let shared = SnapPreview()

    private lazy var window: NSWindow = {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.widgetSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.45), lineWidth: 1))
                .frame(width: Theme.widgetSize.width, height: Theme.widgetSize.height))
        return window
    }()

    func show(at origin: NSPoint, below widget: NSWindow) {
        window.level = widget.level
        window.setFrameOrigin(origin)
        window.order(.below, relativeTo: widget.windowNumber)
    }

    func hide() { window.orderOut(nil) }
}
