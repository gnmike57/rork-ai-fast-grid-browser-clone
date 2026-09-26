import Foundation

/// One recorded Leader action, normalized from the recorder's JavaScript
/// payload into a typed value. Pure data — no WebKit, no main-actor state —
/// so the queue and coalescing rules around it are fully unit-testable.
nonisolated struct FollowLeaderAction: Equatable, Sendable {
    enum Kind: String, Sendable {
        case click
        case input
        case select
        case check
        case submit
        case key
        case scroll
        /// Unbreakable only: the leader moved into a field. Replayed because
        /// plenty of sites only attach validation to focus.
        case focus
        /// Unbreakable only: the leader left a field. This is what fires the
        /// "looks like an invalid card number" check on most checkouts.
        case blur
        /// Unbreakable only: the hovered element changed. Menus that open on
        /// hover cannot be mirrored without it.
        case hover
    }

    /// Monotonic sequence number assigned when the action is recorded. Used
    /// for ordering, the ledger's row identity, and to tell an action that
    /// predates a repair from one that arrived during it.
    var seq: Int
    var kind: Kind
    /// CSS path captured in the leader. May be stale on a follower whose page
    /// laid out slightly differently, hence the hint fallbacks.
    var selector: String
    var value: String
    var checked: Bool
    /// Key name for `.key` actions. Relaxed records only `Enter`; Unbreakable
    /// records every key the leader pressed.
    var key: String
    /// Modifier keys held during a `.key` action, as a stable sorted string
    /// (`"alt+meta+shift"`). Empty when none were held.
    var modifiers: String
    var scrollX: Int
    var scrollY: Int
    /// Where inside the target element the leader tapped, as a fraction of
    /// its box (0…1 on each axis). Negative means "not captured", in which
    /// case the follower activates the element's centre as it always has.
    ///
    /// A fraction rather than a coordinate on purpose: a follower's element
    /// can sit at a different place on the page, and a map, slider or canvas
    /// cares about *where in itself* it was hit.
    var pointX: Double
    var pointY: Double
    /// True for the irreversible steps — a submit, an Enter, a tap on a
    /// pay/order/sign-in control. In Unbreakable the leader is held at these
    /// until every window has confirmed everything before them.
    var isCommit: Bool
    var hint: FollowLeaderHint
    /// `location.href` of the frame the action happened in. Lets a follower
    /// look inside same-origin sub-frames instead of only the top document.
    var frameURL: String
    /// False when the action came from an embedded frame rather than the
    /// top-level document.
    var isTopFrame: Bool

    /// Actions that target the same element and can safely collapse into one
    /// replay when they are still queued back to back (typing bursts).
    var coalesceKey: String? {
        switch kind {
        case .input, .select:
            let identity = [hint.id, hint.name, selector, frameURL].joined(separator: "|")
            return identity.isEmpty ? nil : "value:\(identity)"
        case .scroll:
            return "scroll"
        case .hover:
            return "hover"
        case .click, .check, .submit, .key, .focus, .blur:
            return nil
        }
    }

    /// True when this action mutates a field's contents, which is what the
    /// card-substitution pass and the ledger's privacy rule both key off.
    var isValueBearing: Bool {
        kind == .input || kind == .select
    }

    /// Plain-English row for the sync ledger.
    ///
    /// Never includes `value`. The ledger is a screen, and a card number or a
    /// password must not be able to reach a screen through a debug surface.
    var ledgerSummary: String {
        let target = hint.describedName
        switch kind {
        case .input:
            return target.isEmpty ? "Typed" : "Typed into \(target)"
        case .select:
            return target.isEmpty ? "Chose an option" : "Chose an option in \(target)"
        case .check:
            let verb = checked ? "Ticked" : "Unticked"
            return target.isEmpty ? verb : "\(verb) \(target)"
        case .click:
            return target.isEmpty ? "Tapped the page" : "Tapped \(target)"
        case .submit:
            return "Submitted the form"
        case .key:
            let name = key.isEmpty ? "a key" : key
            return modifiers.isEmpty ? "Pressed \(name)" : "Pressed \(modifiers)+\(name)"
        case .scroll:
            return "Scrolled"
        case .focus:
            return target.isEmpty ? "Moved into a field" : "Moved into \(target)"
        case .blur:
            return target.isEmpty ? "Left a field" : "Left \(target)"
        case .hover:
            return target.isEmpty ? "Hovered" : "Hovered \(target)"
        }
    }

    /// Argument dictionary handed to `callAsyncJavaScript`. Only JSON-safe
    /// primitives — WebKit rejects anything else.
    var jsArguments: [String: Any] {
        [
            "kind": kind.rawValue,
            "selector": selector,
            "value": value,
            "checked": checked,
            "key": key,
            "mods": modifiers,
            "x": scrollX,
            "y": scrollY,
            "px": pointX,
            "py": pointY,
            "frame": frameURL,
            "topFrame": isTopFrame,
            "hint": hint.jsDictionary
        ]
    }

    /// Builds an action from a recorder message body. Returns nil for
    /// payloads with no usable kind so malformed posts can never enter a
    /// follower's queue.
    init?(payload: [String: Any], seq: Int) {
        guard let rawKind = payload["kind"] as? String,
              let kind = Kind(rawValue: rawKind) else { return nil }
        self.seq = seq
        self.kind = kind
        self.selector = payload["selector"] as? String ?? ""
        self.value = payload["value"] as? String ?? ""
        self.checked = payload["checked"] as? Bool ?? false
        self.key = payload["key"] as? String ?? ""
        self.modifiers = payload["mods"] as? String ?? ""
        self.scrollX = FollowLeaderAction.int(payload["x"])
        self.scrollY = FollowLeaderAction.int(payload["y"])
        self.pointX = FollowLeaderAction.fraction(payload["px"])
        self.pointY = FollowLeaderAction.fraction(payload["py"])
        self.isCommit = payload["commit"] as? Bool ?? false
        self.hint = FollowLeaderHint(payload["hint"] as? [String: Any] ?? [:])
        self.frameURL = payload["frame"] as? String ?? ""
        self.isTopFrame = payload["topFrame"] as? Bool ?? true
    }

    /// Memberwise initializer for tests and internal construction.
    init(
        seq: Int,
        kind: Kind,
        selector: String = "",
        value: String = "",
        checked: Bool = false,
        key: String = "",
        modifiers: String = "",
        scrollX: Int = 0,
        scrollY: Int = 0,
        pointX: Double = -1,
        pointY: Double = -1,
        isCommit: Bool = false,
        hint: FollowLeaderHint = FollowLeaderHint(),
        frameURL: String = "",
        isTopFrame: Bool = true
    ) {
        self.seq = seq
        self.kind = kind
        self.selector = selector
        self.value = value
        self.checked = checked
        self.key = key
        self.modifiers = modifiers
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.pointX = pointX
        self.pointY = pointY
        self.isCommit = isCommit
        self.hint = hint
        self.frameURL = frameURL
        self.isTopFrame = isTopFrame
    }

    private static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    /// Reads a 0…1 tap fraction, clamped. Anything unreadable becomes -1,
    /// which means "activate the centre" rather than "activate the corner".
    private static func fraction(_ any: Any?) -> Double {
        let raw: Double
        if let d = any as? Double { raw = d }
        else if let i = any as? Int { raw = Double(i) }
        else if let n = any as? NSNumber { raw = n.doubleValue }
        else { return -1 }
        guard raw.isFinite, raw >= 0 else { return -1 }
        return min(1, raw)
    }
}

