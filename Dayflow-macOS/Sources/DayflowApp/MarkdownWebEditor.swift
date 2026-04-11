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
struct MarkdownWebEditor: NSViewRepresentable {
    @Binding var markdown: String
    @Binding var markdownJSON: String?
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

        init(_ parent: MarkdownWebEditor) { self.parent = parent }

        func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard let body = msg.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                flushIfReady()
            case "change":
                let md = (body["md"] as? String) ?? ""
                let json = body["json"] as? String
                lastEmittedMarkdown = md
                lastEmittedJSON = json ?? ""
                DispatchQueue.main.async {
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
            guard ready else { return }
            guard let md = pendingMarkdown else { return }
            let json = pendingJSON
            pendingMarkdown = nil
            pendingJSON = nil
            lastEmittedMarkdown = md
            lastEmittedJSON = json ?? ""
            // JSON-encode both string args so quotes, backslashes, newlines,
            // and multi-byte unicode (e.g. Korean) come through cleanly.
            // Naïve base64 + atob() corrupts UTF-8 because atob returns a
            // binary string of single bytes.
            guard let mdData = try? JSONEncoder().encode(md),
                  let mdLiteral = String(data: mdData, encoding: .utf8) else { return }
            let jsonLiteral: String
            if let json = json,
               let jdata = try? JSONEncoder().encode(json),
               let s = String(data: jdata, encoding: .utf8) {
                jsonLiteral = s
            } else {
                jsonLiteral = "null"
            }
            let js = "window.dayflowSetContent(\(mdLiteral), \(jsonLiteral))"
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
    #dayflow-toolbar {
        flex: 0 0 auto;
        display: flex;
        align-items: center;
        gap: 4px;
        padding: 6px 10px;
        background: rgba(28, 28, 32, 0.7);
        border-bottom: 1px solid rgba(255, 255, 255, 0.06);
        backdrop-filter: blur(12px);
        -webkit-backdrop-filter: blur(12px);
        font-size: 13px;
        user-select: none;
    }
    #dayflow-toolbar .sep {
        width: 1px;
        height: 16px;
        background: rgba(255, 255, 255, 0.12);
        margin: 0 4px;
    }
    #dayflow-toolbar .label {
        font-size: 11px;
        color: rgba(255, 255, 255, 0.45);
        margin-right: 2px;
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
    #dayflow-toolbar .swatch.clear {
        background: transparent;
        color: rgba(255, 255, 255, 0.55);
        font-size: 11px;
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
    /* drag-handle side menu + slash-suggestion menu stay hidden to keep
       the layout minimal — the Dayflow toolbar above covers the common
       styling actions. */
    .bn-side-menu, .bn-suggestion-menu { display: none !important; }
    /* placeholder */
    .bn-block-content[data-is-empty-and-focused="true"]::before {
        color: rgba(255,255,255,0.25) !important;
    }
    </style>
    </head>
    <body>
    <div id="dayflow-toolbar">
      <button data-cmd="bold" title="Bold (⌘B)">B</button>
      <button data-cmd="italic" class="italic" title="Italic (⌘I)">I</button>
      <button data-cmd="underline" class="underline" title="Underline (⌘U)">U</button>
      <button data-cmd="strike" class="strike" title="Strikethrough">S</button>
      <div class="sep"></div>
      <span class="label">A</span>
      <button class="swatch clear" data-text="default" title="Default text color">×</button>
      <button class="swatch" data-text="red"    style="background:#ef4444" title="Red"></button>
      <button class="swatch" data-text="orange" style="background:#f59e0b" title="Orange"></button>
      <button class="swatch" data-text="yellow" style="background:#eab308" title="Yellow"></button>
      <button class="swatch" data-text="green"  style="background:#22c55e" title="Green"></button>
      <button class="swatch" data-text="blue"   style="background:#3b82f6" title="Blue"></button>
      <button class="swatch" data-text="purple" style="background:#a855f7" title="Purple"></button>
      <div class="sep"></div>
      <span class="label">▨</span>
      <button class="swatch clear" data-bg="default" title="Default background">×</button>
      <button class="swatch" data-bg="red"    style="background:#ef4444" title="Red highlight"></button>
      <button class="swatch" data-bg="orange" style="background:#f59e0b" title="Orange highlight"></button>
      <button class="swatch" data-bg="yellow" style="background:#eab308" title="Yellow highlight"></button>
      <button class="swatch" data-bg="green"  style="background:#22c55e" title="Green highlight"></button>
      <button class="swatch" data-bg="blue"   style="background:#3b82f6" title="Blue highlight"></button>
      <button class="swatch" data-bg="purple" style="background:#a855f7" title="Purple highlight"></button>
    </div>
    <div id="editor"></div>
    <script type="module">
    import { BlockNoteEditor } from "https://esm.sh/@blocknote/core@0.15.11";

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

    // Prefer the JSON tree when present — it's the lossless representation
    // that preserves text color / background color / underline that
    // `blocksToMarkdownLossy` would strip. Fall back to parsing the
    // markdown for notes written before JSON side-storage existed, or for
    // any day whose JSON was intentionally nulled (QuickThrow, Week
    // checkbox toggle).
    window.dayflowSetContent = async function(md, json) {
        if (!editor) return;
        try {
            suppressEmit = true;
            let blocks = null;
            if (json) {
                try {
                    const parsed = JSON.parse(json);
                    if (Array.isArray(parsed) && parsed.length > 0) {
                        blocks = parsed;
                    }
                } catch (e) {
                    console.log('json parse error: ' + e.message);
                }
            }
            if (!blocks) {
                blocks = mdToBlocks(md || '');
            }
            if (blocks.length === 0) {
                // BlockNote requires at least one block — insert an empty paragraph.
                blocks.push({ type: 'paragraph', props: {}, content: [], children: [] });
            }
            editor.replaceBlocks(editor.document, blocks);
            lastEmitted = md;
            lastEmittedJSON = json || "";
        } catch (e) {
            console.log('setContent error: ' + e.message + ' :: ' + (e.stack || ''));
        } finally {
            // small delay so the post-replace onChange that fires synchronously
            // is also suppressed.
            setTimeout(() => { suppressEmit = false; }, 50);
        }
    };

    async function emitCurrentContent() {
        if (!editor) return;
        try {
            const md = await editor.blocksToMarkdownLossy(editor.document);
            const json = JSON.stringify(editor.document);
            postChange(md, json);
        } catch (e) {}
    }

    // Trailing debounce so that per-keystroke blocksToMarkdownLossy +
    // JSON.stringify + JS↔Swift bridge + binding write only fires after
    // the user pauses.
    let emitTimer = null;
    function scheduleEmit() {
        if (emitTimer) clearTimeout(emitTimer);
        emitTimer = setTimeout(() => { emitTimer = null; emitCurrentContent(); }, 200);
    }

    // Wire the Dayflow formatting toolbar. mousedown + preventDefault()
    // keeps the editor's text selection intact — plain click would
    // steal focus and collapse the selection before the style call
    // lands. BlockNote's style API:
    //   editor.toggleStyles({ bold: true })
    //   editor.addStyles({ textColor: 'red' })
    //   editor.removeStyles({ textColor: 'red' })
    //   editor.getActiveStyles() → { bold?, italic?, underline?, strike?, textColor?, backgroundColor? }
    function bindToolbar() {
        const bar = document.getElementById('dayflow-toolbar');
        if (!bar) return;
        bar.addEventListener('mousedown', (e) => {
            const btn = e.target.closest('button');
            if (!btn) return;
            e.preventDefault();
            if (!editor) return;
            const cmd = btn.getAttribute('data-cmd');
            const text = btn.getAttribute('data-text');
            const bg = btn.getAttribute('data-bg');
            try {
                if (cmd) {
                    editor.toggleStyles({ [cmd]: true });
                } else if (text != null) {
                    if (text === 'default') {
                        const active = editor.getActiveStyles() || {};
                        if (active.textColor) editor.removeStyles({ textColor: active.textColor });
                    } else {
                        editor.addStyles({ textColor: text });
                    }
                } else if (bg != null) {
                    if (bg === 'default') {
                        const active = editor.getActiveStyles() || {};
                        if (active.backgroundColor) editor.removeStyles({ backgroundColor: active.backgroundColor });
                    } else {
                        editor.addStyles({ backgroundColor: bg });
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
        const bar = document.getElementById('dayflow-toolbar');
        if (!bar) return;
        bar.querySelectorAll('button[data-cmd]').forEach((b) => {
            const cmd = b.getAttribute('data-cmd');
            b.classList.toggle('active', !!active[cmd]);
        });
        bar.querySelectorAll('button[data-text]').forEach((b) => {
            const val = b.getAttribute('data-text');
            const current = active.textColor || 'default';
            b.classList.toggle('active', val === current);
        });
        bar.querySelectorAll('button[data-bg]').forEach((b) => {
            const val = b.getAttribute('data-bg');
            const current = active.backgroundColor || 'default';
            b.classList.toggle('active', val === current);
        });
    }

    (async () => {
        try {
            editor = BlockNoteEditor.create({
                domAttributes: { editor: { class: 'bn-editor' } },
                initialContent: undefined,
            });
            editor.mount(document.getElementById('editor'));
            editor.onEditorContentChange(scheduleEmit);
            if (editor.onEditorSelectionChange) {
                editor.onEditorSelectionChange(refreshToolbarState);
            }
            bindToolbar();
            refreshToolbarState();
            postReady();
        } catch (e) {}
    })();
    </script>
    </body>
    </html>
    """
}
