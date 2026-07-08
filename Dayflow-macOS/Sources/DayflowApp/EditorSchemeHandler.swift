import Foundation
import WebKit

/// Serves the locally-vendored BlockNote editor assets to the WKWebView over a
/// private `dayflow-asset://editor/` origin, replacing the previous runtime
/// fetch from `https://esm.sh`. The editor page is still handed to WKWebView as
/// an HTML string (via `loadHTMLString` with this scheme's base URL as the
/// origin); this handler answers the sub-resource requests the page makes —
/// the stylesheet, the entry module, and every module it transitively imports.
///
/// The vendored files live under `EditorWeb/vendor/esm/` mirroring esm.sh's own
/// absolute-path layout, so the modules' `/node/…` and `/@blocknote/…` imports
/// resolve against this origin root back onto the mirrored tree with no
/// rewriting of the module bodies.
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "dayflow-asset"
    /// Origin the editor page is loaded under. `'self'` in the page CSP equals
    /// this origin, which is why `script-src 'self'` covers every vendored module.
    static let baseURL = URL(string: "\(scheme)://editor/")!

    /// The copied `EditorWeb` resource directory inside the SPM bundle.
    private static let editorRoot: URL? =
        Bundle.module.resourceURL?.appendingPathComponent("EditorWeb")
        ?? Bundle.module.url(forResource: "EditorWeb", withExtension: nil)

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = Self.editorRoot else {
            task.didFailWithError(URLError(.badURL))
            return
        }

        // The page itself is `dayflow-asset://editor/index.html`; every module
        // and the stylesheet resolve to `dayflow-asset://editor/<path>` which
        // maps onto the mirrored `EditorWeb/vendor/esm/<path>` tree.
        var rel = url.path
        if rel.hasPrefix("/") { rel.removeFirst() }
        let fileURL: URL = (rel.isEmpty || rel == "index.html")
            ? root.appendingPathComponent("index.html")
            : root.appendingPathComponent("vendor/esm").appendingPathComponent(rel)

        guard let data = try? Data(contentsOf: fileURL) else {
            NSLog("dayflow: editor asset not found for \(url.absoluteString) -> \(fileURL.path)")
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": Self.mime(forExtension: fileURL.pathExtension)]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private static func mime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mjs", "js": return "text/javascript; charset=utf-8"
        case "css":       return "text/css; charset=utf-8"
        case "html":      return "text/html; charset=utf-8"
        case "json":      return "application/json; charset=utf-8"
        case "map":       return "application/json; charset=utf-8"
        case "wasm":      return "application/wasm"
        default:          return "application/octet-stream"
        }
    }
}
