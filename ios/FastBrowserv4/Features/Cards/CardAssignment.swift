import Foundation

/// How saved cards are spread across the open windows.
nonisolated enum CardFillMode: String, CaseIterable, Identifiable, Sendable {
    /// Every window fills the same card the leader uses.
    case sameAsLeader
    /// Each window takes the next card down the wallet, repeating the list
    /// when there are more windows than cards.
    case rotate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sameAsLeader: return "Same as leader"
        case .rotate: return "Rotate"
        }
    }

    var shortLabel: String {
        switch self {
        case .sameAsLeader: return "Same"
        case .rotate: return "Rotate"
        }
    }

    var iconName: String {
        switch self {
        case .sameAsLeader: return "equal.square"
        case .rotate: return "arrow.triangle.2.circlepath"
        }
    }

    var explanation: String {
        switch self {
        case .sameAsLeader: return "Every window fills the same card."
        case .rotate: return "Each window takes the next card, repeating when you run out."
        }
    }
}

/// Which card each window fills.
///
/// Pure index math, deliberately kept away from SwiftData and WebKit: the
/// rule that matters most — a wallet shorter than the grid repeats instead of
/// leaving windows empty — is the sort of thing that is only ever trustworthy
/// if it is pinned down by tests.
nonisolated enum CardAssignment {
    /// Card index for the window sitting at `position` in the window order.
    ///
    /// - Parameters:
    ///   - position: 0-based position among the enabled windows.
    ///   - cardCount: how many cards are saved.
    ///   - offset: how far the rotation has been advanced by "Next Set".
    ///   - mode: same-as-leader collapses every position onto the leader's card.
    /// - Returns: the card's index, or nil when the wallet is empty.
    static func cardIndex(
        position: Int,
        cardCount: Int,
        offset: Int,
        mode: CardFillMode
    ) -> Int? {
        guard cardCount > 0, position >= 0 else { return nil }
        switch mode {
        case .sameAsLeader:
            // The leader is position 0, so every window lands on whatever the
            // leader is currently holding.
            return normalized(offset, count: cardCount)
        case .rotate:
            return normalized(offset + position, count: cardCount)
        }
    }

    /// Full window-index → card-index map for one grid.
    ///
    /// - Parameter windowIndices: enabled windows in mirroring order, leader
    ///   first. Disabled windows are simply absent, which is what keeps an
    ///   unused cell (the 3×3 centre in dual-site) from consuming a card.
    static func plan(
        windowIndices: [Int],
        cardCount: Int,
        offset: Int,
        mode: CardFillMode
    ) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (position, windowIndex) in windowIndices.enumerated() {
            guard let card = cardIndex(
                position: position,
                cardCount: cardCount,
                offset: offset,
                mode: mode
            ) else { continue }
            result[windowIndex] = card
        }
        return result
    }

    /// Offset after one "Next Set". Wraps at the end of the wallet so the
    /// counter can never run away, and is a no-op on an empty wallet.
    static func advanced(offset: Int, cardCount: Int) -> Int {
        guard cardCount > 0 else { return 0 }
        return normalized(offset + 1, count: cardCount)
    }

    /// Modulo that stays correct for negative input — a stored offset from an
    /// older, larger wallet must never index backwards off the front.
    private static func normalized(_ value: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let m = value % count
        return m < 0 ? m + count : m
    }
}
