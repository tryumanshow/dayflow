// Unit tests for the DOM-free half of EditorWeb/app/clipboard.mjs.
// Run: node --test Dayflow-macOS/Tests/EditorWeb/*.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
    markdownToBlocks, blocksToMarkdown, parseInline, plainTextShape,
} from '../../Sources/DayflowApp/EditorWeb/app/clipboard.mjs';

/** Compact tree view: `type[flag]: text` per line, two spaces per depth. */
function outline(blocks, depth = 0) {
    return blocks.map((b) => {
        const text = Array.isArray(b.content)
            ? b.content.map((r) => (r.type === 'link' ? r.content.map((c) => c.text).join('') : r.text)).join('')
            : '';
        const flag = b.type === 'checkListItem' ? (b.props.checked ? '[x]' : '[ ]') : '';
        return '  '.repeat(depth) + `${b.type}${flag}: ${text}\n` + outline(b.children || [], depth + 1);
    }).join('');
}

const TREE = [
    'bulletListItem: 부모',
    '  bulletListItem: 자식',
    '    checkListItem[x]: 손자',
    'bulletListItem: 둘째',
    '',
].join('\n');

test('nesting is relative to the parent, whatever the indent unit', () => {
    for (const unit of ['  ', '   ', '    ', '\t']) {
        const md = `- 부모\n${unit}- 자식\n${unit}${unit}- [x] 손자\n- 둘째`;
        assert.equal(outline(markdownToBlocks(md)), TREE, JSON.stringify(unit));
    }
});

test('a shared left margin (terminal copy) is dedented', () => {
    assert.equal(outline(markdownToBlocks('    - 부모\n      - 자식\n        - [x] 손자\n    - 둘째')), TREE);
});

test('BlockNote loose list output round-trips (stored markdown shape)', () => {
    const md = '*   부모\n\n    *   자식\n\n        *   [x] 손자\n\n*   둘째\n';
    assert.equal(outline(markdownToBlocks(md)), TREE);
});

test('checkbox marks, including on-hold', () => {
    const blocks = markdownToBlocks('- [ ] 열림\n- [x] 완료\n- [X] 완료2\n- [~] 보류\n[ ] 맨체크');
    assert.equal(outline(blocks), [
        'checkListItem[ ]: 열림', 'checkListItem[x]: 완료', 'checkListItem[x]: 완료2',
        'checkListItem[ ]: 보류', 'checkListItem[ ]: 맨체크', '',
    ].join('\n'));
    assert.equal(blocks[3].content[0].styles.backgroundColor, 'blue');
});

test('bullets, numbers, headings', () => {
    const md = '# H1\n#### H4\n• 점\n+ 플러스\n1. 하나\n2) 둘\n   - 둘 밑';
    assert.equal(outline(markdownToBlocks(md)), [
        'heading: H1', 'heading: H4', 'bulletListItem: 점', 'bulletListItem: 플러스',
        'numberedListItem: 하나', 'numberedListItem: 둘', '  bulletListItem: 둘 밑', '',
    ].join('\n'));
    assert.equal(markdownToBlocks('#### H4')[0].props.level, 3);
});

test('Korean dates stay paragraphs; rules become dividers', () => {
    assert.equal(outline(markdownToBlocks('2026. 9. 24 회의\n---\n***\n*강조*')),
        'paragraph: 2026. 9. 24 회의\ndivider: \ndivider: \nparagraph: 강조\n');
    assert.equal(blocksToMarkdown(markdownToBlocks('위\n---\n아래')), '위\n---\n아래');
});

test('fenced code keeps its body verbatim, including list-looking lines', () => {
    const blocks = markdownToBlocks('```python\n# not a heading\n- not a bullet\n```\n- after');
    assert.equal(blocks[0].type, 'codeBlock');
    assert.equal(blocks[0].props.language, 'python');
    assert.equal(blocks[0].content[0].text, '# not a heading\n- not a bullet');
    assert.equal(blocks[1].type, 'bulletListItem');
});

test('GFM tables become table blocks', () => {
    const [t] = markdownToBlocks('| a | b |\n|---|:-:|\n| 1 | **2** |');
    assert.equal(t.type, 'table');
    assert.equal(t.content.rows.length, 2);
    assert.equal(t.content.rows[1].cells[1][0].text, '2');
    assert.equal(t.content.rows[1].cells[1][0].styles.bold, true);
});

test('image-only lines become image blocks; HTML comments are skipped', () => {
    const blocks = markdownToBlocks('<!-- x -->\n![a.png](dayflow-asset://attachment/a.png)![b](dayflow-asset://attachment/b.png)\n말 ![c](u) 중간');
    assert.deepEqual(blocks.map((b) => b.type), ['image', 'image', 'paragraph']);
});

test('inline markdown', () => {
    assert.deepEqual(parseInline('a **b** *c* ~~d~~ `e` [f](https://x.y) snake_case_name'), [
        { type: 'text', text: 'a ', styles: {} },
        { type: 'text', text: 'b', styles: { bold: true } },
        { type: 'text', text: ' ', styles: {} },
        { type: 'text', text: 'c', styles: { italic: true } },
        { type: 'text', text: ' ', styles: {} },
        { type: 'text', text: 'd', styles: { strike: true } },
        { type: 'text', text: ' ', styles: {} },
        { type: 'text', text: 'e', styles: { code: true } },
        { type: 'text', text: ' ', styles: {} },
        { type: 'link', href: 'https://x.y', content: [{ type: 'text', text: 'f', styles: {} }] },
        { type: 'text', text: ' snake_case_name', styles: {} },
    ]);
});

test('javascript: links are dropped to plain text', () => {
    assert.ok(!parseInline('[x](javascript:alert(1))').some((r) => r.type === 'link'));
});

test('blocksToMarkdown emits a tight list that parses back to the same tree', () => {
    const blocks = markdownToBlocks('- 부모 **굵게**\n  - 자식\n    - [x] 손자\n    - [~] 보류\n1. 하나\n2. 둘\n   - 밑');
    const md = blocksToMarkdown(blocks);
    assert.equal(md, [
        '- 부모 **굵게**',
        '    - 자식',
        '        - [x] 손자',
        '        - [ ] 보류',
        '1. 하나',
        '2. 둘',
        '    - 밑',
    ].join('\n'));
    assert.equal(outline(markdownToBlocks(md)), outline(blocks));
    assert.match(blocksToMarkdown(blocks, { onHoldMark: '[~]' }), /- \[~\] 보류/);
});

test('blocksToMarkdown keeps bold markers tight against the text', () => {
    const md = blocksToMarkdown([{ type: 'paragraph', props: {}, content: [
        { type: 'text', text: 'a', styles: {} }, { type: 'text', text: ' b ', styles: { bold: true } },
    ], children: [] }]);
    assert.equal(md, 'a **b** ');
});

test('plainTextShape', () => {
    assert.equal(plainTextShape(''), 'empty');
    assert.equal(plainTextShape('just words'), 'inline');
    assert.equal(plainTextShape('- one'), 'marker-line');
    assert.equal(plainTextShape('[ ] todo'), 'marker-line');
    assert.equal(plainTextShape('a\nb'), 'blocks');
    assert.equal(plainTextShape('\n\nonly\n\n'), 'inline');
});
