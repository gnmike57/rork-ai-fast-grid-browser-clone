//
//  FollowLeaderLayoutTests.swift
//  FastBrowserv4Tests
//
//  Layout math for Follow the Leader (Hidden / Peek) plus the decision of
//  which windows receive the cloned session on a Single → grid switch.
//

import Testing
import Foundation
import CoreGraphics
@testable import FastBrowserv4

struct FollowLeaderLayoutTests {

    private let canvas = CGSize(width: 390, height: 720)

    // MARK: - Hidden style

    @Test func hiddenLeaderFillsCanvas() {
        let p = FollowLeaderLayout.placement(
            isLeader: true, followerPosition: 0, followerCount: 3,
            in: canvas, style: .hidden
        )
        #expect(p.frame == CGRect(origin: .zero, size: canvas))
        #expect(p.interactive)
        #expect(p.opacity == 1)
        #expect(p.zIndex == 10)
    }

    @Test func hiddenFollowersRenderFullSizeBehindTheLeader() {
        let leader = FollowLeaderLayout.placement(
            isLeader: true, followerPosition: 0, followerCount: 3,
            in: canvas, style: .hidden
        )
        let p = FollowLeaderLayout.placement(
            isLeader: false, followerPosition: 0, followerCount: 3,
            in: canvas, style: .hidden
        )
        // Identical layout size to the leader is the whole point: a page that
        // lays out the same way exposes the same controls to mirror into.
        #expect(p.contentSize == leader.contentSize)
        #expect(p.frame.size == canvas)
        #expect(p.scale == 1)
        #expect(!p.interactive)
        #expect(p.opacity < 0.1)
        #expect(p.zIndex < leader.zIndex)
    }

    @Test func peekFollowersAreFullSizeContentScaledDown() {
        let count = 4
        let p = FollowLeaderLayout.placement(
            isLeader: false, followerPosition: 1, followerCount: count,
            in: canvas, style: .peek
        )
        // Thumbnails are a scaled view of a full-size page, not a mini layout.
        #expect(p.contentSize.width == canvas.width)
        #expect(p.contentSize.height == canvas.height - FollowLeaderLayout.peekStripHeight)
        #expect(p.scale < 1)
        #expect(p.scale > 0)
        let scaledWidth = p.contentSize.width * p.scale
        #expect(abs(scaledWidth - p.frame.width) < 0.001)
    }

    @Test func followerContentMatchesLeaderForBothStyles() {
        for style in FollowLeaderDisplayStyle.allCases {
            let leader = FollowLeaderLayout.placement(
                isLeader: true, followerPosition: 0, followerCount: 5,
                in: canvas, style: style
            )
            let follower = FollowLeaderLayout.placement(
                isLeader: false, followerPosition: 2, followerCount: 5,
                in: canvas, style: style
            )
            #expect(follower.contentSize == leader.frame.size)
        }
    }

    // MARK: - Peek style

    @Test func peekLeaderLeavesRoomForStrip() {
        let p = FollowLeaderLayout.placement(
            isLeader: true, followerPosition: 0, followerCount: 3,
            in: canvas, style: .peek
        )
        #expect(p.frame.height == canvas.height - FollowLeaderLayout.peekStripHeight)
        #expect(p.frame.width == canvas.width)
        #expect(p.interactive)
    }

    @Test func peekThumbnailsStayInsideStrip() {
        let count = 5
        for position in 0..<count {
            let p = FollowLeaderLayout.placement(
                isLeader: false, followerPosition: position, followerCount: count,
                in: canvas, style: .peek
            )
            #expect(p.frame.minY >= canvas.height - FollowLeaderLayout.peekStripHeight)
            #expect(p.frame.maxY <= canvas.height)
            #expect(p.frame.minX >= 0)
            #expect(p.frame.maxX <= canvas.width)
            #expect(!p.interactive)
        }
    }

    @Test func peekThumbnailsDoNotOverlap() {
        let count = 4
        var previousMaxX: CGFloat = -1
        for position in 0..<count {
            let p = FollowLeaderLayout.placement(
                isLeader: false, followerPosition: position, followerCount: count,
                in: canvas, style: .peek
            )
            #expect(p.frame.minX >= previousMaxX)
            previousMaxX = p.frame.maxX
        }
    }

    @Test func peekFitsFifteenFollowers() {
        for position in 0..<15 {
            let p = FollowLeaderLayout.placement(
                isLeader: false, followerPosition: position, followerCount: 15,
                in: canvas, style: .peek
            )
            #expect(p.frame.width > 0)
            #expect(p.frame.maxX <= canvas.width + 0.5)
        }
    }

    @Test func displayStyleRoundTripsThroughStorage() {
        FollowLeaderDisplayStyle.peek.save()
        #expect(FollowLeaderDisplayStyle.saved == .peek)
        FollowLeaderDisplayStyle.hidden.save()
        #expect(FollowLeaderDisplayStyle.saved == .hidden)
    }
}
