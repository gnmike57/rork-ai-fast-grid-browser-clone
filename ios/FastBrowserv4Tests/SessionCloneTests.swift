//
//  SessionCloneTests.swift
//  FastBrowserv4Tests
//
//  Which windows donate and which receive when Window 1's session is cloned
//  across a layout, plus the cookie matching behind clone verification.
//

import Testing
import Foundation
@testable import FastBrowserv4

struct SessionCloneTests {

    private func windows(_ indices: [Int]) -> [SessionCarry.Window] {
        indices.map { SessionCarry.Window(index: $0) }
    }

    /// Checkerboard-style dual layout: even indices Site A, odd Site B.
    private func dualWindows(_ indices: [Int]) -> [SessionCarry.Window] {
        indices.map { SessionCarry.Window(index: $0, targetSiteIndex: $0 % 2) }
    }

    // MARK: - Single site

    @Test func singleSiteGridIsLedByWindowOne() {
        let jobs = SessionCarry.jobs(
            cloneToAll: true,
            windows: windows([0, 1, 2, 3]),
            isDualSite: false,
            external: nil
        )
        #expect(jobs.count == 1)
        let isWindowOne = jobs.first?.source == .window(0)
        #expect(isWindowOne)
        #expect(jobs.first?.targetIndices == [1, 2, 3])
    }

    @Test func gridToGridNeedsNoExternalDonor() {
        // A grid → grid switch (4 → 12 windows) still clones: the leader is
        // a live window, not the single-window tab.
        let jobs = SessionCarry.jobs(
            cloneToAll: true,
            windows: windows(Array(0..<12)),
            isDualSite: false,
            external: nil
        )
        #expect(jobs.count == 1)
        #expect(jobs.first?.targetIndices == Array(1..<12))
    }

    @Test func loneWindowHasNothingToSeed() {
        let jobs = SessionCarry.jobs(
            cloneToAll: true,
            windows: windows([0]),
            isDualSite: false,
            external: nil
        )
        #expect(jobs.isEmpty)
    }

    @Test func emptyLayoutProducesNoJobs() {
        let jobs = SessionCarry.jobs(cloneToAll: true, windows: [], isDualSite: false, external: nil)
        #expect(jobs.isEmpty)
    }

    // MARK: - Single window → grid

    @Test func singleWindowSeedsEveryWindowOfTheNewGrid() {
        let donor = SessionCarry.ExternalDonor(host: "example.com", laneHosts: [0: "example.com"])
        let jobs = SessionCarry.jobs(
            cloneToAll: true,
            windows: windows([0, 1, 2, 3, 4, 5]),
            isDualSite: false,
            external: donor
        )
        #expect(jobs.count == 1)
        let isExternal = jobs.first?.source == .external
        #expect(isExternal)
        // Window 1 included: the grid window has its own store and would
        // otherwise start logged out.
        #expect(jobs.first?.targetIndices == [0, 1, 2, 3, 4, 5])
    }

    @Test func donorHostIgnoresWWWAndCase() {
        let donor = SessionCarry.ExternalDonor(host: "WWW.Example.com", laneHosts: [0: "example.com"])
        let jobs = SessionCarry.jobs(
            cloneToAll: true,
            windows: windows([0, 1]),
            isDualSite: false,
            external: donor
        )
        let isExternal = jobs.first?.source == .external
        #expect(isExternal)
    }

    // MARK: - Toggle off

    @Test func toggleOffCarriesOnlyIntoTheFirstWindow() {
        let donor = SessionCarry.ExternalDonor(host: "example.com", laneHosts: [0: "example.com"])
        let jobs = SessionCarry.jobs(
            cloneToAll: false,
            windows: windows([0, 1, 2, 3]),
            isDualSite: false,
            external: donor
        )
        #expect(jobs.count == 1)
        #expect(jobs.first?.targetIndices == [0])
    }

    @Test func toggleOffLeavesGridToGridAlone() {
        let jobs = SessionCarry.jobs(
            cloneToAll: false,
            windows: windows([0, 1, 2, 3]),
            isDualSite: false,
            external: nil
        )
        #expect(jobs.isEmpty)
    }

    // MARK: - Dual site

    @Test func dualSiteUsesPerLaneLeaders() {
        let jobs = SessionCarry.jobs(
            cloneToAll: true,
            windows: dualWindows([0, 1, 2, 3, 4, 5]),
            isDualSite: true,
            external: nil
        )
        #expect(jobs.count == 2)
        let siteALeads = jobs.first?.source == .window(0)
        let siteBLeads = jobs.last?.source == .window(1)
        #expect(siteALeads)
        #expect(siteBLeads)
        #expect(jobs.first?.targetIndices == [2, 4])
        #expect(jobs.last?.targetIndices == [3, 5])
    }

    @Test func dualSiteNeverCrossesLanes() {
        let jobs = SessionCarry.jobs(
            cloneToAll: true,
            windows: dualWindows(Array(0..<8)),
            isDualSite: true,
            external: nil
        )
        let siteAIndices = Set([0, 2, 4, 6])
        let siteBIndices = Set([1, 3, 5, 7])
        for job in jobs {
            guard case .window(let leader) = job.source else { continue }
            let lane = siteAIndices.contains(leader) ? siteAIndices : siteBIndices
            let staysInLane = job.targetIndices.allSatisfy { lane.contains($0) }
            #expect(staysInLane)
        }
    }

