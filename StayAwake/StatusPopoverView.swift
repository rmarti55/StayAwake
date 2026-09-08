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
        }
    }

    private func statRow(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
            Toggle("Keep Awake (Lid Open)", isOn: $powerManager.isLidOpenAwakeEnabled)
            Toggle("Keep Awake (Lid Closed)", isOn: $powerManager.isLidClosedAwakeEnabled)

            if powerManager.isLidClosedAwakeEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    if powerManager.isClamshellOverrideActive {
                        Text("Clamshell override: active")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Lid closed runs hot — use with care")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            batteryCutoffSection

            Toggle("Start at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))

            Button("Quit") {
                onQuit()
            }
            .keyboardShortcut("q")
        }
    }

    private var batteryCutoffSection: some View {
        let keepAwakeEnabled = powerManager.isKeepAwakeEnabledForUI

        return VStack(alignment: .leading, spacing: 6) {
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
            .disabled(!keepAwakeEnabled)

            if !keepAwakeEnabled {
                Text("Turn on a keep-awake toggle to use this")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if powerManager.hasInternalBattery {
                batteryStatusCaption
            }
        }
    }

    private var batteryStatusCaption: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let percent = powerManager.batteryPercent {
                Text("Battery \(percent)%\(powerManager.isOnAC ? " · AC power" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if powerManager.isBatteryCutoffArmed {
                Text("Sleeping at \(powerManager.batterySleepThreshold.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if powerManager.isBatteryCutoffActive {
                Text("Battery cutoff active — keep-awake suspended")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private extension PowerAssertionManager {
    var isKeepAwakeEnabledForUI: Bool {
        isLidOpenAwakeEnabled || isLidClosedAwakeEnabled
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
