// Structure-preserving conversions between the three shapes a note takes on
// its way through the clipboard: BlockNote blocks, markdown text, and HTML.
//
// Why this exists instead of BlockNote's own converters (0.22):
// - Its HTML parser mis-reads `<li><p>…</p></li>` — the shape BlockNote itself,
//   Notion, Google Docs and most web pages put on the clipboard — and wraps
//   every list item in an extra empty parent, so nesting shifts one level per
//   item. Checkbox items (`<li><input type=checkbox>…`) split into an empty
//   check item plus a stray paragraph.
// - Its plain-text paste never reads markdown, so a list copied out of a
//   terminal or a plain-text editor lands as literal `- item` lines with the
//   indentation thrown away.
// - Its clipboard markdown is a "loose" list (`*   a`, blank line between
//   every item), which reads badly anywhere that shows plain text.
//
// Everything here is pure data in / data out. The markdown half has no DOM
// dependency (unit-tested under node); the HTML half takes a parsed Document.

const INDENT_UNIT = '    ';
const MAX_HEADING_LEVEL = 3; // BlockNote's default schema stops at h3.

// A leading `[ ]` / `[x]` / `[~]`. `[~]` is Dayflow's on-hold mark: BlockNote
// has no third checkbox state, so on-hold rides as an unchecked item whose text
// carries the reserved blue background (the emit path turns it back into `[~]`).
const CHECK_MARK_RE = /^\[([ xX~])\]\s+/;
const BULLET_RE = /^([-*+•◦▪‣●○■])\s+(.*)$/;
// Up to three digits: `2026. 9. 24 회의` is a date, not item 2026.
const ORDERED_RE = /^(\d{1,3})[.)]\s+(.*)$/;
const UNSAFE_HREF_RE = /^\s*(javascript|vbscript|data):/i;
const HEADING_RE = /^(#{1,6})\s+(.*)$/;
const TABLE_SEPARATOR_RE = /^\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$/;
const ON_HOLD_BACKGROUND = 'blue';

// ---------------------------------------------------------------- inline

const INLINE_TOKEN_RE = new RegExp([
    '(`+)([^`]|[^`][\\s\\S]*?[^`])\\1(?!`)',            // 1,2  code span
    '\\[([^\\]\\n]+)\\]\\(([^)\\s]+)\\)',                // 3,4  link
    '(\\*\\*|__)(?=\\S)([\\s\\S]*?\\S)\\5',              // 5,6  bold
    '~~(?=\\S)([\\s\\S]*?\\S)~~',                         // 7    strike
    '\\*(?=[^\\s*])([\\s\\S]*?[^\\s*])\\*',              // 8    italic (*)
    '(?<![\\p{L}\\p{N}_])_(?=\\S)([\\s\\S]*?\\S)_(?![\\p{L}\\p{N}_])', // 9 italic (_), not snake_case
].join('|'), 'gu');

/** Markdown inline syntax → BlockNote inline content (styled text + links). */
export function parseInline(text, styles = {}) {
    const out = [];
    let last = 0;
    const source = String(text ?? '');
    // Re-entrant: nested calls reset `lastIndex`, so walk with a local copy.
    const re = new RegExp(INLINE_TOKEN_RE.source, INLINE_TOKEN_RE.flags);
    let m;
    while ((m = re.exec(source)) !== null) {
        if (m.index > last) pushText(out, source.slice(last, m.index), styles);
        if (m[1] !== undefined) {
            pushText(out, m[2], { ...styles, code: true });
        } else if (m[3] !== undefined) {
            if (UNSAFE_HREF_RE.test(m[4])) out.push(...parseInline(m[3], styles));
            else out.push({ type: 'link', href: m[4], content: parseInline(m[3], styles) });
        } else if (m[5] !== undefined) {
            out.push(...parseInline(m[6], { ...styles, bold: true }));
        } else if (m[7] !== undefined) {
            out.push(...parseInline(m[7], { ...styles, strike: true }));
        } else {
            out.push(...parseInline(m[8] ?? m[9], { ...styles, italic: true }));
        }
        last = re.lastIndex;
    }
    if (last < source.length) pushText(out, source.slice(last), styles);
    return mergeRuns(out);
}

function pushText(out, text, styles) {
    if (text) out.push({ type: 'text', text, styles: { ...styles } });
}

function sameStyles(a, b) {
    const ka = Object.keys(a);
    return ka.length === Object.keys(b).length && ka.every((k) => a[k] === b[k]);
}

function mergeRuns(runs) {
    const out = [];
    for (const run of runs) {
        const prev = out[out.length - 1];
        if (run.type === 'text' && prev && prev.type === 'text' && sameStyles(prev.styles, run.styles)) {
            prev.text += run.text;
        } else {
            out.push(run);
        }
    }
    return out;
}

function inlineText(content) {
    if (!Array.isArray(content)) return '';
    return content.map((r) => (r.type === 'link' ? inlineText(r.content) : r.text || '')).join('');
}

// ---------------------------------------------------------- markdown → blocks

function block(type, content, props = {}) {
    return { type, props, content, children: [] };
}

function listItemBlock(type, rest) {
    const check = type === 'bulletListItem' ? rest.match(CHECK_MARK_RE) : null;
    if (!check) return block(type, parseInline(rest));
    const mark = check[1].toLowerCase();
    const styles = mark === '~' ? { backgroundColor: ON_HOLD_BACKGROUND } : {};
    return block('checkListItem', parseInline(rest.slice(check[0].length), styles), { checked: mark === 'x' });
}

/// Returns one image block per `![name](url)` token when `text` consists of
/// nothing else, otherwise null (so `![x](y)` inside a sentence stays prose).
/// `blocksToMarkdownLossy` writes consecutive image blocks on a single line.
function imageOnlyLine(text) {
    const token = /!\[([^\]]*)\]\(([^)\s]+)\)/g;
    const blocks = [];
    let cursor = 0;
    let m;
    while ((m = token.exec(text)) !== null) {
        if (m.index !== cursor) return null;
        cursor = token.lastIndex;
        blocks.push({ type: 'image', props: { url: m[2], name: m[1] }, children: [] });
    }
    return blocks.length && cursor === text.length ? blocks : null;
}

