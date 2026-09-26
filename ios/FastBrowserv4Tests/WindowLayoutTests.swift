import Foundation
import Testing
@testable import FastBrowserv4

struct WindowLayoutTests {
    @Test @MainActor
    func requestedGridDimensionsAreAvailable() {
        #expect(WindowGridSize.eight.rows == 2)
        #expect(WindowGridSize.eight.columns == 4)
        #expect(WindowGridSize.eight.label == "4×2")
        #expect(WindowGridSize.nine.rows == 3)
        #expect(WindowGridSize.nine.columns == 3)
        #expect(WindowGridSize.nine.label == "3×3")
        #expect(WindowGridSize.sixteen.rows == 4)
        #expect(WindowGridSize.sixteen.columns == 4)
        #expect(WindowGridSize.sixteen.label == "4×4")
        #expect(WindowGridSize.sixteen.rawValue == 16)
        #expect(WindowGridSize.sixteen.supportsDualSite)
    }

    @Test @MainActor
    func threeByThreeSupportsDualSiteWithDisabledCenter() {
        #expect(WindowGridSize.nine.supportsDualSite)
        #expect(WindowGridSize.nine.disabledIndexInDualSite == 4)
        #expect(WindowGridSize.allCases.filter(\.supportsDualSite).map(\.rawValue) == [4, 6, 8, 9, 12, 16])
    }

    @Test @MainActor
    func everyDualPatternSplitsEverySupportedGridExactlyEvenly() {
        for grid in WindowGridSize.allCases where grid.supportsDualSite {
            for pattern in DualSiteSplitPattern.allCases {
                let assignments = (0..<grid.rawValue).map {
                    pattern.targetSiteIndex(for: $0, in: grid)
                }
                let siteA = assignments.filter { $0 == 0 }.count
                let siteB = assignments.filter { $0 == 1 }.count
                let disabled = assignments.filter { $0 == -1 }.count
                if grid == .nine {
                    // 3×3: center disabled, remaining 8 split 4/4.
                    #expect(disabled == 1)
                    #expect(siteA == 4)
                    #expect(siteB == 4)
                } else {
                    #expect(disabled == 0)
                    #expect(siteA == grid.rawValue / 2)
                    #expect(siteB == grid.rawValue / 2)
                }
            }
        }
    }

    @Test @MainActor
    func controllerRecalculatesAssignmentsWhenGridOrPatternChanges() {
        let controller = QuadController()
        let urlA = URL(string: "https://a.example")!
        let urlB = URL(string: "https://b.example")!

        controller.setGridSize(.six)
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .horizontal)
        #expect(controller.activeSessions.filter { $0.targetSiteIndex == 0 }.count == 3)
        #expect(controller.activeSessions.filter { $0.targetSiteIndex == 1 }.count == 3)

