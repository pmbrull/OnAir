import SwiftUI

/// The one place a colour, a font or a metric is chosen.
///
/// Deliberately built on AppKit's **semantic** colours rather than a hand-picked palette. OnAir has
/// two surfaces — a small menu panel and a settings window — and both sit inside system chrome, so
/// matching the system is the whole design goal. A literal hex would have to be maintained twice,
/// once per appearance, and would be visibly wrong beside the menu bar in one of them (ADR-0010).
enum OnAirColor {
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let raised = Color(nsColor: .underPageBackgroundColor)
    static let inset = Color(nsColor: .controlBackgroundColor)
    static let border = Color(nsColor: .separatorColor)

    static let textPrimary = Color(nsColor: .labelColor)
    static let textSecondary = Color(nsColor: .secondaryLabelColor)
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    /// State, never decoration.
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    /// The one colour that means "a device is live". Red because that is what a tally light is,
    /// and because it is the only thing on the panel worth looking at first.
    static let live = Color(nsColor: .systemRed)
    static let idle = Color(nsColor: .tertiaryLabelColor)
}

enum OnAirFont {
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12)
    static let compact = Font.system(size: 11)
    static let caption = Font.system(size: 10)
    /// For anything the reader compares character by character — a redirect URL, a port.
    static let mono = Font.system(size: 11, design: .monospaced)
}

enum OnAirMetrics {
    static let padding: CGFloat = 12
    static let gutter: CGFloat = 8
    static let tight: CGFloat = 4
    static let radius: CGFloat = 6
    static let dot: CGFloat = 8
    static let panelWidth: CGFloat = 300
    static let settingsWidth: CGFloat = 460
}

/// A device's state, as one dot. Decorative: the row's text already says it, so a screen reader
/// hearing it twice would be worse than not hearing it at all.
struct StatusDot: View {
    let isLive: Bool

    var body: some View {
        Circle()
            .fill(isLive ? OnAirColor.live : OnAirColor.idle)
            .frame(width: OnAirMetrics.dot, height: OnAirMetrics.dot)
            .accessibilityHidden(true)
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(OnAirColor.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// A label and a value on one line. The shape most of both surfaces is made of.
struct FieldRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: OnAirMetrics.gutter) {
            Text(label)
                .font(OnAirFont.body)
                .foregroundStyle(OnAirColor.textSecondary)
            Spacer(minLength: OnAirMetrics.gutter)
            trailing
        }
    }
}
