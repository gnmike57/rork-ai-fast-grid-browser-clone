import Foundation

/// One field read out of the leader window by an Instant Fill audit.
///
/// Pure data — no WebKit, no main-actor state — so the matching hints and the
/// card-substitution rules around it are fully unit-testable.
nonisolated struct InstantFillField: Equatable, Sendable {
    /// CSS path captured in the leader. Tried first on a follower, and may
    /// legitimately miss on a page that laid out differently — hence every
    /// fallback below it.
    var selector: String
    /// `location.href` of the frame this field lives in, so a follower looks
    /// inside the matching sub-frame before anywhere else.
    var frame: String
    /// Position among every candidate field of that frame, filled or not.
    /// The last-resort match, and deliberately so: it is the only rule that
    /// ignores what the field says about itself.
    var index: Int
    var tag: String
    var type: String
    var name: String
    var id: String
    var placeholder: String
    var aria: String
    var autocomplete: String
    var label: String
    var value: String
    /// Visible text of the chosen option, so a follower can still match when a
    /// site rebuilds its option values per session.
    var optionText: String
    var checked: Bool
    var isCheckbox: Bool
    var isSelect: Bool
    var isEditable: Bool

    /// The descriptive fingerprint, in the shape the card classifier already
    /// understands. Reusing `FollowLeaderHint` here is what lets Instant Fill
    /// and mirrored typing agree on what counts as a card field — two separate
    /// classifiers would eventually disagree, and the failure would be a
    /// follower filling the leader's card number.
    var hint: FollowLeaderHint {
        var hint = FollowLeaderHint()
        hint.tag = tag
        hint.type = type
        hint.name = name
        hint.id = id
        hint.placeholder = placeholder
        hint.aria = aria
        hint.autocomplete = autocomplete
        hint.label = label
        return hint
    }

    /// Dictionary handed back to the injected apply pass. Only JSON-safe
    /// primitives — WebKit rejects anything else.
    var jsDictionary: [String: Any] {
        [
            "selector": selector,
            "frame": frame,
            "index": index,
            "tag": tag,
            "type": type,
            "name": name,
            "id": id,
            "placeholder": placeholder,
            "aria": aria,
            "autocomplete": autocomplete,
            "label": label,
            "value": value,
            "optionText": optionText,
            "checked": checked,
            "isCheckbox": isCheckbox,
            "isSelect": isSelect,
            "isEditable": isEditable
        ]
    }

    /// Builds a field from one audit entry. Returns nil when the entry carries
    /// nothing usable, so a malformed row can never enter a fill.
    init?(_ dictionary: [String: Any]) {
        let selector = dictionary["selector"] as? String ?? ""
        let name = dictionary["name"] as? String ?? ""
        let id = dictionary["id"] as? String ?? ""
        let index = InstantFillField.int(dictionary["index"])
        // With no selector, no name, no id and no position there is no way to
        // find this control again in another window.
        guard !selector.isEmpty || !name.isEmpty || !id.isEmpty || index >= 0 else { return nil }
        self.selector = selector
        self.frame = dictionary["frame"] as? String ?? ""
        self.index = index
        self.tag = (dictionary["tag"] as? String ?? "").lowercased()
        self.type = (dictionary["type"] as? String ?? "").lowercased()
        self.name = name
        self.id = id
        self.placeholder = dictionary["placeholder"] as? String ?? ""
        self.aria = dictionary["aria"] as? String ?? ""
        self.autocomplete = dictionary["autocomplete"] as? String ?? ""
        self.label = dictionary["label"] as? String ?? ""
        self.value = dictionary["value"] as? String ?? ""
        self.optionText = dictionary["optionText"] as? String ?? ""
        self.checked = dictionary["checked"] as? Bool ?? false
        self.isCheckbox = dictionary["isCheckbox"] as? Bool ?? false
        self.isSelect = dictionary["isSelect"] as? Bool ?? false
        self.isEditable = dictionary["isEditable"] as? Bool ?? false
    }

    /// Memberwise initializer for tests and internal construction.
    init(
        selector: String = "",
        frame: String = "",
        index: Int = -1,
        tag: String = "",
        type: String = "",
        name: String = "",
        id: String = "",
        placeholder: String = "",
        aria: String = "",
        autocomplete: String = "",
        label: String = "",
        value: String = "",
        optionText: String = "",
        checked: Bool = false,
        isCheckbox: Bool = false,
        isSelect: Bool = false,
        isEditable: Bool = false
    ) {
        self.selector = selector
        self.frame = frame
        self.index = index
        self.tag = tag
        self.type = type
        self.name = name
        self.id = id
        self.placeholder = placeholder
        self.aria = aria
        self.autocomplete = autocomplete
        self.label = label
        self.value = value
        self.optionText = optionText
        self.checked = checked
        self.isCheckbox = isCheckbox
        self.isSelect = isSelect
        self.isEditable = isEditable
    }

    private static func int(_ any: Any?) -> Int {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return -1
    }
}

