import AppKit
import DeviceKit
import Foundation
import Observation
import SlackKit
import StatusKit

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
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var pumpAgain = false
    @ObservationIgnored private var retryDelay: TimeInterval = AppCoordinator.minimumRetry

    // Internal rather than private only because `AppCoordinator+Notifications.swift` is a separate
    // file, and Swift's `private` does not reach across one. Nothing outside the coordinator may
    // touch these: the snooze bookkeeping is the difference between handing back a Do Not Disturb
    // OnAir started and stamping on one the user set by hand (ADR-0013).
    @ObservationIgnored var client: SlackClient?
    @ObservationIgnored var snoozeOwnership = SnoozeOwnership()
    @ObservationIgnored var snoozeRenewalTask: Task<Void, Never>?

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
        // Unconditionally, not lazily on read: the common upgrade path — token present, Settings
        // never opened — would otherwise never touch the legacy item, and the retired client
        // secret would sit in the Keychain forever under a README that promises it is gone.
        if !TokenStore.scrubLegacyClientItem() {
            note(
                "Could not remove the retired Slack client secret from the Keychain; "
                    + "will retry at next launch.",
                level: .warning
            )
        }
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
        guard let client else { return }
        await releaseSnoozeIfOwned(using: client)
        guard let previous = engine.appliedPrevious else { return }
        // ADR-0008 applies on the way out too. Quitting is not a licence to overwrite a status the
        // user typed during the call — the check costs one extra call inside the window
        // `.terminateLater` buys, and skipping it would make quitting the one path that clobbers.
        //
        // A read that *fails* is deliberately treated the same as one that says "not yours": OnAir
        // then knows nothing about what Slack holds, and writing blind is the failure ADR-0008
        // calls the worst one, because it destroys text nothing else remembers. The cost is the
        // stranded status ADR-0009 already names and the README already warns about.
        guard let live = try? await client.currentStatus(), engine.stillOwns(live) else {
            engine.recordRestored()
            return
        }
        try? await putBack(previous, using: client)
        engine.recordRestored()
    }

    private func deviceStateChanged(_ snapshot: DeviceSnapshot) {
        devices = snapshot
        pump()
    }

    // MARK: - Slack connection

    func reloadClient() {
        // The token outranks the client id: a connected app stays connected even if the id that
        // bought the token is gone, because the id is only needed to mint the *next* token.
        guard let token = TokenStore.token() else {
            client = nil
            connection = resolvedClientID() == nil ? .notConfigured : .disconnected
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
        guard let source = resolvedClientID() else {
            note("This build has no Slack app id — add one in Settings.", level: .warning)
            return
        }
        connection = .connecting
        do {
            let session = try SlackOAuthSession(clientID: source.id)
            openInBrowser(session.authorizationURL)
            note("Waiting for Slack in your browser…")
            try await TokenStore.saveToken(session.awaitToken())
            reloadClient()
        } catch let error as LoopbackReceiver.Failure {
            connection = .disconnected
            note(error.summary, level: .failure)
        } catch let error as SlackError {
            connection = .disconnected
            note(error.summary, level: .failure)
        } catch {
            connection = .disconnected
            note("Could not complete the Slack connection.", level: .failure)
        }
    }

    /// Disconnecting puts the status back first. Dropping the token while OnAir still holds the
    /// status would strand it with nothing left that could restore it.
    func disconnect() async {
        if let client {
            await releaseSnoozeIfOwned(using: client)
            if let previous = engine.appliedPrevious {
                // The same ADR-0008 check the restore and the quit paths make. Without it this is
                // the one path that writes blind — and since ADR-0015 a blind write over a stash
                // whose expiry has passed writes a *clear*, deleting a status the user typed by
                // hand rather than merely replacing it.
                do {
                    let live = try await client.currentStatus()
                    if engine.stillOwns(live) {
                        try await putBack(previous, using: client)
                    } else {
                        note("Your status had changed — left it as it is.", level: .warning)
                    }
                } catch {
                    note(
                        "Could not put your status back before disconnecting.",
                        level: .failure
                    )
                }
            }
        }
        engine.forgetOwnership()
        snoozeOwnership.recordEnded()
        TokenStore.deleteToken()
        client = nil
        connection = resolvedClientID() == nil ? .notConfigured : .disconnected
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
            note("Updated your status to \(wanted.display).")
            await beginSnoozeIfWanted(using: client)
            return
        }

        let live = try await client.currentStatus()
        // `effectiveStatus`, not `status`: a status whose expiry has fallen due is one Slack has
        // already retired, and protecting it would leave OnAir writing nothing for a whole call
        // because of a status nobody can see. It is also the reading the restore side takes, and
        // the two must agree (ADR-0015).
        if case let .leaveAlone(reason) = policy.verdict(forLive: live.effectiveStatus(now: Date()))
        {
            engine.recordSkipped(reason)
            note(
                "Left your status alone — “\(live.status.display)” was already set.",
                level: .warning
            )
            return
        }
        try await client.setStatus(wanted)
        engine.recordApplied(status: wanted, previous: live)
        note("Set your status to \(wanted.display).")
        await beginSnoozeIfWanted(using: client)
    }

    private func restore(_ previous: LiveStatus, using client: SlackClient) async throws {
        let live = try await client.currentStatus()
        guard engine.stillOwns(live) else {
            // Changed by hand during the call. OnAir does not own it any more, and putting the
            // old one back would silently undo a deliberate edit (ADR-0008). The snooze is a
            // separate ownership with its own check — standing down on the status does not mean
            // abandoning a snooze OnAir started.
            engine.recordRestored()
            note(
                "Your status changed while you were on camera — left it as it is.",
                level: .warning
            )
            await releaseSnoozeIfOwned(using: client)
            return
        }
        try await putBack(previous, using: client)
        engine.recordRestored()
        await releaseSnoozeIfOwned(using: client)
    }

    /// Put a stashed status back the way it was always going to end, and say which way that was.
    ///
    /// The expiry travels with it: a status written by Google Calendar or any other integration
    /// carries the clock that was going to clear it, and those integrations do not come back to
    /// tidy up — writing the words without the clock is what leaves someone "In a meeting" for the
    /// rest of the day (ADR-0015). The decision of *which* of the two things to write is
    /// `LiveStatus.restoration`, in `StatusKit`, where it is tested (A3).
    ///
    /// It writes its own history line rather than returning one, so every caller reports the
    /// outcome — the clear is the surprising branch, and the path that dropped it silently was the
    /// one where the user is still looking at the menu.
    private func putBack(_ previous: LiveStatus, using client: SlackClient) async throws {
        switch previous.restoration(now: Date()) {
        case let .put(status, expiresAt):
            try await client.setStatus(status, expiresAt: expiresAt)
            note(status.isCleared ? "Cleared your status." : "Put “\(status.display)” back.")
        case .expired:
            try await client.setStatus(.cleared)
            note(
                "“\(previous.status.display)” expired during your call — cleared your status "
                    + "instead of putting it back.",
                level: .warning
            )
        }
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

    /// Internal for the same reason as `client` above — the notifications extension reports
    /// through it, and it lives in another file.
    func note(_ message: String, level: ActivityEntry.Level = .info) {
        history.insert(ActivityEntry(at: Date(), level: level, message: message), at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
    }
}
