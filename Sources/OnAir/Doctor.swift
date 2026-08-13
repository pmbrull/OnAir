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
        let hasStored = TokenStore.token() != nil
        print("  \(pad("user credential", 22))\(hasStored ? "present in the Keychain" : "missing")")
        print("  \(pad("redirect URL", 22))\(SlackOAuth.redirectURI())")

        guard includeSlack else {
            print("\n  (pass --slack for one read-only round trip against these)")
            return
        }
        guard let stored = TokenStore.token() else {
            print("\n  cannot reach Slack: nothing stored. Connect from Settings first.")
            return
        }

        let client = SlackClient(token: stored)
        do {
            let identity = try await client.identity()
            print("  \(pad("identity", 22))\(identity.userName) in \(identity.teamName)")
            let live = try await client.currentStatus()
            print(
                "  \(pad("your status now", 22))\(live.status.isCleared ? "(none)" : live.status.display)"
            )
            // The field ADR-0015 is about. A third-party status carries the clock that will clear
            // it, and printing it is how the next person sees that OnAir is carrying it too.
            print("  \(pad("expires", 22))\(describe(expiry: live.expiresAt))")
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

    private static func describe(expiry: Int) -> String {
        guard expiry > 0 else { return "never (nothing will clear it but you or OnAir)" }
        let at = Date(timeIntervalSince1970: TimeInterval(expiry))
        let when = at.formatted(date: .abbreviated, time: .shortened)
        return at > Date() ? "\(when) — Slack will clear it then" : "\(when) — already passed"
    }
}
