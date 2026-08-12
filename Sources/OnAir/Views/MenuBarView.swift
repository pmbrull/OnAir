import StatusKit
import SwiftUI

/// What the menu-bar icon shows. The icon is the only part of OnAir most days, so it carries the
/// four states worth interrupting for and nothing else.
@MainActor
enum MenuBarSymbol {
    static func name(for coordinator: AppCoordinator) -> String {
        if case .needsReconnect = coordinator.connection {
            return "exclamationmark.triangle.fill"
        }
        if coordinator.policy.paused {
            return "pause.circle"
        }
        let watched = (coordinator.policy.watchCamera && coordinator.devices.cameraInUse)
            || (coordinator.policy.watchMicrophone && coordinator.devices.microphoneInUse)
        return watched ? "record.circle.fill" : "video"
    }
}

struct MenuBarView: View {
    @Bindable var coordinator: AppCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            devices
            Hairline()
            latest
            Hairline()
            actions
        }
        .frame(width: OnAirMetrics.panelWidth)
    }

    private var header: some View {
        HStack(spacing: OnAirMetrics.gutter) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(OnAirFont.title)
                    .foregroundStyle(OnAirColor.textPrimary)
                Text(subhead)
                    .font(OnAirFont.compact)
                    .foregroundStyle(subheadColor)
            }
            Spacer(minLength: 0)
            if coordinator.isBusy {
                ProgressView().controlSize(.small)
            }
        }
        .padding(OnAirMetrics.padding)
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: OnAirMetrics.tight) {
            deviceRow(
                "Camera",
                isLive: coordinator.devices.cameraInUse,
                watched: coordinator.policy.watchCamera
            )
            deviceRow(
                "Microphone",
                isLive: coordinator.devices.microphoneInUse,
                watched: coordinator.policy.watchMicrophone
            )
        }
        .padding(OnAirMetrics.padding)
    }

    private func deviceRow(_ label: String, isLive: Bool, watched: Bool) -> some View {
        HStack(spacing: OnAirMetrics.gutter) {
            StatusDot(isLive: isLive && watched)
            Text(label)
                .font(OnAirFont.body)
                .foregroundStyle(OnAirColor.textPrimary)
            Spacer(minLength: 0)
            Text(watched ? (isLive ? "in use" : "idle") : "not watched")
                .font(OnAirFont.compact)
                .foregroundStyle(OnAirColor.textTertiary)
        }
        .accessibilityElement(children: .combine)
    }

    /// One line of history, not a scrolling log. The question this panel answers is "why is my
    /// status what it is", and that is always the most recent thing OnAir did.
    @ViewBuilder private var latest: some View {
        if let entry = coordinator.history.first {
            HStack(alignment: .top, spacing: OnAirMetrics.gutter) {
                Text(entry.message)
                    .font(OnAirFont.compact)
                    .foregroundStyle(colour(for: entry.level))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(entry.at, style: .time)
                    .font(OnAirFont.caption)
                    .foregroundStyle(OnAirColor.textTertiary)
                    .monospacedDigit()
            }
            .padding(OnAirMetrics.padding)
        }
    }

    private var actions: some View {
        VStack(spacing: OnAirMetrics.tight) {
            Toggle("Pause OnAir", isOn: $coordinator.policy.paused)
                .font(OnAirFont.body)
                .toggleStyle(.switch)
                .controlSize(.mini)

            HStack(spacing: OnAirMetrics.gutter) {
                Button("Settings…") { openSettings() }
                Spacer(minLength: 0)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(OnAirFont.body)
            .buttonStyle(.link)
        }
        .padding(OnAirMetrics.padding)
    }

    // MARK: - Wording

    private var headline: String {
        switch coordinator.connection {
        case .notConfigured: "Set up Slack"
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case let .connected(identity): "\(identity.userName) · \(identity.teamName)"
        case .needsReconnect: "Reconnect Slack"
        }
    }

    private var subhead: String {
        if case let .needsReconnect(reason) = coordinator.connection {
            return reason
        }
        if case .notConfigured = coordinator.connection {
            return "Add your Slack app's client id and secret in Settings."
        }
        if coordinator.policy.paused {
            return "Paused — your status will not change."
        }
        return coordinator.policy.status.text.isEmpty
            ? "No status configured."
            : "\(coordinator.policy.status.emoji) \(coordinator.policy.status.text)"
    }

    private var subheadColor: Color {
        if case .needsReconnect = coordinator.connection {
            return OnAirColor.danger
        }
        if coordinator.policy.paused {
            return OnAirColor.warning
        }
        return OnAirColor.textSecondary
    }

    private func colour(for level: ActivityEntry.Level) -> Color {
        switch level {
        case .info: OnAirColor.textSecondary
        case .warning: OnAirColor.warning
        case .failure: OnAirColor.danger
        }
    }
}
