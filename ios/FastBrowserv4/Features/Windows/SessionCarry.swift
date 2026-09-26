import Foundation

/// Pure planning logic for carrying a signed-in session across the
/// multi-window grid. Given the shape of a layout it answers one question:
/// *which window donates its session, and which windows receive it.*
///
/// Two donor kinds exist:
/// - `.external` — the single-window tab handing its session to a grid it is
///   about to become.
/// - `.window(index)` — a live grid window (the lane leader) seeding its own
///   lane, used for every grid → grid transition and for Follow the Leader.
///
/// Dual-site layouts plan per lane: the first live Site A window leads the
/// Site A windows and the first live Site B window leads the Site B windows,
/// so a Site B login is never overwritten by Site A's cookies.
nonisolated enum SessionCarry {
    /// One live window as the planner sees it.
    struct Window: Equatable, Sendable {
        /// Stable window index (`QuadSession.index`), not a list position.
        let index: Int
        /// 0 = Site A, 1 = Site B. Always 0 in single-site layouts.
        let targetSiteIndex: Int

        init(index: Int, targetSiteIndex: Int = 0) {
            self.index = index
            self.targetSiteIndex = targetSiteIndex
        }
    }

    /// Where a clone's session comes from.
    enum Source: Equatable, Sendable {
        /// The single-window tab that is handing off to the grid.
        case external
        /// A live grid window, identified by `QuadSession.index`.
        case window(Int)
    }

    /// The single-window donor's page host plus the host each lane is about
    /// to show, so the planner can tell which lane the donor belongs to.
    struct ExternalDonor: Equatable, Sendable {
        let host: String
        /// Host of each lane's target URL keyed by target site index.
        /// Single-site layouts pass `[0: host]`.
        let laneHosts: [Int: String]

        init(host: String, laneHosts: [Int: String]) {
            self.host = host
            self.laneHosts = laneHosts
        }
    }

    /// One donor and every window that receives its session.
    struct Job: Equatable, Sendable {
        let source: Source
        /// Window indices to seed, in ascending layout order.
        let targetIndices: [Int]
    }

    /// Builds the clone plan for a layout.
    ///
    /// - Parameters:
    ///   - cloneToAll: the "Clone session from Window 1" toggle. When off the
    ///     only carry-over is the legacy one — the single window hands its
    ///     session to the first grid window and nothing else is touched.
    ///   - windows: live (non-disabled) windows in ascending layout order.
    ///   - isDualSite: whether the layout splits across two target sites.
    ///   - external: the single-window donor, when the grid is being entered
    ///     from single-window mode. `nil` for grid → grid transitions.
    static func jobs(
        cloneToAll: Bool,
        windows: [Window],
        isDualSite: Bool,
        external: ExternalDonor?
    ) -> [Job] {
        guard let firstWindow = windows.first else { return [] }

        guard cloneToAll else {
            // Toggle off keeps the original behaviour: only the first window
            // inherits the single window's session, and only on that switch.
            guard external != nil else { return [] }
            return [Job(source: .external, targetIndices: [firstWindow.index])]
        }

        let lanes: [[Window]] = isDualSite
            ? [0, 1].map { site in windows.filter { $0.targetSiteIndex == site } }.filter { !$0.isEmpty }
            : [windows]

        var jobs: [Job] = []
        for lane in lanes {
            guard let leader = lane.first else { continue }
            let laneIndices = lane.map(\.index)
            let laneHost = external?.laneHosts[isDualSite ? leader.targetSiteIndex : 0]
            if let external, hostsMatch(external.host, laneHost) {
                // The single window was already on this lane's site, so its
                // live session seeds the whole lane — leader included, since
                // the grid window has its own store and starts logged out.
                jobs.append(Job(source: .external, targetIndices: laneIndices))
            } else {
                // No external donor for this lane: the lane's own leader
                // keeps its store and hands it to the rest of the lane.
                let followers = Array(laneIndices.dropFirst())
                guard !followers.isEmpty else { continue }
                jobs.append(Job(source: .window(leader.index), targetIndices: followers))
            }
        }
        return jobs
    }

    /// Host comparison that ignores case and a leading `www.`, so
    /// `www.example.com` and `example.com` count as the same site.
    static func hostsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedHost(lhs), let rhs = normalizedHost(rhs) else { return false }
        return lhs == rhs
    }

    static func normalizedHost(_ host: String?) -> String? {
        guard let host, !host.isEmpty else { return nil }
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
}
