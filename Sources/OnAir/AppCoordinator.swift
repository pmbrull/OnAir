import AppKit
import DeviceKit
import Foundation
import Observation
import SlackKit
import StatusKit

/// How OnAir stands with Slack right now.
enum ConnectionState: Equatable {
    /// No client id and secret yet — the Slack app has not been created.
    case notConfigured
    /// Credentials, but no token: the user has not pressed Connect.
    case disconnected
    case connecting
    case connected(SlackIdentity)
    /// A token that Slack will not accept. Retrying will not help.
    case needsReconnect(String)

    var isConnected: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
}

/// One line in the menu's short history. The app's answer to "why is my status like this".
struct ActivityEntry: Identifiable, Equatable {
    enum Level: Equatable { case info, warning, failure }

    let id = UUID()
    let at: Date
    let level: Level
    let message: String
}

/// Everything joined up: the hardware, the policy, and Slack.
///
/// The coordinator performs; it does not decide. Every "should we?" belongs to `StatusEngine`
/// (invariant A3), which is what keeps the debounce and the override rules testable without a
/// webcam. What lives here is the part that genuinely cannot be pure — the network call, the
/// retry, and the check that OnAir still owns the status before putting the old one back.
@MainActor
@Observable
final class AppCoordinator {
    private(set) var devices = DeviceSnapshot.idle
    private(set) var connection: ConnectionState = .disconnected
    private(set) var history: [ActivityEntry] = []
    private(set) var isBusy = false

    var policy: StatusPolicy {
        didSet {
            guard policy != oldValue else { return }
            PolicyStore.save(policy)
            pump()
        }
    }

    @ObservationIgnored private var engine = StatusEngine()
    @ObservationIgnored private let watcher = DeviceWatcher()
    @ObservationIgnored private var client: SlackClient?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var pumpAgain = false
    @ObservationIgnored private var retryDelay: TimeInterval = AppCoordinator.minimumRetry

    private static let minimumRetry: TimeInterval = 15
    private static let maximumRetry: TimeInterval = 300
    private static let historyLimit = 30

    /// One instance, reached by both scenes and the app delegate. A `@State` coordinator per scene
    /// would give the menu and the settings window separate engines, and only one of them would
    /// know it owned the status.
    static let shared = AppCoordinator()

    init(policy: StatusPolicy = PolicyStore.load()) {
        self.policy = policy
    }

    /// OnAir owns the status only while it is running. Restoring it here is the difference between
    /// quitting mid-meeting and leaving a stale status behind for the rest of the day.
    var owesRestore: Bool {
        engine.appliedPrevious != nil
    }

    // MARK: - Lifecycle

    func start() {
        watcher.start { [weak self] snapshot in
            Task { @MainActor in self?.deviceStateChanged(snapshot) }
        }
        devices = watcher.snapshot
        reloadClient()
    }

    /// Best-effort, on the way out. `NSApplication` will not wait for an async teardown, so this
    /// gets whatever time the run loop has left rather than a guarantee — which is exactly why
    /// there is no other safety net and why the README says so (ADR-0009).
    func restoreBeforeQuit() async {
        guard let client, let previous = engine.appliedPrevious else { return }
        // ADR-0008 applies on the way out too. Quitting is not a licence to overwrite a status the
        // user typed during the call — the check costs one extra call inside the window
        // `.terminateLater` buys, and skipping it would make quitting the one path that clobbers.
        guard let live = try? await client.currentStatus(), engine.stillOwns(live) else {
            engine.recordRestored()
            return
        }
        try? await client.setStatus(previous)
        engine.recordRestored()
    }

    private func deviceStateChanged(_ snapshot: DeviceSnapshot) {
        devices = snapshot
        pump()
    }

    // MARK: - Slack connection

    func reloadClient() {
        guard let credentials = TokenStore.credentials(), credentials.isComplete else {
            client = nil
            connection = .notConfigured
            return
        }
        guard let token = TokenStore.token() else {
            client = nil
            connection = .disconnected
            return
        }
        client = SlackClient(token: token)
        Task { await confirmIdentity() }
    }

    private func confirmIdentity() async {
        guard let client else { return }
        connection = .connecting
        do {
            connection = try await .connected(client.identity())
            pump()
        } catch let error as SlackError {
            connection = error.requiresReconnect
                ? .needsReconnect(error.summary)
                : .disconnected
            note(error.summary, level: .failure)
        } catch {
            connection = .disconnected
            note("Could not reach Slack.", level: .failure)
        }
    }

    func connect() async {
        guard let credentials = TokenStore.credentials(), credentials.isComplete else {
            note("Add the Slack app's client id and secret first.", level: .warning)
            return
        }
        connection = .connecting
        do {
            let session = try SlackOAuthSession(
                credentials: credentials,
                supportDirectory: PolicyStore.supportDirectory
            )
            openInBrowser(session.authorizationURL)
            note("Waiting for Slack in your browser…")
            try await TokenStore.saveToken(session.awaitToken())
            reloadClient()
        } catch let error as LoopbackReceiver.Failure {
            connection = .disconnected
            note(Self.describe(error), level: .failure)
        } catch let error as SlackError {
            connection = .disconnected
            note(error.summary, level: .failure)
        } catch let error as LoopbackIdentity.Failure {
            connection = .disconnected
            note(Self.describe(error), level: .failure)
        } catch {
            connection = .disconnected
            note("Could not complete the Slack connection.", level: .failure)
        }
    }

