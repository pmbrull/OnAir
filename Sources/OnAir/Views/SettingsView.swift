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
    @State private var saveError: String?
    @State private var showSetup = false
    /// Resolved once per appearance and after every save, not in `body`: resolving reads the
    /// Keychain, and a synchronous securityd round trip per render is the wrong place for it.
    @State private var source: SlackOAuth.ClientIDSource?

    private var redirectURI: String {
        SlackOAuth.redirectURI()
    }

    /// The whole point of the public-client design (ADR-0012): when the build carries the shared
    /// app's id, this pane is one button and no fields.
    private var hasBuiltInApp: Bool {
        !SlackOAuth.builtInClientID.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OnAirMetrics.padding) {
            connectionSummary

            if !hasBuiltInApp {
                GroupBox {
                    VStack(alignment: .leading, spacing: OnAirMetrics.gutter) {
                        FieldRow(label: "Client ID") {
                            TextField("", text: $clientID)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: OnAirMetrics.fieldWidth)
                        }
                        HStack {
                            Text("This build ships no Slack app, so it needs the id of yours. "
                                + "There is no secret to paste — OnAir uses PKCE.")
                                .font(OnAirFont.caption)
                                .foregroundStyle(OnAirColor.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Save") { save() }
                                .disabled(clientID.isEmpty)
                        }
                    }
                    .padding(OnAirMetrics.tight)
                }
            }

            if let saveError {
                Text(saveError)
                    .font(OnAirFont.compact)
                    .foregroundStyle(OnAirColor.danger)
            }

            // A pasted id silently outranking the built-in app would be a trap: the pane would
            // show one button while Connect used an app the user forgot about, with no way to
            // see or undo it. So when both exist, say so, and offer the way back (ADR-0012).
            if hasBuiltInApp, case .pasted = source {
                HStack(spacing: OnAirMetrics.gutter) {
                    Text("Connecting with your own Slack app's id, not the built-in one.")
                        .font(OnAirFont.caption)
                        .foregroundStyle(OnAirColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Use built-in") {
                        TokenStore.deleteClientIDOverride()
                        refreshSource()
                    }
                }
            }

            HStack(spacing: OnAirMetrics.gutter) {
                if coordinator.connection.isConnected {
                    Button("Disconnect") { Task { await coordinator.disconnect() } }
                } else {
                    Button("Connect to Slack") { Task { await coordinator.connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(source == nil)
                }
                Spacer()
            }

            Text("Connecting opens your browser. It will warn once that localhost's certificate "
                + "is not trusted — that is OnAir's own callback listener; continue past it.")
                .font(OnAirFont.caption)
                .foregroundStyle(OnAirColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if !hasBuiltInApp {
                DisclosureGroup("How to create your Slack app", isExpanded: $showSetup) {
                    setupSteps
                }
                .font(OnAirFont.body)
            }

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
        case .notConfigured: "This build has no Slack app id yet."
        case .disconnected: "Ready to connect."
        case .connecting: "Connecting…"
        case let .connected(identity): "Connected as \(identity.userName) in \(identity.teamName)."
        case let .needsReconnect(reason): reason
        }
    }

    /// Only shown on a build with no baked-in app id — the audience is the person creating the
    /// shared app (or their own), not every user. The app manifest in the README does the whole
    /// configuration in one paste; the redirect URL is repeated here because it is the one value
    /// that must match to the character, and here it can be copied.
    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: OnAirMetrics.gutter) {
            step(
                1,
                "api.slack.com/apps → Create New App → From a manifest → your workspace → paste "
                    + "the manifest from OnAir's README. It sets the scopes, the redirect URL "
                    + "below, PKCE (no secret is ever used), and keeps token rotation off."
            )
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
                2,
                "Basic Information → App Credentials: copy the Client ID — only the id — into "
                    + "the field above, then Save and Connect."
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

    private func load() {
        clientID = TokenStore.clientIDOverride() ?? ""
        refreshSource()
    }

    private func refreshSource() {
        source = resolvedClientID()
    }

    private func save() {
        do {
            try TokenStore.saveClientIDOverride(
                clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            saveError = nil
            refreshSource()
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
                            .frame(width: OnAirMetrics.fieldWidth)
                    }
                    FieldRow(label: "Text") {
                        TextField("On camera", text: $coordinator.policy.status.text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: OnAirMetrics.fieldWidth)
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

            Toggle(isOn: $coordinator.policy.pauseNotifications) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also pause notifications (Do Not Disturb)")
                        .font(OnAirFont.body)
                    Text("Snoozes Slack while you are on camera, in half-hour slices that renew "
                        + "themselves, and resumes afterwards. A snooze you set yourself is never "
                        + "touched. Needs extra permissions: if you connected before this option "
                        + "existed, disconnect and reconnect once. Takes effect from the next "
                        + "call.")
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
