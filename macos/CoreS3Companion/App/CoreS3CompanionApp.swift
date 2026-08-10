import AppKit
import Combine
import SwiftUI

@MainActor
final class CoreS3CompanionAppDelegate: NSObject, NSApplicationDelegate {
    let model = CompanionViewModel()

    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    private lazy var settingsWindowController: NSWindowController = {
        let rootView = ContentView().environmentObject(model)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "CoreS3 Companion"
        window.setContentSize(NSSize(width: 720, height: 580))
        window.minSize = NSSize(width: 680, height: 520)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination(
            "CoreS3 Companion monitors local agent sessions from the menu bar."
        )
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        observeModel()
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return false
    }

    @objc private func showSettings() {
        settingsWindowController.showWindow(nil)
        settingsWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "CoreS3 Companion")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(showSettings)
            button.toolTip = "CoreS3 Companion"
        }
        statusItem = item
    }

    private func observeModel() {
        model.$agentSnapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let button = self?.statusItem?.button else { return }
                button.image = NSImage(
                    systemSymbolName: snapshot.state.systemImage,
                    accessibilityDescription: snapshot.state.displayName
                )
                button.image?.isTemplate = true
                button.toolTip = "\(snapshot.source.displayName) · \(snapshot.state.displayName)"
            }
            .store(in: &cancellables)
    }
}

@main
struct CoreS3CompanionApp: App {
    @NSApplicationDelegateAdaptor(CoreS3CompanionAppDelegate.self)
    private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
