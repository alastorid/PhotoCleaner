import AppKit
import Foundation
import WebKit

/// The native window: the same interface the browser was showing, hosted by
/// WebKit.
///
/// The server is untouched by this existing. The window still loads
/// `http://127.0.0.1:<port>` and the page still reaches the API with `fetch` and
/// an `EventSource`. That is deliberate rather than lazy — the alternative,
/// serving the embedded assets through a `WKURLSchemeHandler`, cannot carry an
/// `EventSource` on a custom scheme, and the live progress read-out is a large
/// part of what the window is for. So WebKit is used to *render* the same
/// loopback app, not to bypass it.
@MainActor
final class AppWindow: NSObject, WKUIDelegate, WKNavigationDelegate {
    /// Saved frame position and size. The only user defaults PhotoCleaner keeps.
    static let frameAutosaveName = "PhotoCleanerMainWindow"

    private let url: URL
    private let window: NSWindow
    private let webView: WKWebView
    private let updateIndicator = UpdateIndicatorController()

    init(url: URL) {
        let configuration = WKWebViewConfiguration()
        // An in-memory website store, deliberately. The UI keeps no cookies, no
        // localStorage and no service worker — it has nothing to persist — so
        // this gives up nothing and keeps the property the smoke test checks:
        // PhotoCleaner writes nothing outside Application Support and Logs.
        // Together with the missing urlCache below this is why there is no WebKit
        // or Cookies entry under ~/Library at all.
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Without this the page is opaque over the scroll view's background and
        // overscroll flashes a white band in dark mode.
        webView.underPageBackgroundColor = .textBackgroundColor
        webView.allowsMagnification = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "PhotoCleaner"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Below this the score grid, the filter panel and the tile context menu
        // stop fitting; the page does not reflow below its own minimum, so the
        // window would clip instead of scroll.
        window.minSize = NSSize(width: 760, height: 540)
        window.setFrameAutosaveName(AppWindow.frameAutosaveName)

        // The update control goes in beside the title. Added once, at construction:
        // the accessory has to exist before the first update status arrives, and
        // the flow it drives replaces this very bundle.
        window.addTitlebarAccessoryViewController(updateIndicator)

        self.url = url
        self.webView = webView
        self.window = window
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Load the interface and bring the window forward.
    ///
    /// Safe to call again to raise an existing window, which is what a second
    /// launch does: the interface is already loaded, and reloading it would
    /// throw away the user's scroll position, their filter and any selection.
    func show() {
        if webView.url == nil {
            webView.load(URLRequest(url: url))
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// ⌘R: reload the interface and throw away the current page state.
    func reload() {
        webView.reloadFromOrigin()
    }

    // MARK: - Update control

    /// Show the updater's state in the title bar.
    ///
    /// The window draws and nothing else: it holds no `Updater` and starts no
    /// work, so the one place the app can replace itself is still
    /// `PhotoCleanerApp`, which owns the process.
    func showUpdateStatus(_ status: Updater.Status) {
        updateIndicator.apply(status)
    }

    /// Show `alert` as a sheet on this window, or modally if the window is not
    /// on screen.
    ///
    /// The wrapping lives here rather than in `AppDelegate` because `AppWindow`
    /// deliberately does not expose its `NSWindow` — nothing else in the app has a
    /// reason to hold it, and one method that shows a sheet is a much smaller hole
    /// than the window itself.
    ///
    /// The modal fallback is for the case where the window exists but has not been
    /// shown, which is what a second launch that focused an existing instance sees.
    /// `beginSheetModal` against an off-screen window never presents, so the
    /// fallback is not defensive padding: without it that alert is never seen.
    func present(_ alert: NSAlert) {
        guard window.isVisible else {
            alert.runModal()
            return
        }
        alert.beginSheetModal(for: window) { _ in }
    }

    // MARK: - Navigation policy

    /// The window may only ever display PhotoCleaner's own loopback server.
    ///
    /// Anything else is refused rather than rendered. The page is served from the
    /// same origin as the API, so a navigation to an outside page would leave a
    /// foreign document running in a window that is trusted locally.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url, AppWindow.isOwnServer(target, port: url.port) else {
            Log.warn("refused navigation to \(navigationAction.request.url?.absoluteString ?? "an unknown URL")")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        // Expected when the server is stopped under the window; the process is
        // on its way out at that point.
        Log.error("the window could not load the interface: \(error.localizedDescription)")
    }

    /// True only for `http://127.0.0.1:<port>` and `localhost` on the same port.
    ///
    /// The port is compared as well as the host because "loopback" alone is not
    /// a sufficient trust boundary here: any other server the user happens to be
    /// running is also on loopback.
    ///
    /// `nonisolated` because it is a pure function of its arguments, and the test
    /// suite calls it directly from off the main actor.
    nonisolated static func isOwnServer(_ candidate: URL, port: Int?) -> Bool {
        guard candidate.scheme == "http" else { return false }
        guard candidate.port == port else { return false }
        guard let host = candidate.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    // MARK: - JavaScript dialogs

    /// WebKit does not implement `alert`/`confirm`/`prompt` for a hosted web view.
    ///
    /// A dialog that silently never appears is the worst possible failure mode
    /// for this particular app: a confirmation that vanishes looks exactly like
    /// one that was skipped. The page happens to use its own modal today, but the
    /// native ones are wired up anyway, so a future `confirm()` cannot become an
    /// unanswerable question about deleting someone's photos.
    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        let sheet = warning(message)
        runSheet(sheet) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        let sheet = warning(message)
        sheet.addButton(withTitle: "Cancel")
        runSheet(sheet) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        let sheet = NSAlert()
        sheet.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = defaultText ?? ""
        sheet.accessoryView = field
        sheet.addButton(withTitle: "OK")
        sheet.addButton(withTitle: "Cancel")
        runSheet(sheet) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// Destructive answers read as destructive: macOS shows a stop sign rather
    /// than the informational icon, whether or not the page chose one.
    private func warning(_ message: String) -> NSAlert {
        let sheet = NSAlert()
        sheet.messageText = message
        sheet.alertStyle = .warning
        sheet.addButton(withTitle: "OK")
        return sheet
    }

    private func runSheet(_ sheet: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        sheet.beginSheetModal(for: window) { response in completion(response) }
    }
}