/// Descriptive fingerprint of the element an action targeted. Followers score
/// candidates against every field so a page that shifted slightly still
/// resolves to the right control.
nonisolated struct FollowLeaderHint: Equatable, Sendable {
    var tag: String = ""
    var type: String = ""
    var name: String = ""
    var id: String = ""
    var placeholder: String = ""
    var aria: String = ""
    var autocomplete: String = ""
    var label: String = ""
    var text: String = ""

    init() {}

    init(_ dictionary: [String: Any]) {
        tag = (dictionary["tag"] as? String ?? "").lowercased()
        type = (dictionary["type"] as? String ?? "").lowercased()
        name = dictionary["name"] as? String ?? ""
        id = dictionary["id"] as? String ?? ""
        placeholder = dictionary["placeholder"] as? String ?? ""
        aria = dictionary["aria"] as? String ?? ""
        autocomplete = dictionary["autocomplete"] as? String ?? ""
        label = dictionary["label"] as? String ?? ""
        text = dictionary["text"] as? String ?? ""
    }

    /// The friendliest name for this element, for the ledger. Prefers what a
    /// person would call the thing — its label — over machine identifiers.
    var describedName: String {
        for candidate in [label, aria, placeholder, text, name, id] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return String(trimmed.prefix(32)) }
        }
        return tag
    }

    var jsDictionary: [String: Any] {
        [
            "tag": tag,
            "type": type,
            "name": name,
            "id": id,
            "placeholder": placeholder,
            "aria": aria,
            "autocomplete": autocomplete,
            "label": label,
            "text": text
        ]
    }
}

