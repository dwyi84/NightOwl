import AppKit
import Combine
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

// MARK: - Modes & timers

/// What the power assertion protects.
enum SleepMode: String, CaseIterable, Identifiable {
    /// Display may sleep and lock; the system itself stays awake.
    case systemOnly
    /// Neither the display nor the system may idle-sleep.
    case displayAndSystem

    var id: String { rawValue }

    var label: String {
        switch self {
        case .systemOnly: "System Only"
        case .displayAndSystem: "Display + System"
        }
    }

    var detail: String {
        switch self {
        case .systemOnly: "Display may sleep and lock."
        case .displayAndSystem: "Display and system stay awake."
        }
    }

    var assertionType: CFString {
        switch self {
        case .systemOnly: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        case .displayAndSystem: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        }
    }
}

/// Snapshot of the power supply, read from IOKit power sources.
struct PowerState: Equatable {
    var onACPower = true
    var batteryPercent: Int?
    var isCharging = false
}

// MARK: - SleepManager

/// Ultra-light keep-awake engine built on `IOPMAssertion`, with a Smart
/// SafeGuard that releases the assertion when the power cable is detached or
/// the battery drops to the protection threshold.
@MainActor
final class SleepManager: ObservableObject {

    /// Battery level at or below which the assertion is auto-released.
    static let batteryThresholdPercent = 20
    /// Backup cadence for the battery check (IOPS events are the primary signal).
    static let batteryPollInterval: TimeInterval = 30
    /// Auto-stop bounds for the steppers.
    static let minTimerMinutes = 10
    static let maxTimerMinutes = 24 * 60

    // Live state
    @Published private(set) var isActive = false
    @Published private(set) var remainingSeconds: TimeInterval?
    @Published private(set) var power = PowerState()
    @Published private(set) var lastReleaseReason: String?

    // Preferences (persisted)
    @Published var mode: SleepMode {
        didSet {
            persist()
            guard isActive else { return }
            if !createAssertion() {
                deactivate(reason: nil)
            }
        }
    }
    /// Auto-stop duration in minutes; `0` means ∞ (no auto-stop).
    @Published var timerMinutes: Int {
        didSet {
            persist()
            guard isActive else { return }
            resetDeadline()
            startTicking()
        }
    }
    @Published var acUnplugSafeguard: Bool {
        didSet {
            persist()
            checkSafeguards(previousOnAC: power.onACPower)
        }
    }
    @Published var batterySafeguard: Bool {
        didSet {
            persist()
            checkSafeguards(previousOnAC: power.onACPower)
        }
    }

    var isSleeping: Bool { !isActive }

    /// "∞", "45m", "1h", "1h 30m" — for display.
    var timerLabel: String {
        Self.label(forMinutes: timerMinutes)
    }

