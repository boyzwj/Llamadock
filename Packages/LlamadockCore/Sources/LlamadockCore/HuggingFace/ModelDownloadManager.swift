import CryptoKit
import Foundation

public enum ModelDownloadManagerError:
    Error,
    Equatable,
    Sendable
{
    case invalidRequest(String)
    case jobNotFound(UUID)
    case invalidState(UUID, ModelDownloadState)
    case destinationConflict(URL)
    case httpStatus(Int)
    case retryLimitExceeded(attempts: Int, reason: String)
    case contentLengthMismatch(expected: Int64, actual: Int64)
    case fileSizeMismatch(
        path: String,
        expected: Int64,
        actual: Int64
    )
    case checksumMismatch(
        path: String,
        expected: String,
        actual: String
    )
    case invalidGGUF(path: String, reason: String)
}

extension ModelDownloadManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason):
            "Invalid model download request: \(reason)"
        case .jobNotFound(let id):
            "Download job not found: \(id.uuidString)."
        case .invalidState(let id, let state):
            "Download job \(id.uuidString) cannot be changed while \(state.rawValue)."
        case .destinationConflict(let url):
            "A model already exists at \(url.path). LlamaDock will not overwrite it."
        case .httpStatus(let status):
            "The model download returned HTTP \(status)."
        case .retryLimitExceeded(let attempts, let reason):
            "The model download still failed after \(attempts) automatic attempts. Partial progress was preserved. Last error: \(reason)"
        case .contentLengthMismatch(let expected, let actual):
            "The response expected \(expected) bytes but received \(actual)."
        case .fileSizeMismatch(let path, let expected, let actual):
            "The downloaded file \(path) expected \(expected) bytes but has \(actual)."
        case .checksumMismatch(let path, let expected, let actual):
            "The downloaded file \(path) failed SHA-256 verification: expected \(expected), got \(actual)."
        case .invalidGGUF(let path, let reason):
            "The downloaded file \(path) is not a valid GGUF: \(reason)"
        }
    }
}

public struct ModelDownloadRetryPolicy:
    Equatable,
    Sendable
{
    public static let `default` = ModelDownloadRetryPolicy()

    public let chunkSizeBytes: Int64
    public let maximumAttemptsPerChunk: Int
    public let baseDelayNanoseconds: UInt64
    public let maximumDelayNanoseconds: UInt64

    public init(
        chunkSizeBytes: Int64 = 256 * 1_048_576,
        maximumAttemptsPerChunk: Int = 8,
        baseDelayNanoseconds: UInt64 = 1_000_000_000,
        maximumDelayNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.chunkSizeBytes = max(chunkSizeBytes, 1)
        self.maximumAttemptsPerChunk = max(
            maximumAttemptsPerChunk,
            1
        )
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.maximumDelayNanoseconds = max(
            maximumDelayNanoseconds,
            baseDelayNanoseconds
        )
    }

    func delayNanoseconds(
        beforeAttempt attempt: Int
    ) -> UInt64 {
        guard attempt > 1 else {
            return 0
        }
        var delay = baseDelayNanoseconds
        for _ in 2..<attempt {
            let doubled = delay.multipliedReportingOverflow(
                by: 2
            )
            delay = doubled.overflow
                ? maximumDelayNanoseconds
                : min(
                    doubled.partialValue,
                    maximumDelayNanoseconds
                )
        }
        return min(delay, maximumDelayNanoseconds)
    }
}

