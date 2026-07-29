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
        case .insecureRedirect(let url):
            "The model download refused an insecure redirect to \(url.absoluteString)."
        case .fileWrite(let reason):
            "Could not write the partial model file: \(reason)"
        case .transport(let reason):
            "The model download failed: \(reason)"
        }
    }
}

public struct ModelDownloadTransferRequest:
    Sendable
{
    public let request: URLRequest
    public let destinationURL: URL
    public let existingByteCount: Int64

    public init(
        request: URLRequest,
        destinationURL: URL,
        existingByteCount: Int64
    ) {
        self.request = request
        self.destinationURL = destinationURL
        self.existingByteCount = existingByteCount
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
        guard
            transfer.destinationURL.isFileURL,
            transfer.destinationURL.path.hasPrefix("/"),
            transfer.existingByteCount >= 0
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

        switch response.statusCode {
        case 200:
            if transfer.existingByteCount > 0 {
                do {
                    try handle?.truncate(atOffset: 0)
                    try handle?.seek(toOffset: 0)
                    effectiveStartByte = 0
                    lastReportedByteCount = 0
                } catch {
                    fail(
                        ModelDownloadTransportError.fileWrite(
                            error.localizedDescription
                        )
                    )
                    completionHandler(.cancel)
                    return
                }
            }
        case 206:
            let header = response.value(
                forHTTPHeaderField: "Content-Range"
            )
            guard
                contentRangeStart(header)
                    == transfer.existingByteCount
            else {
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
            try handle?.write(contentsOf: data)
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

    private func contentRangeStart(
        _ value: String?
    ) -> Int64? {
        guard
            let value,
            value.lowercased().hasPrefix("bytes "),
            let range = value.dropFirst(6).split(
                separator: "/",
                maxSplits: 1
            ).first,
            let start = range.split(
                separator: "-",
                maxSplits: 1
            ).first
        else {
            return nil
        }
        return Int64(start)
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
