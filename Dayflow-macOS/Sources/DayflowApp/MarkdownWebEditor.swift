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
/// - Swift owns the canonical markdown string in the binding.
/// - When the binding changes externally (different day loaded), we push
///   it into the editor via `window.dayflowSetMarkdown`.
/// - When the user types, BlockNote fires `onEditorContentChange` which
///   posts the new markdown back via the `dayflow` message handler.
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
        return web
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only push when the binding diverged from what the editor last
        // emitted — otherwise we'd bounce the user's own edit back.
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
    <link rel="stylesheet" href="https://esm.sh/@blocknote/core@0.15.11/style.css">
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
        padding: 24px 8px;
    }

    /* BlockNote dark theme overrides */
    .bn-container, .bn-editor, .ProseMirror {
        background: transparent !important;
        color: rgba(255,255,255,0.92) !important;
        outline: none !important;
        font-size: 15px !important;
        line-height: 1.7 !important;
    }
    .bn-block-content[data-content-type="heading"][data-level="1"] {
        font-size: 28px !important; font-weight: 700 !important; letter-spacing: -0.5px;
    }
    .bn-block-content[data-content-type="heading"][data-level="2"] {
        font-size: 22px !important; font-weight: 600 !important;
    }
    .bn-block-content[data-content-type="heading"][data-level="3"] {
        font-size: 18px !important; font-weight: 600 !important;
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
    .bn-block-content code {
        background: rgba(255,255,255,0.08);
        color: #f79e33;
        border-radius: 4px;
        padding: 1px 5px;
        font-family: ui-monospace, "SF Mono", monospace;
        font-size: 13px;
    }
    .bn-block-content[data-content-type="codeBlock"] {
        background: rgba(255,255,255,0.05);
        border-radius: 6px;
        padding: 10px 12px;
    }
    .bn-block-content[data-content-type="quote"] {
        border-left: 3px solid rgba(247, 158, 51, 0.6);
        padding-left: 12px;
        color: rgba(255,255,255,0.75);
    }
    .ProseMirror ::selection { background: rgba(247, 158, 51, 0.32); }
    /* hide the formatting toolbar / side menu chrome — keep it minimal */
    .bn-formatting-toolbar, .bn-side-menu, .bn-suggestion-menu { display: none !important; }
    /* placeholder */
    .bn-block-content[data-is-empty-and-focused="true"]::before {
        color: rgba(255,255,255,0.25) !important;
    }
    </style>
    </head>
    <body>
    <div id="editor"></div>
    <script type="module">
    import { BlockNoteEditor } from "https://esm.sh/@blocknote/core@0.15.11";

    let editor = null;
    let lastEmitted = "";
    let suppressEmit = false;

    function postReady() {
        try { window.webkit.messageHandlers.dayflow.postMessage({ type: "ready" }); } catch (e) {}
    }
    function postChange(md) {
        if (suppressEmit) return;
        if (md === lastEmitted) return;
        lastEmitted = md;
        try { window.webkit.messageHandlers.dayflow.postMessage({ type: "change", value: md }); } catch (e) {}
    }

    // Line-based markdown parser. BlockNote 0.15.11's tryParseMarkdownToBlocks
    // chokes on GFM task lists (`- [ ] foo` becomes [empty checkListItem, "foo"
    // paragraph]), so we parse ourselves. Indentation (2-space unit) turns into
    // BlockNote block children, which is exactly how cross-list-type nesting
    // works in BlockNote — a bulletListItem can have checkListItem children and
    // vice versa, all within the same `blockContainer` tree.
    function mdToBlocks(md) {
        const lines = (md || '').replace(/\\r\\n?/g, '\\n').split('\\n');
        const root = { children: [] };
        const stack = [{ indent: -1, block: root }];
        for (const raw of lines) {
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
        return root.children;
    }

    window.dayflowSetMarkdown = async function(md) {
        if (!editor) return;
        try {
            suppressEmit = true;
            const blocks = mdToBlocks(md || '');
            if (blocks.length === 0) {
                // BlockNote requires at least one block — insert an empty paragraph.
                blocks.push({ type: 'paragraph', props: {}, content: [], children: [] });
            }
            editor.replaceBlocks(editor.document, blocks);
            lastEmitted = md;
        } catch (e) {
            console.log('setMarkdown error: ' + e.message + ' :: ' + (e.stack || ''));
        } finally {
            // small delay so the post-replace onChange that fires synchronously
            // is also suppressed.
            setTimeout(() => { suppressEmit = false; }, 50);
        }
    };

    async function emitCurrentMarkdown() {
        if (!editor) return;
        try {
            const md = await editor.blocksToMarkdownLossy(editor.document);
            postChange(md);
        } catch (e) {}
    }

    // Trailing debounce so that per-keystroke blocksToMarkdownLossy +
    // JS↔Swift bridge + binding write only fires after the user pauses.
    let emitTimer = null;
    function scheduleEmit() {
        if (emitTimer) clearTimeout(emitTimer);
        emitTimer = setTimeout(() => { emitTimer = null; emitCurrentMarkdown(); }, 200);
    }

    (async () => {
        try {
            editor = BlockNoteEditor.create({
                domAttributes: { editor: { class: 'bn-editor' } },
                initialContent: undefined,
            });
            editor.mount(document.getElementById('editor'));
            editor.onEditorContentChange(scheduleEmit);
            postReady();
        } catch (e) {}
    })();
    </script>
    </body>
    </html>
    """
}
