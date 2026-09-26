import Foundation

/// Snapshot of the browsing layout (mode, grid size, per-window pages,
/// focus) captured whenever the app leaves the foreground, so the next
/// launch can offer to restore it exactly instead of always starting blank.
struct LastSessionSnapshot: Codable, Equatable {
    enum ModeKind: String, Codable { case single, grid }

    var modeKind: ModeKind
    var gridSize: Int?
    var isDual: Bool
    var tabURLs: [String]
    var activeTabIndex: Int
    var quadSessionURLs: [String]
    var focusedIndex: Int
    var savedAt: Date

    /// Short human summary for the restore card, e.g. "3 tabs" or
    /// "4x2 grid, dual-site".
    var summary: String {
        switch modeKind {
        case .single:
            let count = max(1, tabURLs.filter { !$0.isEmpty }.count)
            return count == 1 ? "1 tab" : "\(count) tabs"
        case .grid:
            let size = WindowGridSize(rawValue: gridSize ?? 0)
            let label = size?.label ?? "\(gridSize ?? 0)-window"
            return isDual ? "\(label) grid, dual-site" : "\(label) grid"
        }
    }
}

/// Persists the single most recent `LastSessionSnapshot`. Read once at
/// launch to offer the restore card, cleared as soon as the user accepts
/// or dismisses it.
@MainActor
final class LastSessionStore {
    static let shared = LastSessionStore()
    private let key = "lastSessionSnapshotV1"

    private init() {}

    func save(_ snapshot: LastSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func load() -> LastSessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(LastSessionSnapshot.self, from: data) else { return nil }
        return snapshot
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
