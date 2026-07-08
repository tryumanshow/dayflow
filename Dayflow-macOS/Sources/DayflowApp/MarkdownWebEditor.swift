import AppKit
import SwiftUI
import WebKit

/// Notion-style markdown editor backed by `WKWebView` + BlockNote.js.
///
/// Why a WKWebView instead of a hand-rolled NSTextField/NSTextView:
/// IME composition (Korean jamo), undo, copy/paste, list continuation,
/// and smart caret behaviour are solved problems in mature web editors.
/// BlockNote gives us block-based cross-list-type nesting (bullet → task
/// child, and vice versa) for free, which is the main thing TipTap's
/// ProseMirror schema wouldn't let us do cleanly.
///
/// Data contract:
/// - Swift owns two parallel representations: the lossy markdown string
///   (read by Week/Month checkbox parsers, backup-readable), and the
///   lossless BlockNote document tree as a JSON string (carries rich
///   styles that markdown can't, e.g. text/background color and
///   underline). Both are bound.
/// - When the binding changes externally (different day loaded), we push
///   into the editor via `window.dayflowSetContent(md, json)`. JSON wins
///   if non-empty; otherwise we fall back to parsing markdown.
/// - When the user types, BlockNote fires `onEditorContentChange`, we
///   compute both markdown and JSON and post them back via the `dayflow`
///   message handler.
/// Notification names for bridging SwiftUI menu commands → WKWebView.
extension Notification.Name {
    static let dayflowCopy      = Notification.Name("dayflowCopy")
    static let dayflowCut       = Notification.Name("dayflowCut")
    static let dayflowPaste     = Notification.Name("dayflowPaste")
    static let dayflowSelectAll = Notification.Name("dayflowSelectAll")
    static let dayflowUndo      = Notification.Name("dayflowUndo")
    static let dayflowRedo      = Notification.Name("dayflowRedo")
    static let dayflowFind      = Notification.Name("dayflowFind")
    /// Editor zoom — bumps `dayEditorFontSize` or
    /// `monthPlanEditorFontSize` in `ContentView` based on the active
    /// view mode. Mirrors the macOS `View → Zoom In/Out/Reset` triplet.
    static let dayflowZoomIn    = Notification.Name("dayflowZoomIn")
    static let dayflowZoomOut   = Notification.Name("dayflowZoomOut")
    static let dayflowZoomReset = Notification.Name("dayflowZoomReset")
}

/// WKWebView consumes scroll-wheel events even when its inner document
/// has no overflow to scroll. That swallows the gesture when this editor
/// is hosted inside a SwiftUI `ScrollView` (the right rail in 이달 계획),
/// so the user can't scroll past the editor with the cursor on top of it.
/// Forward the event to `nextResponder` whenever the inner editor body
/// reports it has nothing to scroll in the wheel direction. JS pushes a
/// `scrollState` message after every content/size change so the flag
/// stays in sync without per-event JS round-trips.
final class ScrollForwardingWebView: WKWebView {
    /// Updated by the `scrollState` message from the editor JS:
    /// `canScrollUp` / `canScrollDown` reflect whether the inner
    /// `#editor` has room to scroll further in that direction.
    var canScrollUp: Bool = false
    var canScrollDown: Bool = false

