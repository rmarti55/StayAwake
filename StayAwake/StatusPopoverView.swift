import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var powerManager: PowerAssertionManager
    @ObservedObject var launchAtLogin: LaunchAtLogin
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statsSection
            timelineSection
            Divider()
            controlsSection
        }
        .padding(16)
        .frame(width: 320)
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            statRow(
                title: "Up since reboot",
                value: DurationFormatter.format(sessionStore.upSinceReboot),
                detail: "Sleep does not reset this"
            )
            statRow(
                title: "Awake since sleep",
                value: DurationFormatter.format(sessionStore.awakeSinceSleep),
                detail: "Resets when the Mac sleeps"
            )
            statRow(
                title: "Heat",
                value: powerManager.thermalStateLabel,
                detail: heatDetail
            )
        }
    }

    private var heatDetail: String {
        let internalReading = internalTemperatureCaption
        switch powerManager.thermalStateLabel {
        case "Nominal":
            return "Mac says heat is fine\(internalReading)"
        case "Fair":
            if powerManager.isLidClosed {
                return "Warm — lid closed waits for ~140°F internal or Serious\(internalReading)"
            }
            return "Warm — heat sleep is lid closed only\(internalReading)"
        case "Serious", "Critical":
            if powerManager.isLidClosed {
                return "Too hot — lid closed sleep will trigger\(internalReading)"
            }
            return "Too hot — heat sleep is lid closed only\(internalReading)"
        default:
            return "Heat sleep is lid closed only\(internalReading)"
        }
    }

    private var internalTemperatureCaption: String {
        guard let virtual = powerManager.virtualTemperatureFahrenheit else {
            return ""
        }

        if let battery = powerManager.batteryTemperatureFahrenheit,
           abs(battery - virtual) >= 5 {
            return String(format: " · internal ~%.0f–%.0f°F (not case temp)", battery, virtual)
        }

        return String(format: " · internal ~%.0f°F (not case temp)", virtual)
    }

    private func captionText(_ string: String, color: Color = .secondary) -> some View {
        Text(string)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption2Text(_ string: String) -> some View {
        Text(string)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statRow(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            caption2Text(detail)
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last 24 hours")
                .font(.caption)
                .foregroundStyle(.secondary)

            TimelineBar(segments: sessionStore.timelineSegments)

            HStack {
                Text("24h ago")
                Spacer()
                Text("now")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                legendItem(color: .accentColor, label: "Awake")
                legendItem(color: Color(nsColor: .separatorColor), label: "Asleep")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Sleep when too hot", isOn: $powerManager.isThermalSleepEnabled)

            captionText(
                "Lid closed only. Sleeps at Serious/Critical, or Fair if internal ~140°F."
            )

            if powerManager.isThermalCutoffActive {
                captionText("Heat cutoff active — keep-awake suspended", color: .orange)
            }

            Toggle("Keep Awake (Lid Open)", isOn: $powerManager.isLidOpenAwakeEnabled)

            if powerManager.isLidOpenAwakeEnabled {
                captionText("Low battery shows a warning before sleeping (lid open only)")
            }

            Toggle("Keep Awake (Lid Closed)", isOn: $powerManager.isLidClosedAwakeEnabled)

            if powerManager.isLidClosedAwakeEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    if powerManager.isClamshellOverrideActive {
                        captionText("Clamshell override: active")
                    }
                    captionText("Lid closed runs hot — use with care")

                    lidClosedBatterySection
                }
            }

            Toggle("Start at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))

            Button("Open log") {
                ToggleLogger.openLogInFinder()
            }

            Button("Quit") {
                onQuit()
            }
            .keyboardShortcut("q")
        }
    }

    private var lidClosedBatterySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sleep at battery")
                    .font(.body)
                Spacer()
                Picker("Sleep at battery", selection: $powerManager.batterySleepThreshold) {
                    ForEach(BatterySleepThreshold.allCases) { threshold in
                        Text(threshold.label).tag(threshold)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 72)
            }

            captionText("Silent sleep when lid is closed and battery hits this level")

            if powerManager.hasInternalBattery {
                batteryStatusCaption
            }
        }
    }

    private var batteryStatusCaption: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let percent = powerManager.batteryPercent {
                captionText("Battery \(percent)%\(powerManager.isOnAC ? " · AC power" : "")")
            }

            if powerManager.isBatteryCutoffArmed && powerManager.batterySleepThreshold != .off {
                captionText("Limit: \(powerManager.batterySleepThreshold.label)")
            }

            if powerManager.isBatteryCutoffSnoozed {
                captionText("Battery warning snoozed — Keep Going active")
            }

            if powerManager.isBatteryCutoffActive {
                captionText("Battery cutoff active — keep-awake suspended", color: .orange)
            }
        }
    }
}

private struct TimelineBar: View {
    let segments: [TimelineSegment]

    var body: some View {
        GeometryReader { geometry in
            let totalDuration = segments.reduce(0) { $0 + $1.duration }
            HStack(spacing: 0) {
                if totalDuration > 0 {
                    ForEach(segments) { segment in
                        let width = geometry.size.width * segment.duration / totalDuration
                        Rectangle()
                            .fill(segment.isAwake ? Color.accentColor : Color(nsColor: .separatorColor))
                            .frame(width: max(width, segment.duration > 0 ? 1 : 0))
                    }
                } else {
                    Rectangle()
                        .fill(Color.accentColor)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 14)
    }
}
