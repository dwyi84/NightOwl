import AppKit
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation
import IOKit

/// Manages true Clamshell mode for headless / remote-desktop sessions:
/// 1. Toggles `pmset -a disablesleep` via a one-time scoped `/etc/sudoers.d`
///    rule so the Mac stays in Full Wake instead of entering Sleep/DarkWake.
/// 2. Observes `IOPMrootDomain`'s `AppleClamshellState` and creates a
///    `CGVirtualDisplay` **on-demand** only while the lid is closed (and no
///    external physical monitor is attached), keeping the normal open-lid
///    display arrangement and native ProMotion/HiDPI completely untouched.
/// 3. Runs a detached watchdog process that automatically restores
///    `disablesleep 0` if NightOwl terminates unexpectedly (crash / SIGKILL).
@MainActor
final class ClamshellManager {

    private static let sudoersPath = "/etc/sudoers.d/nightowl"
    private static let pmsetPath = "/usr/bin/pmset"

    private var virtualDisplay: CGVirtualDisplay?
    private var watchdogProcess: Process?
    private var notificationPort: IONotificationPortRef?
    private var clamshellNotifier: io_object_t = IO_OBJECT_NULL
    private var notificationContext: UnsafeMutableRawPointer?
    private var pendingStopWorkItem: DispatchWorkItem?
    private(set) var isClamshellActive = false

    /// Checks whether passwordless `pmset -a disablesleep` is configured.
    var isSudoersConfigured: Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "-l", Self.pmsetPath, "-a", "disablesleep", "1"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Prompts once with the macOS admin dialog to install `/etc/sudoers.d/nightowl`,
    /// scoped strictly to `pmset -a disablesleep 0/1` for the current user.
    func installSudoersRule() -> Bool {
        let user = NSUserName()
        guard user.range(of: #"^[a-zA-Z0-9._-]+$"#, options: .regularExpression) != nil else {
            return false
        }

        let rule = "\(user) ALL=(root) NOPASSWD: \(Self.pmsetPath) -a disablesleep 0, \(Self.pmsetPath) -a disablesleep 1"
        let shell = """
        tmp=$(mktemp) && printf '%s\\n' '\(rule)' > "$tmp" && chmod 0440 "$tmp" && visudo -cf "$tmp" >/dev/null && mv "$tmp" '\(Self.sudoersPath)' || { rm -f "$tmp"; exit 1; }
        """
        return runWithAdminPrivileges(shell)
    }

    /// Restores `disablesleep 0` and removes `/etc/sudoers.d/nightowl`.
    @discardableResult
    func uninstallSudoersRule() -> Bool {
        disable()
        let shell = "rm -f '\(Self.sudoersPath)'"
        return runWithAdminPrivileges(shell)
    }

    /// Enables `pmset -a disablesleep 1`, crash watchdog, and On-Demand lid
    /// monitoring (`CGVirtualDisplay` is created only when the lid closes).
    @discardableResult
    func enable() -> Bool {
        guard isSudoersConfigured else { return false }
        guard setDisableSleep(true) else { return false }

        startWatchdog()
        isClamshellActive = true
        startClamshellMonitoring()
        syncVirtualDisplayForLidState()
        return true
    }

    /// Stops lid monitoring, stops watchdog, restores `pmset -a disablesleep 0`,
    /// and tears down any active virtual display.
    func disable() {
        stopClamshellMonitoring()
        stopWatchdog()
        if isClamshellActive || isSudoersConfigured {
            _ = setDisableSleep(false)
        }
        stopVirtualDisplay()
        isClamshellActive = false
    }

    /// Defensive cleanup on app launch so a prior hard-reboot never leaves
    /// `disablesleep 1` stranded.
    func restoreOnLaunchIfNeeded() {
        guard isSudoersConfigured else { return }
        _ = setDisableSleep(false)
    }

    // MARK: - On-Demand Lid Monitoring (IOPMrootDomain)

    private func startClamshellMonitoring() {
        guard notificationPort == nil else { return }
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(rootDomain) }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

