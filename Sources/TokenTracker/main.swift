import AppKit

let arguments = CommandLine.arguments

MainActor.assumeIsolated {
    // Developer helpers that don't need a signed-in session.
    if let i = arguments.firstIndex(of: "--render-preview"), i + 1 < arguments.count {
        PreviewRenderer.render(to: arguments[i + 1])
        exit(0)
    }
    if arguments.contains("--print-grid") {
        // Top-left coordinates, like the screen: y grows downward from the top of the main display.
        let height = NSScreen.screens[0].frame.maxY
        for frame in WidgetGrid.nativeWidgetFrames() {
            print("Apple widget  x=\(frame.minX) y=\(height - frame.maxY) \(frame.width)×\(frame.height)")
        }
        for screen in NSScreen.screens {
            print("\(screen.localizedName): \(WidgetGrid.slots(on: screen).count) medium slots")
        }
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--parse-captures"), i + 1 < arguments.count {
        PreviewRenderer.parseCaptures(in: arguments[i + 1])
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
