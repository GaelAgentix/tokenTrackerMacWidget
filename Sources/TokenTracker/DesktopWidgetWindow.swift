import AppKit
import SwiftUI

/// A borderless window pinned to the desktop layer, sized and placed like a native
/// medium widget. Drag to move: it snaps into the desktop widget grid like Apple's widgets,
/// and the position is remembered.
@MainActor
final class DesktopWidgetWindow: NSWindow {
    private static let all = NSHashTable<DesktopWidgetWindow>.weakObjects()
    private let positionKey: String
    private let defaultRow: Int

    init<Content: View>(profile: Profile, rootView: Content, onClick: @escaping () -> Void, menu: @escaping () -> NSMenu) {
        // v2: the grid changed to the measured native one, so older saved spots are dropped.
        positionKey = "position.v2.\(profile.rawValue)"
        defaultRow = profile.defaultRow
        super.init(contentRect: NSRect(origin: .zero, size: Theme.widgetSize),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        // Just above Finder's desktop (so clicking the desktop can't cover it), below every app window.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        appearance = NSAppearance(named: .darkAqua)

        let bounds = NSRect(origin: .zero, size: Theme.widgetSize)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.maskImage = Self.roundedMask(size: bounds.size, radius: Theme.cornerRadius)
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        let host = WidgetHostingView(rootView: AnyView(
            rootView.background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Theme.glassTint)
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .strokeBorder(Theme.rim, lineWidth: 0.5))
            )
        ))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        host.onClick = onClick
        host.menuProvider = menu
        host.onDragged = { [weak self] in self?.showSnapTarget() }
        host.onMoved = { [weak self] in self?.snapIntoPlace(animated: true) }
        container.addSubview(host)

        contentView = container
        setFrameOrigin(savedOrigin() ?? Self.defaultOrigin(row: defaultRow))
        Self.all.add(self)
        snapIntoPlace(animated: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: positionKey)
        setFrameOrigin(Self.defaultOrigin(row: defaultRow))
    }

    /// Keep the widget on a connected screen, in a grid slot, after displays change.
    func ensureOnScreen() {
        if !NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            setFrameOrigin(Self.defaultOrigin(row: defaultRow))
        }
        snapIntoPlace(animated: false)
    }

    private var otherWidgetFrames: [NSRect] {
        Self.all.allObjects.filter { $0 !== self }.map(\.frame)
    }

    private func showSnapTarget() {
        guard let slot = WidgetGrid.nearestFreeSlot(to: frame, occupied: otherWidgetFrames) else {
            SnapPreview.shared.hide()
            return
        }
        SnapPreview.shared.show(at: slot, below: self)
    }

    private func snapIntoPlace(animated: Bool) {
        SnapPreview.shared.hide()
        let slot = WidgetGrid.nearestFreeSlot(to: frame, occupied: otherWidgetFrames) ?? frame.origin
        UserDefaults.standard.set(NSStringFromPoint(slot), forKey: positionKey)
        guard slot != frame.origin else { return }
        let target = NSRect(origin: slot, size: frame.size)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true)
        }
    }

    private func savedOrigin() -> NSPoint? {
        guard let string = UserDefaults.standard.string(forKey: positionKey) else { return nil }
        let origin = NSPointFromString(string)
        let rect = NSRect(origin: origin, size: Theme.widgetSize)
        return NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) ? origin : nil
    }

    /// Directly under the native widget column (top-left of the built-in display).
    static func defaultOrigin(row: Int) -> NSPoint {
        let screen = NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("built-in") }
            ?? NSScreen.main ?? NSScreen.screens[0]
        return WidgetGrid.origin(column: 0, row: row, on: screen)
    }

    private static func roundedMask(size: NSSize, radius: CGFloat) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Click to act, drag to move, right-click for the menu.
final class WidgetHostingView: NSHostingView<AnyView> {
    var onClick: (() -> Void)?
    var onDragged: (() -> Void)?
    var onMoved: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var dragged = false

    required init(rootView: AnyView) { super.init(rootView: rootView) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.mouse.x, dy = now.y - start.mouse.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: (start.origin.x + dx).rounded(), y: (start.origin.y + dy).rounded()))
        onDragged?()
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?() } else if dragStart != nil { onClick?() }
        dragStart = nil
        dragged = false
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
