import Foundation
import Testing
@testable import LlamadockCore

@Suite("Local model scanner")
struct LocalModelScannerTests {
    @Test("scans GGUF recursively while keeping invalid files visible")
    func scansSafely() async throws {
        let root = try makeDirectory(named: "root")
        let outside = try makeDirectory(named: "outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let nested = root.appending(
            path: "Nested",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )

        let valid = root.appending(
            path: "Tiny-15M-Q4_0.gguf"
        )
        try minimalGGUF(name: "Tiny").write(to: valid)
        let mmproj = nested.appending(
            path: "mmproj-Tiny.gguf"
        )
        try minimalGGUF(
            name: "Tiny Projector",
            kind: "mmproj"
        ).write(to: mmproj)
        let invalid = root.appending(
            path: "broken.gguf"
        )
        try Data("broken".utf8).write(to: invalid)
        try minimalGGUF(name: "Hidden").write(
            to: root.appending(path: ".hidden.gguf")
        )
        try minimalGGUF(name: "Partial").write(
            to: root.appending(path: "partial.gguf.part")
        )

        let outsideModel = outside.appending(
            path: "outside.gguf"
        )
        try minimalGGUF(name: "Outside").write(
            to: outsideModel
        )
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "escaped.gguf"),
            withDestinationURL: outsideModel
        )

        let snapshot = try await LocalModelScanner().scan(
            roots: [root]
        )

        #expect(snapshot.models.count == 3)
        #expect(
            snapshot.models.map(\.displayName)
                == ["broken", "Tiny", "Tiny Projector"]
        )
        #expect(
            snapshot.models.first(
                where: { $0.url == invalid }
            )?.validation
                == .invalid(
                    reason: "The model does not begin with the GGUF magic bytes."
                )
        )
        #expect(
            snapshot.models.first(
                where: { $0.url == mmproj }
            )?.role == .mmproj
        )
        #expect(
            snapshot.models.allSatisfy {
                $0.id.hasPrefix("model:")
                    && $0.id.count == 70
            }
        )
        #expect(snapshot.issues.isEmpty)
    }

    @Test("deduplicates overlapping roots by file resource identity")
    func deduplicatesOverlappingRoots() async throws {
        let root = try makeDirectory(named: "root")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appending(
            path: "Nested",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try minimalGGUF(name: "Only Once").write(
            to: nested.appending(path: "model.gguf")
        )

        let snapshot = try await LocalModelScanner().scan(
            roots: [root, nested, root]
        )

        #expect(snapshot.roots == [root, nested])
        #expect(snapshot.models.count == 1)
        #expect(snapshot.models.first?.rootURL == root)
    }

    @Test("reports unavailable roots without hiding valid roots")
    func reportsRootIssues() async throws {
        let root = try makeDirectory(named: "root")
        defer { try? FileManager.default.removeItem(at: root) }
        try minimalGGUF(name: "Available").write(
            to: root.appending(path: "model.gguf")
        )
        let missing = root.appending(
            path: "Missing",
            directoryHint: .isDirectory
        )

        let snapshot = try await LocalModelScanner().scan(
            roots: [missing, root]
        )

        #expect(snapshot.models.count == 1)
        #expect(snapshot.issues.count == 1)
        #expect(snapshot.issues.first?.rootURL == missing)
    }

    private func makeDirectory(
        named name: String
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "LlamadockModelScanner-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func minimalGGUF(
        name: String,
        kind: String = "model"
    ) -> Data {
        let entries = [
            ("general.architecture", "llama"),
            ("general.type", kind),
            ("general.name", name),
        ]
        var data = Data("GGUF".utf8)
        data.appendLittleEndian(UInt32(3))
        data.appendLittleEndian(UInt64(1))
        data.appendLittleEndian(UInt64(entries.count))
        for (key, value) in entries {
            data.appendGGUFString(key)
            data.appendLittleEndian(UInt32(8))
            data.appendGGUFString(value)
        }
        data.appendGGUFString("weight")
        data.appendLittleEndian(UInt32(1))
        data.appendLittleEndian(UInt64(4))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt64(0))
        let remainder = data.count % 32
        if remainder != 0 {
            data.append(
                Data(repeating: 0, count: 32 - remainder)
            )
        }
        data.append(Data(repeating: 0, count: 16))
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T
    ) {
        for byteIndex in 0..<MemoryLayout<T>.size {
            append(
                UInt8(
                    truncatingIfNeeded:
                        value >> T(byteIndex * 8)
                )
            )
        }
    }

    mutating func appendGGUFString(
        _ value: String
    ) {
        let encoded = Data(value.utf8)
        appendLittleEndian(UInt64(encoded.count))
        append(encoded)
    }
}