/// One complete reading of the leader window.
nonisolated struct InstantFillSnapshot: Equatable, Sendable {
    var fields: [InstantFillField]
    /// Candidate fields the audit walked, filled or not. Used only to tell
    /// "this page has no form" apart from "this form is empty" in the message
    /// shown afterwards.
    var scanned: Int

    var isEmpty: Bool { fields.isEmpty }

    init(fields: [InstantFillField] = [], scanned: Int = 0) {
        self.fields = fields
        self.scanned = scanned
    }

    /// Parses the audit's result. Anything unreadable becomes an empty
    /// snapshot rather than a partial one — filling half a form because the
    /// rest failed to parse would be worse than not filling at all.
    init(jsResult: Any?) {
        guard let dict = jsResult as? [String: Any],
              let rows = dict["fields"] as? [[String: Any]] else {
            self.init()
            return
        }
        self.init(
            fields: rows.compactMap(InstantFillField.init),
            scanned: (dict["scanned"] as? Int) ?? rows.count
        )
    }

    var jsArguments: [String: Any] {
        ["fields": fields.map(\.jsDictionary)]
    }

    /// This snapshot rewritten for one window's own card.
    ///
    /// Only card fields are touched, and only in rotate mode — everything else
    /// travels exactly as the leader had it. A cleared field stays cleared:
    /// substituting a full number into a box the user just emptied would fight
    /// them.
    func substitutingCard(_ payload: CardFillPayload?) -> InstantFillSnapshot {
        guard let payload else { return self }
        var copy = self
        copy.fields = fields.map { field in
            guard !field.isCheckbox,
                  let kind = CardFieldKind.classify(hint: field.hint) else { return field }
            var substituted = field
            substituted.value = CardSubstitution.value(
                for: kind,
                card: payload,
                leaderValue: field.value
            )
            // A select's option text describes the leader's chosen row and
            // would no longer match the substituted value, so the follower is
            // left to match on value alone.
            if field.isSelect, substituted.value != field.value {
                substituted.optionText = ""
            }
            return substituted
        }
        return copy
    }

    /// True when this snapshot carries any card field at all. Drives whether a
    /// rotate-mode fill needs a per-window card resolved for it.
    var containsCardFields: Bool {
        fields.contains { !$0.isCheckbox && CardFieldKind.classify(hint: $0.hint) != nil }
    }
}

/// What one window did with an Instant Fill snapshot.
nonisolated struct InstantFillOutcome: Equatable, Sendable {
    /// Snapshot fields that resolved to a control in this window.
    var found: Int
    /// Fields actually written. Lower than `found` when a box already held the
    /// right value, which is a success rather than a miss.
    var filled: Int
    /// Fields this window had no matching control for.
    var missed: Int
    var reason: String

    init(found: Int = 0, filled: Int = 0, missed: Int = 0, reason: String = "") {
        self.found = found
        self.filled = filled
        self.missed = missed
        self.reason = reason
    }

    init(jsResult: Any?) {
        guard let dict = jsResult as? [String: Any] else {
            self.init(reason: "unreadable-result")
            return
        }
        func int(_ any: Any?) -> Int {
            if let i = any as? Int { return i }
            if let d = any as? Double { return Int(d) }
            if let n = any as? NSNumber { return n.intValue }
            return 0
        }
        self.init(
            found: int(dict["found"]),
            filled: int(dict["filled"]),
            missed: int(dict["missed"]),
            reason: dict["reason"] as? String ?? ""
        )
    }

    var didReachAnything: Bool { found > 0 }
}

/// Totals for one grid-wide Instant Fill.
nonisolated struct InstantFillSummary: Equatable, Sendable {
    /// Fields read out of the leader.
    var sourceFields: Int = 0
    /// Candidate fields the leader's page exposed, filled or not.
    var leaderScanned: Int = 0
    /// Follower windows the fill reached.
    var windows: Int = 0
    /// Windows where at least one field landed.
    var windowsFilled: Int = 0
    /// Fields written across every window.
    var filled: Int = 0
    /// Snapshot fields no window could find, summed across windows.
    var missed: Int = 0

    /// The message shown afterwards.
    ///
    /// Each failure reads differently on purpose. "Nothing filled in yet" and
    /// "no form here" and "the other windows don't have these boxes" are three
    /// genuinely different situations, and collapsing them into one apologetic
    /// sentence is what makes a button feel broken.
    var toastMessage: String {
        if windows == 0 { return "No other windows to fill" }
        if sourceFields == 0 {
            return leaderScanned == 0
                ? "No form on this page to copy"
                : "Nothing filled in yet — fill this window first"
        }
        if windowsFilled == 0 {
            return missed > 0
                ? "No matching fields in the other windows"
                : "Other windows already match"
        }
        let windowWord = windowsFilled == 1 ? "window" : "windows"
        let fieldWord = filled == 1 ? "field" : "fields"
        return "Filled \(filled) \(fieldWord) across \(windowsFilled) \(windowWord)"
    }
}
