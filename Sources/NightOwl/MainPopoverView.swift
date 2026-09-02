import AppKit
import SwiftUI

/// Single-screen, scroll-free 320pt popover — follows the LookHere layout spec.
struct MainPopoverView: View {
    @ObservedObject var sleep: SleepManager
    @ObservedObject var updater: UpdaterViewModel

    @State private var showResetConfirm = false

    private let coffeeURL = URL(string: "https://buymeacoffee.com/dwyi84d")!

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                toggleSection
                modeSection
                timerSection
                statusSection
                safeguardSection
            }
            .padding(16)

            Divider()
            footer
        }
        .frame(width: 320)
        .onAppear {
            sleep.refreshPowerState()
        }
        .confirmationDialog(
            "Reset all settings to defaults?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                sleep.resetSettings()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Update to v\(updater.pendingUpdateVersion ?? "")?",
            isPresented: $updater.showUpdateConfirm,
            titleVisibility: .visible
        ) {
            Button("Update Now") {
                updater.installNow()
            }
            Button("Cancel", role: .cancel) {
                updater.cancelPrompt()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            OwlIconView(isSleeping: sleep.isSleeping)
                .frame(width: 18, height: 18)
                .foregroundStyle(Color(red: 1.0, green: 0.584, blue: 0.0))
            Text("NightOwl")
                .font(.headline)
            Text("v\(UpdaterViewModel.currentVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            updateIndicator
                // Pinned to the bordered small-button height so the header
                // (and the popover) never resizes as the indicator swaps.
                .frame(height: 20)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Header update control, following the CopyNinja popover: a compact
    /// state indicator instead of a button that swaps its own title.
    @ViewBuilder
    private var updateIndicator: some View {
        switch updater.updateState {
        case .checking:
            ProgressView()
                .controlSize(.mini)
                .help("Checking for updates…")
        case .downloading:
            ProgressView()
                .controlSize(.mini)
                .help("Downloading update…")
        case .upToDate:
            HStack(spacing: 3) {
                Image(systemName: "checkmark.circle")
                Text("Up to date")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        case .updateAvailable:
            Button("Update Available") {
                updater.showUpdateConfirm = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Update to v\(updater.pendingUpdateVersion ?? "")")
        case .idle:
            Button("Check for Updates") {
                updater.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Check for updates")
        case .failed:
            Button("Check Again") {
                updater.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Check for updates again")
        }
    }

    // MARK: - Main toggle

    private var toggleSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Keep Awake")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { sleep.isActive },
                    set: { on in
                        if on {
                            sleep.activate()
                        } else {
                            sleep.deactivate(reason: nil)
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Keep Awake")
            }
            Text(sleep.isActive ? sleep.mode.detail : "Owl is dozing — your Mac sleeps normally.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Mode

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode")
                .font(.subheadline.weight(.medium))
            Picker("", selection: $sleep.mode) {
                Text("System Only").tag(SleepMode.systemOnly)
                Text("Display + System").tag(SleepMode.displayAndSystem)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    // MARK: - Auto-stop timer

    private let timerPresets: [(minutes: Int, label: String)] = [
        (0, "∞"), (15, "15m"), (30, "30m"), (60, "1h"), (120, "2h")
    ]

    private var timerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-Stop")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                ForEach(timerPresets, id: \.minutes) { preset in
                    let isSelected = sleep.timerMinutes == preset.minutes
                    Button {
                        sleep.timerMinutes = preset.minutes
                    } label: {
                        Text(preset.label)
                            .font(.caption.monospacedDigit().weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.15))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                stepperButton("−1h", minutes: -60)
                stepperButton("−10m", minutes: -10)
                Text(sleep.timerLabel)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.10))
                    )
                stepperButton("+10m", minutes: 10)
                stepperButton("+1h", minutes: 60)
            }
        }
    }

    private func stepperButton(_ title: String, minutes: Int) -> some View {
        let isPlus = minutes > 0
        let isEnabled = isPlus
            ? sleep.timerMinutes < SleepManager.maxTimerMinutes
            : sleep.timerMinutes > SleepManager.minTimerMinutes
        return Button {
            sleep.stepTimer(by: minutes)
        } label: {
            Text(title)
                .font(.caption.monospacedDigit().weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.gray.opacity(isEnabled ? 0.15 : 0.08))
                )
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isPlus ? "Add \(abs(minutes)) minutes" : "Subtract \(abs(minutes)) minutes")
    }

    // MARK: - Smart SafeGuard

    private var safeguardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Smart SafeGuard")
                .font(.subheadline.weight(.medium))

            if sleep.isLaptop {
                switchRow("Keep running with lid closed", isOn: $sleep.keepAwakeLidClosed)
                    .help("Experimental — keeps the system awake with the lid closed (DarkWake)")
            }
            switchRow("Thermal Guard", isOn: $sleep.thermalGuard)
            switchRow("Release on AC unplug", isOn: $sleep.acUnplugSafeguard)
            if sleep.isLaptop {
                switchRow("Stop below \(SleepManager.batteryThresholdPercent)% battery", isOn: $sleep.batterySafeguard)
            }

            HStack(spacing: 6) {
                Image(systemName: powerIconName)
                    .foregroundStyle(powerIconColor)
                Text(powerStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }

    private var powerIconName: String {
        if sleep.power.onACPower {
            return sleep.power.batteryPercent != nil ? "battery.100.bolt" : "powerplug.fill"
        }
        guard let pct = sleep.power.batteryPercent else { return "powerplug.fill" }
        if pct <= SleepManager.batteryThresholdPercent { return "battery.25percent" }
        if pct <= 50 { return "battery.50percent" }
        if pct <= 75 { return "battery.75percent" }
        return "battery.100percent"
    }

    private var powerIconColor: Color {
        if sleep.power.onACPower { return .green }
        if let pct = sleep.power.batteryPercent, pct <= SleepManager.batteryThresholdPercent {
            return .orange
        }
        return .secondary
    }

    private var powerStatusText: String {
        if sleep.power.onACPower {
            if let pct = sleep.power.batteryPercent {
                return "On AC power · \(pct)%"
            }
            return "On AC power"
        }
        if let pct = sleep.power.batteryPercent {
            let suffix = sleep.power.isCharging ? " · charging" : ""
            return "On battery · \(pct)%\(suffix)"
        }
        return "On battery"
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Status")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(remainingText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // Fixed 16×16 tile: SF Symbols have state-dependent metrics
            // (moon.zzz 17pt vs eye 13pt), which used to resize the popover
            // on every Keep Awake toggle.
            HStack(spacing: 6) {
                Image(systemName: statusIconName)
                    .font(.caption)
                    .foregroundStyle(statusIconColor)
                    .frame(width: 16, height: 16)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if sleep.thermalState == .serious || sleep.thermalState == .critical {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.high")
                        .foregroundStyle(sleep.thermalState == .critical ? Color.red : Color.orange)
                    Text("Thermal: \(sleep.thermalLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var remainingText: String {
        guard sleep.isActive else { return "—" }
        guard let remaining = sleep.remainingSeconds else { return "∞" }
        let total = Int(remaining.rounded(.up))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private var statusMessage: String {
        if sleep.isActive {
            return sleep.timerMinutes == 0
                ? "Keeping your Mac awake — no auto-stop."
                : "Keeping your Mac awake."
        }
        if let reason = sleep.lastReleaseReason {
            return "Auto-released: \(reason)."
        }
        return "Not keeping your Mac awake."
    }

    private var statusIconName: String {
        if sleep.isActive { return "eye.fill" }
        if sleep.lastReleaseReason != nil { return "info.circle.fill" }
        return "moon.zzz.fill"
    }

    private var statusIconColor: Color {
        if sleep.isActive { return .green }
        if sleep.lastReleaseReason != nil { return .orange }
        return .secondary
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Link(destination: coffeeURL) {
                    HStack(spacing: 6) {
                        Text("☕")
                        Text("Buy me a coffee")
                            .font(.callout.weight(.medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 1.0, green: 0.87, blue: 0.0))
                    )
                    .foregroundStyle(.black)
                }
                .buttonStyle(.plain)

                Spacer()

                Button("Reset") {
                    showResetConfirm = true
                }
                .controlSize(.small)
                .help("Reset all settings to defaults")

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .controlSize(.small)
            }

            Text("Crafted by MelissaSoft")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
