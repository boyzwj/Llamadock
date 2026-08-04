import Foundation
import Testing
@testable import LlamadockCore

@Suite("Real model download transport smoke")
struct RealModelDownloadTransportSmokeTests {
    @Test("appends a validated HTTP Range response")
    func resumesFromLocalFixture() async throws {
        guard
            let value = ProcessInfo.processInfo.environment[
                "LLAMADOCK_RANGE_SMOKE_URL"
            ],
            let url = URL(string: value)
        else {
            return
        }

        let payload = Data(
            "GGUF-llamadock-range-smoke-payload".utf8
        )
        let prefixLength = 8
        let destination = FileManager.default
            .temporaryDirectory.appending(
                path: "LlamadockRangeSmoke-\(UUID().uuidString).part"
            )
        defer {
            try? FileManager.default.removeItem(
                at: destination
            )
        }
        try payload.prefix(prefixLength).write(
            to: destination
        )

        var request = URLRequest(url: url)
        request.setValue(
            "bytes=\(prefixLength)-\(payload.count - 1)",
            forHTTPHeaderField: "Range"
        )
        let response = try await URLSessionModelDownloadTransport()
            .transfer(
                ModelDownloadTransferRequest(
                    request: request,
                    destinationURL: destination,
                    existingByteCount: Int64(prefixLength),
                    expectedRange: ModelDownloadByteRange(
                        start: Int64(prefixLength),
                        end: Int64(payload.count - 1),
                        total: Int64(payload.count)
                    )
                )
            ) { _ in }

        #expect(response.statusCode == 206)
        #expect(
            response.resumedFromByte == Int64(prefixLength)
        )
        #expect(
            response.finalByteCount == Int64(payload.count)
        )
        #expect(
            try Data(contentsOf: destination) == payload
        )
    }

    @Test("preserves the partial file when the server ignores Range")
    func preservesPartialWhenRangeIsIgnored() async throws {
        guard let baseURL = smokeURL else {
            return
        }
        let payload = expectedPayload
        let prefixLength = 8
        let destination = temporaryPart()
        defer { try? FileManager.default.removeItem(at: destination) }
        try payload.prefix(prefixLength).write(to: destination)

        var request = URLRequest(
            url: baseURL.deletingLastPathComponent().appending(
                path: "no-range.gguf"
            )
        )
        request.setValue(
            "bytes=\(prefixLength)-\(payload.count - 1)",
            forHTTPHeaderField: "Range"
        )
        await #expect(throws: ModelDownloadTransportError.self) {
            _ = try await URLSessionModelDownloadTransport().transfer(
                ModelDownloadTransferRequest(
                    request: request,
                    destinationURL: destination,
                    existingByteCount: Int64(prefixLength),
                    expectedRange: ModelDownloadByteRange(
                        start: Int64(prefixLength),
                        end: Int64(payload.count - 1),
                        total: Int64(payload.count)
                    )
                )
            ) { _ in }
        }

        #expect(
            try Data(contentsOf: destination)
                == Data(payload.prefix(prefixLength))
        )
    }

    @Test("rejects a mismatched Content-Range before appending")
    func rejectsInvalidContentRange() async throws {
        guard let baseURL = smokeURL else {
            return
        }
        let payload = expectedPayload
        let prefixLength = 8
        let destination = temporaryPart()
        defer { try? FileManager.default.removeItem(at: destination) }
        let prefix = Data(payload.prefix(prefixLength))
        try prefix.write(to: destination)

        var request = URLRequest(
            url: baseURL.deletingLastPathComponent().appending(
                path: "bad-range.gguf"
            )
        )
        request.setValue(
            "bytes=\(prefixLength)-\(payload.count - 1)",
            forHTTPHeaderField: "Range"
        )

        await #expect(throws: ModelDownloadTransportError.self) {
            _ = try await URLSessionModelDownloadTransport()
                .transfer(
                    ModelDownloadTransferRequest(
                        request: request,
                        destinationURL: destination,
                        existingByteCount: Int64(prefixLength),
                        expectedRange: ModelDownloadByteRange(
                            start: Int64(prefixLength),
                            end: Int64(payload.count - 1),
                            total: Int64(payload.count)
                        )
                    )
                ) { _ in }
        }
        #expect(try Data(contentsOf: destination) == prefix)
    }

    private var smokeURL: URL? {
        guard
            let value = ProcessInfo.processInfo.environment[
                "LLAMADOCK_RANGE_SMOKE_URL"
            ]
        else {
            return nil
        }
        return URL(string: value)
    }

    private var expectedPayload: Data {
        Data("GGUF-llamadock-range-smoke-payload".utf8)
    }

    private func temporaryPart() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "LlamadockRangeSmoke-\(UUID().uuidString).part"
        )
    }
}
