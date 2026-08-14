import StatusKit
import SwiftUI

struct BehaviourPane: View {
    @Bindable var coordinator: AppCoordinator

    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: OnAirMetrics.padding) {
            GroupBox {
                VStack(alignment: .leading, spacing: OnAirMetrics.gutter) {
                    Toggle("Watch the camera", isOn: $coordinator.policy.watchCamera)
                    Toggle("Watch the microphone", isOn: $coordinator.policy.watchMicrophone)
                    Text("Either one is enough to set your status. The microphone is off by "
                        + "default because audio mixers — Wave Link, Loopback, BlackHole, Krisp — "
                        + "hold it open around the clock, which would leave your status on "
                        + "permanently. Run `onair doctor`: if it says your microphone is idle "
                        + "right now, this is safe to turn on.")
                        .font(OnAirFont.caption)
                        .foregroundStyle(OnAirColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(OnAirMetrics.tight)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: OnAirMetrics.gutter) {
                    FieldRow(label: "Wait before setting") {
                        Stepper(
                            value: $coordinator.policy.onDelay,
                            in: 0 ... 60,
                            step: 1
                        ) {
                            Text("\(Int(coordinator.policy.onDelay))s")
                                .font(OnAirFont.mono)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    FieldRow(label: "Wait before clearing") {
                        Stepper(
                            value: $coordinator.policy.offDelay,
                            in: 0 ... 600,
                            step: 15
                        ) {
                            Text("\(Int(coordinator.policy.offDelay))s")
                                .font(OnAirFont.mono)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    Text("Clearing waits longer on purpose: leaving one meeting and joining the "
                        + "next should not flicker your status for everyone watching.")
                        .font(OnAirFont.caption)
                        .foregroundStyle(OnAirColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(OnAirMetrics.tight)
            }

            Toggle("Launch OnAir at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, wanted in setLaunchAtLogin(wanted) }

            if let launchError {
                Text(launchError)
                    .font(OnAirFont.compact)
                    .foregroundStyle(OnAirColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private func setLaunchAtLogin(_ wanted: Bool) {
        do {
            try LaunchAtLogin.set(wanted)
            // "requiresApproval" is macOS holding the registration pending a switch in System
            // Settings. Reporting it as success would leave the user with a toggle that is on and
            // a login item that never runs.
            launchError = LaunchAtLogin.awaitingApproval
                ? "macOS is waiting for approval in System Settings › General › Login Items."
                : nil
        } catch {
            launchAtLogin = LaunchAtLogin.isEnabled
            launchError = "Could not change the login item: \(error.localizedDescription). "
                + "This needs OnAir to be a signed app in /Applications."
        }
    }
}
