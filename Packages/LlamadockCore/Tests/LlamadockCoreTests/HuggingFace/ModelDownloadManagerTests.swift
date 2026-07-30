import CryptoKit
import Foundation
import Testing
@testable import LlamadockCore

@Suite("Model download manager")
struct ModelDownloadManagerTests {
    @Test("downloads, verifies, and atomically imports a grouped artifact")
    func downloadsGroupedArtifact() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let payloads = [
            minimalGGUF(name: "first"),
            minimalGGUF(name: "second"),
            minimalGGUF(name: "projector"),
        ]
        let transport = FixtureModelDownloadTransport(
            payloads: payloads
        )
        let manager = ModelDownloadManager(
            directories: directories,
            transport: transport,
            tokenStore: StaticHuggingFaceTokenStore(
                value: "hf_fixture_secret"
            )
        )

        let id = try await manager.enqueue(
            request(
                files: [
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "weights/model-00001-of-00002.gguf",
                        payload: payloads[0]
                    ),
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "weights/model-00002-of-00002.gguf",
                        payload: payloads[1]
                    ),
                    requestFile(
                        artifactID: "mmproj",
                        role: .mmproj,
                        path: "vision/mmproj-f16.gguf",
                        payload: payloads[2]
                    ),
                ]
            )
        )

        let job = try await waitForState(
            .completed,
            id: id,
            manager: manager
        )
        #expect(
            job.files.allSatisfy { $0.isVerified }
        )
        #expect(job.progress == 1)

        for (file, payload) in zip(job.files, payloads) {
            let installed = directories.models
                .appending(
                    path: job.destinationRelativeDirectory,
                    directoryHint: .isDirectory
                )
                .appending(
                    path: file.repositoryPath,
                    directoryHint: .notDirectory
                )
            #expect(try Data(contentsOf: installed) == payload)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: directories.downloadJobs
                    .appending(path: id.uuidString).path
            )
        )

        let transfers = await transport.transfers()
        #expect(transfers.count == 3)
        #expect(
            transfers.allSatisfy {
                $0.request.value(
                    forHTTPHeaderField: "Authorization"
                ) == "Bearer hf_fixture_secret"
            }
        )
    }

    @Test("restores a partial file and resumes with Range")
    func restoresAndResumes() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let fullPayload = minimalGGUF(name: "resumed")
        let prefixLength = 17
        let firstManager = ModelDownloadManager(
            directories: directories,
            transport: BlockingPartialModelDownloadTransport(
                prefix: Data(fullPayload.prefix(prefixLength))
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        let id = try await firstManager.enqueue(
            request(
                files: [
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "model.gguf",
                        payload: fullPayload
                    ),
                ]
            )
        )

        _ = try await waitForState(
            .downloading,
            id: id,
            manager: firstManager
        )
        try await waitForPartialFile(
            id: id,
            directories: directories,
            minimumSize: Int64(prefixLength)
        )
        try await firstManager.pause(id: id)
        _ = try await waitForNoActiveJob(firstManager)

        let resumeTransport = FixtureModelDownloadTransport(
            payloads: [
                Data(fullPayload.dropFirst(prefixLength))
            ]
        )
        let restoredManager = ModelDownloadManager(
            directories: directories,
            transport: resumeTransport,
            tokenStore: StaticHuggingFaceTokenStore()
        )
        try await restoredManager.restore()
        let paused = try #require(
            await restoredManager.snapshot().jobs.first {
                $0.id == id
            }
        )
        #expect(paused.state == .paused)
        #expect(paused.receivedBytes == prefixLength)

        try await restoredManager.resume(id: id)
        let completed = try await waitForState(
            .completed,
            id: id,
            manager: restoredManager
        )
        let transfer = try #require(
            await resumeTransport.transfers().first
        )
        #expect(transfer.existingByteCount == prefixLength)
        #expect(
            transfer.request.value(
                forHTTPHeaderField: "Range"
            ) == "bytes=\(prefixLength)-"
        )
        let installed = directories.models
            .appending(
                path: completed.destinationRelativeDirectory
            )
            .appending(path: "model.gguf")
        #expect(
            try Data(contentsOf: installed) == fullPayload
        )
    }

    @Test("cancel removes partial transaction without importing")
    func cancelsAndCleansUp() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let manager = ModelDownloadManager(
            directories: directories,
            transport: BlockingPartialModelDownloadTransport(
                prefix: Data("abc".utf8)
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        let id = try await manager.enqueue(
            request(
                files: [
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "model.gguf",
                        payload: Data("abcdef".utf8)
                    ),
                ]
            )
        )
        _ = try await waitForState(
            .downloading,
            id: id,
            manager: manager
        )
        try await waitForPartialFile(
            id: id,
            directories: directories,
            minimumSize: 3
        )

        try await manager.cancel(id: id)
        _ = try await waitForNoActiveJob(manager)
        let cancelled = try #require(
            await manager.snapshot().jobs.first {
                $0.id == id
            }
        )
        #expect(cancelled.state == .cancelled)
        #expect(
            !FileManager.default.fileExists(
                atPath: directories.downloadJobs
                    .appending(path: id.uuidString).path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: directories.models.path
                    + "/huggingface"
            )
        )
    }

    @Test("fails safely when response length is inconsistent")
    func rejectsLengthMismatch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FixtureModelDownloadTransport(
            payloads: [Data("abc".utf8)],
            contentLengthAdjustment: 1
        )
        let manager = ModelDownloadManager(
            directories: ApplicationDirectories(root: root),
            transport: transport,
            tokenStore: StaticHuggingFaceTokenStore()
        )
        let id = try await manager.enqueue(
            request(
                files: [
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "model.gguf",
                        payload: Data("abc".utf8)
                    ),
                ]
            )
        )

        let failed = try await waitForState(
            .failed,
            id: id,
            manager: manager
        )
        #expect(
            failed.error?.contains(
                "expected 4 bytes but received 3"
            ) == true
        )
        #expect(
            !failed.error!.contains("hf_")
        )
    }

    @Test("rejects a checksum-valid file without GGUF structure")
    func rejectsInvalidGGUF() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("not-a-gguf".utf8)
        let manager = ModelDownloadManager(
            directories: ApplicationDirectories(root: root),
            transport: FixtureModelDownloadTransport(
                payloads: [payload]
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        let id = try await manager.enqueue(
            request(
                files: [
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "model.gguf",
                        payload: payload
                    ),
                ]
            )
        )

        let failed = try await waitForState(
            .failed,
            id: id,
            manager: manager
        )
        #expect(
            failed.error?.contains("not a valid GGUF") == true
        )
        #expect(failed.files[0].receivedBytes == 0)
        #expect(!failed.files[0].isVerified)
    }

    @Test("rejects an insecure resolved model URL")
    func rejectsInsecureResolvedURL() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FixtureModelDownloadTransport(
            payloads: [Data("abc".utf8)]
        )
        let manager = ModelDownloadManager(
            directories: ApplicationDirectories(root: root),
            transport: transport,
            urlResolver: StaticHuggingFaceFileURLResolver(
                url: URL(string: "http://example.com/model.gguf")!
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        let id = try await manager.enqueue(
            request(
                files: [
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "model.gguf",
                        payload: Data("abc".utf8)
                    ),
                ]
            )
        )

        let failed = try await waitForState(
            .failed,
            id: id,
            manager: manager
        )
        #expect(
            failed.error?.contains("must use HTTPS") == true
        )
        #expect(await transport.transfers().isEmpty)
    }

    @Test("discarding a failed job removes its transaction and incomplete import")
    func discardsFailedDownloadRemnants() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let manager = ModelDownloadManager(
            directories: directories,
            transport: FixtureModelDownloadTransport(
                payloads: []
            ),
            urlResolver: StaticHuggingFaceFileURLResolver(
                url: URL(string: "http://example.com/model.gguf")!
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        let id = try await manager.enqueue(
            request(
                files: [
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "model.gguf",
                        payload: Data("abcdef".utf8)
                    ),
                ]
            )
        )
        let failed = try await waitForState(
            .failed,
            id: id,
            manager: manager
        )
        let transactionURL = directories.downloadJobs.appending(
            path: id.uuidString,
            directoryHint: .isDirectory
        )
        let finalURL = directories.models.appending(
            path: failed.destinationRelativeDirectory,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: transactionURL,
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(
            to: transactionURL.appending(path: "model.gguf.part")
        )
        try FileManager.default.createDirectory(
            at: finalURL,
            withIntermediateDirectories: true
        )
        try Data("short".utf8).write(
            to: finalURL.appending(path: "model.gguf")
        )

        try await manager.discardFailed(id: id)

        #expect(
            await manager.snapshot().jobs.allSatisfy {
                $0.id != id
            }
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: transactionURL.path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: finalURL.path
            )
        )
        let persistedJobs = try await JSONModelDownloadStore(
            fileURL: directories.downloadState
        ).loadJobs()
        #expect(persistedJobs.allSatisfy { $0.id != id })
    }

    @Test("discard refuses a completed job and preserves its imported files")
    func doesNotDiscardCompletedDownload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let payload = minimalGGUF(name: "preserved")
        let manager = ModelDownloadManager(
            directories: directories,
            transport: FixtureModelDownloadTransport(
                payloads: [payload]
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        let id = try await manager.enqueue(
            request(
                files: [
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "model.gguf",
                        payload: payload
                    ),
                ]
            )
        )
        let completed = try await waitForState(
            .completed,
            id: id,
            manager: manager
        )
        let importedFile = directories.models
            .appending(
                path: completed.destinationRelativeDirectory,
                directoryHint: .isDirectory
            )
            .appending(
                path: "model.gguf",
                directoryHint: .notDirectory
            )

        await #expect(throws: ModelDownloadManagerError.self) {
            try await manager.discardFailed(id: id)
        }

        #expect(
            FileManager.default.fileExists(
                atPath: importedFile.path
            )
        )
        #expect(
            await manager.snapshot().jobs.contains {
                $0.id == id && $0.state == .completed
            }
        )
    }

    @Test("rejects overlapping paths and duplicate companion roles")
    func rejectsAmbiguousArtifactGroups() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ModelDownloadManager(
            directories: ApplicationDirectories(root: root),
            transport: FixtureModelDownloadTransport(
                payloads: []
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        let payload = minimalGGUF(name: "ambiguous")

        await #expect(throws: ModelDownloadManagerError.self) {
            _ = try await manager.enqueue(
                request(
                    files: [
                        requestFile(
                            artifactID: "main",
                            role: .main,
                            path: "same.gguf",
                            payload: payload
                        ),
                        requestFile(
                            artifactID: "mmproj",
                            role: .mmproj,
                            path: "same.gguf",
                            payload: payload
                        ),
                    ]
                )
            )
        }

        await #expect(throws: ModelDownloadManagerError.self) {
            _ = try await manager.enqueue(
                request(
                    files: [
                        requestFile(
                            artifactID: "main",
                            role: .main,
                            path: "main.gguf",
                            payload: payload
                        ),
                        requestFile(
                            artifactID: "mmproj-a",
                            role: .mmproj,
                            path: "mmproj-a.gguf",
                            payload: payload
                        ),
                        requestFile(
                            artifactID: "mmproj-b",
                            role: .mmproj,
                            path: "mmproj-b.gguf",
                            payload: payload
                        ),
                    ]
                )
            )
        }
    }

    @Test("does not restore an incomplete final directory as completed")
    func rejectsIncompleteRestoredImport() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let payload = minimalGGUF(name: "restored")
        let now = Date()
        let id = UUID()
        let files = [
            ModelDownloadFile(
                artifactID: "main",
                artifactDisplayName: "main",
                role: .main,
                repositoryPath:
                    "model-00001-of-00002.gguf",
                expectedSize: Int64(payload.count),
                expectedSHA256: sha256(payload),
                receivedBytes: Int64(payload.count),
                isVerified: true
            ),
            ModelDownloadFile(
                artifactID: "main",
                artifactDisplayName: "main",
                role: .main,
                repositoryPath:
                    "model-00002-of-00002.gguf",
                expectedSize: Int64(payload.count),
                expectedSHA256: sha256(payload),
                receivedBytes: Int64(payload.count),
                isVerified: true
            ),
        ]
        let job = ModelDownloadJob(
            id: id,
            repositoryID: "owner/repo",
            revision: "main",
            displayName: "restored",
            quantization: nil,
            destinationRelativeDirectory:
                "huggingface/owner/repo/main/restored",
            files: files,
            state: .completed,
            error: nil,
            createdAt: now,
            updatedAt: now
        )
        try await JSONModelDownloadStore(
            fileURL: directories.downloadState
        ).saveJobs([job])
        let finalDirectory = directories.models.appending(
            path: job.destinationRelativeDirectory,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: finalDirectory,
            withIntermediateDirectories: true
        )
        try payload.write(
            to: finalDirectory.appending(
                path: files[0].repositoryPath
            )
        )

        let manager = ModelDownloadManager(
            directories: directories,
            transport: FixtureModelDownloadTransport(
                payloads: []
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        try await manager.restore()
        let restored = try #require(
            await manager.snapshot().jobs.first
        )

        #expect(restored.state == .failed)
        #expect(
            restored.error?.contains(
                "will not overwrite"
            ) == true
        )
    }

    @Test("strips authorization on cross-host redirects")
    func stripsRedirectAuthorization() throws {
        var proposed = URLRequest(
            url: URL(
                string: "https://cdn-lfs.hf.co/file"
            )!
        )
        proposed.setValue(
            "Bearer hf_secret",
            forHTTPHeaderField: "Authorization"
        )

        let sanitized = try URLSessionModelDownloadTransport
            .sanitizedRedirectRequest(
                initialURL: URL(
                    string: "https://huggingface.co/resolve"
                ),
                proposedRequest: proposed
            )

        #expect(
            sanitized.value(
                forHTTPHeaderField: "Authorization"
            ) == nil
        )
        #expect(throws: ModelDownloadTransportError.self) {
            var insecure = proposed
            insecure.url = URL(
                string: "http://cdn-lfs.hf.co/file"
            )
            _ = try URLSessionModelDownloadTransport
                .sanitizedRedirectRequest(
                    initialURL: proposed.url,
                    proposedRequest: insecure
                )
        }
    }

    private func request(
        files: [ModelDownloadRequestFile]
    ) -> ModelDownloadRequest {
        ModelDownloadRequest(
            reference: HuggingFaceRepositoryReference(
                repositoryID: "owner/repo"
            ),
            displayName: "model-Q4_K_M",
            quantization: "Q4_K_M",
            files: files
        )
    }

    private func requestFile(
        artifactID: String,
        role: HuggingFaceGGUFRole,
        path: String,
        payload: Data
    ) -> ModelDownloadRequestFile {
        ModelDownloadRequestFile(
            artifactID: artifactID,
            artifactDisplayName: artifactID,
            role: role,
            repositoryPath: path,
            expectedSize: Int64(payload.count),
            expectedSHA256: sha256(payload)
        )
    }

    private func sha256(
        _ data: Data
    ) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func minimalGGUF(
        name: String
    ) -> Data {
        let entries = [
            ("general.architecture", "llama"),
            ("general.type", "model"),
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

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "LlamadockModelDownloadTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func waitForState(
        _ state: ModelDownloadState,
        id: UUID,
        manager: ModelDownloadManager
    ) async throws -> ModelDownloadJob {
        for _ in 0..<300 {
            if
                let job = await manager.snapshot().jobs.first(
                    where: { $0.id == id }
                ),
                job.state == state
            {
                return job
            }
            try await Task.sleep(
                nanoseconds: 10_000_000
            )
        }
        let snapshot = await manager.snapshot()
        let current = snapshot.jobs.first { $0.id == id }
        throw DownloadTestError.timedOut(
            "waiting for \(state.rawValue), got \(current?.state.rawValue ?? "missing"): \(current?.error ?? "no error")"
        )
    }

    private func waitForNoActiveJob(
        _ manager: ModelDownloadManager
    ) async throws -> ModelDownloadSnapshot {
        for _ in 0..<300 {
            let snapshot = await manager.snapshot()
            if snapshot.activeJobID == nil {
                return snapshot
            }
            try await Task.sleep(
                nanoseconds: 10_000_000
            )
        }
        throw DownloadTestError.timedOut(
            "waiting for active job to finish"
        )
    }

    private func waitForPartialFile(
        id: UUID,
        directories: ApplicationDirectories,
        minimumSize: Int64
    ) async throws {
        let jobRoot = directories.downloadJobs.appending(
            path: id.uuidString
        )
        for _ in 0..<300 {
            if
                let enumerator = FileManager.default.enumerator(
                    at: jobRoot,
                    includingPropertiesForKeys: [
                        .fileSizeKey,
                    ]
                ),
                enumerator.compactMap({
                    ($0 as? URL).flatMap {
                        try? $0.resourceValues(
                            forKeys: [.fileSizeKey]
                        ).fileSize
                    }
                }).contains(where: {
                    Int64($0) >= minimumSize
                })
            {
                return
            }
            try await Task.sleep(
                nanoseconds: 10_000_000
            )
        }
        throw DownloadTestError.timedOut(
            "waiting for partial file"
        )
    }
}

