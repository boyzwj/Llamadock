import Foundation

public enum RuntimeArchiveDownloadError:
    Error,
    Equatable,
    Sendable
{
    case untrustedDownloadURL(URL)
    case invalidDestination(URL)
    case destinationAlreadyExists(URL)
    case httpStatus(Int)
    case contentLengthMismatch(expected: Int64, actual: Int64)
    case transport(String)
}

extension RuntimeArchiveDownloadError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .untrustedDownloadURL(let url):
            "The runtime asset URL is not an official llama.cpp release URL: \(url.absoluteString)"
        case .invalidDestination(let url):
            "The runtime archive destination is invalid: \(url.path)"
        case .destinationAlreadyExists(let url):
            "The runtime archive destination already exists: \(url.path)"
        case .httpStatus(let statusCode):
            "The runtime archive download returned HTTP \(statusCode)."
        case .contentLengthMismatch(let expected, let actual):
            "The runtime archive expected \(expected) bytes but received \(actual)."
        case .transport(let reason):
            "The runtime archive download failed: \(reason)"
        }
    }
}

public struct RuntimeDownloadTransportResponse: Sendable {
    public let temporaryFileURL: URL
    public let statusCode: Int
    public let contentLength: Int64?

    public init(
        temporaryFileURL: URL,
        statusCode: Int,
        contentLength: Int64?
    ) {
        self.temporaryFileURL = temporaryFileURL
        self.statusCode = statusCode
        self.contentLength = contentLength
    }
}

public protocol RuntimeDownloadTransporting: Sendable {
    func download(
        for request: URLRequest
    ) async throws -> RuntimeDownloadTransportResponse
}

public struct URLSessionRuntimeDownloadTransport:
    RuntimeDownloadTransporting,
    @unchecked Sendable
{
    private let session: URLSession
    private let fileManager: FileManager

    public init(
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.fileManager = fileManager
    }

    public func download(
        for request: URLRequest
    ) async throws -> RuntimeDownloadTransportResponse {
        let (temporaryURL, response) = try await session.download(
            for: request
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.nonHTTPResponse
        }

        let ownedTemporaryURL = fileManager.temporaryDirectory
            .appending(
                path: "LlamadockRuntimeDownload-\(UUID().uuidString).part",
                directoryHint: .notDirectory
            )
        try fileManager.moveItem(
            at: temporaryURL,
            to: ownedTemporaryURL
        )

        let expectedLength = httpResponse.expectedContentLength
        return RuntimeDownloadTransportResponse(
            temporaryFileURL: ownedTemporaryURL,
            statusCode: httpResponse.statusCode,
            contentLength: expectedLength >= 0
                ? expectedLength
                : nil
        )
    }
}

public protocol RuntimeArchiveDownloading: Sendable {
    func download(
        asset: GitHubRuntimeReleaseAsset,
        destinationURL: URL
    ) async throws -> URL
}

public struct URLSessionRuntimeArchiveDownloader:
    RuntimeArchiveDownloading,
    @unchecked Sendable
{
    private let transport: any RuntimeDownloadTransporting
    private let fileManager: FileManager

    public init(
        transport: any RuntimeDownloadTransporting =
            URLSessionRuntimeDownloadTransport(),
        fileManager: FileManager = .default
    ) {
        self.transport = transport
        self.fileManager = fileManager
    }

    public func download(
        asset: GitHubRuntimeReleaseAsset,
        destinationURL: URL
    ) async throws -> URL {
        guard isTrustedOfficialURL(asset.downloadURL) else {
            throw RuntimeArchiveDownloadError.untrustedDownloadURL(
                asset.downloadURL
            )
        }
        guard
            destinationURL.isFileURL,
            destinationURL.path.hasPrefix("/"),
            destinationURL.lastPathComponent == "asset.part"
        else {
            throw RuntimeArchiveDownloadError.invalidDestination(
                destinationURL
            )
        }
        guard !fileManager.fileExists(
            atPath: destinationURL.path
        ) else {
            throw RuntimeArchiveDownloadError.destinationAlreadyExists(
                destinationURL
            )
        }

        var request = URLRequest(url: asset.downloadURL)
        request.httpMethod = "GET"
        request.setValue(
            "application/octet-stream",
            forHTTPHeaderField: "Accept"
        )
        request.setValue(
            "LlamaDock",
            forHTTPHeaderField: "User-Agent"
        )

        let response: RuntimeDownloadTransportResponse
        do {
            response = try await transport.download(for: request)
        } catch {
            throw RuntimeArchiveDownloadError.transport(
                diagnosticDescription(error)
            )
        }
        defer {
            try? fileManager.removeItem(
                at: response.temporaryFileURL
            )
        }

        guard response.statusCode == 200 else {
            throw RuntimeArchiveDownloadError.httpStatus(
                response.statusCode
            )
        }
        if let contentLength = response.contentLength {
            guard contentLength == asset.size else {
                throw RuntimeArchiveDownloadError
                    .contentLengthMismatch(
                        expected: asset.size,
                        actual: contentLength
                    )
            }
        }

        let attributes = try fileManager.attributesOfItem(
            atPath: response.temporaryFileURL.path
        )
        let actualSize = (attributes[.size] as? NSNumber)?
            .int64Value
            ?? -1
        guard actualSize == asset.size else {
            throw RuntimeArchiveDownloadError
                .contentLengthMismatch(
                    expected: asset.size,
                    actual: actualSize
                )
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.moveItem(
            at: response.temporaryFileURL,
            to: destinationURL
        )
        return destinationURL
    }

    private func isTrustedOfficialURL(
        _ url: URL
    ) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "github.com"
            && url.path.hasPrefix(
                "/ggml-org/llama.cpp/releases/download/"
            )
    }

    private func diagnosticDescription(
        _ error: any Error
    ) -> String {
        let localized = error.localizedDescription
        let typed = String(describing: error)
        return localized == typed
            ? localized
            : "\(localized) [\(typed)]"
    }
}
