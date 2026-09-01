import AppKit
import Combine
import SwiftUI

@main
struct NightOwlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The app is a pure LSUIElement menu bar agent — no windows.
        // The scene is only here to satisfy the SwiftUI lifecycle.
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let sleepManager = SleepManager()
    let updater = UpdaterViewModel()

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var rightClickMenu: NSMenu!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = NSMenu()

        setupStatusItem()
        setupPopover()

        sleepManager.$isActive
            .sink { [weak self] active in
                self?.updateStatusIcon(isSleeping: !active)
                self?.rightClickMenu.item(at: 0)?.title = active ? "Stop Keeping Awake" : "Keep Awake"
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sleepManager.deactivate(reason: nil)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }

        updateStatusIcon(isSleeping: true)

        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        rightClickMenu = NSMenu()
        rightClickMenu.addItem(
            withTitle: "Keep Awake",
            action: #selector(toggleKeepAwake),
            keyEquivalent: ""
        )
        rightClickMenu.addItem(.separator())
        rightClickMenu.addItem(
            withTitle: "Quit NightOwl",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
    }

    private func updateStatusIcon(isSleeping: Bool) {
        statusItem?.button?.image = OwlMenuBarIcon.image(isSleeping: isSleeping)
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(
            rootView: MainPopoverView(sleep: sleepManager, updater: updater)
        )
        popover.contentViewController = hosting

        let fitting = hosting.view.fittingSize
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let targetHeight = min(fitting.height, screenHeight - 80)
        popover.contentSize = NSSize(width: 320, height: max(targetHeight, 150))
    }

    // MARK: - Actions

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem.menu = rightClickMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc private func toggleKeepAwake() {
        sleepManager.toggle()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
