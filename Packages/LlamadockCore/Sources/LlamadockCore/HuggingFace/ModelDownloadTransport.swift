import Foundation

public enum ModelDownloadTransportError:
    Error,
    Equatable,
    Sendable
{
    case invalidDestination(URL)
    case existingFileSizeMismatch(
        expected: Int64,
        actual: Int64
    )
    case nonHTTPResponse
    case invalidContentRange(String?)
    case rangeNotHonored(expectedStart: Int64, statusCode: Int)
    case entityTagMismatch(expected: String, actual: String)
    case repositoryCommitMismatch(expected: String, actual: String)
    case insecureRedirect(URL)
    case fileWrite(String)
    case transport(String)
}

extension ModelDownloadTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDestination(let url):
            "Invalid model download destination: \(url.path)"
        case .existingFileSizeMismatch(let expected, let actual):
            "The partial file expected \(expected) bytes but has \(actual)."
        case .nonHTTPResponse:
            "The model download did not return an HTTP response."
        case .invalidContentRange(let value):
            "The model download returned an invalid Content-Range: \(value ?? "missing")."
        case .rangeNotHonored(let expectedStart, let statusCode):
            "The model host did not honor the byte range starting at \(expectedStart) (HTTP \(statusCode))."
        case .entityTagMismatch(let expected, let actual):
            "The model file changed while it was downloading (ETag \(expected) became \(actual))."
        case .repositoryCommitMismatch(let expected, let actual):
            "The model repository changed while it was downloading (revision \(expected) became \(actual))."
        case .insecureRedirect(let url):
            "The model download refused an insecure redirect to \(url.absoluteString)."
        case .fileWrite(let reason):
            "Could not write the partial model file: \(reason)"
        case .transport(let reason):
            "The model download failed: \(reason)"
        }
    }
}

public struct ModelDownloadByteRange:
    Equatable,
    Sendable
{
    public let start: Int64
    public let end: Int64
    public let total: Int64

    public init(start: Int64, end: Int64, total: Int64) {
        self.start = start
        self.end = end
        self.total = total
    }
}

public struct ModelDownloadResponseMetadata:
    Equatable,
    Sendable
{
    public let etag: String?
    public let repositoryCommit: String?

    public init(
        etag: String? = nil,
        repositoryCommit: String? = nil
    ) {
        self.etag = etag
        self.repositoryCommit = repositoryCommit
    }
}

public final class ModelDownloadResponseMetadataRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var etag: String?
    private var repositoryCommit: String?

    public init() {}

    public func record(
        _ metadata: ModelDownloadResponseMetadata
    ) {
        lock.lock()
        etag = metadata.etag ?? etag
        repositoryCommit = metadata.repositoryCommit
            ?? repositoryCommit
        lock.unlock()
    }

    public func snapshot() -> ModelDownloadResponseMetadata {
        lock.lock()
        let metadata = ModelDownloadResponseMetadata(
            etag: etag,
            repositoryCommit: repositoryCommit
        )
        lock.unlock()
        return metadata
    }
}

public struct ModelDownloadTransferRequest:
    Sendable
{
    public let request: URLRequest
    public let destinationURL: URL
    public let existingByteCount: Int64
    public let expectedRange: ModelDownloadByteRange?
    public let expectedETag: String?
    public let expectedRepositoryCommit: String?
    public let metadataRecorder:
        ModelDownloadResponseMetadataRecorder?

    public init(
        request: URLRequest,
        destinationURL: URL,
        existingByteCount: Int64,
        expectedRange: ModelDownloadByteRange? = nil,
        expectedETag: String? = nil,
        expectedRepositoryCommit: String? = nil,
        metadataRecorder:
            ModelDownloadResponseMetadataRecorder? = nil
    ) {
        self.request = request
        self.destinationURL = destinationURL
        self.existingByteCount = existingByteCount
        self.expectedRange = expectedRange
        self.expectedETag = expectedETag
        self.expectedRepositoryCommit =
            expectedRepositoryCommit
        self.metadataRecorder = metadataRecorder
    }
}

