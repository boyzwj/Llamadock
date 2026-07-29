import Foundation
import Testing
@testable import LlamadockCore

@Suite("Managed runtime archive")
struct RuntimeArchiveTests {
    @Test("accepts official-style relative files and links")
    func acceptsSafeManifest() throws {
        let entries = [
            RuntimeArchiveEntry(
                path: "llama-b10176/",
                kind: .directory
            ),
            RuntimeArchiveEntry(
                path: "llama-b10176/llama-server",
                kind: .file
            ),
            RuntimeArchiveEntry(
                path: "llama-b10176/libllama.dylib",
                kind: .symbolicLink(
                    target: "libllama.0.dylib"
                )
            ),
            RuntimeArchiveEntry(
                path: "llama-b10176/libllama.0.dylib",
                kind: .symbolicLink(
                    target: "libllama.0.0.10176.dylib"
                )
            ),
        ]

        try RuntimeArchiveManifestValidator().validate(entries)
    }

    @Test(
        "rejects absolute, traversal, deep, and escaping link entries",
        arguments: [
            (
                [RuntimeArchiveEntry(path: "/tmp/payload", kind: .file)],
                RuntimeArchiveError.unsafePath("/tmp/payload")
            ),
            (
                [
                    RuntimeArchiveEntry(
                        path: "runtime/../../payload",
                        kind: .file
                    )
                ],
                RuntimeArchiveError.unsafePath(
                    "runtime/../../payload"
                )
            ),
            (
                [
                    RuntimeArchiveEntry(
                        path: "runtime/link",
                        kind: .symbolicLink(
                            target: "../../payload"
                        )
                    )
                ],
                RuntimeArchiveError.unsafeLink(
                    path: "runtime/link",
                    target: "../../payload"
                )
            ),
            (
                [
                    RuntimeArchiveEntry(
                        path: "a/b/c/d/e",
                        kind: .file
                    )
                ],
                RuntimeArchiveError.excessiveDepth(
                    path: "a/b/c/d/e",
                    maximum: 4
                )
            ),
        ]
    )
    func rejectsUnsafeManifest(
        entries: [RuntimeArchiveEntry],
        expectedError: RuntimeArchiveError
    ) {
        #expect(throws: expectedError) {
            try RuntimeArchiveManifestValidator(
                maximumDepth: 4
            )
            .validate(entries)
        }
    }

    @Test("parses the stable C-locale bsdtar verbose listing")
    func parsesBSDTarListing() throws {
        let listing = """
            drwxr-xr-x  0 runner staff 0 Jul 29 16:16 llama-b10176/
            -rwxr-xr-x  0 runner staff 33472 Jul 29 16:16 llama-b10176/llama-server
            lrwxr-xr-x  0 runner staff 0 Jul 29 16:15 llama-b10176/libllama.dylib -> libllama.0.dylib
            """

        let entries = try BSDTarVerboseListingParser().parse(listing)

        #expect(
            entries
                == [
                    RuntimeArchiveEntry(
                        path: "llama-b10176/",
                        kind: .directory
                    ),
                    RuntimeArchiveEntry(
                        path: "llama-b10176/llama-server",
                        kind: .file
                    ),
                    RuntimeArchiveEntry(
                        path: "llama-b10176/libllama.dylib",
                        kind: .symbolicLink(
                            target: "libllama.0.dylib"
                        )
                    ),
                ]
        )
    }

    @Test("does not extract when archive inspection finds traversal")
    func blocksExtractionAfterUnsafeListing() async throws {
        let runner = ArchiveProcessRunner(
            responses: [
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: """
                        -rw-r--r--  0 runner staff 4 Jul 29 16:16 ../payload
                        """,
                    standardError: ""
                )
            ]
        )
        let extractor = BSDTarRuntimeArchiveExtractor(
            processRunner: runner
        )
        let destination = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockArchiveTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: destination) }

        await #expect(
            throws: RuntimeArchiveError.unsafePath("../payload")
        ) {
            try await extractor.extract(
                archiveURL: URL(filePath: "/tmp/runtime.tar.gz"),
                destinationURL: destination
            )
        }
        #expect(await runner.invocations().count == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.path
            )
        )
    }

    @Test("inspects before extracting with absolute tar invocation")
    func extractsValidatedArchive() async throws {
        let runner = ArchiveProcessRunner(
            responses: [
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: """
                        drwxr-xr-x  0 runner staff 0 Jul 29 16:16 llama-b10176/
                        -rwxr-xr-x  0 runner staff 4 Jul 29 16:16 llama-b10176/llama-server
                        """,
                    standardError: ""
                ),
                ProcessResult(
                    terminationStatus: 0,
                    standardOutput: "",
                    standardError: ""
                ),
            ]
        )
        let extractor = BSDTarRuntimeArchiveExtractor(
            processRunner: runner
        )
        let destination = FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockArchiveTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        defer { try? FileManager.default.removeItem(at: destination) }

        try await extractor.extract(
            archiveURL: URL(filePath: "/tmp/runtime.tar.gz"),
            destinationURL: destination
        )

        let invocations = await runner.invocations()
        let expectedInspection = try ProcessInvocation(
            executableURL: URL(filePath: "/usr/bin/tar"),
            arguments: ["-tvf", "/tmp/runtime.tar.gz"],
            environment: ["LC_ALL": "C"]
        )
        #expect(invocations.count == 2)
        #expect(invocations[0] == expectedInspection)
        #expect(invocations[1].executableURL.path == "/usr/bin/tar")
        #expect(invocations[1].arguments.contains(destination.path))
        #expect(
            FileManager.default.fileExists(
                atPath: destination.path
            )
        )
    }
}

private actor ArchiveProcessRunner: ProcessRunning {
    private var responses: [ProcessResult]
    private var recordedInvocations: [ProcessInvocation] = []

    init(responses: [ProcessResult]) {
        self.responses = responses
    }

    func run(
        _ invocation: ProcessInvocation,
        timeout: Duration
    ) -> ProcessResult {
        recordedInvocations.append(invocation)
        return responses.removeFirst()
    }

    func invocations() -> [ProcessInvocation] {
        recordedInvocations
    }
}
