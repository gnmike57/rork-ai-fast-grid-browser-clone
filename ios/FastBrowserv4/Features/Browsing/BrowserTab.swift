import Foundation
import WebKit
import UIKit

@Observable
@MainActor
class BrowserTab: Identifiable {
    let id: String
    /// Persistent WebKit data-store identity for this tab. Cookies, cache,
    /// localStorage and IndexedDB stay isolated from every other tab and
    /// every multi-window cell.
    var dataStoreID: UUID
    /// Bumped when the tab adopts a new isolated store so SwiftUI rebuilds
    /// the `WKWebView` (configuration is immutable after creation).
    var webViewGeneration: Int
    var url: URL?
    var title: String
    var isLoading: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var estimatedProgress: Double
    var webView: WKWebView?
    var lastURL: URL?
    var snapshot: UIImage?
    /// True when the last navigation failed (offline, DNS, dead host) and
    /// hasn't been retried yet. Drives the "Couldn't load" retry overlay
    /// instead of leaving the tab blank forever.
    var loadFailed: Bool = false
    /// Latest attributed memory sample for the diagnostic overlay.
    var memorySnapshot: WindowMemorySnapshot?
    /// Latest automated leak-check result for this tab.
    var leakCheck: WindowLeakCheckReport = .idle

    init(url: URL? = nil, dataStoreID: UUID = UUID()) {
        self.id = UUID().uuidString
        self.dataStoreID = dataStoreID
        self.webViewGeneration = 0
        self.url = url
        self.title = "New Tab"
        self.isLoading = false
        self.canGoBack = false
        self.canGoForward = false
        self.estimatedProgress = 0
        self.lastURL = url
    }

    var domain: String {
        guard let host = url?.host(percentEncoded: false)?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayURL: String {
        url?.absoluteString ?? ""
    }

    /// Hands this tab a brand-new isolated store. The previous store is
    /// left untouched — callers park or burn it themselves.
    func adoptFreshStore() {
        dataStoreID = UUID()
        webViewGeneration += 1
        webView = nil
    }

    func captureSnapshot() {
        guard let webView else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 200
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            Task { @MainActor in
                self?.snapshot = image
            }
        }
    }
}
