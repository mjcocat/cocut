import SwiftUI

/// Cocut's look, in one place: calm neutral surfaces so the film stands out, the Cocut blue
/// (the accent color) for selection and the one main action of a screen, red only for
/// recording, and green and orange only for status. Screens build from these tokens and
/// components rather than styling themselves.
enum Design {
    /// Spacing, on a 4-point grid.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Corner radii (always continuous).
    enum Radius {
        /// Thumbnails, chips' containers, small controls.
        static let small: CGFloat = 6
        /// Video, cards, list highlights.
        static let medium: CGFloat = 10
        /// Panels and banners.
        static let large: CGFloat = 14
    }

    /// The fill behind a grouped panel: a wash of the text color, so it suits light and dark.
    static let panelFill = Color.primary.opacity(0.045)
    /// A hairline edge on panels and media, so dark video doesn't melt into a dark window.
    static let hairline = Color.primary.opacity(0.08)
    /// Recording, and nothing else.
    static let record = Color.red
}

extension View {
    /// A grouped panel: soft fill, continuous corners, a hairline edge.
    func panel(padding: CGFloat = Design.Space.l, radius: CGFloat = Design.Radius.large) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Design.panelFill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Design.hairline, lineWidth: 1))
    }

    /// Video, thumbnails and cards: continuous corners with a hairline edge.
    func mediaFrame(radius: CGFloat = Design.Radius.medium) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Design.hairline, lineWidth: 1))
    }
}

/// A small uppercase heading over a group, like "RALLIES" or "THEN".
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A short status tag on a row: "Left out", "Card", "Added".
struct Pill: View {
    let text: String
    var icon: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.13)))
    }
}

/// A status strip: what happened or what's needed, and the actions for it. `card` sits inside
/// a screen's content; `strip` runs edge to edge along the top of a window.
struct Banner<Actions: View>: View {
    enum Tone {
        case info, success, warning

        var color: Color {
            switch self {
            case .info: return .accentColor
            case .success: return .green
            case .warning: return .orange
            }
        }
    }

    enum Style { case card, strip }

    let tone: Tone
    let icon: String
    let title: String
    var message: String?
    var style: Style = .card
    var onDismiss: (() -> Void)?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        let content = HStack(alignment: message == nil ? .center : .top, spacing: Design.Space.m) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tone.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                Text(title)
                    .font(.callout.weight(.semibold))
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Design.Space.s)
            HStack(spacing: Design.Space.s) { actions() }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .accessibilityElement(children: .contain)

        switch style {
        case .card:
            content
                .padding(.horizontal, Design.Space.l)
                .padding(.vertical, Design.Space.m)
                .background(RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                    .fill(tone.color.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.large, style: .continuous)
                    .strokeBorder(tone.color.opacity(0.22), lineWidth: 1))
        case .strip:
            content
                .padding(.horizontal, Design.Space.l)
                .padding(.vertical, Design.Space.s + 1)
                .background(tone.color.opacity(0.09))
                .overlay(alignment: .bottom) { Divider() }
        }
    }
}

extension Banner where Actions == EmptyView {
    init(tone: Tone, icon: String, title: String, message: String? = nil, style: Style = .card,
         onDismiss: (() -> Void)? = nil) {
        self.init(tone: tone, icon: icon, title: title, message: message, style: style,
                  onDismiss: onDismiss, actions: { EmptyView() })
    }
}

/// Animates changes to `value`, or not at all when Reduce Motion is on.
private struct MotionModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Cocut's standard motion: quick and settled, and none with Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation = .snappy, value: Value) -> some View {
        modifier(MotionModifier(animation: animation, value: value))
    }
}

/// A filled capsule button that keeps its color in windows that never become key, like the
/// region bar and the recording control floating over other apps, where the system's prominent
/// style fades as if it were disabled.
struct SolidButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.75 : 1)))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}
