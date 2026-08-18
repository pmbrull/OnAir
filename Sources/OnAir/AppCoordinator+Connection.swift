import AppKit
import Foundation
import SlackKit

/// The Slack half of the coordinator: getting a credential, keeping it alive, and giving it back.
///
/// Split from `AppCoordinator.swift` because the two halves are read for different reasons — one is
/// "what does OnAir do when the camera turns on", the other is "why am I still logged in" — and
/// because ADR-0020's renewal loop pushed the single file past what a reviewer reads in one
/// sitting.
/// The stored properties it touches stay in the class: Swift has no stored properties in
/// extensions,
/// and `private` does not reach across a file, which is why they read as internal there.
@MainActor
extension AppCoordinator {
    // MARK: - Slack connection

    func reloadClient() {
        // The stored credential outranks the client id: a connected app stays connected even if
        // the id that bought it is gone. The id is needed to mint the *next* one — which, since
        // ADR-0020, includes every renewal, so an id that disappears is a slow disconnection
        // rather than none at all. `renew` says so when it happens.
        guard let stored = TokenStore.credential() else {
            forgetCredential()
            report(resolvedClientID() == nil ? .notConfigured : .disconnected)
            return
        }
        adopt(stored)
        Task { await confirmIdentity() }
    }

    private func confirmIdentity() async {
        guard client != nil else { return }
        report(.connecting)
        do {
            try await report(.connected(callSlack { try await $0.identity() }))
            pump()
        } catch let error as SlackError {
            report(error.requiresReconnect ? .needsReconnect(error.summary) : .disconnected)
            note(error.summary, level: .failure)
        } catch {
            report(.disconnected)
            note("Could not reach Slack.", level: .failure)
        }
    }

    // MARK: - Keeping the credential alive (ADR-0020)

    private func adopt(_ credential: SlackCredential) {
        self.credential = credential
        client = SlackClient(token: credential.accessToken)
        credentialGeneration += 1
        reportedUnrenewable = false
    }

    private func forgetCredential() {
        credential = nil
        client = nil
        credentialGeneration += 1
        renewalWakeTask?.cancel()
        renewalWakeTask = nil
        renewalTask?.cancel()
        reportedUnrenewable = false
    }

    /// Every Slack call goes through here, so there is one answer to "is the credential still
    /// good?" instead of one per call site.
    ///
    /// Two chances, because a rotating token can expire between the check and the answer: renew if
    /// the plan says it is due, and renew once more if Slack says `token_expired` anyway. The
    /// second is not belt-and-braces — the machine can sleep between the two lines.
    ///
    /// The generation check is what stops two calls that expired together from renewing twice.
    /// Slack's refresh tokens are single-use, so the second renewal is not merely wasted work: it
    /// spends the token the first one just minted, and every extra rotation is another chance to
    /// lose the chain to a crash or a dropped connection.
    func callSlack<T>(_ work: (SlackClient) async throws -> T) async throws -> T {
        await renewIfDue()
        guard let client else { throw SlackError.api(code: "not_authed") }
        let generation = credentialGeneration
        do {
            return try await work(client)
        } catch SlackError.api(code: "token_expired") {
            if credentialGeneration == generation, await renew() == false {
                throw SlackError.api(code: "token_expired")
            }
            guard let renewed = self.client else { throw SlackError.api(code: "token_expired") }
            return try await work(renewed)
        }
    }

    /// What `TokenRefresh.plan` says, performed. The decision itself is a pure function in the kit
    /// so it can be tested without a Keychain or a network (A3).
    func renewIfDue() async {
        guard let credential else { return }
        switch TokenRefresh.plan(for: credential, now: Date()) {
        case .noExpiry:
            renewalWakeTask?.cancel()
            renewalWakeTask = nil
        case .refreshNow:
            _ = await renew()
        case let .refreshAt(date):
            scheduleRenewal(at: date)
        case let .cannotRenew(expiresAt):
            guard !reportedUnrenewable else { return }
            reportedUnrenewable = true
            note(
                "Slack issued a credential that expires \(Self.when(expiresAt)) and gave OnAir "
                    + "no way to renew it — you will have to reconnect then.",
                level: .warning
            )
        }
    }

    @discardableResult
    private func renew() async -> Bool {
        if let renewalTask {
            return await renewalTask.value
        }
        let task = Task { @MainActor in await performRenewal() }
        renewalTask = task
        let renewed = await task.value
        renewalTask = nil
        return renewed
    }