    static func label(forMinutes minutes: Int) -> String {
        guard minutes > 0 else { return "∞" }
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m)m" }
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }

    /// Steps the auto-stop duration. Stepping up from `∞` starts at the step
    /// size itself (10m or 1h); stepping down from `∞` is a no-op.
    func stepTimer(by minutes: Int) {
        if timerMinutes == 0 {
            guard minutes > 0 else { return }
            timerMinutes = minutes
            return
        }
        timerMinutes = min(
            max(timerMinutes + minutes, Self.minTimerMinutes),
            Self.maxTimerMinutes
        )
    }

    // Internals
    private var assertionID: IOPMAssertionID = 0
    private var deadline: Date?
    private var tickTimer: Timer?
    private var batteryPollTimer: Timer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var powerContext: UnsafeMutableRawPointer?
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let domain = "com.nightowl.NightOwl"
        static let mode = "mode"
        static let timer = "timerMinutes"
        static let acSafeguard = "acUnplugSafeguard"
        static let batterySafeguard = "batterySafeguard"
    }

    init() {
        let storedMode = defaults.string(forKey: Keys.mode)
        mode = storedMode.flatMap(SleepMode.init(rawValue:)) ?? .systemOnly
        let storedTimer = defaults.object(forKey: Keys.timer) as? Int ?? 0
        timerMinutes = max(storedTimer, 0)
        acUnplugSafeguard = defaults.object(forKey: Keys.acSafeguard) as? Bool ?? true
        batterySafeguard = defaults.object(forKey: Keys.batterySafeguard) as? Bool ?? true

        observeWorkspaceLifecycle()
        startPowerMonitoring()
    }

    // MARK: Activation

    func activate() {
        guard !isActive else { return }
        requestNotificationPermissionIfNeeded()
        lastReleaseReason = nil

        guard createAssertion() else {
            lastReleaseReason = "Could not create power assertion"
            return
        }

        isActive = true
        resetDeadline()
        startTicking()
        startBatteryPolling()

        // Initial safeguard pass: refuse to keep a sub-threshold battery awake.
        power = readPowerState()
        checkSafeguards(previousOnAC: power.onACPower)
    }

    func deactivate(reason: String? = nil) {
        guard isActive else { return }
        releaseAssertion()
        stopTicking()
        stopBatteryPolling()
        isActive = false
        deadline = nil
        remainingSeconds = nil

        if let reason {
            lastReleaseReason = reason
            postNotification(
                title: "NightOwl",
                body: "\(reason) — your Mac can sleep again."
            )
        } else {
            lastReleaseReason = nil
        }
    }

    func toggle() {
        if isActive {
            deactivate(reason: nil)
        } else {
            activate()
        }
    }

    func resetSettings() {
        deactivate(reason: nil)
        defaults.removePersistentDomain(forName: Keys.domain)
        mode = .systemOnly
        timerMinutes = 0
        acUnplugSafeguard = true
        batterySafeguard = true
        lastReleaseReason = nil
    }

    // MARK: Power assertion

    @discardableResult
    private func createAssertion() -> Bool {
        releaseAssertion()
        var id = IOPMAssertionID()
        let result = IOPMAssertionCreateWithName(
            mode.assertionType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "NightOwl is keeping the Mac awake" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else { return false }
        assertionID = id
        return true
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
    }

    // MARK: Timer

    private func resetDeadline() {
        deadline = timerMinutes == 0
            ? nil
            : Date().addingTimeInterval(TimeInterval(timerMinutes * 60))
        remainingSeconds = deadline?.timeIntervalSinceNow
    }

    private func startTicking() {
        stopTicking()
        guard deadline != nil else { return }
        remainingSeconds = deadline?.timeIntervalSinceNow
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func tick() {
        guard isActive, let deadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            deactivate(reason: "Timer finished")
        } else {
            remainingSeconds = remaining
        }
    }

    // MARK: Power monitoring

    /// Subscribes to IOKit power source notifications on the main run loop.
    /// The source lives for the whole process; safeguard checks only act
    /// while the assertion is active.
    private func startPowerMonitoring() {
        let context = Unmanaged.passRetained(self).toOpaque()
        powerContext = context

        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let manager = Unmanaged<SleepManager>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated {
                manager.powerSourceChanged()
            }
        }

        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, CFRunLoopMode.commonModes)
            powerSourceRunLoopSource = source
        }

        power = readPowerState()
    }

    /// Called by the IOPS callback and the battery poll. Always refreshes the
    /// published power snapshot, and evaluates the safeguards when active.
    func powerSourceChanged() {
        let previousOnAC = power.onACPower
        power = readPowerState()
        checkSafeguards(previousOnAC: previousOnAC)
    }

    func refreshPowerState() {
        power = readPowerState()
    }

    private func checkSafeguards(previousOnAC: Bool) {
        guard isActive else { return }

        // SafeGuard 1: the cable came out — stop propping the system up.
        if acUnplugSafeguard, previousOnAC, !power.onACPower {
            deactivate(reason: "Power adapter disconnected")
            return
        }

        // SafeGuard 2: battery at or below the protection threshold.
        if batterySafeguard, !power.onACPower,
           let percent = power.batteryPercent,
           percent <= Self.batteryThresholdPercent {
            deactivate(reason: "Battery low (\(percent)%)")
        }
    }

    private func readPowerState() -> PowerState {
        var state = PowerState()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return state
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else {
                continue
            }
            state.onACPower = (desc[kIOPSPowerSourceStateKey] as? String) != kIOPSBatteryPowerValue
            state.batteryPercent = desc[kIOPSCurrentCapacityKey] as? Int
            state.isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            break
        }
        return state
    }

    private func startBatteryPolling() {
        stopBatteryPolling()
        let t = Timer.scheduledTimer(withTimeInterval: Self.batteryPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.powerSourceChanged()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        batteryPollTimer = t
    }

    private func stopBatteryPolling() {
        batteryPollTimer?.invalidate()
        batteryPollTimer = nil
    }

    // MARK: System sleep / wake

    private func observeWorkspaceLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(systemWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    /// The system is going to sleep (lid closed, Apple menu, …). Release the
    /// assertion so nothing fights the sleep; the timer deadline keeps ticking
    /// in wall-clock time.
    @objc private func systemWillSleep(_ notification: Notification) {
        guard isActive else { return }
        releaseAssertion()
        stopTicking()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        guard isActive else { return }

        // Power may have changed while asleep (docked / undocked).
        let previousOnAC = power.onACPower
        power = readPowerState()
        checkSafeguards(previousOnAC: previousOnAC)
        guard isActive else { return }

        if let deadline, deadline <= Date() {
            deactivate(reason: "Timer finished")
            return
        }

        guard createAssertion() else {
            deactivate(reason: nil)
            return
        }
        startTicking()
    }

    // MARK: Notifications

    private func requestNotificationPermissionIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "notificationPermissionRequested") else { return }
        UserDefaults.standard.set(true, forKey: "notificationPermissionRequested")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Persistence

    private func persist() {
        defaults.set(mode.rawValue, forKey: Keys.mode)
        defaults.set(timerMinutes, forKey: Keys.timer)
        defaults.set(acUnplugSafeguard, forKey: Keys.acSafeguard)
        defaults.set(batterySafeguard, forKey: Keys.batterySafeguard)
    }
}
