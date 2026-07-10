import Foundation
import Testing
@testable import DayflowApp

/// `fileURL(forName:)` is the only thing standing between the editor origin and
/// the rest of the user's disk: the web view hands it a string lifted straight
/// out of a note body, which a synced/restored/hand-edited note could control.
struct AttachmentStoreTests {
    @Test func rejectsPathTraversal() {
        #expect(AttachmentStore.fileURL(forName: "../dayflow.db") == nil)
        #expect(AttachmentStore.fileURL(forName: "../../../../etc/passwd") == nil)
        #expect(AttachmentStore.fileURL(forName: "sub/dir/file.png") == nil)
        #expect(AttachmentStore.fileURL(forName: "..\\dayflow.db") == nil)
    }

    @Test func rejectsAbsoluteAndDotfileNames() {
        #expect(AttachmentStore.fileURL(forName: "/etc/passwd") == nil)
        #expect(AttachmentStore.fileURL(forName: ".ssh") == nil)
        #expect(AttachmentStore.fileURL(forName: "") == nil)
    }

    /// A name that passes validation but has no file behind it must not resolve —
    /// otherwise the scheme handler would answer 200 with zero bytes.
    @Test func rejectsMissingFile() {
        #expect(AttachmentStore.fileURL(forName: "\(UUID().uuidString).png") == nil)
    }

    @Test func roundTripsASavedFile() throws {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let name = try AttachmentStore.save(bytes, mimeType: "image/png", originalName: "shot.png")
        defer { try? FileManager.default.removeItem(at: AttachmentStore.directory.appendingPathComponent(name)) }

        #expect(name.hasSuffix(".png"))
        let resolved = try #require(AttachmentStore.fileURL(forName: name))
        #expect(try Data(contentsOf: resolved) == bytes)
        #expect(AttachmentStore.assetURL(forName: name) == "dayflow-asset://attachment/\(name)")
    }

    /// Screenshots arrive with a MIME type but a generic name; dragged files can
    /// arrive with a name and no MIME type. Both need a usable suffix so the
    /// scheme handler can answer with a decodable Content-Type.
    @Test func derivesExtensionFromMimeThenName() throws {
        let fromMime = try AttachmentStore.save(Data([0]), mimeType: "image/jpeg", originalName: "clipboard")
        let fromName = try AttachmentStore.save(Data([0]), mimeType: nil, originalName: "diagram.HEIC")
        defer {
            for n in [fromMime, fromName] {
                try? FileManager.default.removeItem(at: AttachmentStore.directory.appendingPathComponent(n))
            }
        }
        #expect(fromMime.hasSuffix(".jpeg"))
        #expect(fromName.hasSuffix(".heic"))
    }

    @Test func rejectsOversizedPayload() {
        let tooBig = Data(count: AttachmentStore.maxBytes + 1)
        #expect(throws: AttachmentStore.Failure.self) {
            try AttachmentStore.save(tooBig, mimeType: "image/png", originalName: nil)
        }
    }

    @Test func mimeTypeForImageExtension() {
        #expect(AttachmentStore.mimeType(forExtension: "png") == "image/png")
        #expect(AttachmentStore.mimeType(forExtension: "zzzz") == "application/octet-stream")
    }
}
