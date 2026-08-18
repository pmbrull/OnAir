import DeviceKit
import Foundation
import SlackKit
import StatusKit

/// Everything the app does, minus the window.
///
/// This is how a change gets validated without sitting in a meeting and without clicking: which
/// devices this Mac actually has, what each of them says right now, what the policy is, and what
/// the engine would do about it. `--slack` adds one **read-only** round trip — it never writes a
/// status, because a diagnostic that changes what it is diagnosing is not one.
enum Doctor {
    static func runSynchronously(includeSlack: Bool) {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await run(includeSlack: includeSlack)
            done.signal()
        }
        done.wait()
    }

    static func run(includeSlack: Bool) async {
        print("OnAir doctor\n")
        let snapshot = reportDevices()
        let policy = reportPolicy()
        reportEngine(snapshot: snapshot, policy: policy)
        await reportSlack(includeSlack: includeSlack)
    }

    // MARK: - Devices

    private static func reportDevices() -> DeviceSnapshot {
        section("Devices")
        let watcher = DeviceWatcher()
        let devices = watcher.inventory()
        if devices.isEmpty {
            // Not "no camera": an empty list is equally consistent with the enumeration failing,
            // and saying which one this is would be inventing a fact.
            print("  none reported by CoreMediaIO or CoreAudio")
        }
        for device in devices {
            let name = device.name ?? "(unnamed \(device.objectID))"
            print(
                "  \(pad(device.kind.rawValue, 12))\(pad(name, 34))\(device.isRunning ? "in use" : "idle")"
            )
        }

        let cameraInUse = devices.contains { $0.kind == .camera && $0.isRunning }
        let microphoneInUse = devices.contains { $0.kind == .microphone && $0.isRunning }
        print("")
        print("  camera      \(cameraInUse ? "in use" : "idle")")
        print("  microphone  \(microphoneInUse ? "in use" : "idle")")
        print("")
        return DeviceSnapshot(cameraInUse: cameraInUse, microphoneInUse: microphoneInUse)
    }

    // MARK: - Policy

    private static func reportPolicy() -> StatusPolicy {
        let policy = PolicyStore.load()
        section("Policy")
        print("  \(pad("status", 22))\(policy.status.display)")
        print("  \(pad("watch camera", 22))\(yesNo(policy.watchCamera))")
        print("  \(pad("watch microphone", 22))\(yesNo(policy.watchMicrophone))")
        print("  \(pad("replace my own", 22))\(yesNo(policy.overrideExistingStatus))")
        print("  \(pad("debounce", 22))on \(Int(policy.onDelay))s / off \(Int(policy.offDelay))s")
        print("  \(pad("running", 22))\(yesNo(policy.isRunning))")
        print("")
        return policy
    }

    // MARK: - Engine

    private static func reportEngine(snapshot: DeviceSnapshot, policy: StatusPolicy) {
        section("Engine")
        var engine = StatusEngine()
        let now = Date()
        let immediate = engine.advance(
            cameraInUse: snapshot.cameraInUse,
            microphoneInUse: snapshot.microphoneInUse,
            policy: policy,
            now: now
        )
        // Reported from a *fresh* engine, so this says what OnAir would do starting from nothing
        // — not what the running app, which may already own the status, would do next.
        if let wakeAt = immediate.wakeAt {
            let wait = Int(wakeAt.timeIntervalSince(now).rounded())
            let settled = engine.advance(
                cameraInUse: snapshot.cameraInUse,
                microphoneInUse: snapshot.microphoneInUse,
                policy: policy,
                now: wakeAt
            )
            print("  waits \(wait)s, then: \(describe(settled.intent))")
        } else {
            print("  \(describe(immediate.intent))")
        }
        print("")
    }

    private static func describe(_ intent: StatusIntent) -> String {
        switch intent {
        case .doNothing:
            "nothing to do"
        case let .apply(status):
            "would set \(status.display)"
        case let .restore(previous):
            previous.status.isCleared
                ? "would clear your status"
                : "would restore “\(previous.status.text)”"
        }
    }

    // MARK: - Slack

    private static func reportSlack(includeSlack: Bool) async {
        section("Slack")
        // Which id Connect would use, and where it came from — the same resolution the app runs,
        // so doctor cannot drift into reporting an id Connect would refuse (ADR-0012).
        let clientID = switch SlackOAuth.resolveClientID(override: TokenStore.clientIDOverride()) {
        case .pasted: "your own app's (pasted)"
        case .builtIn: "built-in shared app"
        case nil: "missing — no built-in id in this build and none pasted"
        }
        print("  \(pad("client id", 22))\(clientID)")
        let stored = TokenStore.credential()
        print(
            "  \(pad("user credential", 22))"
                + (stored == nil ? "missing" : "present in the Keychain")
        )
        if let stored {
            print("  \(pad("renewal", 22))\(describe(renewalOf: stored))")
        }
        print("  \(pad("redirect URL", 22))\(SlackOAuth.redirectURI)")
        print("  \(pad("callback port", 22))\(SlackOAuth.defaultPort) (loopback, plain HTTP)")

        guard includeSlack else {
            print("\n  (pass --slack for one read-only round trip against these)")
            return
        }
        guard let stored else {
            print("\n  cannot reach Slack: nothing stored. Connect from Settings first.")
            return
        }
        // Doctor renews nothing — it is the read-only command, and a diagnostic that quietly
        // rotated the user's credential would change the thing it was asked to report on. It says
        // so instead, because `token_expired` from a credential the app would have renewed reads
        // as a broken connection when it is not (ADR-0020).
        if case .refreshNow = TokenRefresh.plan(for: stored, now: Date()) {
            print("\n  (the app would renew this before calling; doctor does not)")
        }

        let client = SlackClient(token: stored.accessToken)
        do {
            let identity = try await client.identity()
            print("  \(pad("identity", 22))\(identity.userName) in \(identity.teamName)")
            let live = try await client.currentStatus()
            print(
                "  \(pad("your status now", 22))\(live.status.isCleared ? "(none)" : live.status.display)"
            )
            // The field ADR-0015 is about. A third-party status carries the clock that will clear
            // it, and printing it is how the next person sees that OnAir is carrying it too.
            print("  \(pad("expires", 22))\(describe(expiry: live))")
        } catch let error as SlackError {
            print("  \(error.summary)")
            if error.requiresReconnect {
                print("  → reconnect from Settings; retrying will not help.")
            }
        } catch {
            print("  could not reach Slack: \(error.localizedDescription)")
        }
    }

    // MARK: - Formatting

    private static func section(_ title: String) {
        print(title)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }

    /// What OnAir would do about the stored credential's expiry, asked of `TokenRefresh` rather
    /// than re-derived — doctor's contract is "what the app would decide" (A3), and the unreadable
    /// case is called out separately because it is a bug in OnAir rather than a state Slack put
    /// the user in (ADR-0020).
    private static func describe(renewalOf credential: SlackCredential) -> String {
        switch TokenRefresh.plan(for: credential, now: Date()) {
        case .noExpiry:
            // Two different facts reach `.noExpiry`, and only one of them is reassuring. A
            // credential stored before ADR-0020 has no record at all, so nothing here knows
            // whether it expires — and on the machine this feature came from, it did.
            switch TokenStore.renewalRecord() {
            case .absent:
                return "unknown — stored before OnAir could renew; reconnect to find out"
            case .unreadable:
                return "record unreadable — OnAir cannot renew; reconnect to replace it"
            case .present:
                return "not needed — Slack issued no expiry"
            }
        case .refreshNow:
            return "due now — the app renews before its next call"
        case let .refreshAt(date):
            let when = date.formatted(date: .abbreviated, time: .shortened)
            return "scheduled for \(when)"
        case let .cannotRenew(expiresAt):
            let when = expiresAt.formatted(date: .abbreviated, time: .shortened)
            return "impossible — expires \(when) and Slack sent nothing to renew it with"
        }
    }

    /// Asks `LiveStatus` rather than comparing the timestamp here. Doctor's contract is "what the
    /// engine would decide", so re-deriving the predicate would let this command disagree with the
    /// app the moment the rule moves — in the one place people come to be told the truth (A3).
    private static func describe(expiry live: LiveStatus) -> String {
        guard live.expiresAt > 0 else { return "never (nothing will clear it but you or OnAir)" }
        let at = Date(timeIntervalSince1970: TimeInterval(live.expiresAt))
        let when = at.formatted(date: .abbreviated, time: .shortened)
        return live.hasExpired(now: Date())
            ? "\(when) — already passed; OnAir would clear rather than restore"
            : "\(when) — Slack will clear it then"
    }
}
