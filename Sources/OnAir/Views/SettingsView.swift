import AppKit
import SlackKit
import StatusKit
import SwiftUI

struct SettingsView: View {
    @Bindable var coordinator: AppCoordinator

    var body: some View {
        TabView {
            SlackPane(coordinator: coordinator)
                .tabItem { Label("Slack", systemImage: "link") }
            StatusPane(coordinator: coordinator)
                .tabItem { Label("Status", systemImage: "face.smiling") }
            BehaviourPane(coordinator: coordinator)
                .tabItem { Label("Behaviour", systemImage: "slider.horizontal.3") }
            AboutPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: OnAirMetrics.settingsWidth)
        .padding(OnAirMetrics.padding)
    }
}

// MARK: - Slack

private struct SlackPane: View {
    @Bindable var coordinator: AppCoordinator

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var saveError: String?
    @State private var showSetup = false

    private var redirectURI: String {
        SlackOAuth.redirectURI()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OnAirMetrics.padding) {
            connectionSummary

            GroupBox {
                VStack(alignment: .leading, spacing: OnAirMetrics.gutter) {
                    FieldRow(label: "Client ID") {
                        TextField("", text: $clientID)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                    FieldRow(label: "Client secret") {
                        SecureField("", text: $clientSecret)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                    HStack {
                        Text("Stored in your Keychain — never in a file or a log.")
                            .font(OnAirFont.caption)
                            .foregroundStyle(OnAirColor.textTertiary)
                        Spacer()
                        Button("Save") { save() }
                            .disabled(clientID.isEmpty || clientSecret.isEmpty)
                    }
                }
                .padding(OnAirMetrics.tight)
            }

            if let saveError {
                Text(saveError)
                    .font(OnAirFont.compact)
                    .foregroundStyle(OnAirColor.danger)
            }

            HStack(spacing: OnAirMetrics.gutter) {
                if coordinator.connection.isConnected {
                    Button("Disconnect") { Task { await coordinator.disconnect() } }
                } else {
                    Button("Connect to Slack") { Task { await coordinator.connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasSavedCredentials)
                }
                Spacer()
            }

            DisclosureGroup("How to create the Slack app", isExpanded: $showSetup) {
                setupSteps
            }
            .font(OnAirFont.body)

            Spacer(minLength: 0)
        }
        .onAppear(perform: load)
    }

    private var connectionSummary: some View {
        HStack(spacing: OnAirMetrics.gutter) {
            StatusDot(isLive: coordinator.connection.isConnected)
            Text(summaryText)
                .font(OnAirFont.body)
                .foregroundStyle(OnAirColor.textPrimary)
            Spacer()
        }
    }

    private var summaryText: String {
        switch coordinator.connection {
        case .notConfigured: "No Slack app configured yet."
        case .disconnected: "Credentials saved. Not connected."
        case .connecting: "Connecting…"
        case let .connected(identity): "Connected as \(identity.userName) in \(identity.teamName)."
        case let .needsReconnect(reason): reason
        }
    }

    /// Written out in the app rather than only in the README, because the redirect URL has to
    /// match to the character and this is the one place it can be copied instead of retyped.
    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: OnAirMetrics.gutter) {
            step(1, "Create an app at api.slack.com/apps → From scratch, in your workspace.")
            step(
                2,
                "OAuth & Permissions → User Token Scopes: add users.profile:read and "
                    + "users.profile:write."
            )
            step(3, "OAuth & Permissions → Redirect URLs: add the URL below, then Save URLs.")
            HStack(spacing: OnAirMetrics.gutter) {
                Text(redirectURI)
                    .font(OnAirFont.mono)
                    .textSelection(.enabled)
                    .padding(.horizontal, OnAirMetrics.gutter)
                    .padding(.vertical, OnAirMetrics.tight)
                    .background(
                        OnAirColor.inset,
                        in: RoundedRectangle(cornerRadius: OnAirMetrics.radius)
                    )
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(redirectURI, forType: .string)
                }
            }
            step(
                4,
                "Basic Information → App Credentials: copy the Client ID and Client Secret "
                    + "into the fields above."
            )
            step(
                5,
                "Press Connect. Your browser will warn that the connection is not private — "
                    + "that is OnAir's own certificate for localhost, which exists because Slack "
                    + "refuses plain http redirects. Continue past it once."
            )
        }
        .padding(.top, OnAirMetrics.gutter)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: OnAirMetrics.gutter) {
            Text("\(number).")
                .font(OnAirFont.mono)
                .foregroundStyle(OnAirColor.textTertiary)
            Text(text)
                .font(OnAirFont.compact)
                .foregroundStyle(OnAirColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasSavedCredentials: Bool {
        if case .notConfigured = coordinator.connection {
            return false
        }
        return true
    }

    private func load() {
        guard let stored = TokenStore.credentials() else { return }
        clientID = stored.clientID
        // The secret is loaded back so Save is idempotent and the field does not read as empty
        // when it is not. It stays in a `SecureField`, and it never leaves this process except
        // to Slack's token endpoint.
        clientSecret = stored.clientSecret
    }

    private func save() {
        do {
            try TokenStore.saveCredentials(
                SlackOAuth.Credentials(
                    clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                    clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            saveError = nil
            coordinator.reloadClient()
        } catch {
            saveError = "Could not write to the Keychain: \(error)"
        }
    }
}

// MARK: - Status

private struct StatusPane: View {
    @Bindable var coordinator: AppCoordinator

    private static let presets = [
        (":movie_camera:", "On camera"),
        (":headphones:", "In a meeting"),
        (":red_circle:", "On air"),
        (":speech_balloon:", "On a call"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: OnAirMetrics.padding) {
            GroupBox {
                VStack(alignment: .leading, spacing: OnAirMetrics.gutter) {
                    FieldRow(label: "Emoji") {
                        TextField(":movie_camera:", text: $coordinator.policy.status.emoji)
                            .textFieldStyle(.roundedBorder)
                            .font(OnAirFont.mono)
                            .frame(width: 240)
                    }
                    FieldRow(label: "Text") {
                        TextField("On camera", text: $coordinator.policy.status.text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                    // Slack takes the shortcode, not the glyph, and silently keeps the old emoji
                    // when given something it cannot resolve — which looks exactly like OnAir
                    // failing to write.
                    Text("Slack wants the shortcode with colons, like :movie_camera:.")
                        .font(OnAirFont.caption)
                        .foregroundStyle(OnAirColor.textTertiary)
                }
                .padding(OnAirMetrics.tight)
            }

            HStack(spacing: OnAirMetrics.gutter) {
                ForEach(Self.presets, id: \.0) { emoji, text in
                    Button(text) {
                        coordinator.policy.status = UserStatus(emoji: emoji, text: text)
                    }
                    .font(OnAirFont.compact)
                }
            }

            Toggle(isOn: $coordinator.policy.overrideExistingStatus) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replace a status I set myself")
                        .font(OnAirFont.body)
                    Text("Off: if you already have a status when the camera comes on, OnAir "
                        + "leaves it alone for that whole call.")
                        .font(OnAirFont.caption)
                        .foregroundStyle(OnAirColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Behaviour

private struct BehaviourPane: View {
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

// MARK: - About

private struct AboutPane: View {
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
