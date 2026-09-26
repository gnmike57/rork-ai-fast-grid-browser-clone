import Foundation
import WebKit

/// Runs the injected card fill inside one web view.
///
/// Shared by multi-window mode and single-window mode so both take the exact
/// same path — a card that fills on a grid tile must behave identically in a
/// single window, or the feature is two features.
@MainActor
enum CardFillService {

    static func fill(
        _ payload: CardFillPayload,
        in webView: WKWebView,
        timeout: TimeInterval
    ) async -> CardFillOutcome {
        let box = CallBox()
        webView.callAsyncJavaScript(
            JavaScriptInjectionService.cardFillBody(),
            arguments: ["card": payload.jsArguments],
            in: nil,
            in: .page
        ) { result in
            guard !box.isSettled else { return }
            box.isSettled = true
            switch result {
            case .success(let value):
                box.outcome = CardFillOutcome(jsResult: value)
            case .failure(let error):
                box.outcome = CardFillOutcome(reason: "js-error-\((error as NSError).code)")
            }
        }
        // Hard deadline: `callAsyncJavaScript` may never complete on a wedged
        // web content process, and a fill must never hang the UI behind it.
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if box.isSettled { return box.outcome ?? CardFillOutcome(reason: "empty-result") }
            if Task.isCancelled { return CardFillOutcome(reason: "cancelled") }
            try? await Task.sleep(for: .milliseconds(12))
        }
        box.isSettled = true
        return CardFillOutcome(reason: "timeout")
    }

    /// One-shot latch, so a late completion handler can never settle a call
    /// that already timed out.
    @MainActor
    private final class CallBox {
        var isSettled: Bool = false
        var outcome: CardFillOutcome?
    }
}
