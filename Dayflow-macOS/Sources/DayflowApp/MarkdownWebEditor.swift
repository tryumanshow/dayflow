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

        let web = WKWebView(frame: .zero, configuration: config)
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
        web.loadHTMLString(Self.htmlContent, baseURL: URL(string: "https://localhost/"))

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

        @objc private func handleCopy() {
            webView?.evaluateJavaScript("window.getSelection().toString().trim()") { result, _ in
                if let raw = result as? String {
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        }

        @objc private func handleCut() {
            webView?.evaluateJavaScript("window.getSelection().toString().trim()") { [weak self] result, _ in
                if let raw = result as? String {
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        self?.webView?.evaluateJavaScript("document.execCommand('delete')", completionHandler: nil)
                    }
                }
            }
        }

        @objc private func handlePaste() {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            let js = Self.jsStringLiteral(text)
            webView?.evaluateJavaScript("document.execCommand('insertText', false, \(js))", completionHandler: nil)
        }

        @objc private func handleSelectAll() {
            webView?.evaluateJavaScript("document.execCommand('selectAll')", completionHandler: nil)
        }

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

    // MARK: - HTML payload ---------------------------------------------------

    private static let htmlContent: String = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <!--
      Content-Security-Policy — defence-in-depth around the BlockNote editor.
      The editor mounts user markdown; BlockNote parses content structurally
      (no innerHTML) so direct XSS from content is not possible today, but
      CSP makes sure a future BlockNote regression, or a compromised CDN
      response from esm.sh, cannot exfiltrate notes to arbitrary origins.
      esm.sh is still allowed for script/style (pending a proper local
      vendoring pass); every other origin is blocked, including `connect-src`
      which would be the exfiltration channel of choice.
    -->
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self' 'unsafe-inline' https://esm.sh; style-src 'self' 'unsafe-inline' https://esm.sh; img-src 'self' data:; font-src 'self' data:; connect-src 'none'; base-uri 'none'; form-action 'none';">
    <link rel="stylesheet" href="https://esm.sh/@blocknote/core@0.25.0/style.css">
    <style>
    html, body {
        margin: 0;
        padding: 0;
        height: 100%;
        background: transparent;
        color: rgba(255,255,255,0.92);
        font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui;
        -webkit-font-smoothing: antialiased;
    }
    body {
        display: flex;
        flex-direction: column;
    }
    #editor {
        flex: 1 1 auto;
        min-height: 0;
        overflow-y: auto;
        padding: 16px 8px 24px 8px;
    }
    /* Dayflow's own formatting strip. BlockNote's React-side toolbar
       component isn't loaded (we're on @blocknote/core only), so we
       build a minimal vanilla one that calls editor.toggleStyles /
       addStyles / removeStyles directly. */
    /* Toolbar is a column of logical groups that wrap as units, not as
       individual buttons. On wide containers (Day view, ~1200px) all
       groups land on one row; on narrow containers (Month plan rail,
       ~300px) each group drops onto its own line cleanly. */
    #dayflow-toolbar {
        flex: 0 0 auto;
        display: flex;
        align-items: center;
        flex-wrap: wrap;
        row-gap: 6px;
        column-gap: 10px;
        padding: 6px 12px;
        background: rgba(28, 28, 32, 0.7);
        border-bottom: 1px solid rgba(255, 255, 255, 0.06);
        backdrop-filter: blur(12px);
        -webkit-backdrop-filter: blur(12px);
        font-size: 13px;
        user-select: none;
    }
    #dayflow-toolbar .tb-group {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        /* Never break a group across rows. */
        flex: 0 0 auto;
    }
    #dayflow-toolbar .tb-group.colors {
        gap: 6px;
    }
    /* Swatch row is a nested flex so its circles share a 7px gap
       regardless of the parent group's gap. */
    #dayflow-toolbar [data-row] {
        display: inline-flex;
        align-items: center;
        gap: 7px;
    }
    #dayflow-toolbar .label {
        /* Fixed width so the `A` and `▨` labels stack vertically
           with their color swatches lining up perfectly when the
           narrow-width layout wraps each color group onto its own
           row. Without this the glyphs have different widths and
           the swatch rows visually drift. */
        font-size: 11px;
        width: 14px;
        text-align: center;
        color: rgba(255, 255, 255, 0.45);
    }
    /* Narrow containers (Month plan rail ~440px and below): force
       every logical group onto its own row so [B I U S] sits
       alone, and the two color rows stack with their labels
       aligned at the same left margin. Body font is user-
       controlled via Settings → Editor font size, so we no longer
       hard-shrink it here. */
    @media (max-width: 540px) {
        #dayflow-toolbar .tb-group {
            flex-basis: 100%;
        }
    }
    #dayflow-toolbar button {
        all: unset;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        min-width: 24px;
        height: 24px;
        padding: 0 6px;
        border-radius: 4px;
        color: rgba(255, 255, 255, 0.85);
        cursor: pointer;
        font-weight: 600;
    }
    #dayflow-toolbar button:hover {
        background: rgba(255, 255, 255, 0.08);
    }
    #dayflow-toolbar button.active {
        background: rgba(247, 158, 51, 0.22);
        color: #f79e33;
    }
    #dayflow-toolbar button.italic { font-style: italic; }
    #dayflow-toolbar button.underline { text-decoration: underline; }
    #dayflow-toolbar button.strike { text-decoration: line-through; }
    #dayflow-toolbar button.code { font-family: ui-monospace, "SF Mono", monospace; font-size: 11px; letter-spacing: -0.5px; }
    #dayflow-toolbar .swatch {
        width: 18px;
        min-width: 18px;
        height: 18px;
        padding: 0;
        border-radius: 50%;
        border: 1px solid rgba(255, 255, 255, 0.18);
    }
    #dayflow-toolbar .swatch.active {
        outline: 2px solid #f79e33;
        outline-offset: 1px;
    }
    #dayflow-toolbar .swatch-reset {
        background: rgba(255, 255, 255, 0.06);
        color: rgba(255, 255, 255, 0.45);
        font-size: 12px;
        line-height: 16px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
    }

    /* Root CSS variable set by Swift (Settings slider) so the user
       can live-adjust the editor body font. Default matches the
       pre-slider look. Headings are expressed in `em` so a single
       variable drives the whole size ramp. */
    :root {
        --editor-font-size: 15px;
    }
    /* BlockNote dark theme overrides */
    .bn-container, .bn-editor, .ProseMirror {
        background: transparent !important;
        color: rgba(255,255,255,0.92) !important;
        outline: none !important;
        font-size: var(--editor-font-size) !important;
        line-height: 1.7 !important;
    }
    .bn-block-content[data-content-type="heading"][data-level="1"] {
        font-size: 1.85em !important; font-weight: 700 !important; letter-spacing: -0.5px;
    }
    .bn-block-content[data-content-type="heading"][data-level="2"] {
        font-size: 1.45em !important; font-weight: 600 !important;
    }
    .bn-block-content[data-content-type="heading"][data-level="3"] {
        font-size: 1.2em !important; font-weight: 600 !important;
    }
    .bn-inline-content { color: rgba(255,255,255,0.92); }
    .bn-block-outer { padding: 1px 0; }
    .bn-block .bn-block-content { padding-left: 0 !important; }
    .bn-block-content[data-content-type="bulletListItem"]::before,
    .bn-block-content[data-content-type="numberedListItem"]::before {
        color: rgba(255,255,255,0.45) !important;
    }
    /* check list item — block-note renders an actual <input type="checkbox"> */
    .bn-block-content[data-content-type="checkListItem"] input[type="checkbox"] {
        accent-color: #4cc66e !important;
        width: 16px !important;
        height: 16px !important;
    }
    .bn-block-content[data-content-type="checkListItem"][data-checked="true"] .bn-inline-content {
        color: rgba(255,255,255,0.45) !important;
        text-decoration: line-through;
    }
    .bn-block-content:not([data-content-type="codeBlock"]) code,
    .bn-block-content[data-content-type="codeBlock"] {
        font-family: ui-monospace, "SF Mono", monospace;
        font-size: 13px;
    }
    .bn-block-content:not([data-content-type="codeBlock"]) code {
        background: rgba(255,255,255,0.08);
        color: #f79e33;
        border-radius: 4px;
        padding: 1px 5px;
    }
    .bn-block-content[data-content-type="codeBlock"] {
        background: rgba(255,255,255,0.05);
        border-radius: 6px;
        padding: 10px 12px;
        color: rgba(255,255,255,0.85);
        line-height: 1.5;
    }
    .bn-block-content[data-content-type="quote"] {
        border-left: 3px solid rgba(247, 158, 51, 0.6);
        padding-left: 12px;
        color: rgba(255,255,255,0.75);
    }
    /* Table dark theme */
    .bn-block-content[data-content-type="table"] table {
        border-collapse: collapse;
        width: 100%;
    }
    .bn-block-content[data-content-type="table"] td,
    .bn-block-content[data-content-type="table"] th {
        border: 1px solid rgba(255, 255, 255, 0.12);
        padding: 6px 10px;
        min-width: 60px;
    }
    .bn-block-content[data-content-type="table"] th {
        background: rgba(255, 255, 255, 0.06);
        font-weight: 600;
    }
    .bn-block-content[data-content-type="table"] td:focus-within {
        outline: 2px solid rgba(247, 158, 51, 0.5);
        outline-offset: -2px;
    }
    .ProseMirror ::selection { background: rgba(247, 158, 51, 0.32); }
    /* drag-handle side menu + slash-suggestion menu stay hidden to keep
       the layout minimal — the Dayflow toolbar above covers the common
       styling actions. */
    /* drag-handle side menu stays hidden; slash command menu below
       is a fully custom vanilla implementation since
       @blocknote/core on its own doesn't ship a UI for it. */
    .bn-side-menu { display: none !important; }
    /* placeholder */
    .bn-block-content[data-is-empty-and-focused="true"]::before {
        color: rgba(255,255,255,0.25) !important;
    }
    /* Custom slash command menu. Floats above the editor near the
       caret, gets its own filterable input row, dark-themed. */
    #dayflow-slash-menu {
        position: fixed;
        z-index: 1000;
        min-width: 260px;
        max-width: 320px;
        max-height: 360px;
        overflow: hidden;
        background: rgba(28, 28, 32, 0.98);
        border: 1px solid rgba(255, 255, 255, 0.1);
        border-radius: 10px;
        box-shadow: 0 12px 32px rgba(0, 0, 0, 0.45);
        padding: 4px;
        font-size: 13px;
        color: rgba(255, 255, 255, 0.9);
        display: flex;
        flex-direction: column;
    }
    #dayflow-slash-menu .sm-list {
        overflow-y: auto;
        padding: 4px 0;
    }
    #dayflow-slash-menu .sm-item {
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 7px 10px;
        border-radius: 6px;
        cursor: pointer;
    }
    #dayflow-slash-menu .sm-item.selected {
        background: rgba(247, 158, 51, 0.18);
        color: #f79e33;
    }
    #dayflow-slash-menu .sm-item .sm-icon {
        width: 20px;
        text-align: center;
        font-weight: 700;
        color: rgba(255, 255, 255, 0.55);
    }
    #dayflow-slash-menu .sm-item.selected .sm-icon {
        color: #f79e33;
    }
    #dayflow-slash-menu .sm-item .sm-label {
        font-weight: 600;
    }
    #dayflow-slash-menu .sm-item .sm-sub {
        font-size: 11px;
        color: rgba(255, 255, 255, 0.4);
        margin-left: auto;
    }
    #dayflow-slash-menu .sm-empty {
        padding: 10px;
        color: rgba(255, 255, 255, 0.4);
        text-align: center;
        font-size: 12px;
    }
    /* Table grid picker */
    #dayflow-grid-picker {
        position: fixed;
        z-index: 1001;
        background: rgba(28, 28, 32, 0.98);
        border: 1px solid rgba(255, 255, 255, 0.1);
        border-radius: 10px;
        box-shadow: 0 12px 32px rgba(0, 0, 0, 0.45);
        padding: 10px;
        font-size: 12px;
        color: rgba(255, 255, 255, 0.7);
        user-select: none;
    }
    #dayflow-grid-picker .gp-grid {
        display: grid;
        grid-template-columns: repeat(6, 24px);
        grid-template-rows: repeat(6, 24px);
        gap: 3px;
        margin-bottom: 8px;
    }
    #dayflow-grid-picker .gp-cell {
        width: 24px;
        height: 24px;
        border-radius: 3px;
        border: 1px solid rgba(255, 255, 255, 0.12);
        background: transparent;
        cursor: pointer;
        transition: background 0.1s;
    }
    #dayflow-grid-picker .gp-cell.active {
        background: rgba(247, 158, 51, 0.35);
        border-color: rgba(247, 158, 51, 0.6);
    }
    #dayflow-grid-picker .gp-label {
        text-align: center;
        color: rgba(255, 255, 255, 0.5);
        font-weight: 600;
    }
    /* Find bar — overlays the editor, toggled by ⌘F. */
    #dayflow-find-bar {
        position: fixed;
        top: 8px;
        right: 12px;
        z-index: 1002;
        display: none;
        align-items: center;
        gap: 4px;
        background: rgba(28, 28, 32, 0.98);
        border: 1px solid rgba(255, 255, 255, 0.12);
        border-radius: 8px;
        box-shadow: 0 8px 24px rgba(0, 0, 0, 0.4);
        padding: 6px;
        font-size: 13px;
    }
    #dayflow-find-bar.open { display: inline-flex; }
    #dayflow-find-bar input {
        all: unset;
        width: 180px;
        color: rgba(255, 255, 255, 0.92);
        padding: 4px 8px;
        border-radius: 5px;
        background: rgba(255, 255, 255, 0.06);
        transition: background 0.15s;
    }
    #dayflow-find-bar input::placeholder { color: rgba(255, 255, 255, 0.35); }
    #dayflow-find-bar input.miss { background: rgba(239, 68, 68, 0.25); }
    #dayflow-find-bar button {
        all: unset;
        min-width: 24px;
        height: 24px;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        border-radius: 4px;
        color: rgba(255, 255, 255, 0.8);
        cursor: pointer;
        font-size: 12px;
    }
    #dayflow-find-bar button:hover { background: rgba(255, 255, 255, 0.1); }
    /* CSS Custom Highlights — match decoration without any DOM or
       selection mutation. WebKit 17.2+ (macOS 14.2+) required; on
       older systems highlights silently no-op but find still
       navigates. */
    ::highlight(dayflow-find) {
        background-color: rgba(247, 158, 51, 0.32);
        color: inherit;
    }
    ::highlight(dayflow-find-current) {
        background-color: rgba(247, 158, 51, 0.85);
        color: #000;
    }
    /* Paragraphs whose text is exactly a markdown HR sequence get
       rendered as a divider. `dayflow-hr-marker` lands on the widest
       block-level ancestor (not the narrow `.bn-block-content` which
       is inline-block) so the line spans the row. Caret stays
       visible via `caret-color` so the block is still editable. */
    .dayflow-hr-marker {
        position: relative;
    }
    .dayflow-hr-marker .bn-inline-content,
    .dayflow-hr-marker [data-content-type="paragraph"] {
        color: transparent;
        caret-color: rgba(247, 158, 51, 0.9);
    }
    .dayflow-hr-marker::after {
        content: '';
        position: absolute;
        left: 0;
        right: 0;
        top: 50%;
        height: 1px;
        background: rgba(255, 255, 255, 0.25);
        transform: translateY(-50%);
        pointer-events: none;
    }
    </style>
    </head>
    <body>
    <div id="dayflow-toolbar">
      <div class="tb-group">
        <button data-cmd="bold" title="Bold (⌘B)">B</button>
        <button data-cmd="italic" class="italic" title="Italic (⌘I)">I</button>
        <button data-cmd="underline" class="underline" title="Underline (⌘U)">U</button>
        <button data-cmd="strike" class="strike" title="Strikethrough">S</button>
        <button data-cmd="code" class="code" title="Inline Code">{ }</button>
      </div>
      <div class="tb-group colors">
        <span class="label">A</span>
        <span data-row="textColor"></span>
      </div>
      <div class="tb-group colors">
        <span class="label">▨</span>
        <span data-row="backgroundColor"></span>
      </div>
    </div>
    <div id="dayflow-find-bar" role="search" aria-label="Find in page">
      <input type="text" placeholder="Find" spellcheck="false" autocomplete="off" autocapitalize="off">
      <button data-find="prev" title="Previous (⇧↵)">↑</button>
      <button data-find="next" title="Next (↵)">↓</button>
      <button data-find="close" title="Close (Esc)">✕</button>
    </div>
    <div id="editor"></div>
    <script type="module">
    import { BlockNoteEditor } from "https://esm.sh/@blocknote/core@0.22.0";

    let editor = null;
    let lastEmitted = "";
    let suppressEmit = false;

    let lastEmittedJSON = "";

    function postReady() {
        try { window.webkit.messageHandlers.dayflow.postMessage({ type: "ready" }); } catch (e) {}
    }
    function postChange(md, json) {
        if (suppressEmit) return;
        if (md === lastEmitted && json === lastEmittedJSON) return;
        lastEmitted = md;
        lastEmittedJSON = json;
        try { window.webkit.messageHandlers.dayflow.postMessage({ type: "change", md: md, json: json }); } catch (e) {}
    }

    // Line-based markdown parser. BlockNote 0.15.11's tryParseMarkdownToBlocks
    // chokes on GFM task lists (`- [ ] foo` becomes [empty checkListItem, "foo"
    // paragraph]), so we parse ourselves. Indentation (2-space unit) turns into
    // BlockNote block children, which is exactly how cross-list-type nesting
    // works in BlockNote — a bulletListItem can have checkListItem children and
    // vice versa, all within the same `blockContainer` tree.
    function makeCodeBlock(lines) {
        return {
            type: 'codeBlock',
            props: {},
            content: [{ type: 'text', text: lines.join('\\n'), styles: {} }],
            children: [],
        };
    }

    function mdToBlocks(md) {
        const lines = (md || '').replace(/\\r\\n?/g, '\\n').split('\\n');
        const root = { children: [] };
        const stack = [{ indent: -1, block: root }];
        let inCodeBlock = false;
        let codeLines = [];
        for (const raw of lines) {
            // Skip HTML comments — no block representation in BlockNote.
            if (!inCodeBlock && /^\\s*<!--.*-->\\s*$/.test(raw)) continue;
            // Fenced code block handling (```...```)
            if (raw.trim().startsWith('```')) {
                if (!inCodeBlock) {
                    inCodeBlock = true;
                    codeLines = [];
                    continue;
                } else {
                    inCodeBlock = false;
                    const block = makeCodeBlock(codeLines);
                    while (stack.length > 1) stack.pop();
                    stack[stack.length - 1].block.children.push(block);
                    continue;
                }
            }
            if (inCodeBlock) {
                codeLines.push(raw);
                continue;
            }
            if (!raw.trim()) continue;
            const leading = raw.match(/^(\\s*)/)[0].length;
            const indent = Math.floor(leading / 2);
            const text = raw.slice(leading);
            let block;
            let m;
            if ((m = text.match(/^(#{1,3})\\s+(.*)$/))) {
                block = {
                    type: 'heading',
                    props: { level: m[1].length },
                    content: [{ type: 'text', text: m[2], styles: {} }],
                    children: [],
                };
            } else if ((m = text.match(/^[-*]\\s+\\[([ xX])\\]\\s+(.*)$/))) {
                block = {
                    type: 'checkListItem',
                    props: { checked: m[1].toLowerCase() === 'x' },
                    content: [{ type: 'text', text: m[2], styles: {} }],
                    children: [],
                };
            } else if ((m = text.match(/^[-*]\\s+(.*)$/))) {
                block = {
                    type: 'bulletListItem',
                    props: {},
                    content: [{ type: 'text', text: m[1], styles: {} }],
                    children: [],
                };
            } else if ((m = text.match(/^\\d+\\.\\s+(.*)$/))) {
                block = {
                    type: 'numberedListItem',
                    props: {},
                    content: [{ type: 'text', text: m[1], styles: {} }],
                    children: [],
                };
            } else {
                block = {
                    type: 'paragraph',
                    props: {},
                    content: [{ type: 'text', text: text, styles: {} }],
                    children: [],
                };
            }
            while (stack.length > 1 && stack[stack.length - 1].indent >= indent) {
                stack.pop();
            }
            stack[stack.length - 1].block.children.push(block);
            stack.push({ indent, block });
        }
        // Flush unclosed fenced code block at EOF
        if (inCodeBlock && codeLines.length > 0) {
            root.children.push(makeCodeBlock(codeLines));
        }
        return root.children;
    }

    // `jsonText` arrives as a JSON string (Swift passes a quoted
    // literal, not raw JS), or `null` for markdown-only rows. We
    // `JSON.parse` here so a tampered `body_json` in the DB can't
    // be interpreted as JS inside the editor origin — the parse
    // enforces a data-only boundary.
    window.dayflowSetContent = async function(md, jsonText) {
        if (!editor) return;
        try {
            suppressEmit = true;
            let blocks = null;
            if (typeof jsonText === 'string' && jsonText.length > 0) {
                try {
                    const parsed = JSON.parse(jsonText);
                    if (Array.isArray(parsed) && parsed.length > 0) {
                        blocks = parsed;
                    }
                } catch (e) {
                    console.log('setContent JSON parse error: ' + e.message);
                }
            }
            if (!blocks) {
                blocks = mdToBlocks(md || '');
            }
            // Replace blocks that are just HTML comments (e.g. "<!---->")
            // with empty paragraphs to preserve visual spacing.
            blocks = blocks.map(b => {
                if (b.type !== 'paragraph' || !b.content) return b;
                const text = (Array.isArray(b.content) ? b.content : [])
                    .map(c => (typeof c === 'string' ? c : c.text || '')).join('').trim();
                if (/^<!--.*-->$/.test(text)) {
                    return { type: 'paragraph', props: b.props || {}, content: [], children: [] };
                }
                return b;
            });
            if (blocks.length === 0) {
                blocks.push({ type: 'paragraph', props: {}, content: [], children: [] });
            }
            editor.replaceBlocks(editor.document, blocks);
            lastEmitted = md;
            lastEmittedJSON = typeof jsonText === 'string' ? jsonText : "";
            applyHrStyling();
        } catch (e) {
            console.log('setContent error: ' + e.message + ' :: ' + (e.stack || ''));
        } finally {
            // Swallow the post-replace synchronous onChange.
            setTimeout(() => { suppressEmit = false; }, 50);
        }
    };

    async function emitCurrentContent() {
        if (!editor) return;
        try {
            let md = await editor.blocksToMarkdownLossy(editor.document);
            let json = JSON.stringify(editor.document);
            // Strip ZWSPs injected by the nested-list IME workaround
            // only when present — avoid an allocation on every emit.
            const ZWSP = '\\u200B';
            if (md && md.indexOf(ZWSP) !== -1) md = md.split(ZWSP).join('');
            if (json.indexOf(ZWSP) !== -1) json = json.split(ZWSP).join('');
            postChange(md, json);
        } catch (e) {}
    }

    // 200ms trailing debounce so typing doesn't thrash the bridge.
    let emitTimer = null;
    function scheduleEmit() {
        if (emitTimer) clearTimeout(emitTimer);
        emitTimer = setTimeout(() => { emitTimer = null; emitCurrentContent(); }, 200);
    }

    // BlockNote default-schema color palette. Names are the public
    // `textColor`/`backgroundColor` values accepted by addStyles; the
    // hex is the swatch background.
    const COLORS = [
        ['red',    '#ef4444'],
        ['orange', '#f59e0b'],
        ['yellow', '#eab308'],
        ['green',  '#22c55e'],
        ['blue',   '#3b82f6'],
        ['purple', '#a855f7'],
    ];

    // Cached NodeLists populated by buildSwatches — refreshToolbarState
    // is called on every selection change, so querySelectorAll per call
    // would burn DOM work.
    let cmdButtons = [];
    let colorButtons = { textColor: [], backgroundColor: [] };
    let lastActiveSig = "";

    function buildSwatches() {
        const bar = document.getElementById('dayflow-toolbar');
        if (!bar) return;
        for (const prop of ['textColor', 'backgroundColor']) {
            const row = bar.querySelector('[data-row="' + prop + '"]');
            if (!row) continue;
            // "Reset to default" button at the front
            const reset = document.createElement('button');
            reset.className = 'swatch swatch-reset';
            reset.dataset.prop = prop;
            reset.dataset.color = 'default';
            reset.title = 'Default';
            reset.textContent = '×';
            row.appendChild(reset);
            for (const [name, hex] of COLORS) {
                const b = document.createElement('button');
                b.className = 'swatch';
                b.dataset.prop = prop;
                b.dataset.color = name;
                b.style.background = hex;
                b.title = name;
                row.appendChild(b);
            }
            colorButtons[prop] = Array.from(row.querySelectorAll('button'));
        }
        cmdButtons = Array.from(bar.querySelectorAll('button[data-cmd]'));
    }

    // mousedown + preventDefault keeps the editor's text selection
    // intact — plain click would steal focus and collapse the selection
    // before the style call lands.
    function bindToolbar() {
        const bar = document.getElementById('dayflow-toolbar');
        if (!bar) return;
        bar.addEventListener('mousedown', (e) => {
            const btn = e.target.closest('button');
            if (!btn) return;
            e.preventDefault();
            if (!editor) return;
            try {
                const cmd = btn.dataset.cmd;
                if (cmd) {
                    editor.toggleStyles({ [cmd]: true });
                } else if (btn.dataset.prop) {
                    const prop = btn.dataset.prop;
                    const color = btn.dataset.color;
                    const active = editor.getActiveStyles() || {};
                    if (color === 'default') {
                        if (active[prop] != null && active[prop] !== '') {
                            editor.removeStyles({ [prop]: active[prop] });
                        }
                    } else if (active[prop] === color) {
                        editor.removeStyles({ [prop]: color });
                    } else {
                        editor.addStyles({ [prop]: color });
                    }
                }
            } catch (err) {
                console.log('toolbar cmd error: ' + err.message);
            }
            refreshToolbarState();
            scheduleEmit();
        });
    }

    function refreshToolbarState() {
        if (!editor) return;
        let active = {};
        try { active = editor.getActiveStyles() || {}; } catch (e) {}
        // Dirty-check: selection changes fire on every caret move, but
        // the active-style signature usually hasn't changed.
        const sig = (active.bold?1:0) + '|' + (active.italic?1:0) + '|' +
                    (active.underline?1:0) + '|' + (active.strike?1:0) + '|' +
                    (active.code?1:0) + '|' +
                    (active.textColor || 'default') + '|' +
                    (active.backgroundColor || 'default');
        if (sig === lastActiveSig) return;
        lastActiveSig = sig;
        for (const b of cmdButtons) {
            b.classList.toggle('active', !!active[b.dataset.cmd]);
        }
        // Color swatches: highlight ONLY a non-default color that's
        // actually applied to the selection. The "×" (default) button
        // never wears the active ring — a blank selection is the normal
        // state and shouldn't look selected.
        for (const prop of ['textColor', 'backgroundColor']) {
            const current = active[prop];
            for (const b of colorButtons[prop]) {
                const val = b.dataset.color;
                const isActive = (val !== 'default') && (val === current);
                b.classList.toggle('active', isActive);
            }
        }
    }

    // Slash command menu — custom vanilla implementation since
    // @blocknote/core on its own doesn't ship a slash menu UI (that
    // piece lives in @blocknote/react). labelLower is precomputed so
    // filter keystrokes don't re-lowercase 7 strings per render.
    const SLASH_COMMANDS = (() => {
        const defs = [
            { key: 'h1',   icon: 'H1', label: 'Heading 1',     block: { type: 'heading', props: { level: 1 } } },
            { key: 'h2',   icon: 'H2', label: 'Heading 2',     block: { type: 'heading', props: { level: 2 } } },
            { key: 'h3',   icon: 'H3', label: 'Heading 3',     block: { type: 'heading', props: { level: 3 } } },
            { key: 'todo', icon: '☐',  label: 'To-do list',    block: { type: 'checkListItem', props: { checked: false } } },
            { key: 'ul',   icon: '•',  label: 'Bullet list',   block: { type: 'bulletListItem' } },
            { key: 'ol',   icon: '1.', label: 'Numbered list', block: { type: 'numberedListItem' } },
            { key: 'code', icon: '{ }', label: 'Code Block',   block: { type: 'codeBlock' } },
            { key: 'table', icon: '▦', label: 'Table',         block: { type: 'table' } },
            { key: 'p',    icon: '¶',  label: 'Paragraph',     block: { type: 'paragraph' } },
        ];
        return defs.map(d => ({ ...d, labelLower: d.label.toLowerCase() }));
    })();

    // Menu singleton. Items are built once in `openSlashMenu` and
    // reused; filter keystrokes toggle `.style.display` on the
    // cached nodes instead of rebuilding innerHTML.
    let slashMenuEl = null;
    let slashItemNodes = [];        // [{ el, cmd }] — one per SLASH_COMMANDS entry
    let slashVisibleItems = [];     // subset currently shown, in display order
    let slashQuery = '';
    let slashSelectedIndex = 0;

    function applyBlockType(block) {
        if (!editor) return;
        try {
            const cursor = editor.getTextCursorPosition();
            if (!cursor || !cursor.block) return;
            if (block.type === 'table') {
                insertTable(3, 3);
                return;
            }
            editor.updateBlock(cursor.block, block);
            scheduleEmit();
        } catch (e) {
            console.log('applyBlockType error: ' + e.message);
        }
    }

    function isCurrentBlockEmpty() {
        if (!editor) return false;
        try {
            const cursor = editor.getTextCursorPosition();
            if (!cursor || !cursor.block) return false;
            const content = cursor.block.content;
            if (!Array.isArray(content)) return true;
            for (const c of content) {
                if (c && typeof c.text === 'string' && c.text.length > 0) return false;
            }
            return true;
        } catch (e) { return false; }
    }

    function openSlashMenu() {
        if (slashMenuEl) return;
        slashMenuEl = document.createElement('div');
        slashMenuEl.id = 'dayflow-slash-menu';
        const list = document.createElement('div');
        list.className = 'sm-list';
        slashMenuEl.appendChild(list);
        slashItemNodes = [];
        for (const cmd of SLASH_COMMANDS) {
            const el = document.createElement('div');
            el.className = 'sm-item';
            el.innerHTML =
                '<span class="sm-icon">' + cmd.icon + '</span>' +
                '<span class="sm-label">' + cmd.label + '</span>' +
                '<span class="sm-sub">/' + cmd.key + '</span>';
            el.addEventListener('mousedown', (ev) => {
                ev.preventDefault();
                commitSlashCommand(cmd);
            });
            list.appendChild(el);
            slashItemNodes.push({ el, cmd });
        }
        document.body.appendChild(slashMenuEl);
        slashQuery = '';
        slashSelectedIndex = 0;
        positionSlashMenu();
        renderSlashMenu();
    }

    function closeSlashMenu() {
        if (!slashMenuEl) return;
        slashMenuEl.remove();
        slashMenuEl = null;
        slashItemNodes = [];
        slashVisibleItems = [];
        slashQuery = '';
        slashSelectedIndex = 0;
    }

    // Shared popup positioning: place `el` below the caret,
    // clamped so it doesn't overflow the viewport.
    function positionPopup(el, vMargin, hMargin) {
        const sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) return;
        let rect = sel.getRangeAt(0).getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) {
            const fb = document.querySelector('.bn-block-content[data-is-empty-and-focused="true"]');
            if (fb) rect = fb.getBoundingClientRect();
        }
        el.style.top = Math.min(window.innerHeight - vMargin, rect.bottom + 6) + 'px';
        el.style.left = Math.min(window.innerWidth - hMargin, Math.max(8, rect.left)) + 'px';
    }

    function positionSlashMenu() {
        if (!slashMenuEl) return;
        positionPopup(slashMenuEl, 380, 340);
    }

    function renderSlashMenu() {
        if (!slashMenuEl) return;
        const q = slashQuery.trim().toLowerCase();
        slashVisibleItems = [];
        for (const item of slashItemNodes) {
            const match = !q || item.cmd.labelLower.includes(q) || item.cmd.key.includes(q);
            item.el.style.display = match ? 'flex' : 'none';
            if (match) slashVisibleItems.push(item);
        }
        if (slashSelectedIndex >= slashVisibleItems.length) {
            slashSelectedIndex = Math.max(0, slashVisibleItems.length - 1);
        }
        for (let i = 0; i < slashVisibleItems.length; i++) {
            slashVisibleItems[i].el.classList.toggle('selected', i === slashSelectedIndex);
        }
        // Empty-state row — created lazily, reused across filters.
        let empty = slashMenuEl.querySelector('.sm-empty');
        if (slashVisibleItems.length === 0) {
            if (!empty) {
                empty = document.createElement('div');
                empty.className = 'sm-empty';
                empty.textContent = 'No commands';
                slashMenuEl.querySelector('.sm-list').appendChild(empty);
            }
        } else if (empty) {
            empty.remove();
        }
    }

    function commitSlashCommand(cmd) {
        if (!cmd) return;
        closeSlashMenu();
        if (cmd.block.type === 'table') {
            openGridPicker();
        } else {
            applyBlockType(cmd.block);
        }
    }

    // Grid picker for table size selection (6×6 max)
    let gridPickerEl = null;

    function openGridPicker() {
        if (gridPickerEl) return;
        gridPickerEl = document.createElement('div');
        gridPickerEl.id = 'dayflow-grid-picker';

        const grid = document.createElement('div');
        grid.className = 'gp-grid';

        const MAX = 6;
        const cells = [];
        for (let r = 0; r < MAX; r++) {
            for (let c = 0; c < MAX; c++) {
                const cell = document.createElement('div');
                cell.className = 'gp-cell';
                cell._r = r;
                cell._c = c;
                grid.appendChild(cell);
                cells.push(cell);
            }
        }

        const label = document.createElement('div');
        label.className = 'gp-label';
        label.textContent = 'Select size';

        gridPickerEl.appendChild(grid);
        gridPickerEl.appendChild(label);
        document.body.appendChild(gridPickerEl);
        positionPopup(gridPickerEl, 250, 200);

        grid.addEventListener('mouseover', (ev) => {
            const cell = ev.target.closest('.gp-cell');
            if (!cell) return;
            const hr = cell._r;
            const hc = cell._c;
            for (const c of cells) {
                c.classList.toggle('active', c._r <= hr && c._c <= hc);
            }
            label.textContent = (hc + 1) + ' × ' + (hr + 1);
        });

        grid.addEventListener('mousedown', (ev) => {
            ev.preventDefault();
            const cell = ev.target.closest('.gp-cell');
            if (!cell) return;
            const rows = cell._r + 1;
            const cols = cell._c + 1;
            closeGridPicker();
            insertTable(rows, cols);
        });
    }

    function closeGridPicker() {
        if (!gridPickerEl) return;
        gridPickerEl.remove();
        gridPickerEl = null;
    }

    function insertTable(numRows, numCols) {
        if (!editor) return;
        try {
            const cursor = editor.getTextCursorPosition();
            if (!cursor || !cursor.block) return;
            const makeRow = () => {
                const cells = [];
                for (let i = 0; i < numCols; i++) {
                    cells.push([{ type: 'text', text: '', styles: {} }]);
                }
                return { cells };
            };
            const rows = [];
            for (let i = 0; i < numRows; i++) {
                rows.push(makeRow());
            }
            const tableBlock = {
                type: 'table',
                content: { type: 'tableContent', rows },
                children: [],
            };
            editor.insertBlocks([tableBlock], cursor.block, 'after');
            if (isCurrentBlockEmpty()) {
                editor.removeBlocks([cursor.block]);
            }
            scheduleEmit();
        } catch (e) {
            console.log('insertTable error: ' + e.message);
        }
    }

    // Find bar — opened by ⌘F. We deliberately avoid `window.find()`:
    // it moves the document selection into the editor's contenteditable,
    // stealing focus from the find input so subsequent keystrokes type
    // into the editor instead. Instead we TreeWalk text nodes for
    // matches and decorate them via the CSS Custom Highlights API —
    // no DOM and no selection mutation, so the input keeps focus.
    const findBarEl = document.getElementById('dayflow-find-bar');
    const findInputEl = findBarEl.querySelector('input');
    const editorRootEl = document.getElementById('editor');
    let findMatches = [];
    let findCurrentIndex = -1;
    const findHighlightsSupported = !!(window.CSS && CSS.highlights && typeof Highlight !== 'undefined');

    function markFindMiss(miss) {
        findInputEl.classList.toggle('miss', !!miss);
    }

    // Render both the all-matches highlight and the current-match
    // highlight. `CSS.highlights.set` replaces existing entries, so
    // we only explicitly delete when transitioning to empty.
    function renderFindHighlights() {
        if (!findHighlightsSupported) return;
        try {
            if (findMatches.length === 0) {
                CSS.highlights.delete('dayflow-find');
                CSS.highlights.delete('dayflow-find-current');
                return;
            }
            CSS.highlights.set('dayflow-find', new Highlight(...findMatches));
            if (findCurrentIndex >= 0) {
                CSS.highlights.set('dayflow-find-current', new Highlight(findMatches[findCurrentIndex]));
            } else {
                CSS.highlights.delete('dayflow-find-current');
            }
        } catch (e) { console.log('find highlight error: ' + e.message); }
    }

    // Lightweight update when only the current match moved —
    // skips re-allocating the full-matches Highlight (potentially
    // thousands of ranges) on every ↑/↓.
    function updateCurrentHighlight() {
        if (!findHighlightsSupported) return;
        try {
            if (findCurrentIndex < 0 || findCurrentIndex >= findMatches.length) {
                CSS.highlights.delete('dayflow-find-current');
                return;
            }
            CSS.highlights.set('dayflow-find-current', new Highlight(findMatches[findCurrentIndex]));
        } catch (e) { console.log('find highlight error: ' + e.message); }
    }

    function computeFindMatches(query) {
        const matches = [];
        if (!query || !editorRootEl) return matches;
        const walker = document.createTreeWalker(editorRootEl, NodeFilter.SHOW_TEXT, null);
        const qLower = query.toLowerCase();
        const qLen = query.length;
        let node;
        while ((node = walker.nextNode())) {
            const text = node.nodeValue;
            if (!text) continue;
            const tLower = text.toLowerCase();
            let idx = 0;
            while (true) {
                const found = tLower.indexOf(qLower, idx);
                if (found === -1) break;
                const range = document.createRange();
                range.setStart(node, found);
                range.setEnd(node, found + qLen);
                matches.push(range);
                idx = found + qLen;
            }
        }
        return matches;
    }

    function scrollCurrentMatchIntoView(smooth) {
        if (findCurrentIndex < 0 || findCurrentIndex >= findMatches.length) return;
        if (!editorRootEl) return;
        const rect = findMatches[findCurrentIndex].getBoundingClientRect();
        const cRect = editorRootEl.getBoundingClientRect();
        if (rect.top < cRect.top + 20 || rect.bottom > cRect.bottom - 20) {
            const offset = rect.top - cRect.top - (cRect.height / 3);
            editorRootEl.scrollBy({ top: offset, behavior: smooth ? 'smooth' : 'instant' });
        }
    }

    function runFindSearch() {
        const q = findInputEl.value;
        findMatches = computeFindMatches(q);
        if (!q) {
            findCurrentIndex = -1;
            markFindMiss(false);
            renderFindHighlights();
            return;
        }
        if (findMatches.length === 0) {
            findCurrentIndex = -1;
            markFindMiss(true);
            renderFindHighlights();
            return;
        }
        markFindMiss(false);
        findCurrentIndex = 0;
        renderFindHighlights();
        scrollCurrentMatchIntoView(false);
    }

    // Trailing-debounce the TreeWalker search so rapid typing (especially
    // Korean IME, which fires `input` per jamo) doesn't re-walk the whole
    // editor on every keystroke.
    let findSearchTimer = null;
    function scheduleFindSearch() {
        if (findSearchTimer) clearTimeout(findSearchTimer);
        findSearchTimer = setTimeout(() => { findSearchTimer = null; runFindSearch(); }, 120);
    }

    function navigateFind(backward) {
        if (findMatches.length === 0) return;
        findCurrentIndex = backward
            ? (findCurrentIndex - 1 + findMatches.length) % findMatches.length
            : (findCurrentIndex + 1) % findMatches.length;
        updateCurrentHighlight();
        scrollCurrentMatchIntoView(true);
    }

    window.dayflowOpenFind = function() {
        findBarEl.classList.add('open');
        findInputEl.focus();
        findInputEl.select();
        // Editor content may have changed since last open; re-run so
        // stale ranges don't point into replaced text nodes.
        if (findInputEl.value) runFindSearch();
    };

    function closeFindBar() {
        findBarEl.classList.remove('open');
        markFindMiss(false);
        findMatches = [];
        findCurrentIndex = -1;
        renderFindHighlights();
    }

    findInputEl.addEventListener('input', scheduleFindSearch);

    findInputEl.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            e.preventDefault();
            e.stopPropagation();
            closeFindBar();
        } else if (e.key === 'Enter') {
            e.preventDefault();
            e.stopPropagation();
            navigateFind(e.shiftKey);
        }
    });

    findBarEl.addEventListener('mousedown', (e) => {
        const btn = e.target.closest('button');
        if (!btn) return;
        e.preventDefault();
        const action = btn.dataset.find;
        if (action === 'close') { closeFindBar(); return; }
        findInputEl.focus();
        if (action === 'next') navigateFind(false);
        else if (action === 'prev') navigateFind(true);
    });

    // Capture-phase keydown so we intercept `/`, arrows, Enter, etc.
    // before ProseMirror sees them.
    document.addEventListener('keydown', (e) => {
        // When focus is in the find input, let its own handlers run
        // and skip all editor-level shortcuts (slash menu, table
        // backspace). Without this, typing `/` in the find field
        // would false-trigger the slash menu.
        if (document.activeElement === findInputEl) return;

        // IME composition guard — Korean/Japanese/Chinese input
        // pre-commit keys fire with `key: "Process"` / isComposing
        // true and keyCode 229. Ignore so ProseMirror handles the
        // composition cleanly.
        if (e.isComposing || e.keyCode === 229) {
            // Enter pressed mid-composition hits a ProseMirror/BlockNote
            // 0.18 bug: the in-flight IME character gets committed AND
            // duplicated onto the new line. Swallow the raw Enter so
            // the IME only commits; the user presses Enter again (after
            // composition ends) to get the newline. This matches macOS
            // native text-field semantics.
            if (e.key === 'Enter') {
                e.preventDefault();
                e.stopPropagation();
            }
            return;
        }

        // Grid picker intercepts Escape
        if (gridPickerEl) {
            if (e.key === 'Escape') { e.preventDefault(); closeGridPicker(); }
            return;
        }

        if (!slashMenuEl) {
            if (e.key === '/' && !e.metaKey && !e.ctrlKey && !e.altKey && isCurrentBlockEmpty()) {
                e.preventDefault();
                openSlashMenu();
            }
            // Backspace inside a table when current cell is empty →
            // delete the entire table block. If the cell has content,
            // let ProseMirror handle normal text deletion.
            if (e.key === 'Backspace' && !e.metaKey && !e.ctrlKey && editor) {
                try {
                    const cursor = editor.getTextCursorPosition();
                    if (!cursor || !cursor.block) throw 0;
                    let tableBlock = null;
                    if (cursor.block.type === 'table') {
                        tableBlock = cursor.block;
                    } else if (cursor.parentBlock && cursor.parentBlock.type === 'table') {
                        tableBlock = cursor.parentBlock;
                    }
                    if (!tableBlock) throw 0;
                    // Only delete if the current cell is empty
                    if (isCurrentBlockEmpty()) {
                        e.preventDefault();
                        editor.removeBlocks([tableBlock]);
                        scheduleEmit();
                    }
                } catch (err) {}
            }
            return;
        }
        if (e.key === 'Escape') {
            e.preventDefault();
            closeSlashMenu();
        } else if (e.key === 'ArrowDown') {
            e.preventDefault();
            slashSelectedIndex = Math.min(slashVisibleItems.length - 1, slashSelectedIndex + 1);
            renderSlashMenu();
        } else if (e.key === 'ArrowUp') {
            e.preventDefault();
            slashSelectedIndex = Math.max(0, slashSelectedIndex - 1);
            renderSlashMenu();
        } else if (e.key === 'Enter') {
            e.preventDefault();
            const picked = slashVisibleItems[slashSelectedIndex];
            if (picked) commitSlashCommand(picked.cmd);
        } else if (e.key === 'Backspace') {
            e.preventDefault();
            if (slashQuery.length === 0) {
                closeSlashMenu();
            } else {
                // Surrogate-safe: slice by grapheme-ish (Array.from
                // splits by code point) so supplementary chars
                // aren't cut mid-pair.
                const chars = Array.from(slashQuery);
                chars.pop();
                slashQuery = chars.join('');
                slashSelectedIndex = 0;
                renderSlashMenu();
            }
        } else if (e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) {
            e.preventDefault();
            slashQuery += e.key;
            slashSelectedIndex = 0;
            renderSlashMenu();
        }
    }, true);

    document.addEventListener('mousedown', (e) => {
        if (gridPickerEl && !gridPickerEl.contains(e.target)) {
            closeGridPicker();
        }
        if (!slashMenuEl) return;
        if (slashMenuEl.contains(e.target)) return;
        closeSlashMenu();
    }, true);

    // Horizontal rule — paragraphs whose trimmed text matches a
    // markdown HR sequence get a marker class that CSS renders as
    // a divider. The marker lands on the widest block-level
    // ancestor (not the narrow inline-block `.bn-block-content`)
    // so the line spans the full row; we walk up until we hit the
    // ProseMirror/editor boundary rather than trusting a specific
    // BlockNote wrapper class, because those have renamed across
    // versions.
    const HR_TEXT_RE = /^(?:-{3,}|\\*{3,}|_{3,})$/;
    const HR_CLASS = 'dayflow-hr-marker';

    function findHrWrapper(p, root) {
        let best = p;
        let bestWidth = p.offsetWidth;
        for (let cur = p; cur; cur = cur.parentElement) {
            const parent = cur.parentElement;
            if (!parent || parent === root) break;
            if (parent.classList.contains('ProseMirror')) break;
            if (parent.classList.contains('bn-editor')) break;
            if (parent.offsetWidth > bestWidth) { best = parent; bestWidth = parent.offsetWidth; }
        }
        return best;
    }

    function applyHrStyling() {
        if (!editorRootEl) return;
        for (const p of editorRootEl.querySelectorAll('[data-content-type="paragraph"]')) {
            const t = (p.textContent || '').replace(/\\u200B/g, '').trim();
            const isHr = HR_TEXT_RE.test(t);
            // Clear any stale marker that may have been set on an
            // ancestor when this paragraph was previously an HR.
            for (let cur = p; cur && cur !== editorRootEl; cur = cur.parentElement) {
                cur.classList.remove(HR_CLASS);
            }
            if (isHr) findHrWrapper(p, editorRootEl).classList.add(HR_CLASS);
        }
    }

    // Primary trigger is the MutationObserver (fires synchronously
    // with ProseMirror's DOM writes; onEditorContentChange is async
    // and can lag the visible state). rAF-coalesced to absorb bursts.
    let hrObserver = null;
    let hrRafPending = false;
    function scheduleHrStyling() {
        if (hrRafPending) return;
        hrRafPending = true;
        requestAnimationFrame(() => {
            hrRafPending = false;
            // Cheap dirty-check: if no HR sequence appears anywhere in
            // the editor, skip the per-paragraph walk entirely.
            if (!editorRootEl) return;
            const t = editorRootEl.textContent || '';
            if (t.indexOf('---') === -1 && t.indexOf('***') === -1 && t.indexOf('___') === -1) {
                // Still clear any leftover markers from a prior HR state.
                const stale = editorRootEl.querySelectorAll('.' + HR_CLASS);
                for (const s of stale) s.classList.remove(HR_CLASS);
                return;
            }
            applyHrStyling();
        });
    }
    function installHrObserver() {
        if (!editorRootEl || hrObserver) return;
        hrObserver = new MutationObserver(scheduleHrStyling);
        hrObserver.observe(editorRootEl, { childList: true, subtree: true, characterData: true });
    }

    // Nested-list Korean IME workaround. ProseMirror has a known bug
    // where composing IME text into an empty nested list item (depth ≥ 2)
    // causes the committed syllable to be duplicated onto a new
    // sibling block. Inserting a zero-width space at compositionstart
    // gives PM a pre-existing text node to write into, avoiding the
    // split path. The ZWSP is stripped from exported markdown/JSON.
    // See: ProseMirror discuss thread on composition regressions +
    // obsidian-day-planner#759 (same repro in another PM-based editor).
    function installNestedImeWorkaround() {
        if (!editorRootEl || !editor) return;
        editorRootEl.addEventListener('compositionstart', () => {
            try {
                // NOTE: `_tiptapEditor` is BlockNote-internal (underscore
                // prefix) and can churn across @blocknote/core bumps.
                // Re-verify on every upgrade.
                const tt = editor._tiptapEditor;
                if (!tt) return;
                const { $from } = tt.state.selection;
                // depth ≥ 2 = inside at least one list-item parent;
                // content.size === 0 = current block is empty (composition
                // is about to write its first character).
                if ($from.depth >= 2 && $from.parent.content.size === 0) {
                    tt.commands.insertContent('\\u200B');
                }
            } catch (e) { console.log('nested-IME workaround error: ' + e.message); }
        }, true);
    }

    (async () => {
        try {
            editor = BlockNoteEditor.create({
                domAttributes: { editor: { class: 'bn-editor' } },
                initialContent: undefined,
            });
            editor.mount(document.getElementById('editor'));
            installHrObserver();
            installNestedImeWorkaround();
            editor.onEditorContentChange(() => { scheduleHrStyling(); scheduleEmit(); });
            if (editor.onEditorSelectionChange) {
                editor.onEditorSelectionChange(refreshToolbarState);
            }
            buildSwatches();
            bindToolbar();
            refreshToolbarState();
            postReady();
        } catch (e) {
            console.error('BlockNote init error: ' + e.message + ' :: ' + (e.stack || ''));
        }
    })();
    </script>
    </body>
    </html>
    """
}