function splitTableRow(line) {
    let s = line.trim();
    if (s.startsWith('|')) s = s.slice(1);
    if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1);
    return s.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, '|'));
}

function tableBlock(rowLines) {
    const rows = rowLines.map(splitTableRow);
    const width = Math.max(...rows.map((r) => r.length));
    return {
        type: 'table',
        props: {},
        content: {
            type: 'tableContent',
            rows: rows.map((cells) => ({
                cells: Array.from({ length: width }, (_, i) => parseInline(cells[i] ?? '')),
            })),
        },
        children: [],
    };
}

function lineWidth(leading) {
    let w = 0;
    for (const ch of leading) w += ch === '\t' ? INDENT_UNIT.length : 1;
    return w;
}

function commonIndent(lines) {
    let min = Infinity;
    for (const line of lines) {
        if (!line.trim()) continue;
        min = Math.min(min, lineWidth(line.match(/^[ \t]*/)[0]));
    }
    return Number.isFinite(min) ? min : 0;
}

/**
 * Markdown → BlockNote blocks. Nesting follows indentation *relative* to the
 * enclosing item, so 2-space, 3-space, 4-space and tab-indented lists all
 * produce the same tree, and a block copied with a shared left margin (e.g.
 * out of a terminal) is dedented first.
 */
