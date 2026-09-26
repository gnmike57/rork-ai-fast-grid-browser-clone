import Foundation

/// Visual distribution of Site A and Site B across an even-sized browser grid.
enum DualSiteSplitPattern: String, CaseIterable, Identifiable, Equatable {
    case horizontal
    case vertical
    case checkerboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal: return "Horizontal (Left / Right)"
        case .vertical: return "Vertical (Top / Bottom)"
        case .checkerboard: return "Checkerboard"
        }
    }

    var systemImage: String {
        switch self {
        case .horizontal: return "rectangle.split.2x1"
        case .vertical: return "rectangle.split.1x2"
        case .checkerboard: return "checkerboard.rectangle"
        }
    }

    /// True when this pattern can divide `grid` into two halves along whole
    /// rows or whole columns, with the same number of live windows each side.
    ///
    /// "Left / Right" on a three-column grid and "Top / Bottom" on a
    /// three-row grid cannot: the halfway point lands mid-band, so one column
    /// (or row) is cut down the middle while the option still claims to split
    /// the grid side to side. Offering it there promises a shape the layout
    /// cannot produce. Checkerboard alternates cell by cell, so it is always
    /// true to its name.
    func splitsCleanly(in grid: WindowGridSize) -> Bool {
        guard grid.supportsDualSite else { return false }
        if self == .checkerboard { return true }
        var sitesPerBand: [Int: Set<Int>] = [:]
        var countPerSite: [Int: Int] = [0: 0, 1: 0]
        for index in 0..<grid.rawValue {
            let target = targetSiteIndex(for: index, in: grid)
            // A disabled cell belongs to no side, so it cannot unbalance one.
            guard target >= 0 else { continue }
            let band = self == .horizontal ? index % grid.columns : index / grid.columns
            sitesPerBand[band, default: []].insert(target)
            countPerSite[target, default: 0] += 1
        }
        // Every band must be wholly one side, and both sides must be equal.
        guard sitesPerBand.values.allSatisfy({ $0.count == 1 }) else { return false }
        return countPerSite[0] == countPerSite[1]
    }

    /// The patterns worth offering for a grid — the ones that actually produce
    /// the arrangement their name describes.
    static func available(for grid: WindowGridSize) -> [DualSiteSplitPattern] {
        allCases.filter { $0.splitsCleanly(in: grid) }
    }

    /// Returns 0 for Site A, 1 for Site B, or -1 for a disabled cell.
    ///
    /// Even-sized grids split exactly in half. The 3×3 grid marks its
    /// center (index 4) as disabled (-1); the remaining 8 cells split
    /// into 4 Site A + 4 Site B using the same pattern logic, with
    /// `half = 9 / 2 = 4` (integer division) as the natural threshold.
    func targetSiteIndex(for index: Int, in grid: WindowGridSize) -> Int {
        guard grid.supportsDualSite, index >= 0, index < grid.rawValue else { return 0 }

        // 3×3 center window is unused in dual-site mode.
        if grid == .nine, index == 4 { return -1 }

        let row = index / grid.columns
        let column = index % grid.columns
        let half = grid.rawValue / 2

        switch self {
        case .horizontal:
            let columnMajorIndex = column * grid.rows + row
            return columnMajorIndex < half ? 0 : 1
        case .vertical:
            return index < half ? 0 : 1
        case .checkerboard:
            return (row + column) % 2
        }
    }
}
