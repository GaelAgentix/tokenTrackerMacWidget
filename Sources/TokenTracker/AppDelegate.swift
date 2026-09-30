import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let enterprise = EnterpriseController()
    private let max = MaxController()
    private var windows: [Profile: DesktopWidgetWindow] = [:]
    private var timer: Timer?

    private var controllers: [UsageController] { [enterprise, max] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windows[.enterprise] = makeWindow(for: enterprise, view: EnterpriseWidgetView(model: enterprise.model))
        windows[.max] = makeWindow(for: max, view: MaxWidgetView(model: max.model))
        windows.values.forEach { $0.orderFront(nil) }

        for controller in controllers {
            controller.session.onAccountWindowNavigated = { [weak controller] in
                guard let controller else { return }
                Task { await controller.refresh() }
            }
        }

        // Start with the Mac so the widgets are always there without any clicks.
        if !UserDefaults.standard.bool(forKey: "didEnableLaunchAtLogin") {
            LaunchAtLogin.isEnabled = true
            UserDefaults.standard.set(true, forKey: "didEnableLaunchAtLogin")
        }

        refreshDue(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDue(force: false) }
        }
        timer?.tolerance = 5

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self?.refreshDue(force: true)
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.windows.values.forEach { $0.ensureOnScreen() } }
        }
    }

    private func refreshDue(force: Bool) {
        for controller in controllers {
            let wait: TimeInterval
            switch controller.status {
            case .error: wait = RefreshPolicy.retryInterval
            case .signedOut: wait = 15 * 60   // signing in via the widget's window refreshes right away
            default: wait = RefreshPolicy.interval
            }
            if force || Date().timeIntervalSince(controller.lastAttempt) >= wait {
                Task { await controller.refresh() }
            }
        }
    }

    private func makeWindow<V: View>(for controller: UsageController, view: V) -> DesktopWidgetWindow {
        DesktopWidgetWindow(
            profile: controller.profile,
            rootView: view,
            // Widgets refresh themselves; a click only matters if the account needs signing in again.
            onClick: { [weak controller] in
                guard let controller, controller.status == .signedOut else { return }
                controller.session.showAccountWindow(url: Profile.loginURL)
            },
            menu: { [weak self, weak controller] in
                guard let self, let controller else { return NSMenu() }
                return self.menu(for: controller)
            })
    }

    private func menu(for controller: UsageController) -> NSMenu {
        let menu = NSMenu()
        let header = NSMenuItem(title: controller.profile.title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let detail: String
        switch controller.status {
        case .signedOut: detail = "Not signed in"
        case .loading: detail = "Updating…"
        case .error(let message): detail = "Last update failed: \(message)"
        case .idle: detail = "Updated \(Fmt.ago(controller.lastSuccess))"
        }
        let info = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())

        menu.addItem(ActionItem("Refresh Now") { Task { await controller.refresh() } })
        menu.addItem(ActionItem("Open Usage Page…") { controller.session.showAccountWindow(url: Profile.usageURL) })
        if controller.status == .signedOut {
            menu.addItem(ActionItem("Sign In…") { controller.session.showAccountWindow(url: Profile.loginURL) })
        } else {
            menu.addItem(ActionItem("Sign Out") { Task { await controller.signOut() } })
        }
        menu.addItem(ActionItem("Show Diagnostics Folder") {
            NSWorkspace.shared.activateFileViewerSelecting([Storage.directory])
        })
        menu.addItem(.separator())

        menu.addItem(ActionItem("Reset Widget Positions") { [weak self] in
            self?.windows.values.forEach { $0.resetPosition() }
        })
        let login = ActionItem("Open at Login") { LaunchAtLogin.isEnabled.toggle() }
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Token Tracker") { NSApp.terminate(nil) })
        return menu
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

/// A per-user LaunchAgent that starts the app when you log in.
enum LaunchAtLogin {
    static let label = "com.gaelagentix.tokentracker"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        get { FileManager.default.fileExists(atPath: plistURL.path) }
        set {
            if newValue {
                guard let executable = Bundle.main.executablePath else { return }
                let plist: [String: Any] = [
                    "Label": label,
                    "ProgramArguments": [executable],
                    "RunAtLoad": true,
                    "ProcessType": "Interactive",
                ]
                try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                    try? data.write(to: plistURL, options: .atomic)
                }
            } else {
                try? FileManager.default.removeItem(at: plistURL)
            }
        }
    }
}
