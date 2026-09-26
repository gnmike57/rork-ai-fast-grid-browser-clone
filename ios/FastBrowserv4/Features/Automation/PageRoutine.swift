import SwiftUI

/// Every automated thing the app does to a web page, described in plain
/// English.
///
/// The app injects a lot of behaviour into pages — filling a login, copying
/// the leader's keystrokes, filling a card, deciding whether a login worked,
/// repairing a fill that got stuck. All of it was invisible: the code lived in
/// four services and two view models, and the switches were scattered across
/// three different settings screens. There was no way to answer "what is this
/// app doing to this page, and why".
///
/// This is that answer. One entry per routine, each saying what it does, when
/// it fires, and where its off switch is — or, honestly, that it hasn't got
/// one because the feature is the routine.
nonisolated struct PageRoutine: Identifiable, Sendable {
    /// Where a routine's off switch lives, if it has one.
    enum Control: Sendable {
        /// A boolean in `UserDefaults` this screen can flip directly.
        case toggle(key: String, defaultOn: Bool)
        /// Armed from the card button's hold-menu and the Cards tab.
        case cardAutoFill
        /// A mode picker rather than an on/off.
        case successDetection
        /// Relaxed vs Unbreakable, plus the way into the sync ledger.
        case followLeaderMode
        /// Core behaviour — switching it off would mean switching the feature
        /// off, so the string says which control does that instead.
        case core(String)
    }

    let id: String
    let title: String
    let icon: String
    let tint: Color
    /// What it does to the page.
    let what: String
    /// The moment it fires.
    let when: String
    let control: Control

    /// Routines in the order they can happen to a page, so reading the list
    /// top to bottom is a description of one login attempt.
    @MainActor
    static var all: [PageRoutine] {
        [
            PageRoutine(
                id: "pageLoadFill",
                title: "Fill a saved login",
                icon: "person.text.rectangle",
                tint: Cockpit.live,
                what: "Finds the username and password boxes and types a matching saved login into them. Never presses the submit button.",
                when: "Whenever a page finishes loading and the vault has a login for that site.",
                control: .toggle(key: SettingsKey.autoFillOnPageLoad, defaultOn: true)
            ),
            PageRoutine(
                id: "runQueue",
                title: "Work through the queue",
                icon: "bolt.fill",
                tint: Cockpit.live,
                what: "Loads the target site, fills one saved login, submits it, waits for the answer, then moves to the next one.",
                when: "Only while a run is going, started from the RCR button.",
                control: .core("Stops when you stop the run.")
            ),
            PageRoutine(
                id: "followLeader",
                title: "Copy the leader",
                icon: "person.2.wave.2",
                tint: Cockpit.live,
                what: "Watches what you type and tap in window one and repeats it in every other window, matching each field by its position and label rather than its screen coordinates. Relaxed copies quickly and merges bursts of typing. Unbreakable copies every keystroke, key combination, focus change, tap point and scroll exactly, confirms each one landed before that window moves on, rebuilds a window that falls out of step by replaying the page, and holds you at a submit or a payment until every window has caught up.",
                when: "Only while Follow the Leader is switched on, from the address bar menu.",
                control: .followLeaderMode
            ),
            PageRoutine(
                id: "cardFill",
                title: "Fill a card",
                icon: "creditcard.fill",
                tint: Cockpit.card,
                what: "Finds card number, expiry, security code and name boxes — including ones inside a payment provider's embedded frame — and types the window's assigned card. Never submits a payment.",
                when: "When you press the card button, or by itself on any page with card fields if auto-fill is armed.",
                control: .cardAutoFill
            ),
            PageRoutine(
                id: "successJudge",
                title: "Decide whether a login worked",
                icon: "checkmark.shield",
                tint: Cockpit.success,
                what: "Reads the page after a submit — the address, the visible text, whether the login form is still there — and decides success, failure, or unclear. Unclear ones can be passed to the AI for a second opinion.",
                when: "After every submit during a run.",
                control: .successDetection
            ),
            PageRoutine(
                id: "healer",
                title: "Repair a stuck fill",
                icon: "wrench.and.screwdriver",
                tint: Cockpit.attention,
                what: "When a fill finds no boxes to type into, sends the page's structure — labels and field names only, never any values — to the AI and asks it which boxes to use, then tries again.",
                when: "Only after a fill has already failed to find anything.",
                control: .toggle(key: "aiHealerEnabled", defaultOn: true)
            ),
            PageRoutine(
                id: "vision",
                title: "Judge from a screenshot",
                icon: "eye",
                tint: Cockpit.attention,
                what: "Sends a picture of the page to the AI so it can read a result the text checks couldn't settle. Passwords are never in the picture.",
                when: "Only on pages the text checks called unclear, and only with this switched on.",
                control: .toggle(key: "aiVisionConsentGranted", defaultOn: false)
            ),
            PageRoutine(
                id: "saveOffer",
                title: "Offer to save a login",
                icon: "square.and.arrow.down",
                tint: Cockpit.live,
                what: "Notices when you submit a form with a username and password it hasn't seen and offers to add it to the vault.",
                when: "When you submit a login form yourself, outside a run.",
                control: .toggle(key: SettingsKey.offerToSavePasswords, defaultOn: true)
            ),
            PageRoutine(
                id: "pacing",
                title: "Learn how slow a site is",
                icon: "timer",
                tint: Cockpit.textSecondary,
                what: "Times how long a site really takes to settle after it says it has loaded — consent banners included — and waits that long before filling next time. Always kept between 0.6 and 12 seconds.",
                when: "Every page load, quietly, per site.",
                control: .core("Reset per site under the address bar menu, Site Settings.")
            ),
            PageRoutine(
                id: "disabledWatch",
                title: "Watch for a disabled account",
                icon: "exclamationmark.triangle",
                tint: Cockpit.danger,
                what: "Listens for the site announcing that an account is disabled, and takes that login out of the queue so the run doesn't keep hammering it.",
                when: "During a run, on the run's target site only.",
                control: .core("Part of running a queue.")
            )
        ]
    }
}
