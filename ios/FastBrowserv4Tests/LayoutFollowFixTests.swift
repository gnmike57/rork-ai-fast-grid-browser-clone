import Foundation
import Testing
@testable import FastBrowserv4

/// The layout and follow-the-leader bookkeeping rules fixed in this pass.
struct LayoutFollowFixTests {

    // MARK: - Honest dual-site splits

    /// A split may only be offered where it produces the arrangement its name
    /// describes. "Left / Right" must never cut a column down the middle while
    /// still claiming to divide the grid side to side.
    @Test
    func aSplitIsOnlyCleanWhereItsNameIsTrue() {
        // Left / Right needs an even number of columns.
        #expect(DualSiteSplitPattern.horizontal.splitsCleanly(in: .four))
        #expect(DualSiteSplitPattern.horizontal.splitsCleanly(in: .eight))
        #expect(DualSiteSplitPattern.horizontal.splitsCleanly(in: .twelve))
        #expect(DualSiteSplitPattern.horizontal.splitsCleanly(in: .sixteen))
        #expect(!DualSiteSplitPattern.horizontal.splitsCleanly(in: .six))
        #expect(!DualSiteSplitPattern.horizontal.splitsCleanly(in: .nine))

        // Top / Bottom needs an even number of rows.
        #expect(DualSiteSplitPattern.vertical.splitsCleanly(in: .four))
        #expect(DualSiteSplitPattern.vertical.splitsCleanly(in: .six))
        #expect(DualSiteSplitPattern.vertical.splitsCleanly(in: .eight))
        #expect(DualSiteSplitPattern.vertical.splitsCleanly(in: .sixteen))
        #expect(!DualSiteSplitPattern.vertical.splitsCleanly(in: .nine))
        #expect(!DualSiteSplitPattern.vertical.splitsCleanly(in: .twelve))
    }

    /// Checkerboard alternates cell by cell, so it is true to its name on every
    /// supported grid — which is what makes it the honest fallback.
    @Test
    func checkerboardIsAlwaysAvailable() {
        for grid in WindowGridSize.allCases where grid.supportsDualSite {
            #expect(DualSiteSplitPattern.checkerboard.splitsCleanly(in: grid))
            #expect(DualSiteSplitPattern.available(for: grid).contains(.checkerboard))
        }
    }

    /// Every grid keeps at least one offer, so dual-site is never unreachable.
    @Test
    func everyDualCapableGridStillOffersSomething() {
        for grid in WindowGridSize.allCases where grid.supportsDualSite {
            #expect(!DualSiteSplitPattern.available(for: grid).isEmpty)
        }
        #expect(DualSiteSplitPattern.available(for: .six) == [.vertical, .checkerboard])
        #expect(DualSiteSplitPattern.available(for: .twelve) == [.horizontal, .checkerboard])
        #expect(DualSiteSplitPattern.available(for: .nine) == [.checkerboard])
    }

    /// A clean split must still put the same number of live windows each side,
    /// which is what lane pairing depends on.
    @Test
    func everyCleanSplitIsAlsoNumericallyBalanced() {
        for grid in WindowGridSize.allCases where grid.supportsDualSite {
            for pattern in DualSiteSplitPattern.available(for: grid) {
                let assignments = (0..<grid.rawValue).map {
                    pattern.targetSiteIndex(for: $0, in: grid)
                }
                #expect(assignments.filter { $0 == 0 }.count == assignments.filter { $0 == 1 }.count)
            }
        }
    }

    // MARK: - Per-page allowances

    /// The rule that decides whether a window's drift allowance refills. A
    /// reload of the same page must not refill it, or a window trapped in a
    /// redirect loop would reset its own budget forever.
    @Test
    func samePageRecognisesAReloadButNotAMove() {
        let key = FollowLeaderSync.normalizedKey(URL(string: "https://example.com/login"))
        #expect(FollowLeaderSync.isSamePage(key, URL(string: "https://example.com/login")))
        // Query strings carry per-session tokens, so they are not a new page.
        #expect(FollowLeaderSync.isSamePage(key, URL(string: "https://example.com/login?token=abc")))
        // A trailing slash and www. are the same page too.
        #expect(FollowLeaderSync.isSamePage(key, URL(string: "https://www.example.com/login/")))
        // A genuinely different path is a move, and refills the allowance.
        #expect(!FollowLeaderSync.isSamePage(key, URL(string: "https://example.com/checkout")))
        #expect(!FollowLeaderSync.isSamePage(key, URL(string: "https://other.com/login")))
    }

    /// With nothing recorded yet, the first commit counts as a move so a fresh
    /// session starts with a full allowance rather than none.
    @Test
    func theFirstPageCountsAsAMove() {
        #expect(!FollowLeaderSync.isSamePage(nil, URL(string: "https://example.com/login")))
        #expect(!FollowLeaderSync.isSamePage("https://example.com/login", nil))
    }

    // MARK: - Pacing

    /// The head start stays a one-off cost per catch-up, charged on position
    /// within the squad — never per action.
    @Test
    func theHeadStartIsChargedOncePerCatchUp() {
        let step: TimeInterval = 0.08
        let cap: TimeInterval = 0.7
        #expect(FollowLeaderPacing.leadIn(position: 0, step: step, cap: cap) == 0)
        #expect(FollowLeaderPacing.leadIn(position: 3, step: step, cap: cap) == step * 3)
        // Capped, so even a sixteen-window grid cannot push the last window
        // further back than the ceiling.
        #expect(FollowLeaderPacing.leadIn(position: 15, step: step, cap: cap) == cap)
        // Ten actions cost exactly one lead-in, not ten.
        #expect(
            FollowLeaderPacing.totalLead(actionCount: 10, position: 3, step: step, cap: cap)
                == FollowLeaderPacing.leadIn(position: 3, step: step, cap: cap)
        )
    }
}
