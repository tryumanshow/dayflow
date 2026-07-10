import Foundation
import Testing

/// Guards the local repairs described in `EditorWeb/vendor/README.md`.
///
/// The BlockNote bundle is a checked-in esm.sh artifact, so a re-vendor is a
/// plain file overwrite with no build step to re-apply the patch. Without this
/// test the regression is invisible: copy still *looks* wired up, it just
/// silently leaves the pasteboard untouched.
struct VendoredBundleTests {
    /// Walks up from this source file to `Sources/DayflowApp/EditorWeb/vendor`.
    private static var vendorRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/DayflowAppTests/VendoredBundleTests.swift
            .deletingLastPathComponent()         // Tests/DayflowAppTests
            .deletingLastPathComponent()         // Tests
            .deletingLastPathComponent()         // Dayflow-macOS
            .appendingPathComponent("Sources/DayflowApp/EditorWeb/vendor")
    }

    private static func blockNoteBundle() throws -> String {
        let esm = vendorRoot.appendingPathComponent("esm/@blocknote")
        let files = FileManager.default.enumerator(at: esm, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "core.bundle.mjs" } ?? []
        let bundle = try #require(files.first)
        return try String(contentsOf: bundle, encoding: .utf8)
    }

    /// esm.sh emits `(void 0)` where `serializeForClipboard` should be. Calling it
    /// throws mid-way through BlockNote's copy handler — after `preventDefault()`
    /// and `clearData()`, before any `setData()` — so ⌘C/⌘X become silent no-ops.
    @Test func bundleHasNoUndefinedCallTargets() throws {
        let source = try Self.blockNoteBundle()
        #expect(!source.contains("(void 0)("),
                "vendored BlockNote calls an undefined symbol — re-apply the patch in EditorWeb/vendor/README.md")
    }

    /// The patch rewrites those call sites onto the bundle's own minified
    /// `serializeForClipboard`. If a re-vendor renames it, the patch is wrong
    /// rather than merely missing, so pin the symbol we aliased onto.
    @Test func serializeForClipboardAliasStillResolves() throws {
        let source = try Self.blockNoteBundle()
        #expect(source.contains(#"function mh(t,e){t.someProp("transformCopied""#),
                "`mh` is no longer prosemirror-view's serializeForClipboard")
        #expect(source.contains("mh(t,t.state.selection.content()).dom.innerHTML"),
                "BlockNote's copyToClipboard extension is not wired to serializeForClipboard")
    }

    /// Attachments are served from a second host on the private scheme, so the
    /// page CSP has to admit it or pasted images render as broken boxes.
    @Test func editorCSPAllowsAttachmentImages() throws {
        let html = try String(
            contentsOf: Self.vendorRoot.deletingLastPathComponent().appendingPathComponent("index.html"),
            encoding: .utf8
        )
        let csp = try #require(html.split(separator: "\n").first {
            $0.hasPrefix("<meta http-equiv=\"Content-Security-Policy\"")
        })
        #expect(csp.contains("img-src 'self' data: dayflow-asset:;"))
        // …and nothing else opened up in the process.
        #expect(csp.contains("connect-src 'none'"))
        #expect(csp.contains("default-src 'none'"))
    }
}
