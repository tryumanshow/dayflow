import Foundation
import UniformTypeIdentifiers

/// On-disk home for files pasted or dropped into the editor.
///
/// Notes stay small and text-only: the markdown body carries
/// `![](dayflow-asset://attachment/<name>)` and the bytes live next to
/// `dayflow.db` under `~/Library/Application Support/Dayflow/attachments/`.
/// Inlining base64 into the body would have doubled every note read and
/// grown the SQLite file by megabytes per screenshot.
///
/// The store is content-addressed by SHA-free random name rather than by
/// hash: two pastes of the same screenshot are two files. That is the
/// cheap, obviously-correct choice — dedup would need refcounting across
/// day notes and month-plan sections to know when a file is orphaned.
enum AttachmentStore {
    /// Refuse anything larger than this. A pasted image arrives as base64
    /// over the JS bridge, so the real cost is ~1.34× this number in a
    /// single `WKScriptMessage` allocation.
    static let maxBytes = 24 * 1024 * 1024

    enum Failure: Error, LocalizedError {
        case tooLarge(Int)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let n): return "File is \(n / 1_048_576)MB; the limit is \(maxBytes / 1_048_576)MB."
            case .unwritable(let p): return "Could not write attachment to \(p)."
            }
        }
    }

    /// `<Application Support>/Dayflow/attachments`, created on demand.
    /// Derived from `DayflowDB.defaultPath` so a future relocation of the
    /// database drags the attachments along instead of stranding them.
    static var directory: URL {
        URL(fileURLWithPath: DayflowDB.defaultPath)
            .deletingLastPathComponent()
            .appendingPathComponent("attachments", isDirectory: true)
    }

    /// Persist `data` and return the opaque file name to reference it by.
    /// The extension is taken from the browser-supplied MIME type, falling
    /// back to the original file name, so `Preview.app` screenshots (which
    /// arrive as `image.png` with `image/png`) and dragged-in `.heic`
    /// files both land with a usable suffix.
    static func save(_ data: Data, mimeType: String?, originalName: String?) throws -> String {
        guard data.count <= maxBytes else { throw Failure.tooLarge(data.count) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let ext = fileExtension(mimeType: mimeType, originalName: originalName)
        let name = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let dest = directory.appendingPathComponent(name)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            throw Failure.unwritable(dest.path)
        }
        return name
    }

    /// Resolve a name that arrived from the web view back to a file inside
    /// `directory`. Rejects traversal (`../…`, absolute paths, symlinks that
    /// escape) — the editor origin must never be able to read arbitrary
    /// files off disk through the asset scheme.
    static func fileURL(forName name: String) -> URL? {
        guard !name.isEmpty,
              !name.hasPrefix("."),
              !name.contains("/"),
              !name.contains("\\"),
              name == (name as NSString).lastPathComponent
        else { return nil }

        let candidate = directory.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(root.path + "/") else { return nil }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    /// The URL the editor stores in the note body. A second host on the
    /// private scheme (`attachment`, not `editor`) keeps user bytes on a
    /// distinct origin from the vendored JS.
    static func assetURL(forName name: String) -> String {
        "dayflow-asset://attachment/\(name)"
    }

    static func mimeType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func fileExtension(mimeType: String?, originalName: String?) -> String {
        if let mimeType, let type = UTType(mimeType: mimeType), let ext = type.preferredFilenameExtension {
            return ext
        }
        if let originalName {
            let ext = (originalName as NSString).pathExtension
            if !ext.isEmpty { return ext.lowercased() }
        }
        return ""
    }
}