    @Test func singleWindowOnlySeedsItsOwnLane() {
        // The single window was on Site B, so it seeds the Site B lane; the
        // Site A lane keeps its own leader and its own login.
        let donor = SessionCarry.ExternalDonor(
            host: "site-b.com",
            laneHosts: [0: "site-a.com", 1: "site-b.com"]
        )
        let jobs = SessionCarry.jobs(
            cloneToAll: true,
            windows: dualWindows([0, 1, 2, 3]),
            isDualSite: true,
            external: donor
        )
        #expect(jobs.count == 2)
        let laneALedByWindow = jobs.first?.source == .window(0)
        #expect(laneALedByWindow)
        #expect(jobs.first?.targetIndices == [2])
        let laneBFromExternal = jobs.last?.source == .external
        #expect(laneBFromExternal)
        // Window 2 (index 1) is the Site B leader and is seeded too.
        #expect(jobs.last?.targetIndices == [1, 3])
    }

    @Test func unrelatedDonorFallsBackToLaneLeaders() {
        let donor = SessionCarry.ExternalDonor(
            host: "somewhere-else.com",
            laneHosts: [0: "site-a.com", 1: "site-b.com"]
        )
        let jobs = SessionCarry.jobs(
            cloneToAll: true,
            windows: dualWindows([0, 1, 2, 3]),
            isDualSite: true,
            external: donor
        )
        let noneExternal = jobs.allSatisfy { $0.source != .external }
        #expect(noneExternal)
        #expect(jobs.count == 2)
    }

    @Test func disabledCenterWindowIsNeverATarget() {
        // 3×3 dual site: the center window (index 4) is unused, so callers
        // leave it out entirely and it must not appear in any job.
        let live = [0, 1, 2, 3, 5, 6, 7, 8].map {
            SessionCarry.Window(index: $0, targetSiteIndex: $0 % 2)
        }
        let jobs = SessionCarry.jobs(cloneToAll: true, windows: live, isDualSite: true, external: nil)
        let mentionsCenter = jobs.contains { $0.targetIndices.contains(4) }
        #expect(!mentionsCenter)
    }

    // MARK: - Host helpers

    @Test func hostMatchingNormalizesWWW() {
        let matches = SessionCarry.hostsMatch("www.example.com", "example.com")
        let differs = SessionCarry.hostsMatch("example.com", "example.org")
        let nilSafe = SessionCarry.hostsMatch(nil, "example.com")
        #expect(matches)
        #expect(!differs)
        #expect(!nilSafe)
    }

    // MARK: - Clone verification

    @Test func cookieDomainCoversSubdomains() {
        let exact = SessionTransferService.cookieDomain("example.com", matchesHost: "example.com")
        let sub = SessionTransferService.cookieDomain(".example.com", matchesHost: "app.example.com")
        let reverse = SessionTransferService.cookieDomain("app.example.com", matchesHost: "example.com")
        let unrelated = SessionTransferService.cookieDomain("evil.com", matchesHost: "example.com")
        #expect(exact)
        #expect(sub)
        #expect(!reverse)
        #expect(!unrelated)
    }

    @Test func snapshotSignatureKeepsOnlyTheTargetSitesCookies() {
        let snapshot = SessionSnapshot(
            version: 1,
            savedAt: Date(),
            href: "https://example.com/account",
            origin: "https://example.com",
            cookies: [
                cookie(name: "session", domain: ".example.com"),
                cookie(name: "csrf", domain: "example.com"),
                cookie(name: "tracker", domain: ".ads.net")
            ],
            localStorage: [:],
            sessionStorage: [:]
        )
        let names = SessionTransferService.cookieNames(in: snapshot, matchingHost: "example.com")
        #expect(names == ["session", "csrf"])
    }

    @Test func missingCookieFailsVerification() {
        let snapshot = SessionSnapshot(
            version: 1,
            savedAt: Date(),
            href: "https://example.com/",
            origin: "https://example.com",
            cookies: [
                cookie(name: "session", domain: "example.com"),
                cookie(name: "remember", domain: "example.com")
            ],
            localStorage: [:],
            sessionStorage: [:]
        )
        let expected = SessionTransferService.cookieNames(in: snapshot, matchingHost: "example.com")
        let landed: Set<String> = ["session"]
        let verified = expected.isSubset(of: landed)
        #expect(!verified)
    }

    private func cookie(name: String, domain: String) -> CookieData {
        CookieData(
            HTTPCookie(properties: [
                .name: name,
                .value: "v",
                .domain: domain,
                .path: "/"
            ])!
        )
    }

    // MARK: - Load timing

    @Test func loadTimingDefaultsToWaitingForTheSession() {
        UserDefaults.standard.removeObject(forKey: SettingsKey.sessionCloneLoadTiming)
        let timing = SessionCloneLoadTiming.saved
        #expect(timing == .waitForSession)
    }

    @Test func loadTimingRoundTripsThroughStorage() {
        UserDefaults.standard.set(
            SessionCloneLoadTiming.loadThenRefresh.rawValue,
            forKey: SettingsKey.sessionCloneLoadTiming
        )
        let timing = SessionCloneLoadTiming.saved
        #expect(timing == .loadThenRefresh)
        UserDefaults.standard.removeObject(forKey: SettingsKey.sessionCloneLoadTiming)
    }
}
