import Foundation
import SwiftUI

struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: OnAirMetrics.gutter) {
            Text("OnAir")
                .font(OnAirFont.title)
            Text(version)
                .font(OnAirFont.mono)
                .foregroundStyle(OnAirColor.textTertiary)

            Hairline().padding(.vertical, OnAirMetrics.tight)

            Text("OnAir never opens your camera or your microphone.")
                .font(OnAirFont.body)
            Text("It asks macOS whether a device is running — the same question the green dot "
                + "answers — and never reads a frame or a sample. That is why it needs no camera "
                + "or microphone permission, and why it does not appear in Privacy & Security.")
                .font(OnAirFont.compact)
                .foregroundStyle(OnAirColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Your Slack token is kept in the macOS Keychain and is sent to nowhere but "
                + "slack.com.")
                .font(OnAirFont.compact)
                .foregroundStyle(OnAirColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "version \(short) (\(build))"
    }
}