private enum DownloadTestError: Error {
    case timedOut(String)
}

private struct StaticHuggingFaceTokenStore:
    HuggingFaceTokenStoring,
    Sendable
{
    let value: String?

    init(value: String? = nil) {
        self.value = value
    }

    func token() throws -> String? {
        value
    }

    func saveToken(_ token: String) throws {}
    func deleteToken() throws {}
}

private struct StaticHuggingFaceFileURLResolver:
    HuggingFaceFileURLResolving,
    Sendable
{
    let url: URL

    func resolveURL(
        reference: HuggingFaceRepositoryReference,
        filePath: String
    ) throws -> URL {
        url
    }
}

private actor FixtureModelDownloadTransport:
    ModelDownloadTransporting
{
    private var pendingPayloads: [Data]
    private var recordedTransfers: [
        ModelDownloadTransferRequest
    ] = []
    private let contentLengthAdjustment: Int64

    init(
        payloads: [Data],
        contentLengthAdjustment: Int64 = 0
    ) {
        pendingPayloads = payloads
        self.contentLengthAdjustment =
            contentLengthAdjustment
    }

    func transfer(
        _ transfer: ModelDownloadTransferRequest,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> ModelDownloadTransferResponse {
        recordedTransfers.append(transfer)
        let payload = pendingPayloads.removeFirst()
        try write(
            payload,
            to: transfer.destinationURL,
            append: transfer.existingByteCount > 0
        )
        let final = transfer.existingByteCount
            + Int64(payload.count)
        let actualSize = (
            try FileManager.default.attributesOfItem(
                atPath: transfer.destinationURL.path
            )[.size] as? NSNumber
        )?.int64Value ?? -1
        guard actualSize == final else {
            throw DownloadTestError.timedOut(
                "fixture wrote \(actualSize), expected \(final)"
            )
        }
        progress(final)
        return ModelDownloadTransferResponse(
            statusCode: transfer.existingByteCount > 0
                ? 206
                : 200,
            contentLength: Int64(payload.count)
                + contentLengthAdjustment,
            etag: "\"fixture\"",
            resumedFromByte: transfer.existingByteCount,
            receivedBytes: Int64(payload.count)
        )
    }

    func transfers() -> [ModelDownloadTransferRequest] {
        recordedTransfers
    }
}

private actor BlockingPartialModelDownloadTransport:
    ModelDownloadTransporting
{
    private let prefix: Data

    init(prefix: Data) {
        self.prefix = prefix
    }

    func transfer(
        _ transfer: ModelDownloadTransferRequest,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> ModelDownloadTransferResponse {
        try write(
            prefix,
            to: transfer.destinationURL,
            append: transfer.existingByteCount > 0
        )
        progress(
            transfer.existingByteCount
                + Int64(prefix.count)
        )
        try await Task.sleep(
            nanoseconds: 60_000_000_000
        )
        throw DownloadTestError.timedOut(
            "blocking transport unexpectedly completed"
        )
    }
}

private func write(
    _ data: Data,
    to url: URL,
    append: Bool
) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(
            atPath: url.path,
            contents: nil
        )
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    if append {
        let size = (
            try FileManager.default.attributesOfItem(
                atPath: url.path
            )[.size] as? NSNumber
        )?.uint64Value ?? 0
        try handle.seek(
            toOffset: UInt64(size)
        )
    } else {
        try handle.truncate(atOffset: 0)
    }
    try handle.write(contentsOf: data)
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
