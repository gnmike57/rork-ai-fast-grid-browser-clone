import SwiftUI

/// Every state a run can be shown in, and how it looks.
///
/// This used to be a pair of functions keyed by loose strings, with each call
/// site spelling the key itself — so `color(for: "frozen")` was correct and
/// `color(for: "Frozen")` silently produced a grey dot with no warning. The
/// cases are now the only way to name a state, and the compiler enforces that
/// both the colour and the label are answered for each one.
enum RunStatusStyle: String, CaseIterable, Sendable {
    case idle
    case navigating
    case filling
    case submitting
    case waiting
    case burning
    case success
    case finished
    case pairWait
    case paused
    case frozen

    /// Dot and pill tint, drawn from the cockpit palette.
    var color: Color {
        switch self {
        case .idle: return Cockpit.textTertiary
        case .navigating: return Cockpit.live.opacity(0.7)
        case .filling: return Cockpit.live
        case .submitting: return Cockpit.laneA
        case .waiting: return Cockpit.attention
        case .burning: return Cockpit.danger
        case .success: return Cockpit.success
        case .finished: return Cockpit.success.opacity(0.75)
        case .pairWait: return Cockpit.live.opacity(0.55)
        case .paused: return Cockpit.attention
        case .frozen: return Cockpit.laneA
        }
    }

    /// Short lowercase word shown next to the dot.
    var label: String {
        switch self {
        case .idle: return "idle"
        case .navigating: return "loading"
        case .filling: return "filling"
        case .submitting: return "submitting"
        case .waiting: return "watching"
        case .burning: return "burning"
        case .success: return "success"
        case .finished: return "done"
        case .pairWait: return "linked"
        case .paused: return "paused"
        case .frozen: return "frozen"
        }
    }

    /// Glyph paired with the colour.
    ///
    /// At sixteen windows a 6pt coloured dot is not a status — it is a pixel.
    /// Colour, icon and word together survive being shrunk, and stay readable
    /// for anyone who can't separate the cyan from the green.
    var iconName: String {
        switch self {
        case .idle: return "circle"
        case .navigating: return "arrow.down.circle"
        case .filling: return "keyboard"
        case .submitting: return "paperplane.fill"
        case .waiting: return "eye"
        case .burning: return "flame.fill"
        case .success: return "checkmark.circle.fill"
        case .finished: return "checkmark"
        case .pairWait: return "link"
        case .paused: return "pause.fill"
        case .frozen: return "snowflake"
        }
    }

    /// True while the run is actively doing something, as opposed to parked.
    /// Drives which tiles brighten and which recede on a busy grid.
    var isBusy: Bool {
        switch self {
        case .navigating, .filling, .submitting, .waiting, .burning: return true
        case .idle, .success, .finished, .pairWait, .paused, .frozen: return false
        }
    }

    /// True when the run has stopped and wants the user's attention.
    var needsAttention: Bool {
        switch self {
        case .paused, .frozen: return true
        default: return false
        }
    }
}

extension BrowserViewModel.RCRStatus {
    /// Presentation state for this run status.
    var runStyle: RunStatusStyle {
        switch self {
        case .idle: return .idle
        case .navigating: return .navigating
        case .filling: return .filling
        case .submitting: return .submitting
        case .waiting: return .waiting
        case .burning: return .burning
        case .success: return .success
        }
    }
}

extension QuadSession.Status {
    /// Presentation state for this window's run status.
    var runStyle: RunStatusStyle {
        switch self {
        case .idle: return .idle
        case .navigating: return .navigating
        case .filling: return .filling
        case .submitting: return .submitting
        case .waiting: return .waiting
        case .burning: return .burning
        case .success: return .success
        case .finished: return .finished
        case .pairWait: return .pairWait
        }
    }
}

extension QuadSession {
    /// The state this window should actually be *shown* in, which is not
    /// always its run status: a frozen or globally-paused window outranks
    /// whatever it was doing when it stopped.
    ///
    /// Every surface that draws a window — grid badge, queue pill, summary
    /// bar — resolves through here, so they cannot disagree about whether a
    /// window is frozen.
    func displayStatus(isPausedAll: Bool) -> RunStatusStyle {
        if isRCRFrozen { return .frozen }
        if isPausedAll { return .paused }
        return rcrStatus.runStyle
    }
}
