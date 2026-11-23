import AppKit
import CGVirtualDisplayBridge
import CoreGraphics
import Foundation

/// Manages true Clamshell mode for headless / remote-desktop sessions:
/// 1. Creates a `CGVirtualDisplay` so WindowServer and remote-desktop tools
///    (RustDesk, Screen Sharing) always have an active framebuffer when the
///    built-in panel turns off.
/// 2. Toggles `pmset -a disablesleep` via a one-time scoped `/etc/sudoers.d`
///    rule so the Mac stays in Full Wake instead of entering Sleep/DarkWake.
/// 3. Runs a detached watchdog process that automatically restores
///    `disablesleep 0` if NightOwl terminates unexpectedly (crash / SIGKILL).
@MainActor
final class ClamshellManager {

    private static let sudoersPath = "/etc/sudoers.d/nightowl"
    private static let pmsetPath = "/usr/bin/pmset"

    private var virtualDisplay: CGVirtualDisplay?
    private var watchdogProcess: Process?
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
        // Validate username to simple POSIX characters before embedding in shell.
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

    /// Enables virtual display + `pmset -a disablesleep 1` + crash watchdog.
    /// Returns `false` if `sudoers` is not configured or `pmset` fails.
    @discardableResult
    func enable() -> Bool {
        guard isSudoersConfigured else { return false }

        startVirtualDisplay()

        guard setDisableSleep(true) else {
            stopVirtualDisplay()
            return false
        }

        startWatchdog()
        isClamshellActive = true
        return true
    }

    /// Stops watchdog, restores `pmset -a disablesleep 0`, and tears down the
    /// virtual display.
    func disable() {
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
