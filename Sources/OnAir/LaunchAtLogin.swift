import Foundation
import ServiceManagement

/// The login item, via `SMAppService`.
///
/// It only works from a real `.app` — `swift run` and an ad-hoc-signed bundle both fail, and they
/// fail differently. The failure is returned rather than swallowed so Settings can say which of
/// the two happened instead of showing a switch that quietly does nothing
/// (`.claude/rules/no-silent-fallbacks.md`).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// `true` when macOS is holding the registration until the user approves it in
    /// System Settings › General › Login Items, which looks exactly like "it didn't work".
    static var awaitingApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