    override func scrollWheel(with event: NSEvent) {
        // deltaY > 0 = wheel rolled up (page scrolls down on natural
        // scroll, up on classic) — match macOS convention: positive
        // deltaY scrolls content downward, i.e. shows content above.
        let dy = event.scrollingDeltaY
        let goingUp = dy > 0
        let goingDown = dy < 0
        let canHandleHere = (goingUp && canScrollUp) || (goingDown && canScrollDown)
        if canHandleHere {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

struct MarkdownWebEditor: NSViewRepresentable {
    @Binding var markdown: String
    @Binding var markdownJSON: String?
    /// Editor body font size in CSS pixels. Pushed into a CSS
    /// variable so Settings can live-update without a relaunch.
    /// Headings scale proportionally via `em`.
    var fontSize: Double = 15
    var onChange: (String, String?) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "dayflow")
        config.userContentController = userContent
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Serve the locally-vendored BlockNote assets over a private scheme so
        // the editor no longer fetches from esm.sh at runtime. Must be set on
        // the configuration before the web view is created.
        config.setURLSchemeHandler(EditorSchemeHandler(), forURLScheme: EditorSchemeHandler.scheme)

        let web = ScrollForwardingWebView(frame: .zero, configuration: config)
        context.coordinator.scrollWebView = web
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        // Safari Web Inspector is a debug-only convenience. Gating it prevents
        // local-access attackers from dumping private markdown through the
        // remote debugging protocol in release builds.
        #if DEBUG
        if #available(macOS 13.3, *) {
            web.isInspectable = true
        }
        #endif
        // Load the page itself through the scheme handler so the document and
        // all its vendored modules share the `dayflow-asset://editor` origin —
        // ES module imports need a real (non-opaque) origin, which loadHTMLString
        // does not reliably provide.
        web.load(URLRequest(url: EditorSchemeHandler.baseURL.appendingPathComponent("index.html")))

        context.coordinator.webView = web
        context.coordinator.pendingMarkdown = markdown
        context.coordinator.pendingJSON = markdownJSON
        context.coordinator.pendingFontSize = fontSize
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only push when the binding diverged from what the editor last
        // emitted — otherwise we'd bounce the user's own edit back.
        let mdChanged = markdown != context.coordinator.lastEmittedMarkdown
        let jsonChanged = (markdownJSON ?? "") != context.coordinator.lastEmittedJSON
        if mdChanged || jsonChanged {
            context.coordinator.pendingMarkdown = markdown
            context.coordinator.pendingJSON = markdownJSON
            context.coordinator.flushIfReady()
        }
        if fontSize != context.coordinator.appliedFontSize {
            context.coordinator.pendingFontSize = fontSize
            context.coordinator.applyFontSizeIfReady()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownWebEditor
        weak var webView: WKWebView?
        weak var scrollWebView: ScrollForwardingWebView?
        var ready: Bool = false
        var pendingMarkdown: String? = nil
        var pendingJSON: String? = nil
        var lastEmittedMarkdown: String = ""
        var lastEmittedJSON: String = ""
        /// Pending font size push; flushed on editor-ready or
        /// whenever `updateNSView` sees a new value.
        var pendingFontSize: Double? = nil
        /// Last value actually pushed to the WebView. Used as the
        /// dirty check so we don't re-inject on every tick.
        var appliedFontSize: Double = -1

        init(_ parent: MarkdownWebEditor) {
            self.parent = parent
            super.init()
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(handleCopy),      name: .dayflowCopy,      object: nil)
            nc.addObserver(self, selector: #selector(handleCut),       name: .dayflowCut,       object: nil)
            nc.addObserver(self, selector: #selector(handlePaste),     name: .dayflowPaste,     object: nil)
            nc.addObserver(self, selector: #selector(handleSelectAll), name: .dayflowSelectAll, object: nil)
            nc.addObserver(self, selector: #selector(handleUndo),      name: .dayflowUndo,      object: nil)
            nc.addObserver(self, selector: #selector(handleRedo),      name: .dayflowRedo,      object: nil)
            nc.addObserver(self, selector: #selector(handleFind),      name: .dayflowFind,      object: nil)
        }

        // MARK: - Menu command handlers (via Notification)

        // Forward to WKWebView's native action selectors. ProseMirror's
        // clipboard plugin runs on the resulting DOM copy/cut/paste event
        // and preserves block structure (HTML + plain text flavors).
        // Trimming or re-serializing in Swift collapses chunk boundaries,
        // so we delegate entirely.
        @objc private func handleCopy()      { webView?.perform(#selector(NSText.copy(_:)),      with: nil) }
        @objc private func handleCut()       { webView?.perform(#selector(NSText.cut(_:)),       with: nil) }
        @objc private func handlePaste()     { webView?.perform(#selector(NSText.paste(_:)),     with: nil) }
        @objc private func handleSelectAll() { webView?.perform(#selector(NSText.selectAll(_:)), with: nil) }

        @objc private func handleUndo() {
            webView?.evaluateJavaScript("""
                document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {
                    key: 'z', code: 'KeyZ', metaKey: true, shiftKey: false,
                    bubbles: true, cancelable: true
                }))
                """, completionHandler: nil)
        }

        @objc private func handleRedo() {
            webView?.evaluateJavaScript("""
                document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {
                    key: 'z', code: 'KeyZ', metaKey: true, shiftKey: true,
                    bubbles: true, cancelable: true
                }))
                """, completionHandler: nil)
        }

        @objc private func handleFind() {
            webView?.evaluateJavaScript("window.dayflowOpenFind && window.dayflowOpenFind()", completionHandler: nil)
        }

        func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard let body = msg.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                flushIfReady()
                applyFontSizeIfReady()
            case "scrollState":
                let up = (body["canScrollUp"] as? Bool) ?? false
                let down = (body["canScrollDown"] as? Bool) ?? false
                scrollWebView?.canScrollUp = up
                scrollWebView?.canScrollDown = down
            case "change":
                let md = (body["md"] as? String) ?? ""
                let json = body["json"] as? String
                lastEmittedMarkdown = md
                lastEmittedJSON = json ?? ""
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.parent.markdown != md {
                        self.parent.markdown = md
                    }
                    if self.parent.markdownJSON != json {
                        self.parent.markdownJSON = json
                    }
                    self.parent.onChange(md, json)
                }
            default:
                break
            }
        }

        func flushIfReady() {
            guard ready, let md = pendingMarkdown else { return }
            let json = pendingJSON
            pendingMarkdown = nil
            pendingJSON = nil
            lastEmittedMarkdown = md
            lastEmittedJSON = json ?? ""
            // Both args are passed as JS string literals (no raw JSON
            // splicing): a tampered `body_json` row in SQLite would
            // otherwise execute as JS inside the editor origin. The
            // JS side calls `JSON.parse` on the string before using.
            let mdLiteral = Self.jsStringLiteral(md)
            let jsonLiteral = json.map(Self.jsStringLiteral) ?? "null"
            let js = "window.dayflowSetContent(\(mdLiteral), \(jsonLiteral))"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        /// JSON-encode a Swift string into a JS/JSON string literal
        /// (including the surrounding double quotes). Falls back to an
        /// empty-string literal if encoding somehow fails — keeps the
        /// callsite total rather than dropping the whole flush.
        private static func jsStringLiteral(_ s: String) -> String {
            if let data = try? JSONEncoder().encode(s),
               let literal = String(data: data, encoding: .utf8) {
                return literal
            }
            return "\"\""
        }

        /// Push the pending font size into the WebView as a CSS
        /// custom property. Headings scale via `em` so a single
        /// variable controls body + all heading levels.
        func applyFontSizeIfReady() {
            guard ready, let size = pendingFontSize else { return }
            pendingFontSize = nil
            appliedFontSize = size
            let js = "document.documentElement.style.setProperty('--editor-font-size', '\(Int(size))px')"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

}
