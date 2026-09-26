import Foundation
import WebKit

/// Shared post-navigation settle used by single-window and multi-window RCR.
/// After a perm-disabled burn the next credential needs extra time for the
/// fresh page to boot, a cookie/consent banner to appear, and that banner
/// to be dismissed — filling too early lands in an empty or blocked form.
enum PageSettleService {
    /// Delay after `didFinish` so SPA / CMP scripts can mount on a burned store.
    static let postBurnBootDelay: Duration = .seconds(2.5)
    /// How long to wait for a consent banner to appear after a burn.
    static let postBurnCookieGraceMs: Int = 5_000
    /// Total wait for the banner to be dismissed after a burn.
    static let postBurnCookieTimeoutMs: Int = 18_000
    /// How long to poll for a visible login form after consent is gone.
    static let postBurnLoginFormTimeout: Duration = .seconds(8)
    static let loginFormPollInterval: Duration = .milliseconds(400)
    /// Navigation watchdog after a burn — casino pages + CMP often exceed 12s.
    static let postBurnNavigationWatchdog: Duration = .seconds(30)

    static let normalCookieGraceMs: Int = 1_500
    static let normalCookieTimeoutMs: Int = 10_000

    /// Shared per-attempt observation watchdog for both single-window and
    /// multi-window RCR — one definition so the two can never drift.
    /// `SpeedProfile.effectiveWatchdog` stretches it for slow profiles and
    /// never lets fast profiles shrink it.
    static let attemptWatchdog: Duration = .seconds(12)

    /// Parses `detectLoginFormScript()` output. Pure so tests can cover it.
    nonisolated static func parseHasLoginForm(_ raw: Any?) -> Bool {
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flag = dict["hasLoginForm"] as? Bool else { return false }
        return flag
    }

    /// Polls until a visible login form exists or the timeout elapses.
    @MainActor
    static func waitForLoginForm(in webView: WKWebView, timeout: Duration = postBurnLoginFormTimeout) async {
        let deadline = Date().addingTimeInterval(timeout.seconds)
        while Date() < deadline {
            let raw = try? await webView.evaluateJavaScript(
                JavaScriptInjectionService.detectLoginFormScript()
            )
            if parseHasLoginForm(raw) { return }
            try? await Task.sleep(for: loginFormPollInterval)
        }
    }
}
