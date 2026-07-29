import Foundation
import Testing
@testable import LlamadockCore

@Suite("Local model removal planner")
struct LocalModelRemovalPlannerTests {
    @Test("accepts one regular GGUF inside an approved root")
    func acceptsApprovedGGUF() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let modelURL = fixture.root.appending(path: "model.gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        let model = makeModel(url: modelURL, root: fixture.root)

        let plan = try LocalModelRemovalPlanner().makePlan(
            model: model,
            approvedRoots: [fixture.root],
            protectedModelURLs: []
        )

        #expect(plan.targetURL == modelURL.standardizedFileURL)
        #expect(plan.rootURL == fixture.root.standardizedFileURL)
    }

    @Test("rejects roots that are no longer approved")
    func rejectsUnapprovedRoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let modelURL = fixture.root.appending(path: "model.gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        let model = makeModel(url: modelURL, root: fixture.root)

        #expect(
            throws: LocalModelRemovalError.unapprovedRoot(
                fixture.root.standardizedFileURL
            )
        ) {
            try LocalModelRemovalPlanner().makePlan(
                model: model,
                approvedRoots: [],
                protectedModelURLs: []
            )
        }
    }

    @Test("rejects a target outside the declared approved root")
    func rejectsRootPrefixEscape() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let sibling = fixture.base.appending(
            path: "models-elsewhere",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: sibling,
            withIntermediateDirectories: true
        )
        let modelURL = sibling.appending(path: "model.gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        let model = makeModel(url: modelURL, root: fixture.root)

        #expect(
            throws: LocalModelRemovalError.targetOutsideRoot(
                modelURL.standardizedFileURL
            )
        ) {
            try LocalModelRemovalPlanner().makePlan(
                model: model,
                approvedRoots: [fixture.root],
                protectedModelURLs: []
            )
        }
    }

    @Test("rejects symlinks instead of following their targets")
    func rejectsSymbolicLink() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let external = fixture.base.appending(path: "external.gguf")
        try Data("GGUF".utf8).write(to: external)
        let link = fixture.root.appending(path: "link.gguf")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: external
        )
        let model = makeModel(url: link, root: fixture.root)

        #expect(
            throws: LocalModelRemovalError.invalidTarget(
                link.standardizedFileURL,
                reason: "symbolic links are not removable model entries"
            )
        ) {
            try LocalModelRemovalPlanner().makePlan(
                model: model,
                approvedRoots: [fixture.root],
                protectedModelURLs: []
            )
        }
        #expect(FileManager.default.fileExists(atPath: external.path))
    }

    @Test("rejects a model used by the owned server")
    func rejectsProtectedModel() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let modelURL = fixture.root.appending(path: "model.gguf")
        try Data("GGUF".utf8).write(to: modelURL)
        let model = makeModel(url: modelURL, root: fixture.root)

        #expect(
            throws: LocalModelRemovalError.modelInUse(
                modelURL.standardizedFileURL
            )
        ) {
            try LocalModelRemovalPlanner().makePlan(
                model: model,
                approvedRoots: [fixture.root],
                protectedModelURLs: [modelURL]
            )
        }
    }

    @Test("rejects missing, directory, and non-GGUF targets")
    func rejectsInvalidTargets() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let missing = fixture.root.appending(path: "missing.gguf")
        let directory = fixture.root.appending(
            path: "directory.gguf",
            directoryHint: .isDirectory
        )
        let nonGGUF = fixture.root.appending(path: "model.bin")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("model".utf8).write(to: nonGGUF)
        let cases: [(URL, String)] = [
            (missing, "the model file no longer exists"),
            (directory, "the target is not a regular file"),
            (nonGGUF, "the target is not a GGUF file"),
        ]

        for (url, reason) in cases {
            #expect(
                throws: LocalModelRemovalError.invalidTarget(
                    url.standardizedFileURL,
                    reason: reason
                )
            ) {
                try LocalModelRemovalPlanner().makePlan(
                    model: makeModel(
                        url: url,
                        root: fixture.root
                    ),
                    approvedRoots: [fixture.root],
                    protectedModelURLs: []
                )
            }
        }
    }

    @Test("production trasher delegates the exact URL to FileManager Trash")
    func delegatesToSystemTrashAPI() async throws {
        let recording = LockedURLRecording()
        let fileManager = RecordingTrashFileManager(
            recording: recording
        )
        let trasher = FileManagerLocalModelTrasher(
            fileManager: fileManager
        )
        let target = URL(
            filePath: "/tmp/Llamadock exact model.gguf",
            directoryHint: .notDirectory
        )

        try await trasher.moveToTrash(target)

        #expect(recording.url == target)
    }

    private func makeFixture() throws -> (
        base: URL,
        root: URL
    ) {
        let base = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockModelRemoval-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let root = base.appending(
            path: "models",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return (base, root)
    }

    private func makeModel(
        url: URL,
        root: URL
    ) -> LocalModelFile {
        LocalModelFile(
            id: url.path,
            url: url,
            rootURL: root,
            fileSize: 4,
            modificationDate: nil,
            role: .main,
            metadata: nil,
            validation: .valid
        )
    }
}

private final class RecordingTrashFileManager:
    FileManager,
    @unchecked Sendable
{
    private let recording: LockedURLRecording

    init(
        recording: LockedURLRecording
    ) {
        self.recording = recording
        super.init()
    }

    override func trashItem(
        at url: URL,
        resultingItemURL outResultingURL:
            AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        recording.record(url)
    }
}

private final class LockedURLRecording:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var recordedURL: URL?

    var url: URL? {
        lock.withLock { recordedURL }
    }

    func record(
        _ url: URL
    ) {
        lock.withLock {
            recordedURL = url
        }
    }
}
