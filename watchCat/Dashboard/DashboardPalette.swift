import SwiftUI

/// Centralized color palette for the dashboard. Living in one file so charts,
/// chips, and category dots can't drift apart over time. Picked to read well in
/// both light and dark mode against `.thinMaterial`/`.regularMaterial` surfaces.
enum DashboardPalette {
    /// Primary accent (peaks, active states, primary chart fill). Soft electric
    /// indigo — distinctive enough to brand the app, calm enough for a long
    /// session of staring at the dashboard.
    static let accent = Color(.displayP3, red: 0.43, green: 0.36, blue: 0.96, opacity: 1)
    static let accentSoft = Color(.displayP3, red: 0.43, green: 0.36, blue: 0.96, opacity: 0.16)
    static let accentMuted = Color(.displayP3, red: 0.43, green: 0.36, blue: 0.96, opacity: 0.35)

    /// Warm highlight — used sparingly: peak-hour callouts and positive deltas.
    static let highlight = Color(.displayP3, red: 0.97, green: 0.69, blue: 0.21, opacity: 1)

    /// Heatmap / timeline gradient endpoints.
    static let cellEmpty = Color(.displayP3, red: 0.5, green: 0.5, blue: 0.55, opacity: 0.08)
    static let cellLow   = Color(.displayP3, red: 0.66, green: 0.61, blue: 0.96, opacity: 0.55)
    static let cellHigh  = Color(.displayP3, red: 0.30, green: 0.21, blue: 0.85, opacity: 1.0)

    /// Category colors used both in the donut chart and per-app row chips.
    /// Picked from a single jewel-tone family so legends stay coherent.
    static func color(for cat: AppCategory?) -> Color {
        switch cat {
        case .productivity:    return Color(.displayP3, red: 0.43, green: 0.36, blue: 0.96, opacity: 1)
        case .communication:   return Color(.displayP3, red: 0.07, green: 0.66, blue: 0.66, opacity: 1)
        case .entertainment:   return Color(.displayP3, red: 0.93, green: 0.42, blue: 0.51, opacity: 1)
        case .other:           return Color(.displayP3, red: 0.55, green: 0.56, blue: 0.62, opacity: 1)
        case nil:              return Color(.displayP3, red: 0.65, green: 0.66, blue: 0.72, opacity: 1)
        }
    }

    /// Up/down delta indicators.
    static let deltaUp   = Color(.displayP3, red: 0.20, green: 0.72, blue: 0.42, opacity: 1)
    static let deltaDown = Color(.displayP3, red: 0.86, green: 0.30, blue: 0.36, opacity: 1)

    /// Diverse jewel-tone series used wherever we need visual variety without
    /// a semantic mapping — e.g., per-page drill-down rows where each domain
    /// gets a stable color so users learn to recognize sites at a glance.
    /// Picked for perceptual balance across hues; saturation and value sit in
    /// the same band so no single color dominates the row.
    static let series: [Color] = [
        Color(.displayP3, red: 0.43, green: 0.36, blue: 0.96, opacity: 1),  // indigo
        Color(.displayP3, red: 0.07, green: 0.66, blue: 0.66, opacity: 1),  // teal
        Color(.displayP3, red: 0.93, green: 0.42, blue: 0.51, opacity: 1),  // rose
        Color(.displayP3, red: 0.97, green: 0.69, blue: 0.21, opacity: 1),  // amber
        Color(.displayP3, red: 0.40, green: 0.74, blue: 0.42, opacity: 1),  // sage
        Color(.displayP3, red: 0.62, green: 0.45, blue: 0.93, opacity: 1),  // violet
        Color(.displayP3, red: 0.99, green: 0.55, blue: 0.36, opacity: 1),  // peach
        Color(.displayP3, red: 0.36, green: 0.62, blue: 0.93, opacity: 1),  // sky
    ]

    /// Pick a stable color from `series` for an arbitrary key. Uses djb2 to
    /// distribute keys evenly across the palette — same string maps to the
    /// same color across renders, so `github.com` is always (say) teal and
    /// the eye learns to recognize it.
    static func stableColor(for key: String) -> Color {
        guard !key.isEmpty else { return series[0] }
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return series[Int(hash % UInt64(series.count))]
    }

    /// Subtle page background — a faint horizontal gradient that adds depth
    /// without competing with the cards.
    static let backgroundGradient = LinearGradient(
        colors: [
            Color(.displayP3, red: 0.96, green: 0.95, blue: 1.00, opacity: 1),
            Color(.displayP3, red: 0.99, green: 0.97, blue: 0.93, opacity: 1)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let backgroundGradientDark = LinearGradient(
        colors: [
            Color(.displayP3, red: 0.07, green: 0.07, blue: 0.10, opacity: 1),
            Color(.displayP3, red: 0.10, green: 0.08, blue: 0.13, opacity: 1)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// Hover + press affordances for tap-driven chips. SwiftUI on macOS doesn't
/// switch the cursor to a pointing hand for `Button`s automatically (unlike
/// `Link`), and `onTapGesture`-based chips need a visible "I'm pressable"
/// hint or they look static. This modifier adds:
///   - pointing-hand cursor on hover (via `NSCursor.pointingHand`),
///   - a brief scale + opacity dip on press for tactile feedback.
///
/// Use `.chipButton { ... }` on any view with a tap target.
struct ChipButton: ViewModifier {
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.94 : 1.0)
            .opacity(isPressed ? 0.7 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .onHover { hovering in
                isHovering = hovering
                if hovering { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed { isPressed = true }
                    }
                    .onEnded { _ in
                        // Only fire if the release happened inside the chip
                        // (i.e. the cursor is still hovering it). This matches
                        // the cancel-on-drag-out behavior of native buttons.
                        if isHovering { action() }
                        isPressed = false
                    }
            )
    }
}

/// Pointing-hand cursor on hover for views that already handle their own click
/// (real `Button`s). Used on the toolbar's chevron arrows and date chips.
struct PointingCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

extension View {
    /// Tap-target chip with hover cursor and press-down feedback.
    func chipButton(action: @escaping () -> Void) -> some View {
        modifier(ChipButton(action: action))
    }

    /// Pointing-hand cursor on hover, no other visual changes.
    func pointingCursor() -> some View { modifier(PointingCursor()) }
}

/// Pill-shaped button style with explicit foreground/background. macOS's
/// built-in `.plain` style ignores outer `.foregroundStyle` on text labels
/// inside a `Button`, which made our "오늘" / "CSV" buttons render as empty
/// pills. A custom `ButtonStyle` is the only reliable way to inject the
/// styling — `makeBody` gives full control over how the label is drawn.
struct PillButtonStyle: ButtonStyle {
    let foreground: Color
    let background: Color
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dbTag)
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Capsule(style: .continuous).fill(background))
            .contentShape(Capsule(style: .continuous))
            .opacity(configuration.isPressed ? 0.65 : 1.0)
    }
}

/// Reusable card surface used by every section. Picks the matching gradient
/// based on color scheme and adds a 1px hairline for definition on top of the
/// material — without that, cards float ambiguously over the page background.
struct DashboardCard<Content: View>: View {
    let title: String?
    let action: AnyView?
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    init(title: String? = nil, action: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.action = action
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || action != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.dbCardTitle)
                            .tracking(DashboardTracking.label)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                    Spacer()
                    if let action { action }
                }
            }
            content
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.background.opacity(scheme == .dark ? 0.45 : 0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(scheme == .dark ? 0.06 : 0.5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.06),
                radius: 12, x: 0, y: 4)
    }
}