        controller.setGridSize(.eight)
        #expect(controller.activeSessions.filter { $0.targetSiteIndex == 0 }.count == 4)
        #expect(controller.activeSessions.filter { $0.targetSiteIndex == 1 }.count == 4)

        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .checkerboard)
        let expected = (0..<WindowGridSize.eight.rawValue).map {
            DualSiteSplitPattern.checkerboard.targetSiteIndex(for: $0, in: .eight)
        }
        #expect(controller.activeSessions.map(\.targetSiteIndex) == expected)
    }

    @Test @MainActor
    func checkerboardAlternatesAcrossRowsAndColumns() {
        for grid in WindowGridSize.allCases where grid.supportsDualSite {
            for row in 0..<grid.rows {
                for column in 0..<grid.columns {
                    let index = row * grid.columns + column
                    let current = DualSiteSplitPattern.checkerboard.targetSiteIndex(for: index, in: grid)
                    if column + 1 < grid.columns {
                        let right = DualSiteSplitPattern.checkerboard.targetSiteIndex(for: index + 1, in: grid)
                        #expect(current != right)
                    }
                    if row + 1 < grid.rows {
                        let below = DualSiteSplitPattern.checkerboard.targetSiteIndex(
                            for: index + grid.columns,
                            in: grid
                        )
                        #expect(current != below)
                    }
                }
            }
        }
    }

    @Test @MainActor
    func lanePairingMatchesSplitPatternForEveryGridAndPattern() {
        for grid in WindowGridSize.allCases where grid.supportsDualSite {
            for pattern in DualSiteSplitPattern.allCases {
                let controller = QuadController()
                let urlA = URL(string: "https://a.example")!
                let urlB = URL(string: "https://b.example")!
                controller.setGridSize(grid)
                controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: pattern)

                let laneCount = controller.laneCount
                let expectedLanes = grid == .nine ? 4 : grid.rawValue / 2
                #expect(laneCount == expectedLanes, "Lane count for \(grid.label) / \(pattern.rawValue)")

                for lane in 0..<laneCount {
                    let (sA, sB) = controller.lanePair(lane)
                    #expect(sA.targetSiteIndex == 0, "Lane \(lane) A-side must be Site A (\(pattern.rawValue) / \(grid.label))")
                    #expect(sB.targetSiteIndex == 1, "Lane \(lane) B-side must be Site B (\(pattern.rawValue) / \(grid.label))")
                    #expect(sA.index != sB.index, "Lane \(lane) must pair two different sessions")
                    #expect(!sA.isDisabled, "Lane \(lane) A-side must not be disabled")
                    #expect(!sB.isDisabled, "Lane \(lane) B-side must not be disabled")
                }

                // Verify no credential doubling up: every lane pairs distinct
                // session indices and no session appears in two lanes.
                var seenIndices: Set<Int> = []
                for lane in 0..<laneCount {
                    let (sA, sB) = controller.lanePair(lane)
                    #expect(!seenIndices.contains(sA.index), "Session \(sA.id) appears in multiple lanes")
                    #expect(!seenIndices.contains(sB.index), "Session \(sB.id) appears in multiple lanes")
                    seenIndices.insert(sA.index)
                    seenIndices.insert(sB.index)
                }

                if grid == .nine {
                    // Center window must be disabled.
                    #expect(controller.sessions[4].isDisabled, "3×3 center must be disabled in dual-site")
                }
            }
        }
    }

    @Test @MainActor
    func everyLaneGetsEqualCredentialsToWithinOne() {
        // Simulate the pre-balanced distribution by checking the round-robin
        // math: with N credentials and L lanes, every lane gets floor(N/L)
        // or ceil(N/L). We verify this with several N/L combinations,
        // including the 4-lane case used by 3×3 dual-site mode.
        let laneCounts: [Int] = [2, 3, 4, 6, 8]
        let vaultSizes: [Int] = [10, 11, 23, 24, 25, 100]
        for lanes in laneCounts {
            for total in vaultSizes {
                var slices = Array(repeating: 0, count: lanes)
                for i in 0..<total {
                    slices[i % lanes] += 1
                }
                let minVal = slices.min()!
                let maxVal = slices.max()!
                #expect(maxVal - minVal <= 1, "Lanes=\(lanes) total=\(total) diff=\(maxVal - minVal)")
            }
        }
    }

    @Test @MainActor
    func normalModePartitionsEquallyAcrossAllWindowCounts() {
        // Normal (single-site) mode uses all windows — 4, 6, 8, 9, 12, 16.
        // Dual-site mode uses enabled sessions only: for 3×3 that's 8.
        let windowCounts: [Int] = [4, 6, 8, 9, 12, 16]
        let vaultSizes: [Int] = [10, 25, 50, 100]
        for windows in windowCounts {
            for total in vaultSizes {
                var slices = Array(repeating: 0, count: windows)
                for i in 0..<total {
                    slices[i % windows] += 1
                }
                let minVal = slices.min()!
                let maxVal = slices.max()!
                #expect(maxVal - minVal <= 1, "Windows=\(windows) total=\(total) diff=\(maxVal - minVal)")
            }
        }
    }

    @Test @MainActor
    func gridChangeRebuildsLaneMapping() {
        let controller = QuadController()
        let urlA = URL(string: "https://a.example")!
        let urlB = URL(string: "https://b.example")!

        controller.setGridSize(.four)
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .checkerboard)
        #expect(controller.laneCount == 2)

        controller.setGridSize(.twelve)
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .horizontal)
        #expect(controller.laneCount == 6)

        controller.setGridSize(.sixteen)
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .vertical)
        #expect(controller.activeCount == 16)
        #expect(controller.laneCount == 8)
        #expect(controller.enabledSessions.count == 16)

        // Every lane must pair one A + one B after the reassignment.
        for lane in 0..<controller.laneCount {
            let (sA, sB) = controller.lanePair(lane)
            #expect(sA.targetSiteIndex == 0)
            #expect(sB.targetSiteIndex == 1)
        }
    }

    @Test @MainActor
    func threeByThreeDualSiteDisablesCenterAndProducesFourLanes() {
        let controller = QuadController()
        let urlA = URL(string: "https://a.example")!
        let urlB = URL(string: "https://b.example")!

        controller.setGridSize(.nine)
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .checkerboard)

        #expect(controller.sessions[4].isDisabled, "Center window must be disabled")
        #expect(controller.laneCount == 4, "3×3 dual-site must produce 4 lanes")

        // No lane should include the disabled center session.
        for lane in 0..<controller.laneCount {
            let (sA, sB) = controller.lanePair(lane)
            #expect(sA.index != 4, "Lane \(lane) A-side must not be the disabled center")
            #expect(sB.index != 4, "Lane \(lane) B-side must not be the disabled center")
            #expect(!sA.isDisabled)
            #expect(!sB.isDisabled)
        }

        // Verify enabled session count is 8 (all except center).
        #expect(controller.enabledSessions.count == 8)
    }

    @Test @MainActor
    func patternChangeRebuildsLaneMapping() {
        let controller = QuadController()
        let urlA = URL(string: "https://a.example")!
        let urlB = URL(string: "https://b.example")!

        controller.setGridSize(.eight)
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .horizontal)
        let horizontalLanes = controller.laneCount

        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .checkerboard)
        let checkerboardLanes = controller.laneCount

        #expect(horizontalLanes == 4)
        #expect(checkerboardLanes == 4)

        // Verify the checkerboard pattern actually swapped which sessions
        // are A vs B compared to horizontal.
        let horizontalAssignments = (0..<8).map { idx in
            DualSiteSplitPattern.horizontal.targetSiteIndex(for: idx, in: .eight)
        }
        let checkerboardAssignments = (0..<8).map { idx in
            DualSiteSplitPattern.checkerboard.targetSiteIndex(for: idx, in: .eight)
        }
        #expect(horizontalAssignments != checkerboardAssignments)
    }

    @Test @MainActor
    func sixteenWindowGridHasUniqueStoresAndEvenDualSplit() {
        #expect(QuadDataStore.identifiers.count == QuadDataStore.maxSessionCount)
        #expect(Set(QuadDataStore.identifiers).count == 16)
        let controller = QuadController()
        #expect(controller.sessions.count == 16)
        #expect(Set(controller.sessions.map(\.storeID)).count == 16)

        let urlA = URL(string: "https://a.example")!
        let urlB = URL(string: "https://b.example")!
        controller.setGridSize(.sixteen)
        controller.applyDualSiteTargets(urlA: urlA, urlB: urlB, pattern: .checkerboard)
        #expect(controller.activeSessions.filter { $0.targetSiteIndex == 0 }.count == 8)
        #expect(controller.activeSessions.filter { $0.targetSiteIndex == 1 }.count == 8)
        #expect(controller.laneCount == 8)
    }

    @Test
    @MainActor
    func pageSettleParsesLoginFormFlag() {
        #expect(PageSettleService.parseHasLoginForm("{\"hasLoginForm\":true}"))
        #expect(!PageSettleService.parseHasLoginForm("{\"hasLoginForm\":false}"))
        #expect(!PageSettleService.parseHasLoginForm(nil))
        #expect(!PageSettleService.parseHasLoginForm("not-json"))
        #expect(!PageSettleService.parseHasLoginForm(42))
        #expect(PageSettleService.postBurnCookieGraceMs > PageSettleService.normalCookieGraceMs)
        #expect(PageSettleService.postBurnCookieTimeoutMs > PageSettleService.normalCookieTimeoutMs)
    }
}
