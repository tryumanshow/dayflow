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
        // capture console.log from JS for debug
        let consoleScript = WKUserScript(
            source: """
            (function(){
                const orig = window.console.log;
                window.console.log = function(...args){
                    try { window.webkit.messageHandlers.dayflow.postMessage({type:'log', value: args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ')}); } catch(e){}
                    if (orig) orig.apply(window.console, args);
                };
                window.addEventListener('error', (e) => {
                    try { window.webkit.messageHandlers.dayflow.postMessage({type:'log', value: 'JS_ERROR: ' + e.message + ' @ ' + e.filename + ':' + e.lineno}); } catch(_){}
                });
            })();
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        userContent.addUserScript(consoleScript)
        config.userContentController = userContent
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        // Enable Safari Web Inspector — Develop → Dayflow → editor (macOS 13.3+)
        if #available(macOS 13.3, *) {
            web.isInspectable = true
        }
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
            case "log":
                if let value = body["value"] as? String {
                    // write JS logs to a known file so we can grep them later
                    let line = "[\(Date())] \(value)\n"
                    if let data = line.data(using: .utf8) {
                        let url = URL(fileURLWithPath: "/tmp/dayflow-debug.log")
                        if let handle = try? FileHandle(forWritingTo: url) {
                            handle.seekToEndOfFile()
                            handle.write(data)
                            try? handle.close()
                        } else {
                            try? data.write(to: url)
                        }
                    }
                }
            case "ready":
                ready = true
                flushIfReady()
                // PERMANENTLY DO NOT auto-invoke dayflowSelfTest(). Even with
                // backup/restore the test sequences leak through onUpdate
                // before restore can run, and the DB ends up containing the
                // last test sequence. Manually call window.dayflowSelfTest()
                // from Safari Web Inspector if you really need to verify rules.
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
    //
    // The trick: StarterKit's BulletList input rule runs first, so when the
    // user types `- ` we IMMEDIATELY get a bullet list. They then type
    // `[ ] ` or `[x] ` *inside* the bullet item, and we transform the bullet
    // into a task. The first pattern (`^- [ ] `) is kept as a fallback for
    // direct paragraph input (e.g. paste).
    const taskListMatchHandler = ({ chain, range, match, state }) => {
        const checked = match[1] === 'x' || match[1] === 'X';

        // Try the simple TipTap path first.
        const okToggle = chain()
            .deleteRange(range)
            .toggleList('taskList', 'taskItem')
            .updateAttributes('taskItem', { checked })
            .run();
        if (okToggle) return;

        // Fallback 1: wrapInList. Helpful when we're inside a same-depth list.
        const okWrap = chain()
            .wrapInList('taskList')
            .updateAttributes('taskItem', { checked })
            .run();
        if (okWrap) return;

        // Fallback 2: manual node manipulation. Walk up to the nearest
        // list item, replace it (and its parent list) with the task
        // equivalents. This is the path that fires inside a *nested*
        // bulletList, where toggleList fails because the parent's
        // children (listItem) don't satisfy taskList's content schema.
        chain()
            .deleteRange(range)
            .command(({ tr, state, dispatch }) => {
                const schema = state.schema;
                const taskListType = schema.nodes.taskList;
                const taskItemType = schema.nodes.taskItem;
                if (!taskListType || !taskItemType) return false;

                const $from = tr.selection.$from;
                let itemDepth = -1;
                let listDepth = -1;
                for (let d = $from.depth; d > 0; d--) {
                    const t = $from.node(d).type.name;
                    if (itemDepth === -1 && (t === 'listItem' || t === 'taskItem')) {
                        itemDepth = d;
                    }
                    if (t === 'bulletList' || t === 'orderedList' || t === 'taskList') {
                        listDepth = d;
                        break;
                    }
                }
                if (itemDepth < 0 || listDepth < 0) return false;

                const itemNode = $from.node(itemDepth);
                const listNode = $from.node(listDepth);
                const listPos = $from.before(listDepth);
                const itemPos = $from.before(itemDepth);

                if (dispatch) {
                    // Set the item type to taskItem with the checked attr.
                    tr.setNodeMarkup(itemPos, taskItemType, { checked });
                    // Set the surrounding list type to taskList. This may
                    // convert sibling items too — that's acceptable for
                    // the nested-bullet case where the user explicitly
                    // typed a task shortcut.
                    tr.setNodeMarkup(listPos, taskListType);
                    dispatch(tr);
                }
                return true;
            })
            .run();
    };
    const TaskListMarkdownShortcut = Extension.create({
        name: 'taskListMarkdownShortcut',
        addInputRules() {
            return [
                // Inside an existing bullet item (most common path).
                new InputRule({
                    find: /^\\[([ xX])\\]\\s$/,
                    handler: taskListMatchHandler,
                }),
                // Direct paragraph form (e.g. paste).
                new InputRule({
                    find: /^\\s*[-+*]\\s\\[([ xX])\\]\\s$/,
                    handler: taskListMatchHandler,
                }),
            ];
        }
    });

    let editor = null;
    let lastEmitted = "";

    function postReady() {
        console.log('postReady called, editor=' + (editor ? 'exists' : 'null'));
        try { window.webkit.messageHandlers.dayflow.postMessage({ type: "ready" }); } catch (e) { console.log('postReady error: ' + e.message); }
    }
    console.log('script loaded, about to import tiptap');
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

    // ---------- self-test ----------
    // Type characters one-by-one through ProseMirror's textInput pipeline so
    // input rules fire just like a real keystroke would. Returns the resulting
    // markdown for each test sequence.
    window.dayflowSelfTest = function() {
        if (!editor) return JSON.stringify({ error: 'no editor' });
        const view = editor.view;

        // Backup current document so we don't destroy user data.
        const backup = editor.getJSON();

        function typeChar(ch) {
            const { from, to } = view.state.selection;
            const handled = view.someProp('handleTextInput', f => f(view, from, to, ch));
            if (!handled) {
                view.dispatch(view.state.tr.insertText(ch));
            }
        }

        function reset() {
            editor.commands.setContent('');
            editor.commands.focus();
        }

        function describe() {
            const md = editor.storage.markdown.getMarkdown();
            const json = editor.getJSON();
            const top = (json.content && json.content[0] && json.content[0].type) || 'empty';
            let inner = null;
            const c0 = json.content && json.content[0];
            if (c0 && c0.content && c0.content[0]) inner = c0.content[0].type;
            return { md, top, inner };
        }

        function runSequence(seq) {
            reset();
            for (const ch of seq) typeChar(ch);
            return describe();
        }

        function runNestedTask() {
            reset();
            // type "- a"
            typeChar('-'); typeChar(' '); typeChar('a');
            // enter — splitListItem
            editor.commands.splitListItem('listItem');
            // tab — sinkListItem
            editor.commands.sinkListItem('listItem');
            // type "[ ] b"
            typeChar('['); typeChar(' '); typeChar(']'); typeChar(' '); typeChar('b');
            return describe();
        }

        const results = {
            'h1':       runSequence('# Hello'),
            'h2':       runSequence('## Hello'),
            'h3':       runSequence('### Hello'),
            'bullet':   runSequence('- foo'),
            'task':     runSequence('- [ ] task'),
            'checked':  runSequence('- [x] done'),
            'nested':   runNestedTask(),
        };

        // Restore the user's content.
        editor.commands.setContent(backup);

        return JSON.stringify(results, null, 2);
    };

    // Tab / Shift+Tab handler.
    //
    // TipTap's TaskItem ships a Tab keymap (`sinkListItem('taskItem')`), but
    // inside a WKWebView the Tab key is intercepted by WebKit's contenteditable
    // focus-traversal default before ProseMirror's keymap can react. We catch
    // the event in the capture phase, run the indent / outdent command
    // directly through TipTap's command API, and only swallow the event when
    // we actually performed an action.
    document.addEventListener('keydown', function(e) {
        if (e.key !== 'Tab') return;
        if (!editor) return;

        let handled = false;
        if (e.shiftKey) {
            handled =
                editor.commands.liftListItem('taskItem') ||
                editor.commands.liftListItem('listItem');
        } else {
            handled =
                editor.commands.sinkListItem('taskItem') ||
                editor.commands.sinkListItem('listItem');
        }
        if (handled) {
            e.preventDefault();
            e.stopPropagation();
        }
    }, true);

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
