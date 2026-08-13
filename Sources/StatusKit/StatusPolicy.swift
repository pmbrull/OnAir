import Foundation

/// Everything the user can change about what OnAir does. A value, so a test can state a situation
/// in one literal and the app can persist the whole thing as one JSON blob.
public struct StatusPolicy: Sendable, Equatable, Codable {
    /// What to set while a device is in use.
    public var status: UserStatus

    public var watchCamera: Bool
    /// Off by default, and that default was measured rather than guessed. On a Mac running Elgato
    /// Wave Link, `IsRunningSomewhere` reads true for the interface *and* the built-in microphone
    /// continuously, because the mixer holds them open in the background — so watching the
    /// microphone would pin the status on permanently. Audio interfaces, Loopback, BlackHole,
    /// Krisp and dictation all behave the same way. The camera has no equivalent: nothing holds
    /// one open for hours (ADR-0011). Turn it on if `onair doctor` says your microphone is idle
    /// when you are not in a call.
    public var watchMicrophone: Bool

    /// Whether to replace a status that was already set when the camera came on. Default off: a
    /// status you typed yourself is a deliberate act, and clobbering it is the one failure mode
    /// that loses information rather than merely being wrong.
    public var overrideExistingStatus: Bool

    /// Whether to also snooze Slack's notifications while a device is in use (ADR-0013). Off by
    /// default: it is additive, it needs the `dnd` scopes — a connection made before this feature
    /// has to reconnect before it can work — and silencing someone's notifications is not a thing
    /// to opt them into.
    public var pauseNotifications: Bool

    /// Seconds a device must stay in use before OnAir writes anything. Cameras blip when an app
    /// enumerates them, and a blip should not reach your colleagues.
    public var onDelay: TimeInterval
    /// Seconds a device must stay idle before OnAir puts the old status back. Deliberately much
    /// longer than `onDelay`: leaving one meeting and joining the next is the common case, and
    /// two writes in that gap is thrash everyone can see.
    public var offDelay: TimeInterval

    /// Set from the menu bar. Takes effect immediately in both directions — a pause that waited
    /// out `offDelay` would not be a pause.
    public var paused: Bool

    public init(
        status: UserStatus,
        watchCamera: Bool,
        watchMicrophone: Bool,
        overrideExistingStatus: Bool,
        pauseNotifications: Bool = false,
        onDelay: TimeInterval,
        offDelay: TimeInterval,
        paused: Bool
    ) {
        self.status = status
        self.watchCamera = watchCamera
        self.watchMicrophone = watchMicrophone
        self.overrideExistingStatus = overrideExistingStatus
        self.pauseNotifications = pauseNotifications
        self.onDelay = onDelay
        self.offDelay = offDelay
        self.paused = paused
    }

    public static let standard = StatusPolicy(
        status: UserStatus(emoji: ":movie_camera:", text: "On camera"),
        watchCamera: true,
        watchMicrophone: false,
        overrideExistingStatus: false,
        pauseNotifications: false,
        onDelay: 3,
        offDelay: 60,
        paused: false
    )

    /// Decoding tolerates a policy written by an older build: a key this version added comes back
    /// as its `standard` value rather than failing the whole decode and resetting every setting.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = StatusPolicy.standard
        status = try container.decodeIfPresent(UserStatus.self, forKey: .status) ?? fallback.status
        watchCamera = try container.decodeIfPresent(Bool.self, forKey: .watchCamera)
            ?? fallback.watchCamera
        watchMicrophone = try container.decodeIfPresent(Bool.self, forKey: .watchMicrophone)
            ?? fallback.watchMicrophone
        overrideExistingStatus = try container
            .decodeIfPresent(Bool.self, forKey: .overrideExistingStatus)
            ?? fallback.overrideExistingStatus
        pauseNotifications = try container
            .decodeIfPresent(Bool.self, forKey: .pauseNotifications)
            ?? fallback.pauseNotifications
        onDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .onDelay)
            ?? fallback.onDelay
        offDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .offDelay)
            ?? fallback.offDelay
        paused = try container.decodeIfPresent(Bool.self, forKey: .paused) ?? fallback.paused
    }
}
