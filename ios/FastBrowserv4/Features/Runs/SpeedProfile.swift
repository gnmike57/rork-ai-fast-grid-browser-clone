import Foundation

/// Live run-speed profile for the run cockpit. Scales the gap between
/// repeat submits, page-settle waits, and judge grace — but NEVER shrinks
/// safety watchdogs: a fast profile only trims non-safety waits, so a slow
/// profile can never be killed early and a turbo one can never wedge a run.
nonisolated enum SpeedProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case slow
    case normal
    case fast
    case turbo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        case .turbo: return "Turbo"
        }
    }

    /// Turtle → rabbit progression.
    var systemImage: String {
        switch self {
        case .slow: return "tortoise.fill"
        case .normal: return "tortoise"
        case .fast: return "hare"
        case .turbo: return "hare.fill"
        }
    }

    /// Multiplier applied to every non-safety wait (page settle, cookie
    /// grace, login-form poll). ≥1 stretches waits; <1 trims them.
    var settleMultiplier: Double {
        switch self {
        case .slow: return 1.75
        case .normal: return 1.0
        case .fast: return 0.7
        case .turbo: return 0.5
        }
    }

    /// Gap between repeat (extra) submits. The user's configured sure-login
    /// retries still run — they're just spaced by this profile.
    var repeatSubmitGap: Duration {
        switch self {
        case .slow: return .seconds(2.4)
        case .normal: return .seconds(1.2)
        case .fast: return .seconds(0.7)
        case .turbo: return .seconds(0.35)
        }
    }

    /// Multiplier applied to the user's configured repeat-submit delay so
    /// the dial scales the gap without overwriting their setting. Normal is
    /// exactly 1×; slow stretches it, fast/turbo tighten it.
    var submitGapMultiplier: Double {
        repeatSubmitGap.seconds / SpeedProfile.normal.repeatSubmitGap.seconds
    }

    /// Per-follower lead-in offset for a mirrored action. Every follower now
    /// runs its own queue concurrently, so this is a small de-synchronising
    /// ripple (so a site never sees sixteen byte-identical hits in the same
    /// millisecond) — not a cascade the back of the grid has to wait out.
    /// Turbo is effectively simultaneous; slow stays deliberate.
    var followLeaderStaggerStep: Duration {
        switch self {
        case .slow: return .milliseconds(250)
        case .normal: return .milliseconds(80)
        case .fast: return .milliseconds(30)
        case .turbo: return .zero
        }
    }

    /// Ceiling on the total lead-in offset, so even a 16-window grid on the
    /// slow dial can never push the last follower more than this far behind.
    var followLeaderMaxStagger: Duration {
        switch self {
        case .slow: return .seconds(2.0)
        case .normal: return .milliseconds(700)
        case .fast: return .milliseconds(300)
        case .turbo: return .zero
        }
    }

    /// Pause before re-attempting a mirrored action that failed. Short: the
    /// usual cause is a control that had not mounted yet.
    var followLeaderRetryBackoff: Duration {
        switch self {
        case .slow: return .milliseconds(400)
        case .normal: return .milliseconds(220)
        case .fast: return .milliseconds(140)
        case .turbo: return .milliseconds(90)
        }
    }

    /// Hard ceiling on a single mirrored action. A wedged web process can
    /// never block the actions queued behind it — this is a safety timeout,
    /// so it never drops below the base regardless of dial position.
    var followLeaderActionTimeout: Duration {
        .seconds(6.0 * max(1.0, settleMultiplier))
    }

    /// Longest the leader is held at a point of no return while the followers
    /// catch up (Unbreakable only).
    ///
    /// A safety release, not a pacing choice: a window that never confirms
    /// must not be able to swallow the tap the user already made, so this
    /// only ever stretches with the dial and never shrinks below the base.
    var followLeaderGateTimeout: Duration {
        .seconds(20.0 * max(1.0, settleMultiplier))
    }

    /// How long a repaired window is given to load the leader's page and
    /// become usable again before the repair is called a failure.
    var followLeaderRepairTimeout: Duration {
        SpeedProfile.effectiveWatchdog(.seconds(14), profile: self)
    }

    /// Settle pause after a repaired window finishes loading, before its
    /// replay of the page begins. Late-mounting panels and payment frames
    /// need a moment or the replay starts against half a page.
    var followLeaderRepairSettle: Duration {
        switch self {
        case .slow: return .milliseconds(1200)
        case .normal: return .milliseconds(700)
        case .fast: return .milliseconds(400)
        case .turbo: return .milliseconds(220)
        }
    }

    /// Extra wait after a submit before the success judge is allowed to run.
    var judgeGrace: Duration {
        switch self {
        case .slow: return .seconds(2.0)
        case .normal: return .seconds(0.8)
        case .fast: return .seconds(0.4)
        case .turbo: return .seconds(0.15)
        }
    }

    /// Human-like pause between page settle and filling the form.
    var preFillPause: Duration {
        switch self {
        case .slow: return .seconds(1.1)
        case .normal: return .seconds(0.5)
        case .fast: return .seconds(0.25)
        case .turbo: return .seconds(0.1)
        }
    }

    /// Effective watchdog duration. Slow stretches watchdogs; fast and turbo
    /// keep the base — watchdogs never shrink.
    static func effectiveWatchdog(_ base: Duration, profile: SpeedProfile) -> Duration {
        .seconds(base.seconds * max(1.0, profile.settleMultiplier))
    }

    /// Scaled settle wait: the base settle time through this profile.
    static func scaledSettle(baseSeconds: Double, profile: SpeedProfile) -> Double {
        baseSeconds * profile.settleMultiplier
    }

    /// Persisted profile used when starting new runs.
    static var saved: SpeedProfile {
        get {
            SpeedProfile(rawValue: UserDefaults.standard.string(forKey: Self.savedKey) ?? "") ?? .normal
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.savedKey)
        }
    }

    private static let savedKey = "runSpeedProfile"
}

nonisolated extension Duration {
    /// Seconds as TimeInterval — shared by pacing + watchdog math.
    var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1_000_000_000_000_000_000
    }
}
