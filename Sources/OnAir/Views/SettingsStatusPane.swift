import StatusKit
import SwiftUI

struct StatusPane: View {
    @Bindable var coordinator: AppCoordinator

    private static let presets = [
        (":movie_camera:", "On camera"),
        (":headphones:", "In a meeting"),
        (":red_circle:", "On air"),
        (":speech_balloon:", "On a call"),
    ]

    /// The glyph OnAir can resolve for what is typed, or `nil` when it cannot. `nil` does **not**
    /// mean Slack will reject it — a workspace custom emoji resolves nowhere but Slack — so the
    /// caption below says exactly that rather than calling it invalid (ADR-0014).
    private var resolvedGlyph: String? {
        EmojiShortcode.glyph(for: coordinator.policy.status.emoji)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OnAirMetrics.padding) {
            GroupBox {
                VStack(alignment: .leading, spacing: OnAirMetrics.gutter) {
                    FieldRow(label: "Emoji") {
                        TextField(":movie_camera:", text: $coordinator.policy.status.emoji)
                            .textFieldStyle(.roundedBorder)
                            .font(OnAirFont.mono)
                            .frame(width: OnAirMetrics.fieldWidth)
                        // A blank rather than nothing: the row would otherwise change height as
                        // the glyph appears and disappears on every keystroke. Hidden from
                        // VoiceOver like the other decorations — the field beside it already
                        // carries the value, and the caption below says what an absent glyph
                        // means, which is more than this element can honestly claim on its own.
                        Text(resolvedGlyph ?? " ")
                            .font(OnAirFont.title)
                            .accessibilityHidden(true)
                    }
                    FieldRow(label: "Text") {
                        TextField("On camera", text: $coordinator.policy.status.text)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: OnAirMetrics.fieldWidth)
                    }
                    // Slack takes the shortcode, not the glyph, and silently keeps the old emoji
                    // when given something it cannot resolve — which looks exactly like OnAir
                    // failing to write.
                    Text(emojiHint)
                        .font(OnAirFont.caption)
                        .foregroundStyle(OnAirColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(OnAirMetrics.tight)
            }

            HStack(spacing: OnAirMetrics.gutter) {
                ForEach(Self.presets, id: \.0) { emoji, text in
                    let status = UserStatus(emoji: emoji, text: text)
                    Button(status.display) {
                        coordinator.policy.status = status
                    }
                    .font(OnAirFont.compact)
                }
            }

            Toggle(isOn: $coordinator.policy.overrideExistingStatus) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replace a status I set myself")
                        .font(OnAirFont.body)
                    Text("Off: if you already have a status when the camera comes on, OnAir "
                        + "leaves it alone for that whole call.")
                        .font(OnAirFont.caption)
                        .foregroundStyle(OnAirColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: $coordinator.policy.pauseNotifications) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Also pause notifications (Do Not Disturb)")
                        .font(OnAirFont.body)
                    Text("Snoozes Slack while you are on camera, in half-hour slices that renew "
                        + "themselves, and resumes afterwards. A snooze you set yourself is never "
                        + "touched. Needs extra permissions: if you connected before this option "
                        + "existed, disconnect and reconnect once. Takes effect from the next "
                        + "call.")
                        .font(OnAirFont.caption)
                        .foregroundStyle(OnAirColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var emojiHint: String {
        let base = "Slack wants the shortcode with colons, like :movie_camera:."
        let emoji = coordinator.policy.status.emoji
        guard !emoji.isEmpty else { return base }
        // The preview renders `headphones` as happily as `:headphones:`, because it has to keep up
        // with a field being typed into. Slack does not: it answers ok and keeps the old emoji,
        // which looks exactly like OnAir failing to write. So the missing colons get their own
        // sentence rather than hiding behind a glyph that renders.
        guard EmojiShortcode.isWireShaped(emoji) else {
            return base + " Yours has no colons, and Slack will ignore it."
        }
        guard resolvedGlyph == nil else { return base }
        // Not "invalid": OnAir's table is the standard set, and a workspace custom emoji is real
        // to Slack and unknowable here. Saying which of the two this is would be inventing a fact.
        return base + " OnAir does not know this one, so it cannot show you the glyph — if it is "
            + "one of your workspace's custom emoji Slack will still resolve it, and if it is a "
            + "typo Slack keeps your old emoji and nothing appears to happen."
    }
}
