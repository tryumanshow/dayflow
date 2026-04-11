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
        overflow-y: auto;
    }
    .ProseMirror {
        outline: none;
        padding: 28px 36px;
        min-height: calc(100vh - 56px);
        font-size: 15px;
        line-height: 1.75;
        color: rgba(255,255,255,0.92);
        caret-color: #f79e33;
    }
    .ProseMirror p { margin: 0.35em 0; }
    .ProseMirror h1 { font-size: 28px; font-weight: 700; letter-spacing: -0.5px; margin: 0.7em 0 0.3em; color: #fff; }
    .ProseMirror h2 { font-size: 22px; font-weight: 600; margin: 0.6em 0 0.3em; color: #fff; }
    .ProseMirror h3 { font-size: 18px; font-weight: 600; margin: 0.5em 0 0.2em; color: rgba(255,255,255,0.9); }
    .ProseMirror h4 { font-size: 16px; font-weight: 600; color: rgba(255,255,255,0.85); }
    .ProseMirror ul, .ProseMirror ol { padding-left: 1.5em; margin: 0.3em 0; }
    .ProseMirror li { margin: 0.2em 0; }
    .ProseMirror ul li::marker { color: rgba(255,255,255,0.4); }

    /* Task list — TipTap renders <ul data-type="taskList"> with <li data-checked> */
    .ProseMirror ul[data-type="taskList"] { list-style: none; padding-left: 0; }
    .ProseMirror ul[data-type="taskList"] li { display: flex; align-items: flex-start; gap: 8px; }
    .ProseMirror ul[data-type="taskList"] li > label {
        margin-top: 5px;
        flex-shrink: 0;
    }
    .ProseMirror ul[data-type="taskList"] li > label > input[type="checkbox"] {
        width: 16px;
        height: 16px;
        accent-color: #4cc66e;
        cursor: pointer;
    }
    .ProseMirror ul[data-type="taskList"] li > div {
        flex: 1;
        min-width: 0;
    }
    .ProseMirror ul[data-type="taskList"] li[data-checked="true"] > div {
        color: rgba(255,255,255,0.45);
        text-decoration: line-through;
    }

    .ProseMirror code {
        background: rgba(255,255,255,0.08);
        color: #f79e33;
        border-radius: 4px;
        padding: 1px 5px;
        font-family: ui-monospace, "SF Mono", monospace;
        font-size: 13px;
    }
    .ProseMirror pre {
        background: rgba(255,255,255,0.05);
        border-radius: 6px;
        padding: 10px 12px;
        overflow-x: auto;
    }
    .ProseMirror pre code { background: transparent; padding: 0; }
    .ProseMirror blockquote {
        border-left: 3px solid rgba(247, 158, 51, 0.6);
        background: rgba(255,255,255,0.03);
        color: rgba(255,255,255,0.75);
        padding: 4px 14px;
        margin: 0.6em 0;
    }
    .ProseMirror hr { border: none; border-top: 1px solid rgba(255,255,255,0.1); margin: 1.2em 0; }
    .ProseMirror strong { color: #fff; font-weight: 700; }
    .ProseMirror em { color: rgba(255,255,255,0.95); }
    .ProseMirror a { color: #f79e33; text-decoration: underline; }
    .ProseMirror ::selection { background: rgba(247, 158, 51, 0.32); }

    /* Placeholder (empty doc only) */
    .ProseMirror p.is-editor-empty:first-child::before {
        content: attr(data-placeholder);
        color: rgba(255,255,255,0.25);
        float: left;
        height: 0;
        pointer-events: none;
    }
    </style>
    </head>
    <body>
    <div id="editor"></div>
    <script type="module">
    import { Editor, Extension, InputRule } from 'https://esm.sh/@tiptap/core@2.10.3';
    import StarterKit from 'https://esm.sh/@tiptap/starter-kit@2.10.3';
    import TaskList from 'https://esm.sh/@tiptap/extension-task-list@2.10.3';
    import TaskItem from 'https://esm.sh/@tiptap/extension-task-item@2.10.3';
    import Placeholder from 'https://esm.sh/@tiptap/extension-placeholder@2.10.3';
    import { Markdown } from 'https://esm.sh/tiptap-markdown@0.8.10';

    // TipTap doesn't ship a markdown input rule for task lists, so we add one.
    // Triggers when the user types `- [ ] ` or `- [x] ` at the start of a line.
    const TaskListMarkdownShortcut = Extension.create({
        name: 'taskListMarkdownShortcut',
        addInputRules() {
            return [
                new InputRule({
                    find: /^\\s*[-+*]\\s\\[([ xX])\\]\\s$/,
                    handler: ({ chain, range, match }) => {
                        const checked = match[1] === 'x' || match[1] === 'X';
                        chain()
                            .deleteRange(range)
                            .toggleTaskList()
                            .updateAttributes('taskItem', { checked })
                            .run();
                    }
                })
            ];
        }
    });

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
        const current = editor.storage.markdown.getMarkdown();
        if (current === md) return;
        lastEmitted = md;
        editor.commands.setContent(md, false);
    };

    editor = new Editor({
        element: document.querySelector('#editor'),
        extensions: [
            StarterKit,
            TaskList,
            TaskItem.configure({ nested: true }),
            TaskListMarkdownShortcut,
            Placeholder.configure({
                placeholder: '## 오늘\\n- [ ] 첫 할 일을 적어봐\\n\\n# / ## 헤더, - 리스트, [ ] 체크박스 — 입력 즉시 변환'
            }),
            Markdown.configure({
                html: false,
                tightLists: true,
                bulletListMarker: '-',
                linkify: false,
                breaks: false,
            })
        ],
        content: '',
        autofocus: true,
        onUpdate: ({ editor }) => {
            const md = editor.storage.markdown.getMarkdown();
            postChange(md);
        },
        onCreate: () => {
            postReady();
        }
    });
    </script>
    </body>
    </html>
    """
}
