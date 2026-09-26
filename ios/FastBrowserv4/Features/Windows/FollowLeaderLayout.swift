import Foundation
import CoreGraphics

/// How the leader and follower windows are arranged while Follow the Leader
/// is on. The choice is persisted and switched from the status-strip toggle.
nonisolated enum FollowLeaderDisplayStyle: String, CaseIterable, Identifiable {
    /// Leader fills the whole canvas; followers run invisible behind it at a
    /// tiny keep-alive size.
    case hidden
    /// Leader fills the canvas minus a slim bottom strip of live, visible
    /// follower thumbnails. The thumbnails never steal taps.
    case peek

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hidden: return "Hidden"
        case .peek: return "Peek"
        }
    }

    var iconName: String {
        switch self {
        case .hidden: return "eye.slash"
        case .peek: return "eye"
        }
    }

    private static let storageKey = "followLeaderDisplayStyle"

    /// The persisted choice; defaults to Hidden.
    static var saved: FollowLeaderDisplayStyle {
        get { FollowLeaderDisplayStyle(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .hidden }
    }

    /// Persists this choice for future launches.
    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }
}

/// Pure layout math for Follow the Leader mode — no SwiftUI or WebKit
/// dependencies, so it is fully unit-testable. The browser grid maps each
/// session to a placement from this, keeping the geometry in one place.
nonisolated enum FollowLeaderLayout {
    /// Where a window sits on screen and — crucially — what size its page is
    /// actually laid out at.
    ///
    /// `contentSize` is the size handed to the web view, so the site lays
    /// itself out exactly as it does on the leader. `frame` is the on-screen
    /// rect, and `scale` shrinks the full-size content into it. Followers are
    /// therefore never rendered as a mini layout, which is what used to make
    /// mirrored taps miss.
    nonisolated struct Placement: Equatable {
        var frame: CGRect
        var contentSize: CGSize
        var scale: CGFloat
        var opacity: Double
        var interactive: Bool
        var zIndex: Double
    }

    /// Height of the follower-thumbnail strip in Peek mode.
    static let peekStripHeight: CGFloat = 110

    private static let peekEdgePadding: CGFloat = 8
    private static let peekSpacing: CGFloat = 6
    private static let peekMaxThumbnailWidth: CGFloat = 120
    /// Floor on a thumbnail's width.
    ///
    /// Dividing the strip evenly looked fine at four windows and fell apart
    /// at eight: seven previews squeezed into one row left each about a
    /// fingernail wide, which is not enough to tell one page from another.
    /// Below this width the strip scrolls sideways instead of shrinking.
    private static let peekMinThumbnailWidth: CGFloat = 68

    /// Placement for one window in Follow the Leader mode.
    /// - Parameters:
    ///   - isLeader: whether this window is the leader.
    ///   - followerPosition: 0-based position of this window among the
    ///     followers (ignored for the leader and in Hidden mode).
    ///   - followerCount: total number of followers.
    ///   - canvas: full canvas available to the grid.
    ///   - style: current display style.
    ///   - peekScroll: how far the Peek strip is scrolled sideways. Ignored
    ///     when every thumbnail already fits.
    static func placement(
        isLeader: Bool,
        followerPosition: Int,
        followerCount: Int,
        in canvas: CGSize,
        style: FollowLeaderDisplayStyle,
        peekScroll: CGFloat = 0
    ) -> Placement {
        if isLeader {
            let height: CGFloat = style == .peek
                ? max(0, canvas.height - peekStripHeight)
                : canvas.height
            let frame = CGRect(x: 0, y: 0, width: canvas.width, height: height)
            return Placement(
                frame: frame,
                contentSize: frame.size,
                scale: 1,
                opacity: 1,
                interactive: true,
                zIndex: 10
            )
        }
        // Followers always lay out at the leader's own size so the DOM they
        // mirror into is identical to the one the actions were recorded from.
        let content = followerContentSize(in: canvas, style: style)
        switch style {
        case .hidden:
            return Placement(
                frame: CGRect(origin: .zero, size: content),
                contentSize: content,
                scale: 1,
                // Not fully transparent: WebKit throttles rendering for views
                // it considers invisible, which would stall the mirroring.
                opacity: 0.02,
                interactive: false,
                zIndex: 0
            )
        case .peek:
            let frame = peekThumbnailFrame(
                position: followerPosition,
                count: max(1, followerCount),
                in: canvas,
                scroll: peekScroll
            )
            // Fill the thumbnail's width and let the taller remainder clip, so
            // the recognisable top of each page stays legible.
            let scale = content.width > 0 ? frame.width / content.width : 1
            return Placement(
                frame: frame,
                contentSize: content,
                scale: scale,
                opacity: 1,
                interactive: false,
                zIndex: 5
            )
        }
    }

    /// The layout size every follower's page is rendered at — the leader's
    /// own canvas, so both sides resolve the same responsive breakpoints.
    static func followerContentSize(in canvas: CGSize, style: FollowLeaderDisplayStyle) -> CGSize {
        CGSize(
            width: max(1, canvas.width),
            height: max(1, style == .peek ? canvas.height - peekStripHeight : canvas.height)
        )
    }

    /// Width of one Peek thumbnail: share the strip evenly, but never go
    /// below the readable floor and never above the cap.
    static func peekThumbnailWidth(count: Int, canvasWidth: CGFloat) -> CGFloat {
        let slots = CGFloat(max(1, count))
        let available = canvasWidth - peekEdgePadding * 2 - peekSpacing * CGFloat(max(0, count - 1))
        let even = available / slots
        return max(peekMinThumbnailWidth, min(peekMaxThumbnailWidth, even))
    }

    /// Total width the thumbnails occupy, padding included.
    static func peekContentWidth(count: Int, canvasWidth: CGFloat) -> CGFloat {
        let n = max(1, count)
        let width = peekThumbnailWidth(count: n, canvasWidth: canvasWidth)
        return width * CGFloat(n) + peekSpacing * CGFloat(n - 1) + peekEdgePadding * 2
    }

    /// How far the strip can be scrolled. Zero when everything already fits,
    /// which is what keeps small grids feeling exactly as they did.
    static func peekMaxScroll(count: Int, canvasWidth: CGFloat) -> CGFloat {
        max(0, peekContentWidth(count: count, canvasWidth: canvasWidth) - canvasWidth)
    }

    /// Thumbnail rect inside the bottom strip.
    ///
    /// While everything fits the row stays centered, exactly as before. Once
    /// it overflows the row is left-anchored and `scroll` slides it, so the
    /// windows off the end are reachable rather than shrunk into illegibility.
    static func peekThumbnailFrame(
        position: Int,
        count: Int,
        in canvas: CGSize,
        scroll: CGFloat = 0
    ) -> CGRect {
        let n = max(1, count)
        let width = peekThumbnailWidth(count: n, canvasWidth: canvas.width)
        let totalUsed = width * CGFloat(n) + peekSpacing * CGFloat(n - 1)
        let maxScroll = peekMaxScroll(count: n, canvasWidth: canvas.width)
        let startX: CGFloat
        if maxScroll <= 0 {
            startX = (canvas.width - totalUsed) / 2
        } else {
            startX = peekEdgePadding - min(max(scroll, 0), maxScroll)
        }
        let x = startX + CGFloat(position) * (width + peekSpacing)
        return CGRect(
            x: x,
            y: canvas.height - peekStripHeight + peekEdgePadding,
            width: width,
            height: peekStripHeight - peekEdgePadding * 2
        )
    }
}