public actor ModelDownloadManager {
    private let directories: ApplicationDirectories
    private let store: any ModelDownloadStoring
    private let transport: any ModelDownloadTransporting
    private let urlResolver: any HuggingFaceFileURLResolving
    private let modelScopeURLResolver:
        any ModelScopeFileURLResolving
    private let tokenStore: any HuggingFaceTokenStoring
    private let metadataReader: GGUFMetadataReader
    private let fileManager: FileManager
    private let retryPolicy: ModelDownloadRetryPolicy
    private let retryDelay:
        @Sendable (UInt64) async throws -> Void

    private var jobs: [UUID: ModelDownloadJob] = [:]
    private var orderedJobIDs: [UUID] = []
    private var activeJobID: UUID?
    private var activeTask: Task<Void, Never>?
    private var didRestore = false
    private var lastPersistedByteCounts: [String: Int64] = [:]
    private var activeProgressGenerations: [String: UUID] = [:]

    public init(
        directories: ApplicationDirectories,
        store: (any ModelDownloadStoring)? = nil,
        transport: any ModelDownloadTransporting =
            URLSessionModelDownloadTransport(),
        urlResolver: any HuggingFaceFileURLResolving =
            HuggingFaceHubClient(),
        modelScopeURLResolver:
            any ModelScopeFileURLResolving =
                ModelScopeHubClient(),
        tokenStore: any HuggingFaceTokenStoring =
            KeychainHuggingFaceTokenStore(),
        metadataReader: GGUFMetadataReader =
            GGUFMetadataReader(),
        fileManager: FileManager = .default,
        retryPolicy: ModelDownloadRetryPolicy = .default,
        retryDelay: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.directories = directories
        self.store = store ?? JSONModelDownloadStore(
            fileURL: directories.downloadState
        )
        self.transport = transport
        self.urlResolver = urlResolver
        self.modelScopeURLResolver = modelScopeURLResolver
        self.tokenStore = tokenStore
        self.metadataReader = metadataReader
        self.fileManager = fileManager
        self.retryPolicy = retryPolicy
        self.retryDelay = retryDelay
    }

    public func restore() async throws {
        guard !didRestore else {
            return
        }
        try fileManager.createDirectory(
            at: directories.downloadJobs,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: directories.models,
            withIntermediateDirectories: true
        )

        let restored = try await store.loadJobs()
        jobs = Dictionary(
            uniqueKeysWithValues: restored.map {
                ($0.id, $0)
            }
        )
        orderedJobIDs = restored.map(\.id)
        for id in orderedJobIDs {
            try reconcileRestoredJob(id: id)
        }
        didRestore = true
        try await persist()
    }

    public func snapshot() -> ModelDownloadSnapshot {
        ModelDownloadSnapshot(
            jobs: orderedJobIDs.compactMap { jobs[$0] },
            activeJobID: activeJobID
        )
    }

    @discardableResult
    public func enqueue(
        _ request: ModelDownloadRequest,
        now: Date = Date()
    ) async throws -> UUID {
        try await ensureRestored()
        try validate(request)

        let id = UUID()
        let destination = destinationRelativeDirectory(
            for: request
        )
        let finalURL = directories.models.appending(
            path: destination,
            directoryHint: .isDirectory
        )
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw ModelDownloadManagerError
                .destinationConflict(finalURL)
        }
        guard !jobs.values.contains(where: {
            $0.destinationRelativeDirectory == destination
                && $0.state != .cancelled
        }) else {
            throw ModelDownloadManagerError.invalidRequest(
                "This artifact already has a download job."
            )
        }

        let job = ModelDownloadJob(
            id: id,
            source: request.source,
            repositoryID: request.reference.repositoryID,
            revision: request.reference.revision,
            displayName: request.displayName,
            quantization: request.quantization,
            destinationRelativeDirectory: destination,
            files: request.files.map {
                ModelDownloadFile(
                    artifactID: $0.artifactID,
                    artifactDisplayName:
                        $0.artifactDisplayName,
                    role: $0.role,
                    repositoryPath: $0.repositoryPath,
                    expectedSize: $0.expectedSize,
                    expectedSHA256: $0.expectedSHA256
                )
            },
            state: .queued,
            error: nil,
            createdAt: now,
            updatedAt: now
        )
        jobs[id] = job
        orderedJobIDs.append(id)
        try await persist()
        scheduleNext()
        return id
    }

    public func pause(
        id: UUID,
        now: Date = Date()
    ) async throws {
        try await ensureRestored()
        guard var job = jobs[id] else {
            throw ModelDownloadManagerError.jobNotFound(id)
        }
        guard [
            .queued,
            .resolving,
            .downloading,
        ].contains(job.state) else {
            throw ModelDownloadManagerError.invalidState(
                id,
                job.state
            )
        }
        job.state = .paused
        job.error = nil
        job.updatedAt = now
        jobs[id] = job
        try await persist()
        if activeJobID == id {
            activeTask?.cancel()
        }
    }

    public func resume(
        id: UUID,
        now: Date = Date()
    ) async throws {
        try await ensureRestored()
        guard var job = jobs[id] else {
            throw ModelDownloadManagerError.jobNotFound(id)
        }
        guard [.paused, .failed].contains(job.state) else {
            throw ModelDownloadManagerError.invalidState(
                id,
                job.state
            )
        }
        let finalURL = finalDirectory(for: job)
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            if try importedFilesAreComplete(job) {
                job.state = .completed
                job.error = nil
                job.files = job.files.map { file in
                    var file = file
                    file.receivedBytes = file.expectedSize
                    file.isVerified = true
                    return file
                }
                job.updatedAt = now
                jobs[id] = job
                try await persist()
                return
            }
            throw ModelDownloadManagerError
                .destinationConflict(finalURL)
        }
        for index in job.files.indices
        where job.files[index].restartReason != nil {
            let url = partURL(job: job, file: job.files[index])
            let existingSize = try fileSizeIfPresent(at: url)
            if
                job.files[index].restartReason == "invalidGGUF",
                existingSize == job.files[index].expectedSize
            {
                // Re-run structural verification before discarding a full,
                // checksum-valid file. This also recovers downloads rejected
                // by older builds that treated secondary GGUF splits as
                // standalone models.
                job.files[index].receivedBytes = existingSize
                job.files[index].isVerified = false
                job.files[index].restartReason = nil
                continue
            }
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            job.files[index].receivedBytes = 0
            job.files[index].etag = nil
            job.files[index].isVerified = false
            job.files[index].restartReason = nil
        }
        job.state = .queued
        job.error = nil
        job.updatedAt = now
        jobs[id] = job
        try await persist()
        scheduleNext()
    }

    public func cancel(
        id: UUID,
        now: Date = Date()
    ) async throws {
        try await ensureRestored()
        guard var job = jobs[id] else {
            throw ModelDownloadManagerError.jobNotFound(id)
        }
        guard !job.state.isTerminal else {
            throw ModelDownloadManagerError.invalidState(
                id,
                job.state
            )
        }
        job.state = .cancelled
        job.error = nil
        job.updatedAt = now
        jobs[id] = job
        try await persist()

        if activeJobID == id {
            activeTask?.cancel()
        } else {
            cleanupTransaction(id: id)
        }
    }

    public func discardFailed(
        id: UUID,
        now: Date = Date()
    ) async throws {
        try await discard(id: id, now: now)
    }

    public func discard(
        id: UUID,
        now: Date = Date()
    ) async throws {
        try await ensureRestored()
        guard var job = jobs[id] else {
            throw ModelDownloadManagerError.jobNotFound(id)
        }
        guard [.failed, .cancelled].contains(job.state) else {
            throw ModelDownloadManagerError.invalidState(
                id,
                job.state
            )
        }

        let finalURL = finalDirectory(for: job)
        if fileManager.fileExists(atPath: finalURL.path) {
            if try importedFilesAreComplete(job) {
                job.state = .completed
                job.error = nil
                job.files = job.files.map { file in
                    var file = file
                    file.receivedBytes = file.expectedSize
                    file.isVerified = true
                    return file
                }
                job.updatedAt = now
                jobs[id] = job
                cleanupTransaction(id: id)
                try await persist()
                return
            }
            try fileManager.removeItem(at: finalURL)
        }

        let transactionURL = jobDirectory(id: id)
        if fileManager.fileExists(atPath: transactionURL.path) {
            try fileManager.removeItem(at: transactionURL)
        }

        jobs.removeValue(forKey: id)
        orderedJobIDs.removeAll { $0 == id }
        try await persist()
    }

    public func suspendForTermination(
        now: Date = Date()
    ) async {
        guard didRestore else {
            return
        }
        var shouldCancelActive = false
        for id in orderedJobIDs {
            guard var job = jobs[id] else {
                continue
            }
            if [
                .queued,
                .resolving,
                .downloading,
            ].contains(job.state) {
                job.state = .paused
                job.error = nil
                job.updatedAt = now
                jobs[id] = job
                if activeJobID == id {
                    shouldCancelActive = true
                }
            }
        }
        try? await persist()
        let task = activeTask
        if shouldCancelActive {
            task?.cancel()
        }
        await task?.value
    }

    private func ensureRestored() async throws {
        if !didRestore {
            try await restore()
        }
    }

    private func scheduleNext() {
        guard activeTask == nil else {
            return
        }
        guard let id = orderedJobIDs.first(
            where: { jobs[$0]?.state == .queued }
        ) else {
            return
        }
        activeJobID = id
        activeTask = Task { [weak self] in
            await self?.run(id: id)
        }
    }

    private func run(
        id: UUID
    ) async {
        do {
            try await transition(id: id, to: .resolving)
            guard let initialJob = jobs[id] else {
                throw ModelDownloadManagerError.jobNotFound(id)
            }
            let token: String?
            switch initialJob.source {
            case .huggingFace:
                token = try tokenStore.token()
            case .modelScope:
                token = nil
            }
            for fileID in initialJob.files.map(\.id) {
                try Task.checkCancellation()
                try await downloadFile(
                    jobID: id,
                    fileID: fileID,
                    token: token
                )
            }

            try Task.checkCancellation()
            try await transition(id: id, to: .verifying)
            try await verify(jobID: id)
            try Task.checkCancellation()
            try await transition(id: id, to: .importing)
            try importDownloadedFiles(jobID: id)
            cleanupTransaction(id: id)
            try await transition(id: id, to: .completed)
        } catch is CancellationError {
            if jobs[id]?.state == .cancelled {
                cleanupTransaction(id: id)
            }
        } catch {
            if
                jobs[id]?.state != .paused,
                jobs[id]?.state != .cancelled
            {
                await fail(
                    id: id,
                    error: error
                )
            }
        }
        activeTask = nil
        activeJobID = nil
        scheduleNext()
    }

    private func downloadFile(
        jobID: UUID,
        fileID: String,
        token: String?
    ) async throws {
        guard
            let initialJob = jobs[jobID],
            let initialFile = initialJob.files.first(
                where: { $0.id == fileID }
            )
        else {
            throw ModelDownloadManagerError.jobNotFound(jobID)
        }
        let destinationURL = partURL(
            job: initialJob,
            file: initialFile
        )
        var existingSize = try fileSizeIfPresent(
            at: destinationURL
        )
        guard existingSize <= initialFile.expectedSize else {
            throw ModelDownloadManagerError.fileSizeMismatch(
                path: initialFile.repositoryPath,
                expected: initialFile.expectedSize,
                actual: existingSize
            )
        }
        updateFile(jobID: jobID, fileID: fileID) {
            $0.receivedBytes = existingSize
            $0.isVerified = false
        }
        try await persist()
        guard existingSize < initialFile.expectedSize else {
            return
        }

        if jobs[jobID]?.state != .downloading {
            try await transition(
                id: jobID,
                to: .downloading
            )
        }

        while existingSize < initialFile.expectedSize {
            try Task.checkCancellation()
            let remaining = initialFile.expectedSize
                - existingSize
            let chunkLength = min(
                retryPolicy.chunkSizeBytes,
                remaining
            )
            let chunkEnd = existingSize + chunkLength - 1
            var attempt = 0

            while existingSize <= chunkEnd {
                try Task.checkCancellation()
                attempt += 1
                let attemptStart = existingSize
                let recorder =
                    ModelDownloadResponseMetadataRecorder()
                var completedResponse = false
                let progressGeneration = UUID()
                activeProgressGenerations[fileID] =
                    progressGeneration

                do {
                    guard
                        let job = jobs[jobID],
                        let file = job.files.first(
                            where: { $0.id == fileID }
                        )
                    else {
                        throw ModelDownloadManagerError
                            .jobNotFound(jobID)
                    }
                    let byteRange = ModelDownloadByteRange(
                        start: attemptStart,
                        end: chunkEnd,
                        total: file.expectedSize
                    )
                    let request = try makeTransferRequest(
                        job: job,
                        file: file,
                        byteRange: byteRange,
                        token: token,
                        destinationURL: destinationURL,
                        metadataRecorder: recorder
                    )
                    let response = try await transport.transfer(
                        request
                    ) { [weak self] byteCount in
                        Task {
                            await self?.recordProgress(
                                jobID: jobID,
                                fileID: fileID,
                                byteCount: byteCount,
                                generation: progressGeneration
                            )
                        }
                    }
                    if
                        activeProgressGenerations[fileID]
                            == progressGeneration
                    {
                        activeProgressGenerations[fileID] = nil
                    }
                    completedResponse = true
                    try await applyResponseMetadata(
                        recorder.snapshot(),
                        fallbackETag: response.etag,
                        jobID: jobID,
                        fileID: fileID,
                        existingByteCount: attemptStart
                    )
                    try validate(
                        response: response,
                        expectedRange: byteRange
                    )
                    let actualSize = try fileSizeIfPresent(
                        at: destinationURL
                    )
                    guard
                        actualSize == response.finalByteCount,
                        actualSize > attemptStart,
                        actualSize <= chunkEnd + 1
                    else {
                        throw ModelDownloadManagerError
                            .fileSizeMismatch(
                                path: file.repositoryPath,
                                expected: chunkEnd + 1,
                                actual: actualSize
                            )
                    }
                    existingSize = actualSize
                    updateFile(
                        jobID: jobID,
                        fileID: fileID
                    ) {
                        $0.receivedBytes = actualSize
                        $0.isVerified = false
                        $0.restartReason = nil
                    }
                    try await persist()
                    attempt = 0
                } catch {
                    if
                        activeProgressGenerations[fileID]
                            == progressGeneration
                    {
                        activeProgressGenerations[fileID] = nil
                    }
                    var attemptError: any Error = error
                    do {
                        try await applyResponseMetadata(
                            recorder.snapshot(),
                            fallbackETag: nil,
                            jobID: jobID,
                            fileID: fileID,
                            existingByteCount: attemptStart
                        )
                    } catch {
                        attemptError = error
                    }
                    if attemptError is CancellationError {
                        throw attemptError
                    }
                    if completedResponse {
                        try truncateFile(
                            at: destinationURL,
                            to: attemptStart
                        )
                    }
                    let actualSize = try fileSizeIfPresent(
                        at: destinationURL
                    )
                    guard
                        actualSize >= attemptStart,
                        actualSize <= chunkEnd + 1
                    else {
                        try truncateFile(
                            at: destinationURL,
                            to: attemptStart
                        )
                        throw ModelDownloadManagerError
                            .fileSizeMismatch(
                                path: initialFile.repositoryPath,
                                expected: chunkEnd + 1,
                                actual: actualSize
                            )
                    }
                    existingSize = actualSize
                    let madeProgress = actualSize > attemptStart
                    updateFile(
                        jobID: jobID,
                        fileID: fileID
                    ) {
                        $0.receivedBytes = actualSize
                        $0.isVerified = false
                    }
                    try await persist()

                    let retryable = isRetryable(attemptError)
                    guard retryable else {
                        throw attemptError
                    }
                    guard
                        attempt
                            < retryPolicy
                                .maximumAttemptsPerChunk
                    else {
                        throw ModelDownloadManagerError
                            .retryLimitExceeded(
                                attempts: attempt,
                                reason: diagnosticDescription(
                                    attemptError
                                )
                            )
                    }
                    let delay = retryPolicy.delayNanoseconds(
                        beforeAttempt: attempt + 1
                    )
                    if delay > 0 {
                        try await retryDelay(delay)
                    }
                    if madeProgress {
                        attempt = 0
                    }
                }
            }
        }
    }

    private func makeTransferRequest(
        job: ModelDownloadJob,
        file: ModelDownloadFile,
        byteRange: ModelDownloadByteRange,
        token: String?,
        destinationURL: URL,
        metadataRecorder:
            ModelDownloadResponseMetadataRecorder
    ) throws -> ModelDownloadTransferRequest {
        let reference = HuggingFaceRepositoryReference(
            repositoryID: job.repositoryID,
            revision: job.resolvedRevision ?? job.revision,
            quantization: job.quantization
        )
        let url: URL
        switch job.source {
        case .huggingFace:
            url = try urlResolver.resolveURL(
                reference: reference,
                filePath: file.repositoryPath
            )
        case .modelScope:
            url = try modelScopeURLResolver.resolveURL(
                reference: reference,
                filePath: file.repositoryPath
            )
        }
        guard
            url.scheme?.lowercased() == "https",
            url.host != nil,
            url.user == nil,
            url.password == nil
        else {
            throw ModelDownloadManagerError.invalidRequest(
                "Resolved model file URLs must use HTTPS without embedded credentials."
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "identity",
            forHTTPHeaderField: "Accept-Encoding"
        )
        request.setValue(
            "LlamaDock",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "bytes=\(byteRange.start)-\(byteRange.end)",
            forHTTPHeaderField: "Range"
        )
        if
            byteRange.start > 0,
            let etag = file.etag
        {
            request.setValue(
                etag,
                forHTTPHeaderField: "If-Range"
            )
        }
        if let token, !token.isEmpty {
            request.setValue(
                "Bearer \(token)",
                forHTTPHeaderField: "Authorization"
            )
        }

        return ModelDownloadTransferRequest(
            request: request,
            destinationURL: destinationURL,
            existingByteCount: byteRange.start,
            expectedRange: byteRange,
            expectedETag: byteRange.start > 0
                ? file.etag
                : nil,
            expectedRepositoryCommit: job.resolvedRevision,
            metadataRecorder: metadataRecorder
        )
    }

    private func applyResponseMetadata(
        _ metadata: ModelDownloadResponseMetadata,
        fallbackETag: String?,
        jobID: UUID,
        fileID: String,
        existingByteCount: Int64
    ) async throws {
        guard
            var job = jobs[jobID],
            let fileIndex = job.files.firstIndex(
                where: { $0.id == fileID }
            )
        else {
            throw ModelDownloadManagerError.jobNotFound(jobID)
        }
        var didChange = false
        if
            job.source == .huggingFace,
            let commit = metadata.repositoryCommit
        {
            if
                let existing = job.resolvedRevision,
                existing != commit
            {
                throw ModelDownloadTransportError
                    .repositoryCommitMismatch(
                        expected: existing,
                        actual: commit
                    )
            }
            if job.resolvedRevision == nil {
                job.resolvedRevision = commit
                didChange = true
            }
        }
        if let etag = metadata.etag ?? fallbackETag {
            if
                existingByteCount > 0,
                let existing = job.files[fileIndex].etag,
                existing != etag
            {
                throw ModelDownloadTransportError
                    .entityTagMismatch(
                        expected: existing,
                        actual: etag
                    )
            }
            if job.files[fileIndex].etag != etag {
                job.files[fileIndex].etag = etag
                didChange = true
            }
        }
        if didChange {
            job.updatedAt = Date()
            jobs[jobID] = job
            try await persist()
        }
    }

    private func isRetryable(
        _ error: any Error
    ) -> Bool {
        if error is CancellationError {
            return false
        }
        if let error = error as? ModelDownloadTransportError {
            switch error {
            case
                .transport,
                .nonHTTPResponse,
                .invalidContentRange,
                .rangeNotHonored:
                return true
            case
                .invalidDestination,
                .existingFileSizeMismatch,
                .entityTagMismatch,
                .repositoryCommitMismatch,
                .insecureRedirect,
                .fileWrite:
                return false
            }
        }
        if
            case .httpStatus(let status) =
                error as? ModelDownloadManagerError
        {
            return [408, 425, 429, 500, 502, 503, 504]
                .contains(status)
        }
        return false
    }

    private func truncateFile(
        at url: URL,
        to byteCount: Int64
    ) throws {
        guard byteCount >= 0 else {
            throw ModelDownloadManagerError.invalidRequest(
                "A partial model file cannot have a negative size."
            )
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(byteCount))
        try handle.synchronize()
    }

    private func transition(
        id: UUID,
        to state: ModelDownloadState,
        now: Date = Date()
    ) async throws {
        guard var job = jobs[id] else {
            throw ModelDownloadManagerError.jobNotFound(id)
        }
        job.state = state
        job.error = nil
        job.updatedAt = now
        jobs[id] = job
        try await persist()
    }

    private func fail(
        id: UUID,
        error: any Error,
        now: Date = Date()
    ) async {
        guard var job = jobs[id] else {
            return
        }
        job.state = .failed
        job.error = LogRedactor.redact(
            diagnosticDescription(error)
        )
        job.updatedAt = now
        jobs[id] = job
        try? await persist()
    }

    private func recordProgress(
        jobID: UUID,
        fileID: String,
        byteCount: Int64,
        generation: UUID
    ) async {
        guard
            var job = jobs[jobID],
            job.state == .downloading,
            activeProgressGenerations[fileID] == generation,
            let index = job.files.firstIndex(
                where: { $0.id == fileID }
            )
        else {
            return
        }
        let bounded = min(
            max(byteCount, 0),
            job.files[index].expectedSize
        )
        let monotonic = max(
            bounded,
            job.files[index].receivedBytes
        )
        job.files[index].receivedBytes = monotonic
        job.updatedAt = Date()
        jobs[jobID] = job

        let persistenceKey = "\(jobID.uuidString):\(fileID)"
        let persisted = lastPersistedByteCounts[persistenceKey]
            ?? 0
        if
            monotonic == job.files[index].expectedSize
                || monotonic - persisted >= 16 * 1_048_576
        {
            lastPersistedByteCounts[persistenceKey] = monotonic
            try? await persist()
        }
    }

    private func verify(
        jobID: UUID
    ) async throws {
        guard let job = jobs[jobID] else {
            throw ModelDownloadManagerError.jobNotFound(jobID)
        }

        // Verify transport integrity for every file before interpreting the
        // GGUF shard set. A split may keep model-level metadata only in its
        // first file, but every file still has an independent size/hash.
        for file in job.files {
            let url = partURL(job: job, file: file)
            let actualSize = try fileSizeIfPresent(at: url)
            guard actualSize == file.expectedSize else {
                throw ModelDownloadManagerError.fileSizeMismatch(
                    path: file.repositoryPath,
                    expected: file.expectedSize,
                    actual: actualSize
                )
            }
            if let expected = file.expectedSHA256 {
                let actual = try await sha256(of: url)
                guard
                    actual.caseInsensitiveCompare(expected)
                        == .orderedSame
                else {
                    updateFile(
                        jobID: jobID,
                        fileID: file.id
                    ) {
                        $0.receivedBytes = file.expectedSize
                        $0.isVerified = false
                        $0.restartReason = "checksumMismatch"
                    }
                    throw ModelDownloadManagerError
                        .checksumMismatch(
                            path: file.repositoryPath,
                            expected: expected.lowercased(),
                            actual: actual
                        )
                }
            }
        }

        var seenArtifactIDs = Set<String>()
        let artifactIDs = job.files.compactMap { file in
            seenArtifactIDs.insert(file.artifactID).inserted
                ? file.artifactID
                : nil
        }
        for artifactID in artifactIDs {
            let files = job.files.filter {
                $0.artifactID == artifactID
            }.sorted {
                $0.repositoryPath.localizedStandardCompare(
                    $1.repositoryPath
                ) == .orderedAscending
            }
            var parsed: [(ModelDownloadFile, GGUFMetadata)] = []
            var primaryMetadata: GGUFMetadata?

            for file in files {
                let url = partURL(job: job, file: file)
                do {
                    let metadata: GGUFMetadata
                    if let primaryMetadata {
                        metadata = try metadataReader.readSplitShard(
                            from: url,
                            inheritingArchitecture:
                                primaryMetadata.architecture
                        )
                    } else {
                        metadata = try metadataReader.read(from: url)
                        primaryMetadata = metadata
                    }
                    parsed.append((file, metadata))
                } catch {
                    updateFile(
                        jobID: jobID,
                        fileID: file.id
                    ) {
                        $0.receivedBytes = file.expectedSize
                        $0.isVerified = false
                        $0.restartReason = "invalidGGUF"
                    }
                    throw ModelDownloadManagerError.invalidGGUF(
                        path: file.repositoryPath,
                        reason: diagnosticDescription(error)
                    )
                }
            }

            if let failure = splitValidationFailure(parsed) {
                guard let file = files.first else {
                    continue
                }
                updateFile(jobID: jobID, fileID: file.id) {
                    $0.receivedBytes = file.expectedSize
                    $0.isVerified = false
                    $0.restartReason = "invalidGGUF"
                }
                throw ModelDownloadManagerError.invalidGGUF(
                    path: file.repositoryPath,
                    reason: failure
                )
            }

            for file in files {
                updateFile(jobID: jobID, fileID: file.id) {
                    $0.receivedBytes = file.expectedSize
                    $0.isVerified = true
                    $0.restartReason = nil
                }
            }
            try await persist()
        }
    }

    private func splitValidationFailure(
        _ files: [(file: ModelDownloadFile, metadata: GGUFMetadata)]
    ) -> String? {
        guard let primary = files.first?.metadata else {
            return "The GGUF artifact contains no files."
        }
        guard let primaryShard = primary.shard else {
            if files.dropFirst().contains(where: {
                $0.metadata.shard != nil
            }) {
                return "The GGUF split is missing its primary shard metadata."
            }
            return nil
        }

        guard
            primaryShard.zeroBasedIndex == 0,
            primaryShard.count == UInt64(files.count)
        else {
            return "The GGUF split count does not match the downloaded shard set."
        }
        let shards = files.compactMap { $0.metadata.shard }
        guard shards.count == files.count else {
            return "One or more GGUF files are missing split metadata."
        }
        guard shards.allSatisfy({
            $0.count == primaryShard.count
        }) else {
            return "The GGUF files disagree about the split count."
        }
        guard
            Set(shards.map(\.zeroBasedIndex))
                == Set(0..<primaryShard.count)
        else {
            return "The GGUF split has a duplicate or missing shard index."
        }
        guard files.allSatisfy({
            $0.metadata.architecture == primary.architecture
        }) else {
            return "The GGUF files disagree about the model architecture."
        }
        if let totalTensorCount = primaryShard.totalTensorCount {
            let sum = files.map { $0.metadata.tensorCount }.reduce(
                UInt64(0)
            ) { partial, count in
                let result = partial.addingReportingOverflow(count)
                return result.overflow ? UInt64.max : result.partialValue
            }
            guard sum == totalTensorCount else {
                return "The GGUF split tensor count does not match its metadata."
            }
        }
        return nil
    }

    private func importDownloadedFiles(
        jobID: UUID
    ) throws {
        guard let job = jobs[jobID] else {
            throw ModelDownloadManagerError.jobNotFound(jobID)
        }
        let finalURL = finalDirectory(for: job)
        if fileManager.fileExists(atPath: finalURL.path) {
            guard try importedFilesAreComplete(job) else {
                throw ModelDownloadManagerError
                    .destinationConflict(finalURL)
            }
            return
        }

        let preparedURL = jobDirectory(id: jobID).appending(
            path: "prepared",
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: preparedURL.path) {
            try fileManager.removeItem(at: preparedURL)
        }
        try fileManager.createDirectory(
            at: preparedURL,
            withIntermediateDirectories: true
        )
        for file in job.files {
            let source = partURL(job: job, file: file)
            let destination = preparedURL.appending(
                path: file.repositoryPath,
                directoryHint: .notDirectory
            )
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(
                at: source,
                to: destination
            )
        }

        try fileManager.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw ModelDownloadManagerError
                .destinationConflict(finalURL)
        }
        try fileManager.moveItem(
            at: preparedURL,
            to: finalURL
        )
    }

    private func reconcileRestoredJob(
        id: UUID
    ) throws {
        guard var job = jobs[id] else {
            return
        }
        let finalURL = finalDirectory(for: job)
        if fileManager.fileExists(atPath: finalURL.path) {
            if try importedFilesAreComplete(job) {
                job.state = .completed
                job.error = nil
                job.files = job.files.map { file in
                    var file = file
                    file.receivedBytes = file.expectedSize
                    file.isVerified = true
                    return file
                }
                jobs[id] = job
                cleanupTransaction(id: id)
                return
            }
            job.state = .failed
            job.error = """
                The imported artifact directory is incomplete. \
                LlamaDock will not overwrite it.
                """
            jobs[id] = job
            cleanupTransaction(id: id)
            return
        }

        for index in job.files.indices {
            let size = try fileSizeIfPresent(
                at: partURL(
                    job: job,
                    file: job.files[index]
                )
            )
            job.files[index].receivedBytes = min(
                max(size, 0),
                job.files[index].expectedSize
            )
            if size != job.files[index].expectedSize {
                job.files[index].isVerified = false
            }
        }
        if !job.state.isTerminal {
            job.state = .paused
            job.error = "Interrupted by app exit. Resume to continue."
        }
        jobs[id] = job
    }

    private func validate(
        _ request: ModelDownloadRequest
    ) throws {
        let repositorySegments = request.reference.repositoryID
            .split(
                separator: "/",
                omittingEmptySubsequences: false
            )
        guard
            repositorySegments.count == 2,
            repositorySegments.allSatisfy({
                isSafeIdentifier(String($0))
            }),
            !request.reference.revision.isEmpty,
            !request.files.isEmpty,
            request.files.contains(where: { $0.role == .main }),
            Set(
                request.files.map {
                    "\($0.artifactID):\($0.repositoryPath)"
                }
            ).count == request.files.count,
            Set(request.files.map(\.repositoryPath)).count
                == request.files.count
        else {
            throw ModelDownloadManagerError.invalidRequest(
                "A safe repository, revision, main artifact, and unique files are required."
            )
        }
        for file in request.files {
            guard
                isSafeRelativePath(file.repositoryPath),
                file.expectedSize > 0,
                isValidSHA256(file.expectedSHA256)
            else {
                throw ModelDownloadManagerError.invalidRequest(
                    "File paths, sizes, or checksums are invalid."
                )
            }
        }
        let artifactGroups = Dictionary(
            grouping: request.files,
            by: \.artifactID
        )
        for group in artifactGroups.values {
            guard
                Set(group.map(\.role)).count == 1,
                Set(group.map(\.artifactDisplayName)).count == 1
            else {
                throw ModelDownloadManagerError.invalidRequest(
                    "Each artifact ID must have one role and display name."
                )
            }
        }
        let artifactIDsByRole = Dictionary(
            grouping: artifactGroups.values,
            by: { $0[0].role }
        ).mapValues { groups in
            Set(groups.compactMap(\.first?.artifactID))
        }
        guard
            artifactIDsByRole[.main]?.count == 1,
            (artifactIDsByRole[.mmproj]?.count ?? 0) <= 1,
            (artifactIDsByRole[.draft]?.count ?? 0) <= 1
        else {
            throw ModelDownloadManagerError.invalidRequest(
                "A download must contain one main artifact and at most one companion of each role."
            )
        }
    }

    private func validate(
        response: ModelDownloadTransferResponse,
        expectedRange: ModelDownloadByteRange
    ) throws {
        let acceptsFullResponse =
            expectedRange.start == 0
                && expectedRange.end == expectedRange.total - 1
                && response.statusCode == 200
        guard response.statusCode == 206 || acceptsFullResponse else {
            throw ModelDownloadManagerError.httpStatus(
                response.statusCode
            )
        }
        if let contentLength = response.contentLength {
            guard contentLength == response.receivedBytes else {
                throw ModelDownloadManagerError
                    .contentLengthMismatch(
                        expected: contentLength,
                        actual: response.receivedBytes
                    )
            }
        }
        guard response.resumedFromByte == expectedRange.start else {
            throw ModelDownloadManagerError
                .contentLengthMismatch(
                    expected: expectedRange.start,
                    actual: response.resumedFromByte
                )
        }
        let maximumFinalSize = expectedRange.end + 1
        guard
            response.finalByteCount > expectedRange.start,
            response.finalByteCount <= maximumFinalSize
        else {
            throw ModelDownloadManagerError
                .contentLengthMismatch(
                    expected: maximumFinalSize,
                    actual: response.finalByteCount
                )
        }
    }

    private func destinationRelativeDirectory(
        for request: ModelDownloadRequest
    ) -> String {
        let repository = request.reference.repositoryID.split(
            separator: "/"
        ).map(String.init)
        let revision = filesystemComponent(
            request.reference.revision
        )
        let artifactSeed = request.files.map(\.artifactID)
            .sorted()
            .joined(separator: "|")
        let artifact = filesystemComponent(
            request.displayName,
            disambiguator: artifactSeed
        )
        return [
            request.source.storageDirectoryComponent,
            repository[0],
            repository[1],
            revision,
            artifact,
        ].joined(separator: "/")
    }

    private func filesystemComponent(
        _ value: String,
        disambiguator: String? = nil
    ) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._")
        )
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars.prefix(80) {
            scalars.append(
                allowed.contains(scalar) ? scalar : "_"
            )
        }
        var component = String(scalars)
            .trimmingCharacters(
                in: CharacterSet(charactersIn: "._")
            )
        if component.isEmpty {
            component = "artifact"
        }
        if
            component != value
                || disambiguator != nil
        {
            let digest = SHA256.hash(
                data: Data(
                    (disambiguator ?? value).utf8
                )
            ).prefix(6).map {
                String(format: "%02x", $0)
            }.joined()
            component += "-\(digest)"
        }
        return component
    }

    private func jobDirectory(
        id: UUID
    ) -> URL {
        directories.downloadJobs.appending(
            path: id.uuidString,
            directoryHint: .isDirectory
        )
    }

    private func partURL(
        job: ModelDownloadJob,
        file: ModelDownloadFile
    ) -> URL {
        jobDirectory(id: job.id)
            .appending(
                path: "payload",
                directoryHint: .isDirectory
            )
            .appending(
                path: file.repositoryPath + ".part",
                directoryHint: .notDirectory
            )
    }

    private func finalDirectory(
        for job: ModelDownloadJob
    ) -> URL {
        directories.models.appending(
            path: job.destinationRelativeDirectory,
            directoryHint: .isDirectory
        )
    }

    private func importedFilesAreComplete(
        _ job: ModelDownloadJob
    ) throws -> Bool {
        let directory = finalDirectory(for: job)
        for file in job.files {
            let url = directory.appending(
                path: file.repositoryPath,
                directoryHint: .notDirectory
            )
            guard
                try fileSizeIfPresent(at: url)
                    == file.expectedSize
            else {
                return false
            }
        }
        return true
    }

    private func fileSizeIfPresent(
        at url: URL
    ) throws -> Int64 {
        guard fileManager.fileExists(atPath: url.path) else {
            return 0
        }
        let values = try url.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw ModelDownloadManagerError
                .invalidRequest(
                    "A download path is not a regular file."
                )
        }
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        return (attributes[.size] as? NSNumber)?
            .int64Value ?? -1
    }

    private func sha256(
        of url: URL
    ) async throws -> String {
        try await Task.detached {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var hasher = SHA256()
            while
                let data = try handle.read(
                    upToCount: 1_048_576
                ),
                !data.isEmpty
            {
                hasher.update(data: data)
            }
            return hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        }.value
    }

    private func updateFile(
        jobID: UUID,
        fileID: String,
        update: (inout ModelDownloadFile) -> Void
    ) {
        guard
            var job = jobs[jobID],
            let index = job.files.firstIndex(
                where: { $0.id == fileID }
            )
        else {
            return
        }
        update(&job.files[index])
        job.updatedAt = Date()
        jobs[jobID] = job
    }

    private func cleanupTransaction(
        id: UUID
    ) {
        let url = jobDirectory(id: id)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func persist() async throws {
        try await store.saveJobs(
            orderedJobIDs.compactMap { jobs[$0] }
        )
    }

    private func diagnosticDescription(
        _ error: any Error
    ) -> String {
        if
            let localized = error as? any LocalizedError,
            let description = localized.errorDescription,
            !description.isEmpty
        {
            return description
        }
        return String(describing: error)
    }
}

private func isSafeIdentifier(
    _ value: String
) -> Bool {
    !value.isEmpty
        && value != "."
        && value != ".."
        && value.count <= 128
        && value.allSatisfy {
            $0.isLetter
                || $0.isNumber
                || $0 == "_"
                || $0 == "-"
                || $0 == "."
        }
}

private func isSafeRelativePath(
    _ path: String
) -> Bool {
    guard !path.hasPrefix("/") else {
        return false
    }
    let segments = path.split(
        separator: "/",
        omittingEmptySubsequences: false
    )
    return !segments.isEmpty
        && segments.allSatisfy {
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && !$0.contains("\\")
        }
}

private func isValidSHA256(
    _ value: String?
) -> Bool {
    guard let value else {
        return true
    }
    return value.count == 64
        && value.allSatisfy(\.isHexDigit)
}
