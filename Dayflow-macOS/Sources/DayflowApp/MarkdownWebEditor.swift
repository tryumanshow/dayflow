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

        init(_ parent: MarkdownWebEditor) { self.parent = parent }

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
            // `md` is a plain string → encode it as a JS string literal
            // so quotes, backslashes, newlines, and multi-byte unicode
            // come through cleanly. `json` is already a valid JSON text
            // (a subset of JS expression grammar since ES2019), so it
            // can be spliced in as a JS object literal directly without
            // the extra encode/parse round-trip.
            let mdLiteral = Self.jsStringLiteral(md)
            let jsonLiteral = json ?? "null"
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
    </style>
    </head>
    <body>
    <div id="dayflow-toolbar">
      <div class="tb-group">
        <button data-cmd="bold" title="Bold (⌘B)">B</button>
        <button data-cmd="italic" class="italic" title="Italic (⌘I)">I</button>
        <button data-cmd="underline" class="underline" title="Underline (⌘U)">U</button>
        <button data-cmd="strike" class="strike" title="Strikethrough">S</button>
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

    // `jsonTree` arrives as an already-parsed array (Swift inlines the
    // raw JSON as a JS object literal), or `null` for markdown-only
    // rows. Markdown is only re-parsed when the JSON sidecar is absent.
    window.dayflowSetContent = async function(md, jsonTree) {
        if (!editor) return;
        try {
            suppressEmit = true;
            let blocks = (Array.isArray(jsonTree) && jsonTree.length > 0) ? jsonTree : null;
            if (!blocks) {
                blocks = mdToBlocks(md || '');
            }
            if (blocks.length === 0) {
                // BlockNote requires at least one block.
                blocks.push({ type: 'paragraph', props: {}, content: [], children: [] });
            }
            editor.replaceBlocks(editor.document, blocks);
            lastEmitted = md;
            lastEmittedJSON = jsonTree ? JSON.stringify(jsonTree) : "";
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
            const md = await editor.blocksToMarkdownLossy(editor.document);
            const json = JSON.stringify(editor.document);
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
                    // Toggle: clicking the already-active color clears it.
                    // Dropping the explicit "clear" chip removes a piece
                    // of visual chrome that used to break the row of
                    // colored circles.
                    const active = editor.getActiveStyles() || {};
                    if (active[prop] === color) {
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

    function positionSlashMenu() {
        if (!slashMenuEl) return;
        const sel = window.getSelection();
        if (!sel || sel.rangeCount === 0) return;
        let rect = sel.getRangeAt(0).getBoundingClientRect();
        // Collapsed selection sometimes has a zero rect on empty
        // blocks — fall back to the empty-and-focused block rect.
        if (rect.width === 0 && rect.height === 0) {
            const focusedBlock = document.querySelector('.bn-block-content[data-is-empty-and-focused="true"]');
            if (focusedBlock) rect = focusedBlock.getBoundingClientRect();
        }
        const top = Math.min(window.innerHeight - 380, rect.bottom + 6);
        const left = Math.min(window.innerWidth - 340, Math.max(8, rect.left));
        slashMenuEl.style.top = top + 'px';
        slashMenuEl.style.left = left + 'px';
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
        applyBlockType(cmd.block);
    }

    // Capture-phase keydown so we intercept `/`, arrows, Enter, etc.
    // before ProseMirror sees them.
    document.addEventListener('keydown', (e) => {
        // IME composition guard — Korean/Japanese/Chinese input
        // pre-commit keys fire with `key: "Process"` / isComposing
        // true and keyCode 229. Ignore so ProseMirror handles the
        // composition cleanly.
        if (e.isComposing || e.keyCode === 229) return;

        if (!slashMenuEl) {
            if (e.key === '/' && !e.metaKey && !e.ctrlKey && !e.altKey && isCurrentBlockEmpty()) {
                e.preventDefault();
                openSlashMenu();
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
        if (!slashMenuEl) return;
        if (slashMenuEl.contains(e.target)) return;
        closeSlashMenu();
    }, true);

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
            buildSwatches();
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
