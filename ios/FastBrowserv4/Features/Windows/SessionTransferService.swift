import Foundation
import WebKit

/// A saved browser session: full cookie jar for the captured window plus the
/// current page's origin-scoped local/session storage. Written to a single
/// file the user picks in Files, and reloadable into one or many windows.
nonisolated struct SessionSnapshot: Codable, Sendable {
    var version: Int
    var savedAt: Date
    var href: String
    var origin: String
    var cookies: [CookieData]
    var localStorage: [String: String]
    var sessionStorage: [String: String]
}

/// Codable projection of an `HTTPCookie`. Only the fields needed to
/// reconstruct a login are stored; HTTPOnly can't be re-set via the public
/// properties API so it is intentionally omitted.
nonisolated struct CookieData: Codable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Double?
    var isSecure: Bool
    var sameSite: String?

    init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        expires = cookie.expiresDate?.timeIntervalSince1970
        isSecure = cookie.isSecure
        sameSite = cookie.sameSitePolicy?.rawValue
    }

    var httpCookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path.isEmpty ? "/" : path
        ]
        if let expires { props[.expires] = Date(timeIntervalSince1970: expires) }
        if isSecure { props[.secure] = "TRUE" }
        if let sameSite { props[.sameSitePolicy] = HTTPCookieStringPolicy(rawValue: sameSite) }
        return HTTPCookie(properties: props)
    }
}

/// Captures and restores browser sessions across isolated data stores.
/// Cookies transfer in full; local/session storage is best-effort and only
/// applies once a target window has loaded the snapshot's origin.
@MainActor
final class SessionTransferService {
    static let shared = SessionTransferService()
    private init() {}

    static let fileExtension = "fast6session"

    /// Snapshots waiting for their target store to land on the right origin
    /// so their storage can be injected. Keyed by data-store identity.
    private var pendingStorage: [UUID: SessionSnapshot] = [:]

    // MARK: - Capture

    func capture(from webView: WKWebView) async -> SessionSnapshot {
        let cookies = await allCookies(from: webView.configuration.websiteDataStore)
        let storage = await captureStorage(from: webView)
        return SessionSnapshot(
            version: 1,
            savedAt: Date(),
            href: storage?.href ?? webView.url?.absoluteString ?? "",
            origin: storage?.origin ?? "",
            cookies: cookies.map(CookieData.init),
            localStorage: storage?.localStorage ?? [:],
            sessionStorage: storage?.sessionStorage ?? [:]
        )
    }

    private func allCookies(from store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            store.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
    }

    private struct StorageCapture {
        let origin: String
        let href: String
        let localStorage: [String: String]
        let sessionStorage: [String: String]
    }

    private func captureStorage(from webView: WKWebView) async -> StorageCapture? {
        let raw = try? await webView.evaluateJavaScript(JavaScriptInjectionService.sessionStorageCaptureScript())
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return StorageCapture(
            origin: dict["origin"] as? String ?? "",
            href: dict["href"] as? String ?? "",
            localStorage: dict["localStorage"] as? [String: String] ?? [:],
            sessionStorage: dict["sessionStorage"] as? [String: String] ?? [:]
        )
    }

    // MARK: - Restore

    /// Writes every cookie into the target store and queues the snapshot's
    /// storage for injection on the next load of its origin.
    func applyCookies(_ snapshot: SessionSnapshot, toStoreID storeID: UUID) async {
        await applyCookies(snapshot, to: WKWebsiteDataStore(forIdentifier: storeID), storeID: storeID)
    }

    /// Same, but against a store instance the caller already holds. Prefer a
    /// rendered web view's own `configuration.websiteDataStore`: a second
    /// `WKWebsiteDataStore(forIdentifier:)` instance is not guaranteed to
    /// publish cookie writes into a web view that is already running on that
    /// identity, which silently loses the clone.
    func applyCookies(_ snapshot: SessionSnapshot, to store: WKWebsiteDataStore, storeID: UUID) async {
        for cookieData in snapshot.cookies {
            guard let cookie = cookieData.httpCookie else { continue }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.httpCookieStore.setCookie(cookie) { cont.resume() }
            }
        }
        if !snapshot.localStorage.isEmpty || !snapshot.sessionStorage.isEmpty {
            pendingStorage[storeID] = snapshot
        } else {
            pendingStorage.removeValue(forKey: storeID)
        }
    }

    /// Called from each web view's `didFinish`. When the window has landed on
    /// the snapshot's origin, injects the stored keys then reloads once so a
    /// single-page app boots with both cookies and storage in place. Clearing
    /// the pending entry before the reload prevents any loop.
    func applyPendingStorageIfNeeded(storeID: UUID, webView: WKWebView) {
        guard let snapshot = pendingStorage[storeID] else { return }
        guard let host = webView.url?.host?.lowercased(),
              let snapHost = URL(string: snapshot.origin)?.host?.lowercased(),
              host == snapHost else { return }
        pendingStorage.removeValue(forKey: storeID)
        guard let localJSON = Self.jsonObjectLiteral(snapshot.localStorage),
              let sessionJSON = Self.jsonObjectLiteral(snapshot.sessionStorage) else { return }
        let js = JavaScriptInjectionService.sessionStorageRestoreScript(
            localStorageJSON: localJSON,
            sessionStorageJSON: sessionJSON
        )
        webView.evaluateJavaScript(js) { _, _ in
            webView.reload()
        }
    }

    /// Drops any queued storage — used when a fresh load is issued so a stale
    /// snapshot can't inject into an unrelated page.
    func clearPending(storeID: UUID) {
        pendingStorage.removeValue(forKey: storeID)
    }

    // MARK: - Verification

    /// Cookie names actually present in a store for `host`. Compared against
    /// the donor's names to prove a clone landed instead of assuming it did.
    func cookieNames(in store: WKWebsiteDataStore, matchingHost host: String?) async -> Set<String> {
        let cookies = await allCookies(from: store)
        guard let host = SessionCarry.normalizedHost(host) else { return Set(cookies.map(\.name)) }
        return Set(cookies.filter { Self.cookieDomain($0.domain, matchesHost: host) }.map(\.name))
    }

    /// Cookie names in a captured snapshot that apply to `host`.
    nonisolated static func cookieNames(in snapshot: SessionSnapshot, matchingHost host: String?) -> Set<String> {
        guard let host = SessionCarry.normalizedHost(host) else { return Set(snapshot.cookies.map(\.name)) }
        return Set(snapshot.cookies.filter { cookieDomain($0.domain, matchesHost: host) }.map(\.name))
    }

    /// Standard cookie-domain matching: an exact host match, or any subdomain
    /// of a domain-scoped cookie (`.example.com` covers `app.example.com`).
    nonisolated static func cookieDomain(_ domain: String, matchesHost host: String) -> Bool {
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        guard let cookieHost = SessionCarry.normalizedHost(bare),
              let target = SessionCarry.normalizedHost(host) else { return false }
        return target == cookieHost || target.hasSuffix("." + cookieHost)
    }

    // MARK: - Encoding

    nonisolated static func encode(_ snapshot: SessionSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(snapshot)
    }

    nonisolated static func decode(_ data: Data) -> SessionSnapshot? {
        try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    /// Serializes a `[String:String]` into a JS object literal for injection.
    nonisolated static func jsonObjectLiteral(_ dict: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
