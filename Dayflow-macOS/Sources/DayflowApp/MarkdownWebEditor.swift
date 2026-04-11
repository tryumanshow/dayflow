import AppKit
import SwiftUI
import WebKit

/// Production-quality markdown editor backed by `WKWebView` + Vditor.
///
/// Why a WKWebView and not hand-rolled NSTextField/NSTextView:
/// - IME composition (Korean jamo), undo, copy/paste, list continuation,
///   smart caret behaviour are *solved problems* in mature web markdown
///   editors. Reinventing them in NSTextField produces fragile half-broken
///   code, which is exactly what the user kept hitting.
/// - Vditor's "instant rendering" mode keeps the source as canonical
///   markdown but renders it inline as the user types — exactly the
///   Notion-style experience the user asked for.
///
/// Data contract:
/// - Swift owns the canonical markdown string in the binding.
/// - When the binding changes externally (different day loaded), we push
///   it into the editor via JS.
/// - When the user types, Vditor fires an `input` callback which posts
///   the new markdown back to Swift via the `dayflow` message handler.
struct MarkdownWebEditor: NSViewRepresentable {
    @Binding var markdown: String
    var onChange: (String) -> Void

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
        web.loadHTMLString(Self.htmlContent, baseURL: URL(string: "https://localhost/"))

        context.coordinator.webView = web
        context.coordinator.pendingMarkdown = markdown
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Push markdown into the editor only when the binding changes from
        // outside the editor. The editor itself echoes its own changes back
        // through onChange, and we track lastEmittedMarkdown so we don't
        // bounce them back in.
        if markdown != context.coordinator.lastEmittedMarkdown {
            context.coordinator.pendingMarkdown = markdown
            context.coordinator.flushIfReady()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MarkdownWebEditor
        weak var webView: WKWebView?
        var ready: Bool = false
        var pendingMarkdown: String? = nil
        var lastEmittedMarkdown: String = ""

        init(_ parent: MarkdownWebEditor) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // The editor still has to construct itself after DOMContentLoaded.
            // We rely on the JS side posting `{type: "ready"}` once Vditor's
            // `after` callback fires, but `didFinish` is a useful fallback.
        }

        func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard let body = msg.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                flushIfReady()
            case "change":
                if let value = body["value"] as? String {
                    lastEmittedMarkdown = value
                    DispatchQueue.main.async {
                        if self.parent.markdown != value {
                            self.parent.markdown = value
                        }
                        self.parent.onChange(value)
                    }
                }
            default:
                break
            }
        }

        func flushIfReady() {
            guard ready, let md = pendingMarkdown else { return }
            pendingMarkdown = nil
            lastEmittedMarkdown = md
            // JSON-encode the string so quotes, backslashes, newlines, AND
            // multi-byte unicode (e.g. Korean) come through cleanly. Naïve
            // base64 + atob() corrupts UTF-8 because atob returns a binary
            // string of single bytes.
            guard let jsonData = try? JSONEncoder().encode(md),
                  let jsonLiteral = String(data: jsonData, encoding: .utf8) else { return }
            let js = "window.dayflowSetMarkdown(\(jsonLiteral))"
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
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/vditor@3.10.6/dist/index.css">
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
    #editor {
        height: 100vh;
        background: transparent;
    }
    .vditor {
        border: none !important;
        background: transparent !important;
    }
    .vditor-reset {
        background: transparent !important;
        color: rgba(255,255,255,0.92) !important;
        font-size: 15px !important;
        line-height: 1.7 !important;
        padding: 24px 28px !important;
    }
    .vditor-ir {
        background: transparent !important;
    }
    .vditor-ir pre.vditor-reset {
        background: transparent !important;
    }
    /* hide toolbar — we want a clean writing surface */
    .vditor-toolbar { display: none !important; }
    .vditor-content { background: transparent !important; }
    .vditor-ir__node, .vditor-ir__marker {
        color: rgba(247, 158, 51, 0.7) !important;
    }
    /* headings */
    .vditor-reset h1 { font-size: 28px !important; font-weight: 700 !important; margin: 0.6em 0 0.3em !important; letter-spacing: -0.5px; color: #fff !important; }
    .vditor-reset h2 { font-size: 21px !important; font-weight: 600 !important; margin: 0.5em 0 0.3em !important; color: #fff !important; }
    .vditor-reset h3 { font-size: 17px !important; font-weight: 600 !important; margin: 0.4em 0 0.2em !important; color: rgba(255,255,255,0.85) !important; }
    .vditor-reset h4, .vditor-reset h5, .vditor-reset h6 { font-size: 14px !important; font-weight: 600 !important; color: rgba(255,255,255,0.8) !important; }
    /* lists */
    .vditor-reset ul, .vditor-reset ol { padding-left: 1.2em !important; }
    .vditor-reset li { margin: 0.18em 0 !important; }
    .vditor-reset li > input[type="checkbox"] {
        width: 16px !important;
        height: 16px !important;
        margin-right: 6px !important;
        accent-color: #4cc66e;
    }
    .vditor-reset ul > li::marker {
        color: rgba(255,255,255,0.45);
    }
    /* paragraphs */
    .vditor-reset p { margin: 0.3em 0 !important; }
    /* code */
    .vditor-reset code, .vditor-reset pre {
        background: rgba(255,255,255,0.06) !important;
        color: #f79e33 !important;
        border-radius: 4px;
        padding: 1px 4px;
    }
    /* selection */
    .vditor-reset ::selection { background: rgba(247, 158, 51, 0.30); }
    /* hide vditor's own styling that conflicts */
    .vditor-counter { display: none !important; }
    .vditor-resize { display: none !important; }
    </style>
    </head>
    <body>
    <div id="editor"></div>
    <script src="https://cdn.jsdelivr.net/npm/vditor@3.10.6/dist/index.min.js"></script>
    <script>
    let vditor = null;
    let lastEmitted = "";

    function postReady() {
        try {
            window.webkit.messageHandlers.dayflow.postMessage({ type: "ready" });
        } catch (e) {}
    }

    function postChange(value) {
        if (value === lastEmitted) return;
        lastEmitted = value;
        try {
            window.webkit.messageHandlers.dayflow.postMessage({ type: "change", value: value });
        } catch (e) {}
    }

    window.dayflowSetMarkdown = function(md) {
        if (!vditor) return;
        if (vditor.getValue() === md) return;
        lastEmitted = md;
        vditor.setValue(md, false);
    };

    window.addEventListener("DOMContentLoaded", () => {
        vditor = new Vditor("editor", {
            mode: "ir",          // instant rendering — Notion-style
            theme: "dark",
            cdn: "https://cdn.jsdelivr.net/npm/vditor@3.10.6",
            height: "100%",
            placeholder: "## 오늘\\n- [ ] 첫 할 일을 적어봐",
            cache: { enable: false },
            toolbar: [],
            counter: { enable: false },
            outline: { enable: false },
            preview: { hljs: { enable: false } },
            input: function(value) {
                postChange(value);
            },
            after: function() {
                postReady();
            },
        });
    });
    </script>
    </body>
    </html>
    """
}
