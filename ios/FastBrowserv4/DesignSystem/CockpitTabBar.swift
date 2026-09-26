import SwiftUI

/// The places you can go. Distinct from the things you can *do*, which live
/// on the floating action dock.
///
/// The split matters: the old bottom bar mixed eight of both together, so
/// Burn — which throws away a whole session — sat between the two buttons
/// pressed most often.
enum CockpitTab: String, CaseIterable, Identifiable, Sendable {
    case browse
    case vault
    case cards
    case automation
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browse: return "Browse"
        case .vault: return "Vault"
        case .cards: return "Cards"
        case .automation: return "Auto"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .browse: return "globe"
        case .vault: return "lock.shield"
        case .cards: return "creditcard"
        case .automation: return "wand.and.sparkles"
        case .settings: return "gearshape"
        }
    }

    var selectedIcon: String {
        switch self {
        case .browse: return "globe.americas.fill"
        case .vault: return "lock.shield.fill"
        case .cards: return "creditcard.fill"
        case .automation: return "wand.and.sparkles.inverse"
        case .settings: return "gearshape.fill"
        }
    }

    /// Cards keep their gold so the tab, the wallet and the fill button all
    /// read as the same feature.
    var tint: Color {
        switch self {
        case .cards: return Cockpit.card
        default: return Cockpit.live
        }
    }

    var accessibilityHint: String {
        switch self {
        case .browse: return "The web page and your windows"
        case .vault: return "Saved logins"
        case .cards: return "Saved cards and which window fills which"
        case .automation: return "Runs, flagged logins, AI brains and page scripts"
        case .settings: return "Browser preferences"
        }
    }
}

/// Bottom tab bar. Auto-hides as the page scrolls down and returns on the way
/// back up, so the page still gets the full screen when you are reading it.
struct CockpitTabBar: View {
    @Binding var selection: CockpitTab
    /// Small counts shown on a tab — flagged logins, saved cards.
    var badges: [CockpitTab: Int] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CockpitTab.allCases) { tab in
                item(tab)
            }
        }
        .padding(.horizontal, Cockpit.Space.tight)
        .padding(.vertical, 6)
        .cockpitFloating(radius: Cockpit.Radius.dock)
        .padding(.horizontal, Cockpit.Space.snug)
    }

    private func item(_ tab: CockpitTab) -> some View {
        let isSelected = selection == tab
        let badge = badges[tab] ?? 0
        return Button {
            guard selection != tab else { return }
            withAnimation(Cockpit.Motion.quick) { selection = tab }
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: isSelected ? tab.selectedIcon : tab.icon)
                        .font(.system(size: 17, weight: isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? tab.tint : Cockpit.textSecondary)
                        .frame(width: 30, height: 24)
                        .symbolEffect(.bounce, value: isSelected)

                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 9, weight: .black, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Cockpit.onAccent)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(tab.tint))
                            .offset(x: 5, y: -3)
                    }
                }

                Text(tab.title)
                    .font(.system(size: 10, weight: isSelected ? .heavy : .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? tab.tint : Cockpit.textTertiary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Cockpit.Radius.medium, style: .continuous)
                        .fill(tab.tint.opacity(0.14))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityHint(tab.accessibilityHint)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
