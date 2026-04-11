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
    <link rel="stylesheet" href="https://uicdn.toast.com/editor/latest/toastui-editor.min.css">
    <link rel="stylesheet" href="https://uicdn.toast.com/editor/latest/theme/toastui-editor-dark.min.css">
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
    #editor { height: 100vh; }

    /* Toast UI dark theme overrides — strip chrome, match dayflow palette. */
    .toastui-editor-defaultUI {
        background: transparent !important;
        border: none !important;
    }
    .toastui-editor-toolbar { display: none !important; }
    .toastui-editor-mode-switch { display: none !important; }
    .toastui-editor-md-tab-container { display: none !important; }
    .toastui-editor-main { background: transparent !important; }
    .toastui-editor-main-container { background: transparent !important; }
    .toastui-editor-ww-container { background: transparent !important; }
    .toastui-editor-md-container { background: transparent !important; }
    .toastui-editor .ProseMirror {
        background: transparent !important;
        color: rgba(255,255,255,0.92) !important;
        padding: 28px 32px !important;
        font-size: 15px !important;
        line-height: 1.75 !important;
        outline: none !important;
        min-height: 100vh !important;
    }
    /* Headings */
    .toastui-editor .ProseMirror h1 { font-size: 28px !important; font-weight: 700 !important; margin: 0.7em 0 0.3em !important; letter-spacing: -0.5px; color: #fff !important; border: none !important; }
    .toastui-editor .ProseMirror h2 { font-size: 22px !important; font-weight: 600 !important; margin: 0.6em 0 0.3em !important; color: #fff !important; border: none !important; }
    .toastui-editor .ProseMirror h3 { font-size: 18px !important; font-weight: 600 !important; margin: 0.5em 0 0.2em !important; color: rgba(255,255,255,0.9) !important; border: none !important; }
    .toastui-editor .ProseMirror h4, .toastui-editor .ProseMirror h5, .toastui-editor .ProseMirror h6 { font-size: 15px !important; font-weight: 600 !important; color: rgba(255,255,255,0.8) !important; }
    /* Paragraphs */
    .toastui-editor .ProseMirror p { margin: 0.35em 0 !important; }
    /* Lists */
    .toastui-editor .ProseMirror ul, .toastui-editor .ProseMirror ol { padding-left: 1.4em !important; }
    .toastui-editor .ProseMirror li { margin: 0.2em 0 !important; }
    .toastui-editor .ProseMirror ul > li::marker { color: rgba(255,255,255,0.45); }
    /* Task list (checkbox) */
    .toastui-editor .ProseMirror .task-list-item { padding-left: 24px !important; position: relative; list-style: none; }
    .toastui-editor .ProseMirror .task-list-item::before {
        content: "";
        position: absolute;
        left: 0;
        top: 5px;
        width: 16px;
        height: 16px;
        border: 1.5px solid rgba(140, 148, 160, 0.9);
        border-radius: 4px;
        background: transparent;
        cursor: pointer;
    }
    .toastui-editor .ProseMirror .task-list-item.checked::before {
        background: #4cc66e;
        border-color: #4cc66e;
    }
    .toastui-editor .ProseMirror .task-list-item.checked::after {
        content: "";
        position: absolute;
        left: 4px;
        top: 8px;
        width: 8px;
        height: 5px;
        border-left: 2px solid white;
        border-bottom: 2px solid white;
        transform: rotate(-45deg);
    }
    .toastui-editor .ProseMirror .task-list-item.checked {
        color: rgba(255,255,255,0.45);
        text-decoration: line-through;
    }
    /* Inline code & blocks */
    .toastui-editor .ProseMirror code {
        background: rgba(255,255,255,0.07) !important;
        color: #f79e33 !important;
        border-radius: 4px;
        padding: 1px 5px;
        font-family: ui-monospace, "SF Mono", monospace;
        font-size: 13px;
    }
    .toastui-editor .ProseMirror pre {
        background: rgba(255,255,255,0.05) !important;
        border-radius: 6px;
        padding: 10px 12px !important;
    }
    /* Blockquote */
    .toastui-editor .ProseMirror blockquote {
        border-left: 3px solid rgba(247, 158, 51, 0.6) !important;
        background: rgba(255,255,255,0.03) !important;
        color: rgba(255,255,255,0.75) !important;
        padding: 4px 14px !important;
        margin: 0.6em 0 !important;
    }
    /* Selection */
    .toastui-editor .ProseMirror ::selection {
        background: rgba(247, 158, 51, 0.32);
    }
    /* Placeholder */
    .toastui-editor .ProseMirror p.placeholder::before {
        color: rgba(255,255,255,0.25) !important;
    }
    </style>
    </head>
    <body>
    <div id="editor"></div>
    <script src="https://uicdn.toast.com/editor/latest/toastui-editor-all.min.js"></script>
    <script>
    let editor = null;
    let lastEmitted = "";

    function postReady() {
        try { window.webkit.messageHandlers.dayflow.postMessage({ type: "ready" }); } catch (e) {}
    }
    function postChange(md) {
        if (md === lastEmitted) return;
        lastEmitted = md;
        try { window.webkit.messageHandlers.dayflow.postMessage({ type: "change", value: md }); } catch (e) {}
    }

    window.dayflowSetMarkdown = function(md) {
        if (!editor) return;
        if (editor.getMarkdown() === md) return;
        lastEmitted = md;
        editor.setMarkdown(md);
    };

    window.addEventListener("DOMContentLoaded", () => {
        editor = new toastui.Editor({
            el: document.querySelector("#editor"),
            height: "100%",
            theme: "dark",
            initialEditType: "wysiwyg",     // Notion-style: `-` instantly becomes a bullet,
                                            // `## ` instantly becomes a heading.
            previewStyle: "tab",
            hideModeSwitch: true,
            toolbarItems: [],
            usageStatistics: false,
            placeholder: "오늘 할 일을 markdown 으로 적어봐",
            events: {
                change: () => {
                    postChange(editor.getMarkdown());
                }
            }
        });
        postReady();
    });
    </script>
    </body>
    </html>
    """
}
