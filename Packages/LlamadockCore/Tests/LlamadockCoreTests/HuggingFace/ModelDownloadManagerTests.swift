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

    @Test("routes ModelScope jobs without Hugging Face credentials")
    func routesModelScopeDownload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let payload = minimalGGUF(name: "modelscope")
        let transport = FixtureModelDownloadTransport(
            payloads: [payload]
        )
        let manager = ModelDownloadManager(
            directories: directories,
            transport: transport,
            urlResolver: StaticHuggingFaceFileURLResolver(
                url: URL(string: "http://should-not-be-used.invalid")!
            ),
            modelScopeURLResolver:
                StaticModelScopeFileURLResolver(
                    url: URL(
                        string:
                            "https://modelscope.cn/api/v1/models/owner/repo/repo"
                    )!
                ),
            tokenStore: StaticHuggingFaceTokenStore(
                value: "hf_must_not_leave_the_app"
            )
        )

        let id = try await manager.enqueue(
            request(
                source: .modelScope,
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
        #expect(completed.source == .modelScope)
        #expect(
            completed.destinationRelativeDirectory
                .hasPrefix("modelscope/")
        )
        let transfer = try #require(
            await transport.transfers().first
        )
        #expect(
            transfer.request.value(
                forHTTPHeaderField: "Authorization"
            ) == nil
        )
        #expect(
            transfer.request.url?.host == "modelscope.cn"
        )
    }

    @Test("accepts GGUF splits whose later files omit model-level metadata")
    func acceptsStandardGGUFSplitMetadataLayout() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let payloads = [
            splitGGUF(
                name: "Split Model",
                index: 0,
                count: 2,
                includesModelMetadata: true
            ),
            splitGGUF(
                name: "Split Model",
                index: 1,
                count: 2,
                includesModelMetadata: false
            ),
        ]
        let transport = FixtureModelDownloadTransport(
            payloads: payloads
        )
        let manager = ModelDownloadManager(
            directories: directories,
            transport: transport,
            tokenStore: StaticHuggingFaceTokenStore()
        )

        let id = try await manager.enqueue(
            request(
                source: .modelScope,
                files: [
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "model-00001-of-00002.gguf",
                        payload: payloads[0]
                    ),
                    requestFile(
                        artifactID: "main",
                        role: .main,
                        path: "model-00002-of-00002.gguf",
                        payload: payloads[1]
                    ),
                ]
            )
        )

        let completed = try await waitForState(
            .completed,
            id: id,
            manager: manager
        )
        #expect(completed.files.allSatisfy { $0.isVerified })
        #expect(await transport.transfers().count == 2)
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
            ) == "bytes=\(prefixLength)-\(fullPayload.count - 1)"
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

    @Test("downloads large files in bounded validated ranges")
    func downloadsInBoundedRanges() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = minimalGGUF(name: "chunked")
        let transport = RangeFixtureModelDownloadTransport(
            payload: payload
        )
        let manager = ModelDownloadManager(
            directories: ApplicationDirectories(root: root),
            transport: transport,
            tokenStore: StaticHuggingFaceTokenStore(),
            retryPolicy: ModelDownloadRetryPolicy(
                chunkSizeBytes: 32,
                maximumAttemptsPerChunk: 2,
                baseDelayNanoseconds: 0,
                maximumDelayNanoseconds: 0
            ),
            retryDelay: { _ in }
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
        let transfers = await transport.transfers()
        #expect(transfers.count > 1)
        #expect(
            transfers.allSatisfy {
                guard let range = $0.expectedRange else {
                    return false
                }
                return range.end - range.start + 1 <= 32
                    && range.total == Int64(payload.count)
            }
        )
        #expect(
            zip(transfers, transfers.dropFirst()).allSatisfy {
                previous, next in
                previous.expectedRange!.end + 1
                    == next.expectedRange!.start
            }
        )
        #expect(
            transfers.dropFirst().allSatisfy {
                $0.expectedRepositoryCommit == "fixture-commit"
                    && $0.expectedETag == "\"fixture-etag\""
            }
        )
        #expect(completed.resolvedRevision == "fixture-commit")
    }

    @Test("automatically resumes a range after a transient disconnect")
    func retriesInterruptedRange() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = minimalGGUF(name: "retry")
        let transport = RangeFixtureModelDownloadTransport(
            payload: payload,
            failuresRemaining: 1,
            failureByteCount: 17
        )
        let manager = ModelDownloadManager(
            directories: ApplicationDirectories(root: root),
            transport: transport,
            tokenStore: StaticHuggingFaceTokenStore(),
            retryPolicy: ModelDownloadRetryPolicy(
                chunkSizeBytes: Int64(payload.count),
                maximumAttemptsPerChunk: 3,
                baseDelayNanoseconds: 0,
                maximumDelayNanoseconds: 0
            ),
            retryDelay: { _ in }
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

        _ = try await waitForState(
            .completed,
            id: id,
            manager: manager
        )
        let transfers = await transport.transfers()
        #expect(transfers.count == 2)
        #expect(transfers[0].expectedRange?.start == 0)
        #expect(transfers[1].expectedRange?.start == 17)
        #expect(
            transfers[1].request.value(
                forHTTPHeaderField: "Range"
            ) == "bytes=17-\(payload.count - 1)"
        )
        #expect(
            transfers[1].request.value(
                forHTTPHeaderField: "If-Range"
            ) == "\"fixture-etag\""
        )
    }

    @Test("reports retry exhaustion after consecutive no-progress failures")
    func reportsRetryExhaustion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = minimalGGUF(name: "exhausted")
        let transport = RangeFixtureModelDownloadTransport(
            payload: payload,
            failuresRemaining: 2,
            failureByteCount: 0
        )
        let manager = ModelDownloadManager(
            directories: ApplicationDirectories(root: root),
            transport: transport,
            tokenStore: StaticHuggingFaceTokenStore(),
            retryPolicy: ModelDownloadRetryPolicy(
                chunkSizeBytes: Int64(payload.count),
                maximumAttemptsPerChunk: 2,
                baseDelayNanoseconds: 0,
                maximumDelayNanoseconds: 0
            ),
            retryDelay: { _ in }
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
        #expect(failed.files[0].receivedBytes == 0)
        #expect(
            failed.error?.contains(
                "after 2 automatic attempts"
            ) == true
        )
        #expect(await transport.transfers().count == 2)
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

        try await manager.discard(id: id)
        #expect(
            await manager.snapshot().jobs.allSatisfy {
                $0.id != id
            }
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
        #expect(
            failed.files[0].receivedBytes
                == Int64(payload.count)
        )
        #expect(!failed.files[0].isVerified)
        #expect(failed.files[0].restartReason == "invalidGGUF")
    }

    @Test("keeps a rejected full file until the user explicitly retries")
    func preservesRejectedFileUntilRetry() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let expectedPayload = minimalGGUF(name: "expected")
        var corruptedPayload = expectedPayload
        corruptedPayload[corruptedPayload.count - 1] ^= 0xff
        let downloadRequest = request(
            files: [
                requestFile(
                    artifactID: "main",
                    role: .main,
                    path: "model.gguf",
                    payload: expectedPayload
                ),
            ]
        )
        let firstManager = ModelDownloadManager(
            directories: directories,
            transport: FixtureModelDownloadTransport(
                payloads: [corruptedPayload]
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        let id = try await firstManager.enqueue(downloadRequest)

        let failed = try await waitForState(
            .failed,
            id: id,
            manager: firstManager
        )
        let rejectedURL = directories.downloadJobs
            .appending(path: id.uuidString)
            .appending(path: "payload/model.gguf.part")
        #expect(failed.files[0].restartReason == "checksumMismatch")
        #expect(
            FileManager.default.fileExists(
                atPath: rejectedURL.path
            )
        )
        #expect(
            try Data(contentsOf: rejectedURL)
                == corruptedPayload
        )

        let retryManager = ModelDownloadManager(
            directories: directories,
            transport: FixtureModelDownloadTransport(
                payloads: [expectedPayload]
            ),
            tokenStore: StaticHuggingFaceTokenStore()
        )
        try await retryManager.restore()
        try await retryManager.resume(id: id)
        let completed = try await waitForState(
            .completed,
            id: id,
            manager: retryManager
        )
        #expect(completed.files[0].restartReason == nil)
    }

    @Test("re-verifies a legacy rejected split without downloading it again")
    func recoversLegacySecondarySplitRejection() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = ApplicationDirectories(root: root)
        let id = UUID()
        let now = Date()
        let payloads = [
            splitGGUF(
                name: "Recovered Split",
                index: 0,
                count: 2,
                includesModelMetadata: true
            ),
            splitGGUF(
                name: "Recovered Split",
                index: 1,
                count: 2,
                includesModelMetadata: false
            ),
        ]
        let paths = [
            "weights/model-00001-of-00002.gguf",
            "weights/model-00002-of-00002.gguf",
        ]
        let files = zip(paths, payloads).enumerated().map {
            index, pair in
            ModelDownloadFile(
                artifactID: "main",
                artifactDisplayName: "model",
                role: .main,
                repositoryPath: pair.0,
                expectedSize: Int64(pair.1.count),
                expectedSHA256: sha256(pair.1),
                receivedBytes: Int64(pair.1.count),
                isVerified: index == 0,
                restartReason: index == 1
                    ? "invalidGGUF"
                    : nil
            )
        }
        let job = ModelDownloadJob(
            id: id,
            source: .modelScope,
            repositoryID: "owner/repo",
            revision: "master",
            displayName: "Recovered Split",
            quantization: "Q4_K_M",
            destinationRelativeDirectory:
                "modelscope/owner/repo/master/recovered",
            files: files,
            state: .failed,
            error: "The GGUF model is missing required metadata: general.architecture",
            createdAt: now,
            updatedAt: now
        )
        try await JSONModelDownloadStore(
            fileURL: directories.downloadState
        ).saveJobs([job])
        for (file, payload) in zip(files, payloads) {
            let partURL = directories.downloadJobs
                .appending(path: id.uuidString)
                .appending(path: "payload")
                .appending(path: file.repositoryPath + ".part")
            try FileManager.default.createDirectory(
                at: partURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: partURL)
        }
        let transport = FixtureModelDownloadTransport(payloads: [])
        let manager = ModelDownloadManager(
            directories: directories,
            transport: transport,
            tokenStore: StaticHuggingFaceTokenStore()
        )

        try await manager.restore()
        try await manager.resume(id: id)
        let completed = try await waitForState(
            .completed,
            id: id,
            manager: manager
        )

        #expect(completed.files.allSatisfy { $0.isVerified })
        #expect(await transport.transfers().isEmpty)
        for file in files {
            #expect(
                FileManager.default.fileExists(
                    atPath: directories.models
                        .appending(
                            path: completed.destinationRelativeDirectory
                        )
                        .appending(path: file.repositoryPath)
                        .path
                )
            )
        }
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
        source: ModelHubSource = .huggingFace,
        files: [ModelDownloadRequestFile]
    ) -> ModelDownloadRequest {
        ModelDownloadRequest(
            source: source,
            reference: HuggingFaceRepositoryReference(
                repositoryID: "owner/repo",
                revision: source == .modelScope
                    ? "master"
                    : "main"
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

    private func splitGGUF(
        name: String,
        index: UInt32,
        count: UInt32,
        includesModelMetadata: Bool
    ) -> Data {
        let stringEntries = includesModelMetadata
            ? [
                ("general.architecture", "llama"),
                ("general.type", "model"),
                ("general.name", name),
            ]
            : []
        var data = Data("GGUF".utf8)
        data.appendLittleEndian(UInt32(3))
        data.appendLittleEndian(UInt64(1))
        data.appendLittleEndian(
            UInt64(stringEntries.count + 3)
        )
        for (key, value) in stringEntries {
            data.appendGGUFString(key)
            data.appendLittleEndian(UInt32(8))
            data.appendGGUFString(value)
        }
        for (key, value) in [
            ("split.no", index),
            ("split.count", count),
            ("split.tensors.count", count),
        ] {
            data.appendGGUFString(key)
            data.appendLittleEndian(UInt32(4))
            data.appendLittleEndian(value)
        }
        data.appendGGUFString("weight.\(index)")
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

private struct StaticModelScopeFileURLResolver:
    ModelScopeFileURLResolving,
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

private actor RangeFixtureModelDownloadTransport:
    ModelDownloadTransporting
{
    private let payload: Data
    private var failuresRemaining: Int
    private let failureByteCount: Int
    private var recordedTransfers: [
        ModelDownloadTransferRequest
    ] = []

    init(
        payload: Data,
        failuresRemaining: Int = 0,
        failureByteCount: Int = 0
    ) {
        self.payload = payload
        self.failuresRemaining = failuresRemaining
        self.failureByteCount = failureByteCount
    }

    func transfer(
        _ transfer: ModelDownloadTransferRequest,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> ModelDownloadTransferResponse {
        recordedTransfers.append(transfer)
        let range = try #require(transfer.expectedRange)
        transfer.metadataRecorder?.record(
            ModelDownloadResponseMetadata(
                etag: "\"fixture-etag\"",
                repositoryCommit: "fixture-commit"
            )
        )

        let start = Int(range.start)
        let requestedEnd = Int(range.end) + 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            let end = min(
                start + max(failureByteCount, 0),
                requestedEnd
            )
            if end > start {
                let partial = payload.subdata(in: start..<end)
                try write(
                    partial,
                    to: transfer.destinationURL,
                    append: range.start > 0
                )
                progress(Int64(end))
            }
            throw ModelDownloadTransportError.transport(
                "fixture connection lost"
            )
        }

        let chunk = payload.subdata(in: start..<requestedEnd)
        try write(
            chunk,
            to: transfer.destinationURL,
            append: range.start > 0
        )
        progress(Int64(requestedEnd))
        return ModelDownloadTransferResponse(
            statusCode: 206,
            contentLength: Int64(chunk.count),
            etag: "\"fixture-etag\"",
            resumedFromByte: range.start,
            receivedBytes: Int64(chunk.count)
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
