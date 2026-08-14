import AppKit
import DeviceKit
import Foundation
import Observation
import SlackKit
import StatusKit

/// The one place the Keychain override meets the kit's precedence rule. The rule itself lives in
/// `SlackOAuth.resolveClientID`, where it is tested (A3); this is only the join.
func resolvedClientID() -> SlackOAuth.ClientIDSource? {
    SlackOAuth.resolveClientID(override: TokenStore.clientIDOverride())
}

/// How OnAir stands with Slack right now.
enum ConnectionState: Equatable {
    /// No built-in client id in this build and none pasted — Connect has nothing to authorise
    /// against.
    case notConfigured
    /// A client id to authorise with, but no token: the user has not pressed Connect.
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
    @ObservationIgnored private var snoozeOwnership = SnoozeOwnership()
    @ObservationIgnored private var snoozeRenewalTask: Task<Void, Never>?

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
            let session = try SlackOAuthSession(
                clientID: source.id,
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

    // MARK: - Notifications (ADR-0013)

    /// Snooze failures deliberately never throw into the status path: the status is the primary
    /// job, and a broken snooze — most likely `missing_scope` on a pre-ADR-0013 connection — must
    /// not make the engine retry a status write that already succeeded.
    private func beginSnoozeIfWanted(using client: SlackClient) async {
        guard policy.pauseNotifications, !snoozeOwnership.ownsASnooze else { return }
        do {
            let live = try await client.snoozeState()
            guard policy.snoozeVerdict(forLive: live) == .start else {
                note(
                    "Left Do Not Disturb alone — you already have a snooze running.",
                    level: .warning
                )
                return
            }
            let set = try await client.setSnooze(minutes: StatusPolicy.snoozeSliceMinutes)
            guard let endtime = set.endsAt else {
                note("Slack accepted the snooze but reported no end time.", level: .warning)
                return
            }
            snoozeOwnership.recordStarted(endtime: endtime)
            note("Paused Slack notifications.")
            scheduleSnoozeRenewal()
        } catch let error as SlackError {
            reportSnoozeProblem(error)
        } catch {
            note("Could not pause notifications.", level: .warning)
        }
    }

    /// Each slice is renewed shortly before it lapses, for as long as OnAir still owns the
    /// snooze. Slices rather than one long snooze so a crash self-heals within
    /// `snoozeSliceMinutes` — the opposite trade to the status (ADR-0009 vs ADR-0013).
    private func scheduleSnoozeRenewal() {
        snoozeRenewalTask?.cancel()
        snoozeRenewalTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(StatusPolicy.snoozeRenewalDelay))
            guard !Task.isCancelled else { return }
            await renewSnooze()
        }
    }

    private func renewSnooze() async {
        guard let client, snoozeOwnership.ownsASnooze, policy.pauseNotifications else { return }
        do {
            let live = try await client.snoozeState()
            guard snoozeOwnership.stillOwns(live) else {
                // Ended or changed by hand mid-call: theirs now, stop renewing (ADR-0013).
                snoozeOwnership.recordEnded()
                return
            }
            let set = try await client.setSnooze(minutes: StatusPolicy.snoozeSliceMinutes)
            if let endtime = set.endsAt {
                snoozeOwnership.recordStarted(endtime: endtime)
                scheduleSnoozeRenewal()
            } else {
                snoozeOwnership.recordEnded()
                note("Slack accepted a snooze renewal but reported no end time.", level: .warning)
            }
        } catch let error as SlackError {
            // The current slice still runs out on its own, so a failed renewal degrades to
            // "notifications come back a little early", said out loud.
            snoozeOwnership.recordEnded()
            reportSnoozeProblem(error)
        } catch {
            snoozeOwnership.recordEnded()
            note(
                "Could not renew the notification snooze; it will lapse on its own.",
                level: .warning
            )
        }
    }

    private func releaseSnoozeIfOwned(using client: SlackClient) async {
        // Cancel, then WAIT: an in-flight renewal past its cancellation check could otherwise
        // mutate ownership between this function's guard and its own bookkeeping.
        if let task = snoozeRenewalTask {
            task.cancel()
            await task.value
            snoozeRenewalTask = nil
        }
        guard snoozeOwnership.ownsASnooze else { return }
        do {
            let live = try await client.snoozeState()
            guard snoozeOwnership.stillOwns(live) else {
                snoozeOwnership.recordEnded()
                // A slice that ran out is not the user's doing — blame no hand that never moved.
                if live.isSnoozing {
                    note(
                        "Your Do Not Disturb changed during the call — left it as it is.",
                        level: .warning
                    )
                }
                return
            }
            try await client.endSnooze()
            snoozeOwnership.recordEnded()
            note("Resumed Slack notifications.")
        } catch let error as SlackError {
            // Give up rather than retry: the slice expires by itself within minutes, which is
            // the safety property the slicing bought (ADR-0013).
            snoozeOwnership.recordEnded()
            reportSnoozeProblem(error)
        } catch {
            snoozeOwnership.recordEnded()
            note(
                "Could not resume notifications; the snooze will lapse on its own.",
                level: .warning
            )
        }
    }

    private func reportSnoozeProblem(_ error: SlackError) {
        if case .api(code: "missing_scope") = error {
            note(
                "Pausing notifications needs new permissions — disconnect and reconnect Slack once.",
                level: .warning
            )
            return
        }
        note(error.summary, level: .warning)
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
