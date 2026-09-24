#!/usr/bin/env python3
"""End-to-end clipboard checks for the editor web view, in headless WebKit.

Serves EditorWeb/ over localhost the way EditorSchemeHandler serves it over
`dayflow-asset://editor/`, stubs the Swift message bridge, and drives real
ClipboardEvents through the page — BlockNote's handlers and ours both run.

    python3 -m pip install playwright && python3 -m playwright install webkit
    python3 Dayflow-macOS/Tests/EditorWeb/clipboard_e2e.py
"""
import faulthandler
import http.server
import pathlib
import sys
import threading

from playwright.sync_api import sync_playwright

EDITOR_WEB = pathlib.Path(__file__).resolve().parents[2] / 'Sources/DayflowApp/EditorWeb'


class EditorAssets(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split('?')[0]
        if path in ('/', '/index.html'):
            body = (EDITOR_WEB / 'index.html').read_text(encoding='utf-8')
            body = body.replace('dayflow-asset://editor/', '/')
            # Expose the module-scoped editor to the test driver.
            body = body.replace("editor.mount(document.getElementById('editor'));",
                                "editor.mount(document.getElementById('editor')); window.__ed = editor;")
            data, ctype = body.encode(), 'text/html'
        else:
            rel = path.lstrip('/')
            f = EDITOR_WEB / rel if rel.startswith('app/') else EDITOR_WEB / 'vendor/esm' / rel
            if '..' in rel.split('/') or not f.is_file():
                self.send_error(404)
                return
            data = f.read_bytes()
            ctype = 'text/javascript' if f.suffix in ('.mjs', '.js') else 'text/css'
        self.send_response(200)
        self.send_header('Content-Type', ctype)
        self.end_headers()
        self.wfile.write(data)


BRIDGE = """
window.__msgs = [];
window.webkit = { messageHandlers: { dayflow: { postMessage: (m) => window.__msgs.push(m) } } };
window.__fire = (type, data, files) => {
    const dt = new DataTransfer();
    for (const [k, v] of Object.entries(data || {})) dt.setData(k, v);
    for (const f of files || []) dt.items.add(new File([new Uint8Array([137, 80, 78, 71])], f.name, { type: f.type }));
    const target = document.querySelector('.ProseMirror');
    target.dispatchEvent(new ClipboardEvent(type, { clipboardData: dt, bubbles: true, cancelable: true }));
    const out = {};
    for (const t of dt.types) if (t !== 'Files') out[t] = dt.getData(t);
    return out;
};
window.__outline = () => {
    const text = (c) => Array.isArray(c) ? c.map((r) => r.type === 'link' ? text(r.content) : (r.text || '')).join('') : '';
    const walk = (bs, d) => bs.map((b) => '  '.repeat(d) + b.type
        + (b.type === 'checkListItem' ? (b.props.checked ? '[x]' : '[ ]') : '')
        + ': ' + text(b.content) + '\\n' + walk(b.children || [], d + 1)).join('');
    // BlockNote always keeps a trailing empty paragraph; it is not content.
    return walk(window.__ed.document, 0).replace(/paragraph: \\n$/, '');
};
window.__caret = (needle, where) => {
    const tt = window.__ed._tiptapEditor;
    let pos = null;
    tt.state.doc.descendants((n, p) => {
        if (pos === null && n.isText && n.text.includes(needle)) pos = p + n.text.indexOf(needle) + (where === 'end' ? needle.length : 0);
    });
    tt.commands.setTextSelection(pos);
};
window.__selectText = (needle) => {
    const tt = window.__ed._tiptapEditor;
    let from = null;
    tt.state.doc.descendants((n, p) => { if (from === null && n.isText && n.text.includes(needle)) from = p + n.text.indexOf(needle); });
    tt.commands.setTextSelection({ from, to: from + needle.length });
};
"""

NESTED_MD = '- 부모\n  - 자식 A\n    - [x] 손자\n  - [ ] 자식 체크\n- 두번째\n1. 번호\n   - 번호 밑'
NESTED = (
    'bulletListItem: 부모\n'
    '  bulletListItem: 자식 A\n'
    '    checkListItem[x]: 손자\n'
    '  checkListItem[ ]: 자식 체크\n'
    'bulletListItem: 두번째\n'
    'numberedListItem: 번호\n'
    '  bulletListItem: 번호 밑\n'
)

failures = []


def check(name, got, want):
    if got == want:
        print(f'  ok   {name}')
    else:
        failures.append(name)
        print(f'  FAIL {name}\n--- got\n{got}\n--- want\n{want}')


def run(page):
    def load(md, json=None):
        page.evaluate('([m, j]) => window.dayflowSetContent(m, j)', [md, json])
        page.wait_for_timeout(80)

    def fresh():
        load('')
        page.evaluate("() => window.__ed.setTextCursorPosition(window.__ed.document[0], 'end')")

    def outline():
        page.wait_for_timeout(30)
        return page.evaluate('window.__outline()')

    fire = lambda kind, data=None, files=None: page.evaluate('([t, d, f]) => window.__fire(t, d, f)', [kind, data or {}, files or []])

    # Dayflow → Dayflow: whole-document copy, paste into an empty note.
    load(NESTED_MD)
    page.evaluate('() => window.__ed._tiptapEditor.commands.selectAll()')
    copied = fire('copy')
    check('copy: plain text is a tight markdown list', copied['text/plain'],
          '- 부모\n    - 자식 A\n        - [x] 손자\n    - [ ] 자식 체크\n- 두번째\n1. 번호\n    - 번호 밑')
    fresh()
    fire('paste', copied)
    check('paste: in-app copy keeps nesting', outline(), NESTED)

    # Colors and the on-hold mark survive an in-app round trip.
    load('', '[{"type":"checkListItem","props":{"checked":false},"content":[{"type":"text","text":"보류","styles":{"backgroundColor":"blue"}}],"children":[{"type":"paragraph","content":[{"type":"text","text":"빨강","styles":{"textColor":"red","bold":true}}]}]}]')
    page.evaluate('() => window.__ed._tiptapEditor.commands.selectAll()')
    copied = fire('copy')
    fresh()
    fire('paste', copied)
    styles = page.evaluate('() => [window.__ed.document[0].content[0].styles, window.__ed.document[0].children[0].content[0].styles]')
    check('paste: on-hold background + text color survive', styles,
          [{'backgroundColor': 'blue'}, {'bold': True, 'textColor': 'red'}])

    # A copy that starts inside a nested item lifts it instead of pasting an empty parent.
    load(NESTED_MD)
    page.evaluate("""() => { const tt = window.__ed._tiptapEditor; let a = null, z = null;
        tt.state.doc.descendants((n, p) => { if (n.isText && n.text === '자식 A') a = p + 1; if (n.isText && n.text === '두번째') z = p + 2; });
        tt.commands.setTextSelection({ from: a, to: z }); }""")
    copied = fire('copy')
    fresh()
    fire('paste', copied)
    check('paste: copy starting mid-nesting', outline(),
          'bulletListItem: 식 A\n  checkListItem[x]: 손자\ncheckListItem[ ]: 자식 체크\nbulletListItem: 두번\n')

    # Every block kind survives an in-app round trip unchanged.
    rich = ('[{"type":"heading","props":{"level":2,"textColor":"red"},"content":[{"type":"text","text":"제목","styles":{"italic":true}},'
            '{"type":"link","href":"https://a.b","content":[{"type":"text","text":"링크","styles":{}}]}]},'
            '{"type":"codeBlock","props":{"language":"python"},"content":"x = 1\\nif x < 2:\\n    pass"},'
            '{"type":"image","props":{"url":"dayflow-asset://attachment/a.png","name":"a.png","caption":"cap","previewWidth":300}},'
            '{"type":"table","content":{"type":"tableContent","rows":[{"cells":[[{"type":"text","text":"c1","styles":{"bold":true}}],"c2"]}]}},'
            '{"type":"paragraph","content":"문단","children":[{"type":"numberedListItem","content":"하위"}]}]')
    load('', rich)
    strip_ids = '() => JSON.stringify(window.__ed.document.map(function s(b) { return { type: b.type, props: b.props, content: b.content, children: b.children.map(s) }; }))'
    before = page.evaluate(strip_ids)
    page.evaluate('() => window.__ed._tiptapEditor.commands.selectAll()')
    copied = fire('copy')
    fresh()
    fire('paste', copied)
    check('paste: heading/code/image/table/nested paragraph round trip', page.evaluate(strip_ids), before)

    # Other apps' HTML.
    cases = {
        'Notion-style <li><p>': '<ul><li><p>부모</p><ul><li><p>자식 A</p><ul><li><p><input type="checkbox" checked>손자</p></li></ul></li><li><input type="checkbox"> 자식 체크</li></ul></li><li>두번째</li></ul><ol><li>번호<ul><li>번호 밑</li></ul></li></ol>',
        'Google Docs ul-in-ul + guid wrapper': '<meta charset="utf-8"><b style="font-weight:normal;" id="docs-internal-guid-1"><ul><li><p><span>부모</span></p></li><ul><li><p>자식 A</p></li><ul><li class="task-list-item checked"><p>손자</p></li></ul><li class="task-list-item"><p>자식 체크</p></li></ul><li><p>두번째</p></li></ul><ol><li><p>번호</p></li><ul><li><p>번호 밑</p></li></ul></ol></b>',
        'GitHub task list': '<ul><li>부모<ul><li>자식 A<ul><li class="task-list-item"><input type="checkbox" class="task-list-item-checkbox" checked disabled> 손자</li></ul></li><li class="task-list-item"><input type="checkbox" disabled> 자식 체크</li></ul></li><li>두번째</li></ul><ol><li>번호<ul><li>번호 밑</li></ul></li></ol>',
    }
    for name, html in cases.items():
        fresh()
        fire('paste', {'text/html': html, 'text/plain': 'ignored'})
        check(f'paste: {name}', outline(), NESTED)
    fresh()
    fire('paste', {'text/html': '<b style="font-weight:normal" id="docs-internal-guid-2"><p><span style="font-weight:700">굵게</span> 보통</p><p>둘째 줄</p></b>'})
    check('paste: Google Docs inline bold, wrapper not bold',
          page.evaluate('() => window.__ed.document[0].content.map((r) => [r.text, !!r.styles.bold])'),
          [['굵게', True], [' 보통', False]])

    # Plain text (terminal, Claude Code, plain editors), tab and 4-space indents.
    for name, text in {
        '2-space': NESTED_MD,
        'tabs + shared margin': '\t- 부모\n\t\t- 자식 A\n\t\t\t- [x] 손자\n\t\t- [ ] 자식 체크\n\t- 두번째\n\t1. 번호\n\t\t- 번호 밑',
    }.items():
        fresh()
        fire('paste', {'text/plain': text})
        check(f'paste: plain markdown ({name})', outline(), NESTED)

    # VS Code: markdown files are prose, source files stay code.
    fresh()
    fire('paste', {'vscode-editor-data': '{"mode":"markdown"}', 'text/plain': NESTED_MD, 'text/html': '<div><span>- 부모</span></div>'})
    check('paste: VS Code markdown → blocks', outline(), NESTED)
    fresh()
    fire('paste', {'vscode-editor-data': '{"mode":"typescriptreact"}', 'text/plain': 'if (a < b) {\n    return <div/>;\n}'})
    check('paste: VS Code source → verbatim code block',
          page.evaluate('() => [window.__ed.document[0].type, window.__ed.document[0].content[0].text]'),
          ['codeBlock', 'if (a < b) {\n    return <div/>;\n}'])

    # Unknown fence languages load as plain-text code instead of failing the note.
    load('```mermaid-ish\ngraph\n```\n```javascriptreact\nx\n```\n- after')
    check('load: unknown code languages fall back', page.evaluate(
        '() => window.__ed.document.slice(0, 3).map((b) => b.type + ":" + (b.props.language || ""))'),
        ['codeBlock:text', 'codeBlock:jsx', 'bulletListItem:'])

    # Caret placement relative to an existing line.
    load('앞뒤')
    page.evaluate("() => window.__caret('앞뒤', 'end')")
    fire('paste', {'text/plain': '- a\n- b'})
    check('paste: at end of a line → after it', outline(), 'paragraph: 앞뒤\nbulletListItem: a\nbulletListItem: b\n')
    load('앞뒤')
    page.evaluate("() => window.__caret('뒤', 'start')")
    fire('paste', {'text/plain': '- a\n- b'})
    check('paste: mid-line → split around it', outline(), 'paragraph: 앞\nbulletListItem: a\nbulletListItem: b\nparagraph: 뒤\n')
    load('앞뒤')
    page.evaluate("() => window.__selectText('뒤')")
    fire('paste', {'text/plain': '- a\n- b'})
    check('paste: over a selection → replaces it', outline(), 'paragraph: 앞\nbulletListItem: a\nbulletListItem: b\n')

    # Structureless text still merges into the line (BlockNote default).
    load('문장 끝')
    page.evaluate("() => window.__caret('문장 끝', 'end')")
    fire('paste', {'text/plain': '이어서', 'text/html': '<span>이어서</span>'})
    check('paste: single inline run merges into the line', outline(), 'paragraph: 문장 끝이어서\n')
    load('문장')
    page.evaluate("() => window.__caret('문장', 'end')")
    fire('paste', {'text/plain': '- 한 줄'})
    check('paste: marker line into non-empty line stays literal', outline(), 'paragraph: 문장- 한 줄\n')
    fresh()
    fire('paste', {'text/plain': '- [ ] 할 일'})
    check('paste: marker line into empty line converts', outline(), 'checkListItem[ ]: 할 일\n')

    # Code blocks take text verbatim.
    load('```\nx\n```')
    page.evaluate("() => window.__caret('x', 'end')")
    fire('paste', {'text/plain': '\n- not a list\n# not a heading'})
    check('paste: into code block is verbatim', page.evaluate('() => window.__ed.document[0].content[0].text'),
          'x\n- not a list\n# not a heading')

    # Images: bytes-only clipboard is an upload; image + text (Office/Keynote) is text.
    fresh()
    page.evaluate('() => { window.__msgs.length = 0; }')
    fire('paste', {'text/html': '<img src="https://example.com/a.png">'}, [{'name': 'a.png', 'type': 'image/png'}])
    page.wait_for_timeout(100)
    check('paste: image-only clipboard uploads the bytes',
          page.evaluate("() => window.__msgs.filter((m) => m.type === 'uploadFile').length"), 1)
    fresh()
    page.evaluate('() => { window.__msgs.length = 0; }')
    fire('paste', {'text/plain': '셀1\t셀2\n행2', 'text/html': '<table><tr><td>셀1</td><td>셀2</td></tr><tr><td>행2</td></tr></table>'},
         [{'name': 'x.png', 'type': 'image/png'}])
    page.wait_for_timeout(100)
    check('paste: Office text + rendered image → text, no upload',
          (page.evaluate("() => window.__msgs.filter((m) => m.type === 'uploadFile').length"), outline().split(':')[0]),
          (0, 'table'))

    # Partial single-line copy keeps BlockNote's own plain text.
    load('- 부모\n  - 자식')
    page.evaluate("() => window.__selectText('자식')")
    check('copy: partial line is plain text only', fire('copy').get('text/plain', '').strip(), '자식')

    # ⌘C / ⌘X with only a caret must leave the clipboard alone.
    load('- 부모\n  - 자식')
    page.evaluate("() => window.__caret('부모', 'end')")
    for kind in ('copy', 'cut'):
        kept = page.evaluate("""(kind) => { const dt = new DataTransfer(); dt.setData('text/plain', 'from another app');
            document.querySelector('.ProseMirror').dispatchEvent(new ClipboardEvent(kind, { clipboardData: dt, bubbles: true, cancelable: true }));
            return dt.getData('text/plain'); }""", kind)
        check(f'{kind}: empty selection keeps the clipboard', kept, 'from another app')
    check('cut: empty selection deletes nothing', outline(), 'bulletListItem: 부모\n  bulletListItem: 자식\n')

    # ⌘⇧V drops text in as written: no markdown reading.
    fresh()
    page.evaluate("() => window.dayflowPastePlainText('# 주석\\n- 그대로')")
    check('paste as plain text keeps markers literal', outline(), 'paragraph: # 주석\nparagraph: - 그대로\n')

    # Markdown shortcuts while typing: `---` is a divider, ``` a code block,
    # both without Space/Enter; stored markdown keeps `---`.
    load('위')
    page.click('.ProseMirror')
    page.evaluate("() => window.__caret('위', 'end')")
    page.keyboard.press('Enter'); page.keyboard.type('---'); page.keyboard.type('아래')
    page.keyboard.press('Enter'); page.keyboard.type('```'); page.keyboard.type('x = 1')
    page.wait_for_timeout(400)
    check('typing: --- and ``` convert immediately', outline(),
          'paragraph: 위\ndivider: \nparagraph: 아래\ncodeBlock: x = 1\n')
    stored = page.evaluate("() => window.__msgs.filter((m) => m.type === 'change').pop().md")
    check('typing: divider stored as ---', '\n---\n' in stored and '***' not in stored, True)
    load('', '[{"type":"paragraph","content":[{"type":"text","text":"a","styles":{}}]},{"type":"paragraph","content":[{"type":"text","text":"---","styles":{}}]}]')
    check('load: saved --- paragraph becomes a divider', outline(), 'paragraph: a\ndivider: \n')

    # One undo step reverts a structured paste.
    load('기존')
    page.evaluate("() => window.__caret('기존', 'end')")
    page.wait_for_timeout(600)  # let history close the previous group
    fire('paste', {'text/plain': '- a\n  - b'})
    page.evaluate("() => window.__ed._tiptapEditor.commands.undo()")
    check('paste: single undo reverts it', outline(), 'paragraph: 기존\n')

    # Stored rows with markdown only (no body_json) still load as a tree.
    load('*   부모\n\n    *   자식 A\n\n        *   [x] 손자\n\n    *   [ ] 자식 체크\n\n*   두번째\n\n1.  번호\n\n    *   번호 밑\n')
    check('load: legacy loose markdown', outline(), NESTED)


# A hung browser must fail the run with a traceback, not sit until the CI
# job's own timeout: page.evaluate() has no timeout of its own.
WATCHDOG_SECONDS = 300


def main():
    faulthandler.dump_traceback_later(WATCHDOG_SECONDS, exit=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), EditorAssets)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f'http://127.0.0.1:{server.server_address[1]}/index.html'
    with sync_playwright() as p:
        print('launching WebKit', flush=True)
        browser = p.webkit.launch(timeout=60_000)
        page = browser.new_page()
        page.set_default_timeout(20_000)
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)) if 'WebAssembly' not in str(e) else None)
        page.on('console', lambda m: (print('  [console]', m.text), errors.append(m.text)) if 'error' in m.text.lower() and 'WebAssembly' not in m.text else None)
        page.add_init_script(BRIDGE)
        page.goto(url)
        page.wait_for_function("window.__msgs.some((m) => m.type === 'ready')")
        print('editor ready', flush=True)
        run(page)
        browser.close()
    for e in errors:
        print('  page error:', e)
    print(f"\n{'FAILED: ' + ', '.join(failures) if failures else 'all clipboard checks passed'}")
    sys.exit(1 if failures or errors else 0)


if __name__ == '__main__':
    main()