    private func performRenewal() async -> Bool {
        guard let refresh = credential?.refreshToken else { return false }
        guard let source = resolvedClientID() else {
            note(
                "Cannot renew the Slack connection: this build has no Slack app id.",
                level: .failure
            )
            return false
        }
        do {
            let renewed = try await SlackOAuth.renew(refreshToken: refresh, clientID: source.id)
            do {
                try TokenStore.saveCredential(renewed)
            } catch {
                // The renewed credential works for this session either way, so OnAir keeps it —
                // but the refresh token that came with it is now the only one Slack will accept
                // and it is not on disk. Saying so is the difference between "reconnect at the
                // next launch for no visible reason" and a line that explains it.
                note(
                    "Renewed the Slack connection, but could not save it to the Keychain — "
                        + "you may have to reconnect after quitting.",
                    level: .warning
                )
            }
            adopt(renewed)
            renewalRetry = Self.minimumRetry
            scheduleRenewalIfWanted(for: renewed)
            // A call the user did not ask for, touching the thing that keeps OnAir connected. It
            // says so — a background credential rotation that leaves no trace is indistinguishable
            // from one that never ran when someone comes to work out why they were logged out.
            note("Renewed the Slack connection.")
            return true
        } catch let error as SlackError {
            reportRenewalFailure(error)
            return false
        } catch {
            note("Could not reach Slack to renew the connection.", level: .warning)
            scheduleRenewalRetry()
            return false
        }
    }

    /// A renewal Slack *refuses* is the end of the chain — the refresh token is spent, revoked or
    /// past its 30 days, and only a human can fix it. A renewal that never reached Slack is a
    /// different thing entirely: the current credential is still valid until its expiry, so OnAir
    /// keeps it and tries again rather than declaring a disconnection over a dropped Wi-Fi.
    private func reportRenewalFailure(_ error: SlackError) {
        switch error {
        case let .rateLimited(retryAfter):
            note(error.summary, level: .warning)
            scheduleRenewal(at: Date().addingTimeInterval(retryAfter))
        case .transport, .http, .malformedResponse:
            note("Could not renew the Slack connection: \(error.summary)", level: .warning)
            scheduleRenewalRetry()
        case .api:
            report(.needsReconnect(error.summary))
            note(
                "Slack would not renew the connection (\(error.summary)) — reconnect from Settings.",
                level: .failure
            )
        }
    }

    private func scheduleRenewalIfWanted(for credential: SlackCredential) {
        if case let .refreshAt(date) = TokenRefresh.plan(for: credential, now: Date()) {
            scheduleRenewal(at: date)
        }
    }

    /// Separate from `scheduleWake`: that one drives the status machine, and a renewal that
    /// cancelled a pending restore would leave a status set for the length of a token's life.
    private func scheduleRenewalRetry() {
        scheduleRenewal(at: Date().addingTimeInterval(renewalRetry))
        renewalRetry = min(renewalRetry * 2, Self.maximumRetry)
    }

    private func scheduleRenewal(at date: Date) {
        renewalWakeTask?.cancel()
        renewalWakeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await renewIfDue()
        }
    }

    private static func when(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    func connect() async {
        guard let source = resolvedClientID() else {
            note("This build has no Slack app id — add one in Settings.", level: .warning)
            return
        }
        report(.connecting)
        do {
            let session = try SlackOAuthSession(clientID: source.id)
            openInBrowser(session.authorizationURL)
            note("Waiting for Slack in your browser…")
            try await TokenStore.saveCredential(session.awaitCredential())
            reloadClient()
        } catch let error as LoopbackReceiver.Failure {
            report(.disconnected)
            note(error.summary, level: .failure)
        } catch let error as SlackError {
            report(.disconnected)
            note(error.summary, level: .failure)
        } catch {
            report(.disconnected)
            note("Could not complete the Slack connection.", level: .failure)
        }
    }

    /// Disconnecting puts the status back first. Dropping the token while OnAir still holds the
    /// status would strand it with nothing left that could restore it.
    func disconnect() async {
        // Before anything is read or written: an expired credential here would fail the ownership
        // check, and the branch that takes is "leave the status alone" — stranding the very status
        // this method exists to put back (ADR-0020).
        await renewIfDue()
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
        TokenStore.deleteCredential()
        forgetCredential()
        report(resolvedClientID() == nil ? .notConfigured : .disconnected)
        note("Disconnected from Slack.")
    }

    /// `NSWorkspace` is the reason `SlackOAuthSession` hands back a URL instead of opening it: a
    /// kit
    /// that imports AppKit stops being testable and stops being reusable (invariant A2, ADR-0002).
    private func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
