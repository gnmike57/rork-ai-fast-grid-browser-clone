import Foundation
import SwiftData
import UIKit
import WebKit

/// Owns parked, still-signed-in sessions. Each parked row keeps its own
/// isolated WebKit store identity so cookies never bleed between accounts,
/// and the metadata survives an app restart.
@MainActor
@Observable
final class ParkedSessionStore {
    static let shared = ParkedSessionStore()

    private(set) var sessions: [ParkedSession] = []
    /// Failures recorded during the current (or most recent) run — powers
    /// the deck header ("3 parked, 12 failed").
    private(set) var failedThisRun: Int = 0
    /// Set briefly after a park so the deck button can flourish.
    var justParkedID: String?
    var runActive: Bool = false

    /// Replay-eligible sessions (Joe Fortune / Ignition) in run order —
    /// oldest first, so the numbered circles read 1, 2, 3… down the deck.
    /// `sessions` itself is newest-first, so this re-sorts ascending.
    var deckSessions: [ParkedSession] {
        sessions
            .filter { $0.replaySite != nil }
            .sorted { $0.parkedAt < $1.parkedAt }
    }

    private var modelContext: ModelContext?

    private init() {}

    func attach(context: ModelContext) {
        modelContext = context
        reload()
    }

    func reload() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ParkedSession>(
            sortBy: [SortDescriptor(\.parkedAt, order: .reverse)]
        )
        sessions = (try? modelContext.fetch(descriptor)) ?? []
    }

    func markRunStarted() {
        failedThisRun = 0
        runActive = true
    }

    func markRunFinished() {
        runActive = false
    }

    func recordFailure() {
        failedThisRun += 1
    }

    func contains(storeID: UUID) -> Bool {
        let raw = storeID.uuidString
        return sessions.contains { $0.storeID == raw }
    }

    /// Parks a live store. The caller is responsible for handing the window
    /// a fresh store afterwards so the batch can continue.
    @discardableResult
    func park(
        storeID: UUID,
        url: URL?,
        username: String,
        domain: String,
        credentialID: String,
        sessionTag: String,
        thumbnail: UIImage?,
        sourceWindowIndex: Int
    ) -> ParkedSession? {
        guard let modelContext else { return nil }
        let row = ParkedSession(
            storeID: storeID,
            urlString: url?.absoluteString ?? "",
            username: username,
            domain: domain,
            credentialID: credentialID,
            sessionTag: sessionTag,
            thumbnailFilename: nil,
            sourceWindowIndex: sourceWindowIndex
        )
        modelContext.insert(row)
        try? modelContext.save()
        reload()
        justParkedID = row.id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if justParkedID == row.id { justParkedID = nil }
        }
        // The JPEG encode runs off-thread; the row lands with no thumbnail
        // and adopts one moments later so parking never stutters on a
        // 16-window batch.
        if let thumbnail {
            Task { [weak self] in
                guard let filename = await ScreenshotStorage.save(thumbnail) else { return }
                row.thumbnailFilename = filename
                try? self?.modelContext?.save()
                self?.reload()
            }
        }
        return row
    }

    /// Removes the row without wiping the WebKit store. Replay reads a
    /// parked store in place, so the only caller left is `forget`, which
    /// wipes the store immediately afterwards.
    private func detach(_ session: ParkedSession) {
        guard let modelContext else { return }
        if let filename = session.thumbnailFilename {
            ScreenshotStorage.delete(filename)
        }
        modelContext.delete(session)
        try? modelContext.save()
        reload()
    }

    /// Closes the parked session and wipes its isolated cookie store.
    func forget(_ session: ParkedSession) async {
        let storeID = session.storeUUID
        detach(session)
        await QuadDataStore.burn(dataStoreID: storeID)
    }

    func clearAll() async {
        let snapshot = sessions
        for session in snapshot {
            await forget(session)
        }
        failedThisRun = 0
    }
}

/// Tiny helper so snapshot-then-park can share one code path.
enum WebViewSnapshotter {
    @MainActor
    static func capture(_ webView: WKWebView?, width: CGFloat = 600) async -> UIImage? {
        guard let webView else { return nil }
        return await withCheckedContinuation { continuation in
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = NSNumber(value: Double(width))
            webView.takeSnapshot(with: config) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