/// Per-follower FIFO of pending mirrored actions.
///
/// Order is never changed, in either mode. A follower must type, then submit —
/// never the reverse — so any merging only ever folds into the *tail* of the
/// queue; an action with something queued behind it is left alone.
///
/// What differs is whether merging happens at all:
/// - **Relaxed** collapses consecutive keystrokes in one field, and
///   consecutive scrolls, into their final value, so a follower that fell
///   behind catches up instead of replaying every intermediate state.
/// - **Unbreakable** merges nothing. Every recorded action is replayed, in the
///   order it happened, because an input mask or a per-key validator only
///   behaves the same way if it sees the same sequence of states.
nonisolated struct FollowLeaderQueue: Equatable, Sendable {
    private(set) var items: [FollowLeaderAction] = []
    /// When true, nothing is ever merged away.
    let isStrict: Bool

    init(isStrict: Bool = false) {
        self.isStrict = isStrict
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    /// Highest sequence number currently queued, or nil when empty.
    var newestSeq: Int? { items.last?.seq }

    /// Appends an action, merging it into the tail when the tail targets the
    /// same field (or is another scroll) and this queue allows merging.
    /// Returns true when the action replaced the tail rather than extending
    /// the queue — always false in a strict queue.
    @discardableResult
    mutating func enqueue(_ action: FollowLeaderAction) -> Bool {
        if !isStrict,
           let key = action.coalesceKey,
           let tail = items.last,
           tail.coalesceKey == key {
            items[items.count - 1] = action
            return true
        }
        items.append(action)
        return false
    }

    mutating func dequeue() -> FollowLeaderAction? {
        items.isEmpty ? nil : items.removeFirst()
    }

    mutating func removeAll() { items.removeAll() }

    /// Rebuilds the queue as a page-repair backlog: every action for the
    /// leader's current page, followed by anything that arrived while the
    /// repair was in flight.
    ///
    /// Splicing by sequence number rather than clearing is what stops a
    /// repair from losing the keystrokes the user typed while the window was
    /// reloading — those have a higher seq than anything in the journal, so
    /// they survive the swap.
    mutating func replaceWithRepair(journal: [FollowLeaderAction]) {
        let newestJournalSeq = journal.last?.seq ?? Int.min
        let arrivedDuringRepair = items.filter { $0.seq > newestJournalSeq }
        items = journal + arrivedDuringRepair
    }
}

/// Which mirrored actions are irreversible enough to hold the leader at.
///
/// The recorder decides this in the page, where it can see whether a button
/// lives in a form and what it says. This is the native-side fallback and the
/// single place the rule is written down, so a test can pin it.
nonisolated enum FollowLeaderCommitPoint {
    /// True when the leader must not be allowed past this action until every
    /// window has confirmed everything before it.
    static func isCommit(_ action: FollowLeaderAction) -> Bool {
        if action.isCommit { return true }
        switch action.kind {
        case .submit:
            return true
        case .key:
            return action.key == "Enter"
        case .click:
            return action.hint.type == "submit"
        case .input, .select, .check, .scroll, .focus, .blur, .hover:
            return false
        }
    }
}

/// Pacing rules for mirrored replay.
///
/// Each follower takes a small head start so a site never sees sixteen
/// byte-identical hits in the same millisecond. That head start is a **one-off
/// cost per catch-up**, not a per-action tax: charging it before every action
/// turned a twenty-step login on a full Slow grid into a forty-second lag for
/// the last window, which is the opposite of what the stagger is for.
nonisolated enum FollowLeaderPacing {
    /// Head start for the window at `position` in the follower order,
    /// charged once when it begins draining a backlog.
    static func leadIn(position: Int, step: TimeInterval, cap: TimeInterval) -> TimeInterval {
        guard position > 0, step > 0, cap > 0 else { return 0 }
        return min(cap, step * Double(position))
    }

    /// Total head-start cost of draining `actionCount` actions in one
    /// catch-up. Constant by design — draining ten actions must never cost
    /// ten lead-ins.
    static func totalLead(
        actionCount: Int,
        position: Int,
        step: TimeInterval,
        cap: TimeInterval
    ) -> TimeInterval {
        guard actionCount > 0 else { return 0 }
        return leadIn(position: position, step: step, cap: cap)
    }
}

/// When a follower is fit to receive a mirrored action.
///
/// A window whose web content process died is *not* merely slow: firing into
/// it burns every retry and the full action timeout before being counted as a
/// miss, so recovery has to hold the queue exactly like a page load does.
nonisolated enum FollowLeaderReadiness {
    static func shouldHold(
        isLoading: Bool,
        isRestoringSession: Bool,
        isRecovering: Bool
    ) -> Bool {
        isLoading || isRestoringSession || isRecovering
    }
}

/// Result of applying one mirrored action inside a follower.
///
/// `ok` is the retry signal, and it is deliberately not the same as
/// `verified`: a benign tap (a tab, a disclosure toggle) legitimately produces
/// no detectable page change, so it reports `ok` but unverified. Retrying
/// those would risk firing a submit twice.
nonisolated struct FollowLeaderApplyOutcome: Equatable, Sendable {
    var ok: Bool
    var verified: Bool
    var method: String
    var reason: String

    init(ok: Bool, verified: Bool, method: String = "", reason: String = "") {
        self.ok = ok
        self.verified = verified
        self.method = method
        self.reason = reason
    }

    /// Parses the dictionary returned by the replay engine. Anything
    /// unreadable is treated as a failure so it retries rather than silently
    /// counting as a success.
    init(jsResult: Any?) {
        guard let dict = jsResult as? [String: Any] else {
            self.init(ok: false, verified: false, reason: "unreadable-result")
            return
        }
        self.init(
            ok: dict["ok"] as? Bool ?? false,
            verified: dict["verified"] as? Bool ?? false,
            method: dict["method"] as? String ?? "",
            reason: dict["reason"] as? String ?? ""
        )
    }

    static func failure(reason: String) -> FollowLeaderApplyOutcome {
        FollowLeaderApplyOutcome(ok: false, verified: false, reason: reason)
    }

    /// The replay engine reports this when the activation provably reached the
    /// control but the page did something it could not observe — a tab that
    /// only swaps its panel, an add-to-cart that updates a badge off screen.
    /// Those must never be pressed a second time.
    var wasDelivered: Bool { ok && method == "delivered" }
}

/// Decides when a follower has drifted onto a different page than the leader
/// and should be pulled back. Pure so the (deliberately conservative) rules
/// are pinned down by tests instead of discovered on a live site.
nonisolated enum FollowLeaderSync {
    /// Scheme + host + path, lowercased, with a trailing slash and `www.`
    /// removed. Query and fragment are ignored on purpose: sites routinely
    /// append per-session tokens there, and treating those as drift would
    /// send followers into a reload loop.
    static func normalizedKey(_ url: URL?) -> String? {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased(),
              !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        var path = url.path(percentEncoded: false).lowercased()
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/" }
        return "\(scheme)://\(host)\(path)"
    }

    /// True when a follower should be quietly navigated back to the leader's
    /// page. Both sides must be resolvable web URLs and genuinely different.
    static func needsResync(leader: URL?, follower: URL?) -> Bool {
        guard let leaderKey = normalizedKey(leader) else { return false }
        guard let followerKey = normalizedKey(follower) else { return true }
        return leaderKey != followerKey
    }

    /// True when a newly committed document is the *same* page as the one
    /// already recorded — a reload, or a redirect that only changed the query.
    ///
    /// This separates "the leader moved on" from "the leader reloaded where it
    /// already was". Per-page allowances refill on the former only: refilling
    /// on a reload would let a window trapped in a redirect loop reset its own
    /// budget forever, which is the exact failure the budget exists to stop.
    static func isSamePage(_ key: String?, _ url: URL?) -> Bool {
        guard let key, let incoming = normalizedKey(url) else { return false }
        return key == incoming
    }
}
