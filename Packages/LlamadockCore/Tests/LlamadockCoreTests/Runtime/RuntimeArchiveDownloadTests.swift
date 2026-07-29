import Foundation
import Testing
@testable import LlamadockCore

@Suite("Managed runtime archive download")
struct RuntimeArchiveDownloadTests {
    @Test("downloads an official asset into the transaction directory")
    func downloadsOfficialAsset() async throws {
        let temporarySource = makeTemporaryURL("source")
        let destination = makeTemporaryURL("asset.part")
        defer {
            try? FileManager.default.removeItem(at: temporarySource)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(
                at: temporarySource.deletingLastPathComponent()
            )
            try? FileManager.default.removeItem(
                at: destination.deletingLastPathComponent()
            )
        }
        let payload = Data("official runtime".utf8)
        try FileManager.default.createDirectory(
            at: temporarySource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try payload.write(to: temporarySource)
        let transport = FakeRuntimeDownloadTransport(
            result: .success(
                RuntimeDownloadTransportResponse(
                    temporaryFileURL: temporarySource,
                    statusCode: 200,
                    contentLength: Int64(payload.count)
                )
            )
        )
        let downloader = URLSessionRuntimeArchiveDownloader(
            transport: transport
        )
        let asset = makeAsset(size: Int64(payload.count))

        let downloadedURL = try await downloader.download(
            asset: asset,
            destinationURL: destination
        )

        #expect(downloadedURL == destination)
        #expect(try Data(contentsOf: destination) == payload)
        #expect(
            !FileManager.default.fileExists(
                atPath: temporarySource.path
            )
        )

        let request = try #require(
            await transport.requests().first
        )
        #expect(request.url == asset.downloadURL)
        #expect(request.httpMethod == "GET")
        #expect(
            request.value(forHTTPHeaderField: "User-Agent")
                == "LlamaDock"
        )
        #expect(
            request.value(forHTTPHeaderField: "Accept")
                == "application/octet-stream"
        )
    }

    @Test("rejects a response length mismatch before installation")
    func rejectsLengthMismatch() async throws {
        let temporarySource = makeTemporaryURL("source")
        let destination = makeTemporaryURL("asset.part")
        defer {
            try? FileManager.default.removeItem(at: temporarySource)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(
                at: temporarySource.deletingLastPathComponent()
            )
            try? FileManager.default.removeItem(
                at: destination.deletingLastPathComponent()
            )
        }
        try FileManager.default.createDirectory(
            at: temporarySource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("short".utf8).write(to: temporarySource)
        let downloader = URLSessionRuntimeArchiveDownloader(
            transport: FakeRuntimeDownloadTransport(
                result: .success(
                    RuntimeDownloadTransportResponse(
                        temporaryFileURL: temporarySource,
                        statusCode: 200,
                        contentLength: 5
                    )
                )
            )
        )

        await #expect(
            throws: RuntimeArchiveDownloadError.contentLengthMismatch(
                expected: 10,
                actual: 5
            )
        ) {
            try await downloader.download(
                asset: makeAsset(size: 10),
                destinationURL: destination
            )
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.path
            )
        )
    }

    @Test("rejects non-official asset download URLs")
    func rejectsUntrustedURL() async {
        let destination = makeTemporaryURL("asset.part")
        let downloader = URLSessionRuntimeArchiveDownloader(
            transport: FakeRuntimeDownloadTransport(
                result: .failure(FakeDownloadError.unused)
            )
        )
        let url = URL(
            string: "https://example.com/runtime.tar.gz"
        )!
        let asset = GitHubRuntimeReleaseAsset(
            id: 1,
            name: "llama-b10176-bin-macos-arm64.tar.gz",
            downloadURL: url,
            size: 10,
            contentType: "application/gzip",
            digest: nil
        )

        await #expect(
            throws: RuntimeArchiveDownloadError
                .untrustedDownloadURL(url)
        ) {
            try await downloader.download(
                asset: asset,
                destinationURL: destination
            )
        }
    }

    @Test("verifies SHA-256 and file size")
    func verifiesDigest() throws {
        let archiveURL = makeTemporaryURL("archive")
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(
                at: archiveURL.deletingLastPathComponent()
            )
        }
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("abc".utf8).write(to: archiveURL)
        let asset = makeAsset(
            size: 3,
            digest: "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        let result = try RuntimeArchiveVerifier().verify(
            archiveURL: archiveURL,
            asset: asset
        )

        #expect(
            result
                == RuntimeArchiveVerification(
                    byteCount: 3,
                    sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                )
        )
    }

    @Test("rejects a mismatched SHA-256")
    func rejectsDigestMismatch() throws {
        let archiveURL = makeTemporaryURL("archive")
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(
                at: archiveURL.deletingLastPathComponent()
            )
        }
        try FileManager.default.createDirectory(
            at: archiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("abc".utf8).write(to: archiveURL)

        #expect(
            throws: RuntimeArchiveVerificationError.digestMismatch(
                expected: String(repeating: "0", count: 64),
                actual: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            )
        ) {
            try RuntimeArchiveVerifier().verify(
                archiveURL: archiveURL,
                asset: makeAsset(
                    size: 3,
                    digest: "sha256:\(String(repeating: "0", count: 64))"
                )
            )
        }
    }

    private func makeAsset(
        size: Int64,
        digest: String? = nil
    ) -> GitHubRuntimeReleaseAsset {
        GitHubRuntimeReleaseAsset(
            id: 1,
            name: "llama-b10176-bin-macos-arm64.tar.gz",
            downloadURL: URL(
                string: "https://github.com/ggml-org/llama.cpp/releases/download/b10176/llama-b10176-bin-macos-arm64.tar.gz"
            )!,
            size: size,
            contentType: "application/gzip",
            digest: digest
        )
    }

    private func makeTemporaryURL(
        _ name: String
    ) -> URL {
        FileManager.default.temporaryDirectory
            .appending(
                path: "LlamadockDownloadTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            .appending(
                path: name,
                directoryHint: .notDirectory
            )
    }
}

private enum FakeDownloadError: Error {
    case unused
}

private actor FakeRuntimeDownloadTransport:
    RuntimeDownloadTransporting
{
    private let result: Result<RuntimeDownloadTransportResponse, Error>
    private var recordedRequests: [URLRequest] = []

    init(
        result: Result<RuntimeDownloadTransportResponse, Error>
    ) {
        self.result = result
    }

    func download(
        for request: URLRequest
    ) async throws -> RuntimeDownloadTransportResponse {
        recordedRequests.append(request)
        return try result.get()
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}
