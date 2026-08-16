import AppKit
import SlackKit
import SwiftUI

struct SlackPane: View {
    @Bindable var coordinator: AppCoordinator

    @State private var clientID = ""
    @State private var saveError: String?
    @State private var showSetup = false
    /// Resolved once per appearance and after every save, not in `body`: resolving reads the
    /// Keychain, and a synchronous securityd round trip per render is the wrong place for it.
    @State private var source: SlackOAuth.ClientIDSource?

    private var redirectURI: String {
        SlackOAuth.redirectURI
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

            Text("Connecting opens your browser. Slack returns you to onair.pmbrull.me, which "
                + "hands the approval straight back to this Mac — nothing is stored there.")
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