public struct ModelDownloadTransferResponse:
    Equatable,
    Sendable
{
    public let statusCode: Int
    public let contentLength: Int64?
    public let etag: String?
    public let resumedFromByte: Int64
    public let receivedBytes: Int64

    public var finalByteCount: Int64 {
        let sum = resumedFromByte.addingReportingOverflow(
            receivedBytes
        )
        return sum.overflow ? Int64.max : sum.partialValue
    }

    public init(
        statusCode: Int,
        contentLength: Int64?,
        etag: String?,
        resumedFromByte: Int64,
        receivedBytes: Int64
    ) {
        self.statusCode = statusCode
        self.contentLength = contentLength
        self.etag = etag
        self.resumedFromByte = resumedFromByte
        self.receivedBytes = receivedBytes
    }
}

public protocol ModelDownloadTransporting: Sendable {
    func transfer(
        _ transfer: ModelDownloadTransferRequest,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> ModelDownloadTransferResponse
}

public struct URLSessionModelDownloadTransport:
    ModelDownloadTransporting,
    @unchecked Sendable
{
    private let fileManager: FileManager

    public init(
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
    }

    public func transfer(
        _ transfer: ModelDownloadTransferRequest,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> ModelDownloadTransferResponse {
        let expectedRangeIsValid: Bool
        if let range = transfer.expectedRange {
            expectedRangeIsValid =
                range.start == transfer.existingByteCount
                    && range.start >= 0
                    && range.end >= range.start
                    && range.total > range.end
        } else {
            expectedRangeIsValid = true
        }
        guard
            transfer.destinationURL.isFileURL,
            transfer.destinationURL.path.hasPrefix("/"),
            transfer.existingByteCount >= 0,
            expectedRangeIsValid
        else {
            throw ModelDownloadTransportError.invalidDestination(
                transfer.destinationURL
            )
        }
        try fileManager.createDirectory(
            at: transfer.destinationURL
                .deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let actualSize: Int64
        if fileManager.fileExists(
            atPath: transfer.destinationURL.path
        ) {
            let attributes = try fileManager.attributesOfItem(
                atPath: transfer.destinationURL.path
            )
            actualSize = (attributes[.size] as? NSNumber)?
                .int64Value ?? -1
        } else {
            actualSize = 0
            guard fileManager.createFile(
                atPath: transfer.destinationURL.path,
                contents: nil
            ) else {
                throw ModelDownloadTransportError.invalidDestination(
                    transfer.destinationURL
                )
            }
        }
        guard actualSize == transfer.existingByteCount else {
            throw ModelDownloadTransportError
                .existingFileSizeMismatch(
                    expected: transfer.existingByteCount,
                    actual: actualSize
                )
        }

        let operation = ModelDownloadTransferOperation(
            transfer: transfer,
            progress: progress
        )
        return try await withTaskCancellationHandler {
            try await operation.start()
        } onCancel: {
            operation.cancel()
        }
    }

    static func sanitizedRedirectRequest(
        initialURL: URL?,
        proposedRequest: URLRequest
    ) throws -> URLRequest {
        guard
            let targetURL = proposedRequest.url,
            targetURL.scheme?.lowercased() == "https"
        else {
            throw ModelDownloadTransportError.insecureRedirect(
                proposedRequest.url
                    ?? URL(filePath: "/invalid-redirect")
            )
        }
        var request = proposedRequest
        if targetURL.host?.lowercased()
            != initialURL?.host?.lowercased()
        {
            request.setValue(
                nil,
                forHTTPHeaderField: "Authorization"
            )
        }
        return request
    }
}

private final class ModelDownloadTransferOperation:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let transfer: ModelDownloadTransferRequest
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()

    private var continuation: CheckedContinuation<
        ModelDownloadTransferResponse,
        any Error
    >?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var statusCode: Int?
    private var contentLength: Int64?
    private var etag: String?
    private var repositoryCommit: String?
    private var effectiveStartByte: Int64
    private var receivedBytes: Int64 = 0
    private var operationError: (any Error)?
    private var shouldReturnHTTPResponse = false
    private var didFinish = false
    private var wasCancelled = false
    private var lastReportedByteCount: Int64

    init(
        transfer: ModelDownloadTransferRequest,
        progress: @escaping @Sendable (Int64) -> Void
    ) {
        self.transfer = transfer
        self.progress = progress
        effectiveStartByte = transfer.existingByteCount
        lastReportedByteCount = transfer.existingByteCount
    }

    func start() async throws -> ModelDownloadTransferResponse {
        do {
            let handle = try FileHandle(
                forWritingTo: transfer.destinationURL
            )
            try handle.seekToEnd()
            self.handle = handle
        } catch {
            throw ModelDownloadTransportError.fileWrite(
                error.localizedDescription
            )
        }

        return try await withCheckedThrowingContinuation {
            continuation in
            lock.lock()
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource =
                7 * 24 * 60 * 60
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            self.session = session
            let task = session.dataTask(
                with: transfer.request
            )
            self.task = task
            let wasCancelled = self.wasCancelled
            lock.unlock()
            if wasCancelled {
                task.cancel()
            } else {
                task.resume()
            }
        }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            fail(ModelDownloadTransportError.nonHTTPResponse)
            completionHandler(.cancel)
            return
        }

        statusCode = response.statusCode
        contentLength = response.expectedContentLength >= 0
            ? response.expectedContentLength
            : nil
        etag = response.value(
            forHTTPHeaderField: "ETag"
        )
        repositoryCommit = response.value(
            forHTTPHeaderField: "X-Repo-Commit"
        ) ?? repositoryCommit
        transfer.metadataRecorder?.record(
            ModelDownloadResponseMetadata(
                etag: etag,
                repositoryCommit: repositoryCommit
            )
        )
        if
            let expected = transfer.expectedETag,
            let etag,
            etag != expected
        {
            fail(
                ModelDownloadTransportError.entityTagMismatch(
                    expected: expected,
                    actual: etag
                )
            )
            completionHandler(.cancel)
            return
        }
        if
            let expected = transfer.expectedRepositoryCommit,
            let repositoryCommit,
            repositoryCommit != expected
        {
            fail(
                ModelDownloadTransportError
                    .repositoryCommitMismatch(
                        expected: expected,
                        actual: repositoryCommit
                    )
            )
            completionHandler(.cancel)
            return
        }

        switch response.statusCode {
        case 200:
            if let expectedRange = transfer.expectedRange {
                guard
                    expectedRange.start == 0,
                    expectedRange.end
                        == expectedRange.total - 1
                else {
                    fail(
                        ModelDownloadTransportError
                            .rangeNotHonored(
                                expectedStart:
                                    expectedRange.start,
                                statusCode: response.statusCode
                            )
                    )
                    completionHandler(.cancel)
                    return
                }
            } else if transfer.existingByteCount > 0 {
                fail(
                    ModelDownloadTransportError
                        .rangeNotHonored(
                            expectedStart:
                                transfer.existingByteCount,
                            statusCode: response.statusCode
                        )
                )
                completionHandler(.cancel)
                return
            }
        case 206:
            let header = response.value(
                forHTTPHeaderField: "Content-Range"
            )
            let contentRange = contentRange(header)
            let isValid: Bool
            if let expected = transfer.expectedRange {
                isValid = contentRange?.start == expected.start
                    && contentRange?.total == expected.total
                    && (contentRange?.end ?? Int64.max)
                        <= expected.end
            } else {
                isValid = contentRange?.start
                    == transfer.existingByteCount
            }
            guard isValid else {
                fail(
                    ModelDownloadTransportError
                        .invalidContentRange(header)
                )
                completionHandler(.cancel)
                return
            }
        default:
            shouldReturnHTTPResponse = true
            completionHandler(.cancel)
            return
        }

        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        do {
            var writeError: (any Error)?
            autoreleasepool {
                do {
                    try handle?.write(contentsOf: data)
                } catch {
                    writeError = error
                }
            }
            if let writeError {
                throw writeError
            }
            let sum = receivedBytes.addingReportingOverflow(
                Int64(data.count)
            )
            guard !sum.overflow else {
                throw ModelDownloadTransportError.fileWrite(
                    "Byte count overflow."
                )
            }
            receivedBytes = sum.partialValue
            let total = effectiveStartByte + receivedBytes
            if total - lastReportedByteCount >= 1_048_576 {
                lastReportedByteCount = total
                progress(total)
            }
        } catch {
            fail(
                error as? ModelDownloadTransportError
                    ?? ModelDownloadTransportError.fileWrite(
                        error.localizedDescription
                    )
            )
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let commit = response.value(
            forHTTPHeaderField: "X-Repo-Commit"
        )
        repositoryCommit = commit ?? repositoryCommit
        transfer.metadataRecorder?.record(
            ModelDownloadResponseMetadata(
                repositoryCommit: repositoryCommit
            )
        )
        if
            let expected = transfer.expectedRepositoryCommit,
            let repositoryCommit,
            repositoryCommit != expected
        {
            fail(
                ModelDownloadTransportError
                    .repositoryCommitMismatch(
                        expected: expected,
                        actual: repositoryCommit
                    )
            )
            completionHandler(nil)
            return
        }
        do {
            completionHandler(
                try URLSessionModelDownloadTransport
                    .sanitizedRedirectRequest(
                        initialURL: transfer.request.url,
                        proposedRequest: request
                    )
            )
        } catch {
            fail(error)
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil

        if let operationError {
            finish(.failure(operationError))
            return
        }
        if shouldReturnHTTPResponse, let statusCode {
            finish(
                .success(
                    ModelDownloadTransferResponse(
                        statusCode: statusCode,
                        contentLength: contentLength,
                        etag: etag,
                        resumedFromByte: effectiveStartByte,
                        receivedBytes: 0
                    )
                )
            )
            return
        }
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(
                    .failure(
                        ModelDownloadTransportError.transport(
                            error.localizedDescription
                        )
                    )
                )
            }
            return
        }
        guard let statusCode else {
            finish(
                .failure(
                    ModelDownloadTransportError.nonHTTPResponse
                )
            )
            return
        }

        progress(effectiveStartByte + receivedBytes)
        finish(
            .success(
                ModelDownloadTransferResponse(
                    statusCode: statusCode,
                    contentLength: contentLength,
                    etag: etag,
                    resumedFromByte: effectiveStartByte,
                    receivedBytes: receivedBytes
                )
            )
        )
    }

    private func contentRange(
        _ value: String?
    ) -> ModelDownloadByteRange? {
        guard
            let value,
            value.lowercased().hasPrefix("bytes ")
        else {
            return nil
        }
        let components = value.dropFirst(6).split(
            separator: "/",
            maxSplits: 1
        )
        guard
            components.count == 2,
            let total = Int64(components[1]),
            let range = components.first
        else {
            return nil
        }
        let bounds = range.split(
            separator: "-",
            maxSplits: 1
        )
        guard
            bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1]),
            start >= 0,
            end >= start,
            total > end
        else {
            return nil
        }
        return ModelDownloadByteRange(
            start: start,
            end: end,
            total: total
        )
    }

    private func fail(
        _ error: any Error
    ) {
        lock.lock()
        if operationError == nil {
            operationError = error
        }
        lock.unlock()
    }

    private func finish(
        _ result: Result<
            ModelDownloadTransferResponse,
            any Error
        >
    ) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