export function markdownToBlocks(md) {
    const lines = String(md ?? '').replace(/\r\n?/g, '\n').replace(/\u00a0/g, ' ').split('\n');
    const baseIndent = commonIndent(lines);
    const root = { children: [] };
    const stack = [{ width: -1, block: root }];
    const attach = (width, b) => {
        while (stack.length > 1 && stack[stack.length - 1].width >= width) stack.pop();
        stack[stack.length - 1].block.children.push(b);
    };

    for (let i = 0; i < lines.length; i++) {
        const raw = lines[i];
        if (!raw.trim()) continue;
        const leading = raw.match(/^[ \t]*/)[0];
        const width = Math.max(0, lineWidth(leading) - baseIndent);
        const text = raw.slice(leading.length).replace(/\s+$/, '');

        if (/^<!--.*-->$/.test(text)) continue;

        const fence = text.match(/^(`{3,}|~{3,})\s*([\w+#.-]*)/);
        if (fence) {
            const body = [];
            let j = i + 1;
            for (; j < lines.length; j++) {
                if (lines[j].trim().startsWith(fence[1])) break;
                body.push(lines[j].slice(Math.min(lineWidth(lines[j].match(/^[ \t]*/)[0]), width + baseIndent)));
            }
            i = j;
            const props = fence[2] ? { language: fence[2].toLowerCase() } : {};
            attach(width, { type: 'codeBlock', props, content: [{ type: 'text', text: body.join('\n'), styles: {} }], children: [] });
            continue;
        }

        if (text.startsWith('|') && i + 1 < lines.length && TABLE_SEPARATOR_RE.test(lines[i + 1].trim())) {
            const rowLines = [text];
            let j = i + 2;
            for (; j < lines.length && lines[j].trim().startsWith('|'); j++) rowLines.push(lines[j]);
            i = j - 1;
            attach(width, tableBlock(rowLines));
            continue;
        }

        const images = imageOnlyLine(text);
        if (images) {
            for (const img of images) attach(width, img);
            stack.push({ width, block: images[images.length - 1] });
            continue;
        }

        let b;
        let m;
        if ((m = text.match(HEADING_RE))) {
            b = block('heading', parseInline(m[2]), { level: Math.min(m[1].length, MAX_HEADING_LEVEL) });
        } else if ((m = text.match(BULLET_RE))) {
            b = listItemBlock('bulletListItem', m[2]);
        } else if ((m = text.match(ORDERED_RE))) {
            b = block('numberedListItem', parseInline(m[2]));
        } else if ((m = text.match(CHECK_MARK_RE))) {
            b = listItemBlock('bulletListItem', text);
        } else {
            b = block('paragraph', parseInline(text));
        }
        attach(width, b);
        stack.push({ width, block: b });
    }
    return root.children;
}

/**
 * Whether pasted plain text should become blocks rather than run into the
 * caret's line. Multi-line text always does (each line is a block anyway);
 * a single line only when it is itself a block marker (`- `, `1. `, `# `,
 * `[ ] `), and the caller decides whether the caret's block is empty enough
 * for that to make sense.
 */
export function plainTextShape(text) {
    const lines = String(text ?? '').replace(/\r\n?/g, '\n').split('\n').filter((l) => l.trim());
    if (lines.length === 0) return 'empty';
    if (lines.length > 1) return 'blocks';
    const t = lines[0].trim();
    return HEADING_RE.test(t) || BULLET_RE.test(t) || ORDERED_RE.test(t) || CHECK_MARK_RE.test(t)
        ? 'marker-line'
        : 'inline';
}

// ---------------------------------------------------------- blocks → markdown

function escapeTableCell(s) {
    return s.replace(/\|/g, '\\|').replace(/\n/g, ' ');
}

/** Inline content → markdown. Colors/underline have no markdown form and drop. */
export function inlineToMarkdown(content) {
    if (!Array.isArray(content)) return '';
    return content.map((run) => {
        if (run.type === 'link') return `[${inlineToMarkdown(run.content)}](${run.href})`;
        let t = run.text || '';
        if (!t) return '';
        const s = run.styles || {};
        if (s.code) return '`' + t + '`';
        // Markers must hug the text: `** a**` is not bold in any renderer.
        const [, lead, core, trail] = t.match(/^(\s*)([\s\S]*?)(\s*)$/);
        if (!core) return t;
        let wrapped = core;
        if (s.strike) wrapped = `~~${wrapped}~~`;
        if (s.italic) wrapped = `*${wrapped}*`;
        if (s.bold) wrapped = `**${wrapped}**`;
        return lead + wrapped + trail;
    }).join('');
}

function isOnHold(b) {
    return b.type === 'checkListItem' && !(b.props && b.props.checked)
        && Array.isArray(b.content)
        && b.content.some((r) => r.styles && r.styles.backgroundColor === ON_HOLD_BACKGROUND);
}

/**
 * Blocks → compact ("tight") markdown for the plain-text clipboard flavour:
 * `-` bullets, one line per item, children indented four spaces (valid under
 * both `- ` and `1. ` parents in CommonMark, GFM, Slack and Obsidian).
 * `onHoldMark` lets Dayflow-bound text keep `[~]` while other apps get `[ ]`.
 */
export function blocksToMarkdown(blocks, { onHoldMark = '[ ]' } = {}) {
    const out = [];
    const walk = (list, depth) => {
        let ordinal = 0;
        for (const b of list) {
            const pad = INDENT_UNIT.repeat(depth);
            ordinal = b.type === 'numberedListItem' ? ordinal + 1 : 0;
            const text = inlineToMarkdown(b.content);
            switch (b.type) {
                case 'heading':
                    out.push(pad + '#'.repeat((b.props && b.props.level) || 1) + ' ' + text);
                    break;
                case 'bulletListItem':
                    out.push(pad + '- ' + text);
                    break;
                case 'numberedListItem':
                    out.push(pad + ordinal + '. ' + text);
                    break;
                case 'checkListItem': {
                    const mark = b.props && b.props.checked ? '[x]' : isOnHold(b) ? onHoldMark : '[ ]';
                    out.push(pad + '- ' + mark + ' ' + text);
                    break;
                }
                case 'codeBlock': {
                    const lang = (b.props && b.props.language) || '';
                    const body = inlineText(b.content).split('\n').map((l) => pad + l);
                    out.push(pad + '```' + (lang === 'text' ? '' : lang), ...body, pad + '```');
                    break;
                }
                case 'table': {
                    const rows = (b.content && b.content.rows) || [];
                    rows.forEach((row, r) => {
                        const cells = row.cells.map((c) => escapeTableCell(inlineToMarkdown(Array.isArray(c) ? c : c.content)));
                        out.push(pad + '| ' + cells.join(' | ') + ' |');
                        if (r === 0) out.push(pad + '|' + cells.map(() => ' --- ').join('|') + '|');
                    });
                    break;
                }
                case 'image':
                    out.push(pad + `![${(b.props && b.props.name) || ''}](${(b.props && b.props.url) || ''})`);
                    break;
                default:
                    out.push(pad + text);
            }
            if (b.children && b.children.length) walk(b.children, depth + 1);
        }
    };
    walk(blocks || [], 0);
    return out.join('\n');
}

// ---------------------------------------------------------------- HTML → blocks

const BLOCK_TAGS = new Set([
    'P', 'DIV', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'UL', 'OL', 'LI', 'PRE', 'BLOCKQUOTE',
    'TABLE', 'THEAD', 'TBODY', 'TFOOT', 'TR', 'HR', 'SECTION', 'ARTICLE', 'MAIN', 'HEADER',
    'FOOTER', 'ASIDE', 'NAV', 'FIGURE', 'FIGCAPTION', 'DL', 'DT', 'DD', 'DETAILS', 'SUMMARY',
]);
const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'META', 'LINK', 'TITLE', 'HEAD', 'NOSCRIPT', 'TEMPLATE', 'svg', 'SVG']);
const LIST_TAGS = new Set(['UL', 'OL']);
const TEXT_COLORS = ['gray', 'brown', 'red', 'orange', 'yellow', 'green', 'blue', 'purple', 'pink'];

function isBlockElement(node) {
    return node.nodeType === 1 && BLOCK_TAGS.has(node.tagName);
}

function stylesFor(el, inherited) {
    const s = { ...inherited };
    const tag = el.tagName;
    const css = el.style || {};
    const weight = css.fontWeight;
    if ((tag === 'B' || tag === 'STRONG') && weight !== 'normal' && weight !== '400') s.bold = true;
    if (weight === 'bold' || weight === 'bolder' || Number(weight) >= 600) s.bold = true;
    if (weight === 'normal' || weight === '400') delete s.bold;
    if (tag === 'I' || tag === 'EM' || css.fontStyle === 'italic') s.italic = true;
    if (tag === 'U' || tag === 'INS') s.underline = true;
    if (tag === 'S' || tag === 'DEL' || tag === 'STRIKE') s.strike = true;
    const deco = css.textDecorationLine || css.textDecoration || '';
    if (deco.includes('underline')) s.underline = true;
    if (deco.includes('line-through')) s.strike = true;
    if (tag === 'CODE' || tag === 'KBD' || tag === 'SAMP') s.code = true;
    // BlockNote marks colors this way in both of its HTML flavours; keep them
    // so an in-app copy/paste round-trips highlights and the on-hold mark.
    if (el.getAttribute) {
        const text = el.getAttribute('data-text-color');
        const background = el.getAttribute('data-background-color');
        if (TEXT_COLORS.includes(text)) s.textColor = text;
        if (TEXT_COLORS.includes(background)) s.backgroundColor = background;
    }
    return s;
}

function collectInline(node, styles, out, pre) {
    if (node.nodeType === 3) {
        const text = pre ? node.nodeValue : node.nodeValue.replace(/[\t\n\r ]+/g, ' ');
        pushText(out, text, styles);
        return;
    }
    if (node.nodeType !== 1 || SKIP_TAGS.has(node.tagName)) return;
    const tag = node.tagName;
    if (tag === 'BR') { pushText(out, '\n', styles); return; }
    if (tag === 'INPUT' || tag === 'IMG' || tag === 'BUTTON') return;
    const next = stylesFor(node, styles);
    if (tag === 'A' && node.getAttribute('href') && !UNSAFE_HREF_RE.test(node.getAttribute('href'))) {
        const inner = [];
        for (const c of node.childNodes) collectInline(c, next, inner, pre);
        const content = mergeRuns(inner);
        if (content.length) out.push({ type: 'link', href: node.getAttribute('href'), content });
        return;
    }
    for (const c of node.childNodes) collectInline(c, next, out, pre || tag === 'PRE');
}

/** Trim collapsed whitespace at the edges of a block's inline content. */
function trimInline(runs) {
    const out = mergeRuns(runs);
    while (out.length && out[0].type === 'text' && !out[0].text.replace(/^[ \n]+/, '')) out.shift();
    while (out.length && out[out.length - 1].type === 'text' && !out[out.length - 1].text.replace(/[ \n]+$/, '')) out.pop();
    if (out.length && out[0].type === 'text') out[0].text = out[0].text.replace(/^[ \n]+/, '');
    const tail = out[out.length - 1];
    if (tail && tail.type === 'text') tail.text = tail.text.replace(/[ \n]+$/, '');
    return out;
}

function inlineOf(nodes, styles = {}) {
    const runs = [];
    for (const n of nodes) collectInline(n, styles, runs, false);
    return trimInline(runs);
}

function checkStateOf(li) {
    // Only look at this item's own line, not at nested sub-lists.
    const own = [...li.querySelectorAll('input[type="checkbox"], [role="checkbox"], .checkbox')]
        .find((el) => el.closest('li') === li);
    const cls = (li.className && String(li.className)) || '';
    const attr = li.getAttribute('data-checked') ?? li.getAttribute('aria-checked');
    if (own) {
        const checked = own.checked || own.hasAttribute('checked')
            || own.getAttribute('aria-checked') === 'true'
            || /checkbox-on|checked/.test(String(own.className || ''));
        return { checked: !!checked };
    }
    if (attr === 'true' || attr === 'false') return { checked: attr === 'true' };
    if (/task-list-item|to-do/.test(cls)) return { checked: /checked/.test(cls) && !/unchecked/.test(cls) };
    return null;
}

function listItemFromLi(li, ordered) {
    const own = [];
    const nested = [];
    for (const c of li.childNodes) (c.nodeType === 1 && LIST_TAGS.has(c.tagName) ? nested : own).push(c);
    // `<li><p>text</p><p>more</p></li>`: first block is the item's line, the
    // rest become children, followed by any nested list.
    const ownBlocks = nodesToBlocks(own);
    const first = ownBlocks[0];
    const leadIsLine = first && Array.isArray(first.content) && !first.children.length
        && (first.type === 'paragraph' || first.type === 'heading');
    const content = leadIsLine ? first.content : [];
    const children = [...(leadIsLine ? ownBlocks.slice(1) : ownBlocks)];
    for (const list of nested) children.push(...listToBlocks(list));

    const state = checkStateOf(li);
    let item;
    if (state) {
        item = block('checkListItem', content, { checked: state.checked });
    } else {
        const text = inlineText(content);
        const mark = !ordered && CHECK_MARK_RE.test(text);
        if (mark) {
            item = listItemBlock('bulletListItem', inlineToMarkdown(content));
        } else {
            item = block(ordered ? 'numberedListItem' : 'bulletListItem', content);
        }
    }
    item.children = children;
    return item;
}

function listToBlocks(list) {
    const ordered = list.tagName === 'OL';
    const items = [];
    for (const c of list.childNodes) {
        if (c.nodeType !== 1) continue;
        if (c.tagName === 'LI') {
            items.push(listItemFromLi(c, ordered));
        } else if (LIST_TAGS.has(c.tagName)) {
            // Google Docs and some rich editors nest `<ul>` directly inside
            // `<ul>` instead of inside the preceding `<li>`.
            const sub = listToBlocks(c);
            if (items.length) items[items.length - 1].children.push(...sub);
            else items.push(...sub);
        } else {
            items.push(...nodesToBlocks([c]));
        }
    }
    return items;
}

function tableFromElement(table) {
    const rows = [...table.querySelectorAll('tr')].filter((tr) => tr.closest('table') === table);
    if (!rows.length) return null;
    const cellRows = rows.map((tr) => [...tr.children].filter((c) => c.tagName === 'TD' || c.tagName === 'TH'));
    const width = Math.max(...cellRows.map((r) => r.length));
    if (!width) return null;
    return {
        type: 'table',
        props: {},
        content: {
            type: 'tableContent',
            rows: cellRows.map((cells) => ({
                cells: Array.from({ length: width }, (_, i) => (cells[i] ? inlineOf([...cells[i].childNodes]) : [])),
            })),
        },
        children: [],
    };
}

// Code text with `<br>` as line breaks (BlockNote writes code blocks that way).
function preText(el) {
    let out = '';
    for (const c of el.childNodes) {
        if (c.nodeType === 3) out += c.nodeValue;
        else if (c.nodeType === 1) out += c.tagName === 'BR' ? '\n' : preText(c);
    }
    return out;
}

function isLocalImage(src) {
    // The editor CSP only admits `dayflow-asset:` (and data:) images; a remote
    // URL would render as an empty box and leak a request if CSP ever loosened.
    return /^dayflow-asset:\/\//.test(src) || /^data:image\//.test(src);
}

function elementToBlocks(el) {
    const tag = el.tagName;
    if (SKIP_TAGS.has(tag)) return [];
    if (LIST_TAGS.has(tag)) return listToBlocks(el);
    if (tag === 'LI') return listToBlocks({ tagName: 'UL', childNodes: [el] });
    if (/^H[1-6]$/.test(tag)) {
        const content = inlineOf([...el.childNodes]);
        return content.length ? [block('heading', content, { level: Math.min(Number(tag[1]), MAX_HEADING_LEVEL) })] : [];
    }
    if (tag === 'PRE') {
        const code = el.querySelector('code');
        const lang = ((code && code.className) || '').match(/language-([\w+#.-]+)/);
        const text = preText(el).replace(/\n$/, '');
        return [{ type: 'codeBlock', props: lang ? { language: lang[1] } : {}, content: [{ type: 'text', text, styles: {} }], children: [] }];
    }
    if (tag === 'TABLE') {
        const t = tableFromElement(el);
        return t ? [t] : [];
    }
    if (tag === 'HR') return [block('paragraph', [{ type: 'text', text: '---', styles: {} }])];
    if (tag === 'IMG') {
        const src = el.getAttribute('src') || '';
        return isLocalImage(src) ? [{ type: 'image', props: { url: src, name: el.getAttribute('alt') || '' }, children: [] }] : [];
    }
    if (tag === 'P' || tag === 'DT' || tag === 'DD' || tag === 'SUMMARY' || tag === 'FIGCAPTION') {
        if (![...el.childNodes].some(isBlockElement)) {
            const content = inlineOf([...el.childNodes]);
            const images = [...el.querySelectorAll('img')].flatMap(elementToBlocks);
            return [...(content.length ? [block('paragraph', content)] : []), ...images];
        }
    }
    // Containers (div, section, blockquote, Google Docs' `<b id=docs-internal-guid-…>` wrapper, …).
    return nodesToBlocks([...el.childNodes], stylesFor(el, {}));
}

/**
 * DOM nodes → blocks. Runs of inline nodes between block elements become one
 * paragraph; block elements recurse. Inline wrappers that contain blocks
 * (e.g. `<b><p>…</p></b>`) are treated as containers.
 */
function nodesToBlocks(nodes, styles = {}) {
    const out = [];
    let inline = [];
    const flush = () => {
        const content = inlineOf(inline, styles);
        if (content.length) out.push(block('paragraph', content));
        inline = [];
    };
    for (const n of nodes) {
        if (n.nodeType === 1 && !SKIP_TAGS.has(n.tagName)
            && (isBlockElement(n) || n.tagName === 'IMG' || (n.querySelector && n.querySelector('p,div,ul,ol,li,h1,h2,h3,h4,h5,h6,pre,table')))) {
            flush();
            out.push(...elementToBlocks(n));
        } else {
            inline.push(n);
        }
    }
    flush();
    return out;
}

/** Clipboard HTML → blocks. `doc` is a parsed Document (DOMParser). */
export function htmlToBlocks(doc) {
    return nodesToBlocks([...doc.body.childNodes]);
}

/**
 * Whether clipboard HTML carries structure worth taking over from the
 * default paste (lists, headings, tables, code, several paragraphs). A single
 * run of inline text is better left to ProseMirror, which merges it into the
 * caret's line.
 */
export function htmlHasBlockStructure(doc) {
    const body = doc.body;
    if (!body) return false;
    if (body.querySelector('li, h1, h2, h3, h4, h5, h6, pre, table, hr')) return true;
    return body.querySelectorAll('p, div, br').length > 1 && htmlToBlocks(doc).length > 1;
}

// ------------------------------------------------ BlockNote internal HTML → blocks

// BlockNote's `blocknote/html` flavour is its editor DOM: nested
// `blockContainer`s, each with one `.bn-block-content[data-content-type]` and
// an optional child `blockGroup`. It is the only flavour that keeps every
// nesting (the external HTML flattens children of non-list blocks) and block
// props, but BlockNote 0.22 parses it back with each block duplicated into an
// empty copy of itself, so we read it ourselves.

const NUMERIC_PROPS = new Set(['level', 'previewWidth']);
const IGNORED_CONTENT_ATTRS = new Set(['data-content-type', 'data-file-block', 'data-pm-slice']);

function kebabToCamel(s) {
    return s.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
}

function contentProps(contentEl) {
    const props = {};
    for (const { name, value } of [...contentEl.attributes]) {
        if (!name.startsWith('data-') || IGNORED_CONTENT_ATTRS.has(name)) continue;
        const key = kebabToCamel(name.slice(5));
        props[key] = value === 'true' ? true : value === 'false' ? false
            : NUMERIC_PROPS.has(key) && value !== '' && !Number.isNaN(Number(value)) ? Number(value) : value;
    }
    return props;
}

function childElements(el, predicate) {
    return [...el.children].filter(predicate);
}

const isContainer = (el) => el.getAttribute('data-node-type') === 'blockContainer';
const isGroup = (el) => el.getAttribute('data-node-type') === 'blockGroup';
const isOuter = (el) => el.getAttribute('data-node-type') === 'blockOuter';

function groupToBlocks(group) {
    const out = [];
    for (const child of group.children) {
        if (isGroup(child)) {
            out.push(...groupToBlocks(child));
            continue;
        }
        const containers = isOuter(child) ? childElements(child, isContainer) : isContainer(child) ? [child] : [];
        for (const c of containers) out.push(...containerToBlocks(c));
    }
    return out;
}

function containerToBlocks(container) {
    const contentEl = [...container.children].find((c) => c.classList.contains('bn-block-content'));
    const children = childElements(container, isGroup).flatMap(groupToBlocks);
    // A copy that starts inside a nested block carries its ancestors as
    // content-less containers (ProseMirror's open slice). They are not part of
    // the selection; lift their children instead of pasting empty parents.
    if (!contentEl) return children;

    const type = contentEl.getAttribute('data-content-type');
    const props = contentProps(contentEl);
    for (const key of ['textColor', 'backgroundColor']) {
        const v = container.getAttribute('data-' + key.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase()));
        if (v) props[key] = v;
    }
    let content;
    if (type === 'table') {
        const table = contentEl.querySelector('table');
        content = table ? tableFromElement(table).content : undefined;
    } else if (type === 'codeBlock') {
        const code = contentEl.querySelector('code') || contentEl;
        const lang = String(code.className || '').match(/language-([\w+#.-]+)/);
        if (lang && !props.language) props.language = lang[1];
        content = [{ type: 'text', text: preText(code), styles: {} }];
    } else if (type === 'checkListItem') {
        const box = contentEl.querySelector('input[type="checkbox"]');
        props.checked = props.checked === true || !!(box && (box.checked || box.hasAttribute('checked')));
        const inline = contentEl.querySelector('.bn-inline-content');
        content = inline ? inlineOf([...inline.childNodes]) : [];
    } else {
        const inline = contentEl.querySelector('.bn-inline-content');
        content = inline ? inlineOf([...inline.childNodes]) : undefined;
    }
    const b = { type, props, children };
    if (content !== undefined) b.content = content;
    return [b];
}

/** `blocknote/html` → blocks, or null when the copy sits inside one block. */
export function blockNoteHtmlToBlocks(doc) {
    const top = [...doc.body.children];
    if (!top.some((el) => isGroup(el) || isOuter(el) || isContainer(el))) return null;
    return groupToBlocks(doc.body);
}
