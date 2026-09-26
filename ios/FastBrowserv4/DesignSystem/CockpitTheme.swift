import SwiftUI

/// The app's single colour vocabulary.
///
/// Before this existed the same electric cyan was hand-typed 68 times across
/// 18 screens, four different surface treatments were in use, and "paused"
/// was a slightly different amber depending on which view drew it. Every
/// colour decision now resolves here, so a screen reached from the tab bar
/// cannot look like it belongs to a different app than the one it was opened
/// from.
///
/// Semantics, not shades: call sites ask for `.live` or `.attention`, never
/// for "cyan" or "amber". That is what lets the palette be retuned in one
/// place without hunting for literals again.
enum Cockpit {

    // MARK: - Surfaces

    /// Deepest layer — the canvas everything else sits on.
    static let canvas = Color(red: 0.043, green: 0.063, blue: 0.082)

    /// Raised charcoal panel: cards, sheets, grouped rows.
    static let surface = Color(red: 0.082, green: 0.110, blue: 0.141)

    /// One step brighter than `surface`, for a panel resting on a panel.
    static let surfaceRaised = Color(red: 0.118, green: 0.157, blue: 0.200)

    /// Pressed / selected fill for controls sitting on `surface`.
    static let surfaceActive = Color(red: 0.153, green: 0.204, blue: 0.259)

    /// Hairline between panels and around chips.
    static let hairline = Color.white.opacity(0.10)

    /// Stronger border, for the focused window ring and selected controls.
    static let hairlineStrong = Color.white.opacity(0.22)

    // MARK: - Semantic accents

    /// Electric cyan. Live, running, focused, primary action.
    static let live = Color(red: 0.133, green: 0.827, blue: 0.933)

    /// Amber. Paused, waiting on you, degraded but not broken.
    static let attention = Color(red: 0.961, green: 0.620, blue: 0.043)

    /// Green. Succeeded, caught up, healthy.
    static let success = Color(red: 0.063, green: 0.725, blue: 0.506)

    /// Red. Burn, delete, failed for good.
    static let danger = Color(red: 0.937, green: 0.267, blue: 0.267)

    /// Warm gold. Everything card-related, so the wallet, the window map and
    /// the fill button read as one feature next to the run button's cyan.
    static let card = Color(red: 0.929, green: 0.722, blue: 0.310)

    /// Violet. Site A in dual-site mode.
    static let laneA = Color(red: 0.663, green: 0.545, blue: 0.984)

    /// Orange. Site B in dual-site mode.
    static let laneB = Color(red: 0.984, green: 0.573, blue: 0.235)

    // MARK: - Text

    static let textPrimary = Color(red: 0.925, green: 0.949, blue: 0.973)
    static let textSecondary = Color(red: 0.612, green: 0.667, blue: 0.729)
    static let textTertiary = Color(red: 0.408, green: 0.459, blue: 0.522)

    /// Text that sits on top of a filled accent (cyan, gold, green).
    static let onAccent = Color(red: 0.031, green: 0.047, blue: 0.063)

    // MARK: - Spacing

    /// One spacing rhythm. Every gap and inset in the app is one of these.
    enum Space {
        /// 4 — inside a chip, between an icon and its own label.
        static let hair: CGFloat = 4
        /// 8 — between tightly related controls.
        static let tight: CGFloat = 8
        /// 12 — inside a panel.
        static let snug: CGFloat = 12
        /// 16 — the standard screen margin.
        static let base: CGFloat = 16
        /// 24 — between distinct groups.
        static let loose: CGFloat = 24
        /// 32 — around a section that should breathe.
        static let section: CGFloat = 32
    }

    // MARK: - Radius

    enum Radius {
        /// 8 — chips, small tiles.
        static let small: CGFloat = 8
        /// 12 — buttons, rows.
        static let medium: CGFloat = 12
        /// 16 — panels and cards.
        static let large: CGFloat = 16
        /// 22 — the floating dock and other free-standing surfaces.
        static let dock: CGFloat = 22
    }

    // MARK: - Motion

    /// Springs, named for what they are used on rather than their numbers, so
    /// two things that should feel the same actually do.
    enum Motion {
        /// Chips, badges, small state flips.
        static let quick = Animation.spring(response: 0.28, dampingFraction: 0.72)
        /// Panels sliding, toolbars hiding.
        static let panel = Animation.spring(response: 0.36, dampingFraction: 0.84)
        /// Layout changes big enough to need settling.
        static let layout = Animation.spring(response: 0.44, dampingFraction: 0.9)
    }
}

// MARK: - Typography

extension Font {
    /// Screen title.
    static let cockpitTitle = Font.system(.title2, design: .rounded).weight(.heavy)
    /// Section heading inside a screen.
    static let cockpitHeading = Font.system(.headline, design: .rounded).weight(.bold)
    /// Standard row text.
    static let cockpitBody = Font.system(.subheadline)
    /// Supporting text under a row.
    static let cockpitCaption = Font.system(.caption)
    /// Chip and badge text — small, heavy, rounded.
    static let cockpitChip = Font.system(size: 11, weight: .heavy, design: .rounded)
    /// Counters and anything that must not jitter as digits change.
    static let cockpitMetric = Font.system(size: 12, weight: .bold, design: .monospaced)
}

// MARK: - Surfaces

extension View {
    /// The one glass panel treatment, replacing the four hand-rolled surface
    /// styles that were in use. Deployment target is iOS 26, so the real
    /// glass effect is always available.
    func cockpitPanel(
        radius: CGFloat = Cockpit.Radius.large,
        bordered: Bool = true
    ) -> some View {
        self
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Cockpit.surface.opacity(0.82))
                    .glassEffect(in: .rect(cornerRadius: radius))
            }
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Cockpit.hairline, lineWidth: 1)
                }
            }
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
    }

    /// A free-floating surface — the action dock, the tab bar, toasts. Reads
    /// as hovering above the page rather than attached to it.
    func cockpitFloating(radius: CGFloat = Cockpit.Radius.dock) -> some View {
        self
            .background {
                Capsuleish(radius: radius)
                    .fill(Cockpit.surface.opacity(0.7))
                    .glassEffect(in: .rect(cornerRadius: radius))
            }
            .overlay {
                Capsuleish(radius: radius)
                    .strokeBorder(Cockpit.hairline, lineWidth: 1)
            }
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    /// Tints a whole screen with the cockpit canvas, including behind a
    /// `List` or `Form`, which otherwise paints its own grouped background.
    func cockpitScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Cockpit.canvas.ignoresSafeArea())
    }
}

/// A rounded rect that degrades to a capsule when the radius exceeds half the
/// height — used by the dock so tall and short variants both look intentional.
/// `nonisolated` because SwiftUI evaluates `Shape.path(in:)` off the main
/// actor, and this project isolates types to `@MainActor` by default.
private nonisolated struct Capsuleish: InsettableShape {
    var radius: CGFloat
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2)
        return RoundedRectangle(cornerRadius: r, style: .continuous)
            .path(in: rect.insetBy(dx: inset, dy: inset))
    }

    func inset(by amount: CGFloat) -> Capsuleish {
        Capsuleish(radius: radius, inset: inset + amount)
    }
}