        let context = Unmanaged.passRetained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            let manager = Unmanaged<ClamshellManager>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                manager.syncVirtualDisplayForLidState()
            }
        }

        var notifier: io_object_t = IO_OBJECT_NULL
        let kr = IOServiceAddInterestNotification(
            port,
            rootDomain,
            kIOGeneralInterest,
            callback,
            context,
            &notifier
        )
        guard kr == KERN_SUCCESS else {
            Unmanaged<ClamshellManager>.fromOpaque(context).release()
            IONotificationPortDestroy(port)
            return
        }

        notificationPort = port
        clamshellNotifier = notifier
        notificationContext = context
    }

    private func stopClamshellMonitoring() {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil

        if clamshellNotifier != IO_OBJECT_NULL {
            IOObjectRelease(clamshellNotifier)
            clamshellNotifier = IO_OBJECT_NULL
        }
        if let port = notificationPort {
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        if let context = notificationContext {
            Unmanaged<ClamshellManager>.fromOpaque(context).release()
            notificationContext = nil
        }
    }

    private func syncVirtualDisplayForLidState() {
        guard isClamshellActive else {
            stopVirtualDisplay()
            return
        }

        let shouldShowVirtual = isLidClosed() && !hasExternalPhysicalDisplay()
        if shouldShowVirtual {
            pendingStopWorkItem?.cancel()
            pendingStopWorkItem = nil
            startVirtualDisplay()
        } else if virtualDisplay != nil && pendingStopWorkItem == nil {
            // Delay teardown briefly on lid-open so the built-in display finishes
            // waking before the virtual framebuffer disappears.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStopWorkItem = nil
                if !self.isClamshellActive || !self.isLidClosed() || self.hasExternalPhysicalDisplay() {
                    self.stopVirtualDisplay()
                }
            }
            pendingStopWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func isLidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard rootDomain != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(rootDomain) }

        guard let state = IORegistryEntryCreateCFProperty(
            rootDomain,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool else {
            return false
        }
        return state
    }

    private func hasExternalPhysicalDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        let virtualID = virtualDisplay?.displayID
        return displays.prefix(Int(count)).contains { id in
            CGDisplayIsBuiltin(id) == 0 && id != virtualID
        }
    }

    // MARK: - Virtual Display

    private func startVirtualDisplay() {
        guard virtualDisplay == nil else { return }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = "NightOwl Virtual Display"
        descriptor.vendorID = 0x4E4F // "NO"
        descriptor.productID = 0x0001
        descriptor.serialNumber = 0x0001
        descriptor.maxPixelsWide = 3840
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 340)
        descriptor.redPrimary = CGPoint(x: 0.6400, y: 0.3300)
        descriptor.greenPrimary = CGPoint(x: 0.3000, y: 0.6000)
        descriptor.bluePrimary = CGPoint(x: 0.1500, y: 0.0600)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.queue = DispatchQueue.main

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = [
            CGVirtualDisplayMode(width: 3840, height: 2160, refreshRate: 60.0),
            CGVirtualDisplayMode(width: 2560, height: 1440, refreshRate: 60.0),
            CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60.0)
        ]

        if display.apply(settings) {
            virtualDisplay = display
        }
    }

    private func stopVirtualDisplay() {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        virtualDisplay = nil
    }

    // MARK: - pmset & Watchdog

    private func setDisableSleep(_ disabled: Bool) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", Self.pmsetPath, "-a", "disablesleep", disabled ? "1" : "0"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Detached child loop: if NightOwl dies unexpectedly (crash / SIGKILL),
    /// immediately restores `pmset -a disablesleep 0` and exits.
    private func startWatchdog() {
        stopWatchdog()
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 2; done
        /usr/bin/sudo -n \(Self.pmsetPath) -a disablesleep 0 >/dev/null 2>&1
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            watchdogProcess = process
        } catch {
            watchdogProcess = nil
        }
    }

    private func stopWatchdog() {
        guard let process = watchdogProcess else { return }
        if process.isRunning {
            process.terminate()
        }
        watchdogProcess = nil
    }

    // MARK: - Admin prompt

    private func runWithAdminPrivileges(_ shellCommand: String) -> Bool {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}
