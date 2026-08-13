import AppKit
import SwiftUI

/// The process entry point.
///
/// Not `main.swift` and not `@main` on the `App`: `onair doctor` has to run and exit without ever
/// standing up an `NSApplication`, and a SwiftUI `App` that has started cannot be un-started.
@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "doctor" {
            Doctor.runSynchronously(includeSlack: arguments.contains("--slack"))
            exit(0)
        }
        OnAirApp.main()
    }
}

struct OnAirApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var coordinator = AppCoordinator.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image(systemName: MenuBarSymbol.name(for: coordinator))
                .accessibilityLabel("OnAir")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        AppCoordinator.shared.start()
    }

    /// Quitting mid-meeting has to put the status back, and putting it back is a network call —
    /// so the app asks AppKit to wait. `terminateLater` is the only way to get that time; without
    /// it the process is gone before the request leaves, and the status stays on for the rest of
    /// the day with nothing left running to notice (ADR-0009).
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard AppCoordinator.shared.owesRestore else { return .terminateNow }
        Task { @MainActor in
            await AppCoordinator.shared.restoreBeforeQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
