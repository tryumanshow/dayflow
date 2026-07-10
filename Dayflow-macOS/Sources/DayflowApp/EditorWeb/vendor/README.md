# Vendored editor assets

The tree under `esm/` is fetched verbatim from esm.sh and served to the editor
`WKWebView` over the private `dayflow-asset://editor/` scheme (see
`EditorSchemeHandler.swift`), so the app never reaches the network at runtime.

Anything listed below is a **local deviation** from the upstream artifact and
must be re-applied whenever the bundle is re-vendored. `VendoredBundleTests`
fails the test run if a patch goes missing.

## 1. `serializeForClipboard` bundled as `(void 0)`

**File:** `esm/@blocknote/core@0.22.0/…/es2022/core.bundle.mjs`

esm.sh builds `@blocknote/core` with `prosemirror-view` marked external, but the
generated bundle does not import `serializeForClipboard` from it — every call
site is emitted as the literal `(void 0)`, i.e. `undefined`. The two call sites
are BlockNote's `copyToClipboard` extension and its side-menu drag handler.

At runtime, copying inside the editor ran

```js
n.preventDefault();
n.clipboardData.clearData();
let {clipboardHTML, externalHTML, markdown} = getCopyableContent(...); // throws
n.clipboardData.setData("blocknote/html", clipboardHTML);              // never runs
```

so `⌘C` / `⌘X` threw `TypeError: (void 0) is not a function`, wrote nothing to
the pasteboard, and — because the default action had already been suppressed —
left the previous clipboard contents in place. Dragging a block had the same
fault. Pasting was unaffected, which is why the symptom read as "copy/paste is
flaky" rather than "copy is dead".

**Patch:** rewrite both call sites to `mh(...)`, the bundle's own minified copy
of `prosemirror-view`'s `serializeForClipboard` (same `(view, slice)` signature,
same `{dom, text, slice}` return). Verified by the fact that ProseMirror's own
`copy` handler in this bundle calls `mh(view, slice)` and destructures
`{dom, text}` from it.

```
sed -i '' 's/(void 0)(/mh(/g' core.bundle.mjs
```

Upstream is fixed in later BlockNote/esm.sh builds; drop this patch when the
bundle is regenerated and the guard test still passes without it.
