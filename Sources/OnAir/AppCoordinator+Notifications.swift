import Foundation
import SlackKit
import StatusKit

/// The Do Not Disturb half of the coordinator (ADR-0013), kept in its own file because it is a
/// self-contained lifecycle — take a snooze, renew it in slices, hand it back — that shares only
/// the Slack client and the history with the status path next door.
///
/// Like the rest of the coordinator, this decides nothing: `StatusPolicy.snoozeVerdict` says
/// whether a snooze may start and `SnoozeOwnership.stillOwns` says whether it is still OnAir's,
/// both in StatusKit where they are tested without a workspace (invariant A3).
extension AppCoordinator {
    /// Snooze failures deliberately never throw into the status path: the status is the primary
    /// job, and a broken snooze — most likely `missing_scope` on a pre-ADR-0013 connection — must
    /// not make the engine retry a status write that already succeeded.
    func beginSnoozeIfWanted(using client: SlackClient) async {
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

    func releaseSnoozeIfOwned(using client: SlackClient) async {
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
}
