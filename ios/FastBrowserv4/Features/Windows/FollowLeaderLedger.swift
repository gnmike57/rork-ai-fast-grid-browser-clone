import Foundation

/// One mirrored action and what each window did with it.
///
/// The ledger exists because "unbreakable" is a claim, and a claim you cannot
/// inspect is just a hope. Every action the leader takes gets a row, and every
/// window gets a cell in that row, so the answer to "did window five actually
/// do this?" is a glance rather than a guess.
///
/// Deliberately never records a *value*: the summary says "Typed into Card
/// number", never what was typed. The ledger is a UI surface, so a card number
/// or a password must not be able to reach it.
nonisolated struct FollowLeaderLedgerEntry: Identifiable, Equatable, Sendable {
    /// What one window did with one action.
    enum WindowState: String, Sendable {
        /// Queued or in flight — not settled yet.
        case pending
        /// Applied and the page provably changed.
        case confirmed
        /// Provably delivered to the control, effect unobservable.
        case delivered
        /// Missed, then recovered by replaying the page from the start.
        case repaired
        /// Never landed, and the window was not repaired (Relaxed only).
        case missed
        /// The window had already left the squad when this action happened.
        case dropped
    }

    /// The action's monotonic sequence number, which is also its row identity.
    let id: Int
    let kind: FollowLeaderAction.Kind
    /// Plain-English description. Never contains a typed value.
    let summary: String
    /// True for the irreversible steps the leader is gated at.
    let isCommit: Bool
    let recordedAt: Date
    /// Window index → what that window did with this action.
    private(set) var states: [Int: WindowState]

    init(
        seq: Int,
        kind: FollowLeaderAction.Kind,
        summary: String,
        isCommit: Bool,
        windows: [Int],
        recordedAt: Date = Date()
    ) {
        self.id = seq
        self.kind = kind
        self.summary = summary
        self.isCommit = isCommit
        self.recordedAt = recordedAt
        var initial: [Int: WindowState] = [:]
        for window in windows { initial[window] = .pending }
        self.states = initial
    }

    fileprivate mutating func set(_ state: WindowState, for window: Int) {
        // A repair is the *story* of this row, not a step in it: once a window
        // had to replay the page to satisfy this action, a later confirmation
        // must not erase that from the record.
        if states[window] == .repaired && state == .confirmed { return }
        if states[window] == .dropped { return }
        states[window] = state
    }

    /// Windows that have not settled yet.
    var pendingCount: Int { states.values.filter { $0 == .pending }.count }

    var isWaiting: Bool { pendingCount > 0 }
    var hasRepair: Bool { states.values.contains(.repaired) }
    var hasDrop: Bool { states.values.contains(.dropped) }

    /// Window indices in ascending order, so every row draws its cells in the
    /// same order and the ticks ripple predictably.
    var windowOrder: [Int] { states.keys.sorted() }
}

/// Bounded, ordered record of mirrored actions.
///
/// Pure value type with an offset map, so marking a window's state on an
/// action that happened two hundred steps ago is a dictionary lookup rather
/// than a scan of the whole history.
nonisolated struct FollowLeaderLedger: Equatable, Sendable {
    /// Oldest first. The screen reverses this for display.
    private(set) var entries: [FollowLeaderLedgerEntry] = []
    /// Sequence number → position in `entries`.
    private var offsets: [Int: Int] = [:]

    /// Rows kept before the oldest are discarded. The ledger is a live view of
    /// the current flow, not an audit trail, and an unbounded one on a
    /// keystroke-exact recorder would grow without limit.
    static let capacity: Int = 250

    init() {}

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// Adds a row for a freshly recorded action.
    mutating func record(
        seq: Int,
        kind: FollowLeaderAction.Kind,
        summary: String,
        isCommit: Bool,
        windows: [Int]
    ) {
        guard offsets[seq] == nil else { return }
        entries.append(
            FollowLeaderLedgerEntry(
                seq: seq,
                kind: kind,
                summary: summary,
                isCommit: isCommit,
                windows: windows
            )
        )
        offsets[seq] = entries.count - 1
        trimIfNeeded()
    }

    /// Records what one window did with one action.
    mutating func mark(seq: Int, window: Int, state: FollowLeaderLedgerEntry.WindowState) {
        guard let offset = offsets[seq], entries.indices.contains(offset) else { return }
        entries[offset].set(state, for: window)
    }

    /// A window left the squad: every row it had not settled becomes a drop,
    /// and it is greyed out for everything that follows.
    mutating func markDropped(window: Int) {
        for index in entries.indices where entries[index].states[window] != nil {
            if entries[index].states[window] == .pending {
                entries[index].set(.dropped, for: window)
            }
        }
    }

    mutating func removeAll() {
        entries.removeAll()
        offsets.removeAll()
    }

    /// Rows still waiting on at least one window.
    var waitingCount: Int { entries.filter(\.isWaiting).count }
    var repairedCount: Int { entries.filter(\.hasRepair).count }

    private mutating func trimIfNeeded() {
        guard entries.count > Self.capacity else { return }
        let excess = entries.count - Self.capacity
        entries.removeFirst(excess)
        offsets.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() { offsets[entry.id] = index }
    }
}

/// Which rows the ledger screen is showing.
nonisolated enum FollowLeaderLedgerFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case waiting
    case repaired
    case dropped

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .waiting: return "Waiting"
        case .repaired: return "Repaired"
        case .dropped: return "Dropped"
        }
    }

    func matches(_ entry: FollowLeaderLedgerEntry) -> Bool {
        switch self {
        case .all: return true
        case .waiting: return entry.isWaiting
        case .repaired: return entry.hasRepair
        case .dropped: return entry.hasDrop
        }
    }
}