    /// Disconnecting puts the status back first. Dropping the token while OnAir still holds the
    /// status would strand it with nothing left that could restore it.
    func disconnect() async {
        if let client, let previous = engine.appliedPrevious {
            try? await client.setStatus(previous)
        }
        engine.forgetOwnership()
        TokenStore.deleteToken()
        client = nil
        connection = TokenStore.credentials()?.isComplete == true ? .disconnected : .notConfigured
        note("Disconnected from Slack.")
    }

    // MARK: - The loop

    /// Coalescing rather than dropping: a device change that arrives while a Slack call is in
    /// flight has to be looked at *after* it, or the camera could go off during the apply and
    /// nothing would ever put the status back.
    func pump() {
        guard pumpTask == nil else {
            pumpAgain = true
            return
        }
        pumpTask = Task { @MainActor in
            defer { pumpTask = nil }
            repeat {
                pumpAgain = false
                await performOnePass()
            } while pumpAgain
        }
    }

    private func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func performOnePass() async {
        let decision = engine.advance(
            cameraInUse: devices.cameraInUse,
            microphoneInUse: devices.microphoneInUse,
            policy: policy,
            now: Date()
        )
        scheduleWake(at: decision.wakeAt)

        switch decision.intent {
        case .doNothing:
            return
        case let .apply(wanted):
            await perform { try await self.apply(wanted, using: $0) }
        case let .restore(previous):
            await perform { try await self.restore(previous, using: $0) }
        }
    }

    private func perform(_ work: (SlackClient) async throws -> Void) async {
        guard let client, connection.isConnected else {
            // Not an error worth a history line on every tick: the menu already says "not
            // connected", and repeating it once a second would bury everything else.
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await work(client)
            retryDelay = Self.minimumRetry
        } catch let error as SlackError {
            engine.recordFailed()
            note(error.summary, level: .failure)
            if error.requiresReconnect {
                connection = .needsReconnect(error.summary)
                return
            }
            if case let .rateLimited(retryAfter) = error {
                scheduleWake(at: Date().addingTimeInterval(retryAfter))
                return
            }
            scheduleRetry()
        } catch {
            engine.recordFailed()
            note("Could not reach Slack.", level: .failure)
            scheduleRetry()
        }
    }

    private func apply(_ wanted: UserStatus, using client: SlackClient) async throws {
        // A previous already on file means this is a refresh — the emoji or the text changed
        // mid-call. Re-reading now would stash OnAir's own status as the thing to restore, and
        // the eventual restore would be a no-op that strands it (ADR-0008).
        if let previous = engine.appliedPrevious {
            try await client.setStatus(wanted)
            engine.recordApplied(status: wanted, previous: previous)
            note("Updated your status to \(wanted.text).")
            return
        }

        let live = try await client.currentStatus()
        if case let .leaveAlone(reason) = policy.verdict(forLive: live) {
            engine.recordSkipped(reason)
            note("Left your status alone — “\(live.text)” was already set.", level: .warning)
            return
        }
        try await client.setStatus(wanted)
        engine.recordApplied(status: wanted, previous: live)
        note("Set your status to \(wanted.text).")
    }

    private func restore(_ previous: UserStatus, using client: SlackClient) async throws {
        let live = try await client.currentStatus()
        guard engine.stillOwns(live) else {
            // Changed by hand during the call. OnAir does not own it any more, and putting the
            // old one back would silently undo a deliberate edit (ADR-0008).
            engine.recordRestored()
            note(
                "Your status changed while you were on camera — left it as it is.",
                level: .warning
            )
            return
        }
        try await client.setStatus(previous)
        engine.recordRestored()
        note(previous.isCleared ? "Cleared your status." : "Put “\(previous.text)” back.")
    }

    // MARK: - Timing

    private func scheduleWake(at date: Date?) {
        wakeTask?.cancel()
        guard let date else {
            wakeTask = nil
            return
        }
        wakeTask = Task { @MainActor in
            let interval = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            pump()
        }
    }

    private func scheduleRetry() {
        scheduleWake(at: Date().addingTimeInterval(retryDelay))
        retryDelay = min(retryDelay * 2, Self.maximumRetry)
    }

    // MARK: - History

    private func note(_ message: String, level: ActivityEntry.Level = .info) {
        history.insert(ActivityEntry(at: Date(), level: level, message: message), at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }

    private static func describe(_ failure: LoopbackReceiver.Failure) -> String {
        switch failure {
        case .identityUnusable:
            "The loopback certificate could not be used for TLS."
        case let .portUnavailable(port):
            "Port \(port) is already in use, so Slack's redirect has nowhere to land."
        case let .listenerFailed(detail):
            "The callback listener failed: \(detail)"
        case .timedOut:
            "Gave up waiting for Slack. Press Connect to try again."
        case let .declined(reason):
            "Slack did not authorise OnAir: \(reason)"
        case .stateMismatch:
            "The callback did not match the request OnAir made, so it was rejected."
        case .malformedRequest:
            "Something other than Slack's redirect arrived on the callback port."
        }
    }

    private static func describe(_ failure: LoopbackIdentity.Failure) -> String {
        switch failure {
        case let .toolMissing(path):
            "\(path) is missing, so the loopback certificate cannot be created."
        case let .toolFailed(command, status, stderr):
            "\(command) exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case let .importFailed(status):
            "The loopback certificate could not be read back (OSStatus \(status))."
        case .noIdentityInArchive:
            "The loopback certificate archive held no identity."
        }
    }
}
